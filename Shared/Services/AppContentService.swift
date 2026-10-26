import Foundation
import Observation
import CryptoKit

struct AppContentResponse: Sendable {
    let data: Data
    let status: Int
    let etag: String?
}

protocol AppContentTransport: Sendable {
    func fetch(id: String?, etag: String?) async throws -> AppContentResponse
}

private enum AppContentError: Error { case invalid, status(Int) }

private final class NoAppContentRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Public content never carries an account token, uses cookies or follows redirects.
actor HTTPAppContentTransport: AppContentTransport {
    func fetch(id: String?, etag: String?) async throws -> AppContentResponse {
        var url = WorkspaceConfiguration.serviceURL.appendingPathComponent("api/native/v1/app-content")
        if let id { url.appendPathComponent(id) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NoAppContentRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url else { throw AppContentError.invalid }
        let tag = response.value(forHTTPHeaderField: "ETag").flatMap { value in
            value.utf8.count <= 160 && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ? value : nil
        }
        if response.statusCode == 304 { return AppContentResponse(data: Data(), status: 304, etag: tag) }
        guard response.statusCode == 200 else { throw AppContentError.status(response.statusCode) }
        let limit = id == nil ? 64 * 1_024 : PublishedContentRules.packageLimit
        guard response.expectedContentLength <= Int64(limit), response.mimeType == "application/json" else {
            throw AppContentError.invalid
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw WorkspaceFailure.tooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        return AppContentResponse(data: data, status: 200, etag: tag)
    }
}

private struct AppContentCache: Codable, Sendable {
    var manifest: PublishedContentManifest
    var packages: [String: Data]
    var etag: String?
    var lastChecked: Date
    var lastUpdated: Date
}

private struct AppContentSnapshot: @unchecked Sendable {
    var cache: AppContentCache
    var payloads: [String: PublishedContentPayload]
}

/// All JSON, hashing and file work runs away from UI rendering. Only a complete,
/// validated snapshot can replace the last usable cache.
private actor AppContentWorker {
    func restore(from url: URL) -> AppContentSnapshot? {
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 6 * 1_024 * 1_024 else { return nil }
            let cache = try JSONDecoder().decode(AppContentCache.self, from: Data(contentsOf: url))
            try PublishedContentRules.validate(cache.manifest)
            var payloads: [String: PublishedContentPayload] = [:]
            for entry in cache.manifest.entries where Self.supports(entry) {
                guard let data = cache.packages[entry.id] else { throw AppContentError.invalid }
                payloads[entry.id] = try verified(data, entry: entry)
            }
            return AppContentSnapshot(cache: cache, payloads: payloads)
        } catch { return nil }
    }

    func manifest(from data: Data) throws -> PublishedContentManifest {
        guard data.count <= 64 * 1_024 else { throw WorkspaceFailure.tooLarge }
        let manifest = try JSONDecoder().decode(PublishedContentManifest.self, from: data)
        try PublishedContentRules.validate(manifest)
        return manifest
    }

    func verified(_ data: Data, entry: PublishedContentEntry) throws -> PublishedContentPayload {
        guard data.count == entry.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw AppContentError.invalid
        }
        return try PublishedContentRules.decodePackage(data, entry: entry)
    }

    func save(_ snapshot: AppContentSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot.cache)
        guard data.count <= 6 * 1_024 * 1_024 else { throw WorkspaceFailure.tooLarge }
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func supports(_ entry: PublishedContentEntry) -> Bool {
        entry.minimumContentVersion <= PublishedContentRules.currentContentVersion
            && ["course", "tutorial", "announcement"].contains(entry.kind)
    }
}

@MainActor @Observable final class AppContentService {
    static let shared = AppContentService()
    private(set) var isRefreshing = false
    private(set) var lastChecked: Date?
    private(set) var lastUpdated: Date?
    private(set) var message: String?
    private var snapshot: AppContentSnapshot?
    @ObservationIgnored private let transport: any AppContentTransport
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let worker = AppContentWorker()
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var preparation: Task<AppContentSnapshot?, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?

    init(transport: any AppContentTransport = HTTPAppContentTransport(), cacheURL: URL? = nil) {
        self.transport = transport
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkshopPublishedContent", isDirectory: true).appendingPathComponent("content-v1.json")
    }

