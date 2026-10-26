import Foundation

struct PublishedContentManifest: Codable, Equatable, Sendable {
    var protocolVersion: String
    var revision: String
    var entries: [PublishedContentEntry]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case revision, entries
    }
}

struct PublishedContentEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var version: Int
    var minimumContentVersion: Int
    var sha256: String
    var byteCount: Int
}

struct PublishedTutorial: Codable, Equatable, Sendable {
    var pages: [PublishedTutorialPage]
}

struct PublishedTutorialPage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var sectionTitle: String? = nil
    var symbol: String? = nil
}

struct PublishedAnnouncement: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var message: String
}

enum PublishedContentPayload: Equatable, @unchecked Sendable {
    case course(CourseDocument)
    case tutorial(PublishedTutorial)
    case announcement(PublishedAnnouncement)
}

enum PublishedContentRules {
    static let protocolVersion = "WORKSHOP-CONTENT/1"
    static let currentContentVersion = 1
    static let packageLimit = 1_024 * 1_024
    static let totalLimit = 4 * packageLimit

    static func validate(_ manifest: PublishedContentManifest) throws {
        try require(manifest.protocolVersion == protocolVersion, "不支持的内容更新协议。")
        try require(validDigest(manifest.revision), "内容更新版本无效。")
        try require(manifest.entries.count <= 32, "内容更新条目过多。")
        var ids = Set<String>()
        var totalBytes = 0
        for entry in manifest.entries {
            try validateEntry(entry)
            try require(ids.insert(entry.id).inserted, "内容更新的 ID 不可重复。")
            try require(totalBytes <= totalLimit - entry.byteCount, "内容更新超过大小上限。")
            totalBytes += entry.byteCount
        }
    }

    /// Digest verification belongs to the transport layer and uses the original response bytes.
    static func decodePackage(_ data: Data, entry: PublishedContentEntry) throws -> PublishedContentPayload {
        try validateEntry(entry)
        try require(data.count == entry.byteCount && data.count <= packageLimit, "内容包大小不符。")
        let decoder = JSONDecoder()
        let header: PackageHeader
        do { header = try decoder.decode(PackageHeader.self, from: data) }
        catch { throw WorkspaceFailure.invalid("内容包格式无效。") }
        try require(header.protocolVersion == protocolVersion && header.id == entry.id
                    && header.kind == entry.kind && header.version == entry.version
                    && header.minimumContentVersion == entry.minimumContentVersion, "内容包与更新清单不一致。")
        try require(entry.minimumContentVersion <= currentContentVersion, "此内容需要更新工作坊后使用。")
        do {
            switch entry.kind {
            case "course":
                let value = try decoder.decode(PackagePayload<CourseDocument>.self, from: data).payload
                try CourseValidation.validate(value)
                return .course(value)
            case "tutorial":
                let value = try decoder.decode(PackagePayload<PublishedTutorial>.self, from: data).payload
                try validateTutorial(value)
                return .tutorial(value)
            case "announcement":
                let value = try decoder.decode(PackagePayload<PublishedAnnouncement>.self, from: data).payload
                try require(validID(value.id) && value.id == entry.id, "公告 ID 无效。")
                try bounded(value.title, max: 240, required: true)
                try bounded(value.message, max: 4_000, required: true)
                return .announcement(value)
            default:
                throw WorkspaceFailure.invalid("当前版本暂不支持这类内容。")
            }
        } catch let error as WorkspaceFailure { throw error }
        catch { throw WorkspaceFailure.invalid("内容包格式无效。") }
    }

    private static func validateEntry(_ entry: PublishedContentEntry) throws {
        try require(validID(entry.id) && validKind(entry.kind), "内容更新标识无效。")
        try require(entry.version > 0 && entry.minimumContentVersion > 0, "内容更新版本无效。")
        try require(validDigest(entry.sha256), "内容更新摘要无效。")
        try require((1...packageLimit).contains(entry.byteCount), "内容包超过大小上限。")
    }

    private static func validateTutorial(_ tutorial: PublishedTutorial) throws {
        try require((1...12).contains(tutorial.pages.count), "使用指南应包含 1 至 12 页。")
        var ids = Set<String>()
        for page in tutorial.pages {
            try require(validID(page.id) && ids.insert(page.id).inserted, "使用指南的页面 ID 无效或重复。")
            try bounded(page.title, max: 240, required: true)
            try bounded(page.subtitle, max: 2_000, required: true)
            if let sectionTitle = page.sectionTitle { try bounded(sectionTitle, max: 120, required: true) }
            if let symbol = page.symbol {
                try bounded(symbol, max: 100, required: true)
                try require(symbol.unicodeScalars.allSatisfy {
                    (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 46
                }, "使用指南的图标名称无效。")
            }
        }
    }

    private static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...80).contains(bytes.count) && bytes.first.map(isLowercaseOrNumber) == true
            && bytes.allSatisfy { isLowercaseOrNumber($0) || $0 == 45 }
    }

    private static func validKind(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...40).contains(bytes.count) && bytes.first.map { (97...122).contains($0) } == true
            && bytes.allSatisfy { isLowercaseOrNumber($0) || $0 == 45 }
    }

    private static func isLowercaseOrNumber(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func bounded(_ value: String, max: Int, required: Bool = false) throws {
        try require(value.utf16.count <= max && (!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    "内容文字为空或超过长度上限。")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorkspaceFailure.invalid(message) }
    }

    private struct PackageHeader: Decodable {
        var protocolVersion: String
        var id: String
        var kind: String
        var version: Int
        var minimumContentVersion: Int

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case id, kind, version, minimumContentVersion
        }
    }

    private struct PackagePayload<Value: Decodable>: Decodable {
        var payload: Value
    }
}