    var availableEntries: [PublishedContentEntry] {
        snapshot?.cache.manifest.entries.filter { snapshot?.payloads[$0.id] != nil } ?? []
    }
    var announcements: [PublishedAnnouncement] {
        availableEntries.compactMap { entry in
            if case .announcement(let value) = snapshot?.payloads[entry.id] { return value }
            return nil
        }
    }
    func tutorial(_ id: String) -> PublishedTutorial? {
        if case .tutorial(let value) = snapshot?.payloads[id] { return value }
        return nil
    }
    func course(_ id: String) -> CourseEdition? {
        guard case .course(let value) = snapshot?.payloads[id],
              let entry = snapshot?.cache.manifest.entries.first(where: { $0.id == id }),
              let updated = lastUpdated else { return nil }
        return CourseEdition(course: value, revision: entry.version, updatedAt: updated)
    }
    var demoCourses: [CourseEdition] {
        availableEntries.filter { $0.kind == "course" && $0.id.hasPrefix("demo-") }.compactMap { course($0.id) }
    }

    /// Cache-only: safe to share across startup, tutorials and course entries.
    func prepare() async {
        guard !prepared else { return }
        let task: Task<AppContentSnapshot?, Never>
        if let preparation { task = preparation }
        else {
            let worker = worker, url = cacheURL
            task = Task(priority: .utility) { await worker.restore(from: url) }
            preparation = task
        }
        let value = await task.value
        guard !prepared else { return }
        snapshot = value
        lastChecked = value?.cache.lastChecked
        lastUpdated = value?.cache.lastUpdated
        prepared = true; preparation = nil
    }

    /// The foreground poll and the manual button share one request. Push wakeups
    /// can call this same entry later; they never carry executable app code.
    func refresh(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        await prepare()
        if let refreshTask { await refreshTask.value; return }
        let previousAttempt = lastAttempt ?? lastChecked
        if !force, let previousAttempt {
            let elapsed = Date().timeIntervalSince(previousAttempt)
            if elapsed >= 0 && elapsed < 15 * 60 { return }
        }
        let task = Task { @MainActor in await self.performRefresh() }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        isRefreshing = true; lastAttempt = Date()
        defer { isRefreshing = false; refreshTask = nil }
        do {
            let response = try await transport.fetch(id: nil, etag: snapshot?.cache.etag)
            let checked = Date()
            if response.status == 304, var current = snapshot {
                current.cache.lastChecked = checked
                try await worker.save(current, to: cacheURL)
                snapshot = current; lastChecked = checked; message = WorkspaceLocalization.string("内容已是最新。")
                return
            }
            guard response.status == 200 else { throw AppContentError.invalid }
            let manifest = try await worker.manifest(from: response.data)
            if manifest.entries.contains(where: {
                !AppContentWorker.supports($0) && snapshot?.payloads[$0.id] != nil
            }) {
                // Keep the complete compatible publication and its ETag. A later
                // compatible release must still be fetched rather than hidden by 304.
                lastChecked = checked
                message = WorkspaceLocalization.string("部分新内容需要更新工作坊，现有内容仍可使用。")
                return
            }
            var packages: [String: Data] = [:]
            var payloads: [String: PublishedContentPayload] = [:]
            for entry in manifest.entries where AppContentWorker.supports(entry) {
                if let previous = snapshot?.cache.manifest.entries.first(where: { $0.id == entry.id }) {
                    // Intentional rollbacks publish the old payload under a new version.
                    guard previous.version <= entry.version,
                          previous.version != entry.version || previous.sha256 == entry.sha256 else {
                        throw AppContentError.invalid
                    }
                    if previous == entry, let data = snapshot?.cache.packages[entry.id], let payload = snapshot?.payloads[entry.id] {
                        packages[entry.id] = data; payloads[entry.id] = payload
                        continue
                    }
                }
                let package = try await transport.fetch(id: entry.id, etag: nil)
                guard package.status == 200 else { throw AppContentError.invalid }
                payloads[entry.id] = try await worker.verified(package.data, entry: entry)
                packages[entry.id] = package.data
            }
            let changed = snapshot?.cache.manifest.revision != manifest.revision
            let updated = changed ? checked : lastUpdated ?? checked
            let next = AppContentSnapshot(cache: AppContentCache(manifest: manifest, packages: packages,
                etag: response.etag, lastChecked: checked, lastUpdated: updated), payloads: payloads)
            try await worker.save(next, to: cacheURL)
            snapshot = next; lastChecked = checked; lastUpdated = updated
            message = changed ? WorkspaceLocalization.string("内容已更新，下次打开时即可使用。") : WorkspaceLocalization.string("内容已是最新。")
        } catch is CancellationError {
            // Keep the last usable package if background work is interrupted.
        } catch {
            message = WorkspaceLocalization.string("暂时无法检查更新，已保留现有内容。")
        }
    }
}
