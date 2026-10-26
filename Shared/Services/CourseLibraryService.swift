import Foundation
import Observation

struct PendingCourseUpdate: Codable, Equatable {
    var courseID: UUID
    var update: CourseProgressUpdate
}

/// Kept outside the workspace snapshot so older clients cannot erase lessons.
struct CourseLibraryCache: Codable, Equatable {
    var catalog = CourseCatalog(courses: [])
    var editions: [UUID: CourseEdition] = [:]
    var progress: [UUID: CourseProgress] = [:]
    var pending: [PendingCourseUpdate] = []
    var pendingStars: [UUID: Bool] = [:]
}

private struct CourseLibraryIndex: Codable {
    var catalog = CourseCatalog(courses: [])
    var completedCounts: [UUID: Int] = [:]
    var completedRevisions: [UUID: Int] = [:]
}

private struct RestoredCourseLibrary {
    var index: CourseLibraryIndex
    var pending: [PendingCourseUpdate]
    var pendingStars: [UUID: Bool]
}

/// Course documents may contain hundreds of rich blocks. Keep their JSON work
/// off the UI actor while the repository retains ownership of its SwiftData context.
private actor CourseLibraryCodec {
    static let shared = CourseLibraryCodec()

    func restoreLibrary(indexData: Data?, pendingData: Data?, starsData: Data?) throws -> RestoredCourseLibrary {
        try Task.checkCancellation()
        let decoder = WorkspaceCoding.decoder()
        let index = try indexData.map { try decoder.decode(CourseLibraryIndex.self, from: $0) } ?? CourseLibraryIndex()
        try Task.checkCancellation()
        let pending = try pendingData.map { try decoder.decode([PendingCourseUpdate].self, from: $0) } ?? []
        try Task.checkCancellation()
        let stars = try starsData.map { try decoder.decode([UUID: Bool].self, from: $0) } ?? [:]
        return RestoredCourseLibrary(index: index, pending: pending, pendingStars: stars)
    }

    func restore(editionData: Data, progressData: Data?, id: UUID) throws -> (CourseEdition, CourseProgress?) {
        try Task.checkCancellation()
        let decoder = WorkspaceCoding.decoder()
        let edition = try decoder.decode(CourseEdition.self, from: editionData)
        try CourseValidation.validate(edition.course)
        try Task.checkCancellation()
        guard edition.course.id == id, edition.revision > 0 else { throw NativeBackendError.malformed }
        let progress = try progressData.map { try decoder.decode(CourseProgress.self, from: $0) }
        guard progress == nil || progress?.courseID == id else { throw NativeBackendError.malformed }
        return (edition, progress)
    }

    func encode(_ edition: CourseEdition) throws -> Data {
        try WorkspaceCoding.encoder().encode(edition)
    }

    func restoreProgress(_ payloads: [UUID: Data]) throws -> [UUID: CourseProgress] {
        let decoder = WorkspaceCoding.decoder()
        var result: [UUID: CourseProgress] = [:]
        for (id, data) in payloads {
            try Task.checkCancellation()
            let progress = try decoder.decode(CourseProgress.self, from: data)
            guard progress.courseID == id else { throw NativeBackendError.malformed }
            result[id] = progress
        }
        return result
    }
}

@MainActor @Observable final class CourseLibraryService {
    private(set) var cache = CourseLibraryCache()
    private(set) var loadedScope: String?
    private(set) var preparing = false
    private(set) var refreshing = false
    private(set) var error: String?
    @ObservationIgnored private let backend: BackendService
    @ObservationIgnored private let repository: SwiftDataRepository
    @ObservationIgnored private let isDemoMode: Bool
    @ObservationIgnored private var flushingScope: String?
    @ObservationIgnored private var submissionTask: Task<Void, Never>?
    private var index = CourseLibraryIndex()
    @ObservationIgnored private var progressGeneration = 0
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var courseGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var metadataPreparation: (id: UUID, task: Task<RestoredCourseLibrary, Error>)?
    @ObservationIgnored private var coursePreparations: [UUID: (id: UUID, task: Task<(CourseEdition, CourseProgress?), Error>)] = [:]
    @ObservationIgnored private var bundledDemoRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var readingCourses: [UUID: UUID] = [:]

    init(backend: BackendService, repository: SwiftDataRepository, isDemoMode: Bool) {
        self.backend = backend; self.repository = repository; self.isDemoMode = isDemoMode
    }
    var scope: String? { isDemoMode ? "course-demo" : backend.accountScope }
    var visibleCache: CourseLibraryCache { loadedScope == scope ? cache : CourseLibraryCache() }

    private func resetScope() {
        submissionTask?.cancel(); submissionTask = nil
        metadataPreparation?.task.cancel(); metadataPreparation = nil
        for preparation in coursePreparations.values { preparation.task.cancel() }
        coursePreparations.removeAll(); preparing = false
        cache = CourseLibraryCache(); index = CourseLibraryIndex(); error = nil; loadedScope = scope
        bundledDemoRevisions.removeAll()
        readingCourses.removeAll()
        catalogGeneration += 1; courseGenerations.removeAll()
    }

    private func prepareDemo() {
        let fallback = CourseDemo.edition()
        var editions = [fallback]
        for published in AppContentService.shared.demoCourses {
            if let index = editions.firstIndex(where: { $0.course.id == published.course.id }) {
                if published.revision >= editions[index].revision { editions[index] = published }
            } else { editions.append(published) }
        }
        for edition in editions {
            bundledDemoRevisions[edition.course.id] = edition.revision
            cache.editions[edition.course.id] = edition
            cache.catalog.courses.append(CourseSummary(id: edition.course.id, title: edition.course.title,
                summary: edition.course.summary, revision: edition.revision, updatedAt: edition.updatedAt,
                lessonCount: edition.course.lessons.count))
        }
    }

    /// Apply new sample content at an explicit course entry, never in the middle
    /// of an answer. A sample deleted or edited in this demo session stays so.
    private func updatePublishedDemoIfNeeded() {
        guard isDemoMode else { return }
        for edition in AppContentService.shared.demoCourses {
            let id = edition.course.id
            guard !readingCourses.values.contains(id) else { continue }
            if let previous = bundledDemoRevisions[id] {
                guard edition.revision > previous, cache.editions[id]?.revision == previous else { continue }
            } else if cache.editions[id] != nil { continue }
            let summary = CourseSummary(id: id, title: edition.course.title, summary: edition.course.summary,
                revision: edition.revision, updatedAt: edition.updatedAt, lessonCount: edition.course.lessons.count)
            cache.editions[id] = edition
            if let index = cache.catalog.courses.firstIndex(where: { $0.id == id }) { cache.catalog.courses[index] = summary }
            else { cache.catalog.courses.append(summary) }
            cache.progress.removeValue(forKey: id)
            cache.pending.removeAll { $0.courseID == id }
            bundledDemoRevisions[id] = edition.revision
            catalogGeneration += 1; progressGeneration += 1; courseGenerations[id, default: 0] += 1
        }
    }

    func beginReading(_ courseID: UUID) -> UUID {
        let ticket = UUID()
        readingCourses[ticket] = courseID
        return ticket
    }
    func endReading(_ ticket: UUID) { readingCourses.removeValue(forKey: ticket) }

    /// Synchronous compatibility for mutations made after a library is visible,
    /// and inexpensive in-memory demo setup. Interactive loads use the async path.
    func prepare() {
        guard loadedScope != scope else { return }
        resetScope()
        guard let scope else { return }
        if isDemoMode {
            prepareDemo()
            return
        }
        do {
            index = try repository.loadSupplement(CourseLibraryIndex.self, key: "courses:" + scope + ":index") ?? CourseLibraryIndex()
            cache.catalog = index.catalog
            cache.pending = try repository.loadSupplement([PendingCourseUpdate].self, key: "courses:" + scope + ":pending") ?? []
            cache.pendingStars = try repository.loadSupplement([UUID: Bool].self, key: "courses:" + scope + ":pending-stars") ?? [:]
            for (id, starred) in cache.pendingStars where cache.catalog.courses.contains(where: { $0.id == id }) {
                cache.catalog.setStarred(id, starred: starred)
            }
        } catch { self.error = WorkspaceLocalization.string("暂时无法读取已下载的课程，请连接网络重试。") }
    }

    /// Local-only preparation, suitable after the first screen has appeared.
    /// Account/workspace changes cancel old work; rich JSON is decoded off the UI
    /// actor and at most one already-downloaded course is brought into memory.
    /// This does not contact the server, create web views, or run course code.
    func prepareForInteraction(preloadFirstCourse: Bool = true) async {
        guard !Task.isCancelled else { return }
        if isDemoMode { await AppContentService.shared.prepare() }
        guard !Task.isCancelled else { return }
        if loadedScope != scope {
            resetScope()
            guard let scope else { return }
            if isDemoMode { prepareDemo(); return }
            preparing = true
            do {
                let prefix = "courses:" + scope + ":"
                let indexData = try repository.loadSupplementData(key: prefix + "index")
                let pendingData = try repository.loadSupplementData(key: prefix + "pending")
                let starsData = try repository.loadSupplementData(key: prefix + "pending-stars")
                let task = Task(priority: .utility) {
                    try await CourseLibraryCodec.shared.restoreLibrary(indexData: indexData, pendingData: pendingData, starsData: starsData)
                }
                metadataPreparation = (UUID(), task)
            } catch {
                preparing = false
                self.error = WorkspaceLocalization.string("暂时无法读取已下载的课程，请连接网络重试。")
            }
        }
        guard let scope, loadedScope == scope else { return }
        if let preparation = metadataPreparation {
            do {
                let restored = try await preparation.task.value
                if self.scope == scope, loadedScope == scope, metadataPreparation?.id == preparation.id {
                    metadataPreparation = nil; preparing = false
                    index = restored.index
                    cache.catalog = restored.index.catalog
                    cache.pending = restored.pending
                    cache.pendingStars = restored.pendingStars
                    let visibleIDs = Set(cache.catalog.courses.map(\.id))
                    for (id, starred) in restored.pendingStars where visibleIDs.contains(id) {
                        cache.catalog.setStarred(id, starred: starred)
                    }
                }
            } catch {
                if self.scope == scope, loadedScope == scope, metadataPreparation?.id == preparation.id {
                    metadataPreparation = nil; preparing = false
                    self.error = WorkspaceLocalization.string("暂时无法读取已下载的课程，请连接网络重试。")
                }
            }
        }
        guard preloadFirstCourse, !Task.isCancelled, self.scope == scope, loadedScope == scope, !isDemoMode else { return }
        let candidate = cache.catalog.courses.first(where: { cache.catalog.isStarred($0.id) }) ?? cache.catalog.courses.first
        if let candidate, cache.editions[candidate.id] == nil {
            // Missing/corrupt optional cache entries are retried by the normal
            // open path. Background preparation must not replace a UI error.
            try? await restoreCourse(candidate.id, scope: scope)
        }
    }
    private func persist(_ draft: CourseLibraryCache, scope: String, encodedEditions: [UUID: Data] = [:]) throws {
        guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
        guard draft != cache else { return }
        var nextIndex = index
        nextIndex.catalog = draft.catalog
        let visibleIDs = Set(draft.catalog.courses.map(\.id))
        nextIndex.completedCounts = nextIndex.completedCounts.filter { visibleIDs.contains($0.key) }
        nextIndex.completedRevisions = nextIndex.completedRevisions.filter { visibleIDs.contains($0.key) }
        if !isDemoMode {
            let prefix = "courses:" + scope + ":"
            let encoder = WorkspaceCoding.encoder()
            var payloads: [String: Data] = [:]
            for (id, edition) in draft.editions where edition != cache.editions[id] {
                payloads[prefix + "edition:" + id.uuidString] = try encodedEditions[id] ?? encoder.encode(edition)
            }
            for (id, progress) in draft.progress where progress != cache.progress[id] {
                payloads[prefix + "progress:" + id.uuidString] = try encoder.encode(progress)
                nextIndex.completedCounts[id] = progress.completedLessonIDs.count
                nextIndex.completedRevisions[id] = progress.courseRevision ?? draft.editions[id]?.revision
            }
            if draft.pending != cache.pending { payloads[prefix + "pending"] = try encoder.encode(draft.pending) }
            if draft.pendingStars != cache.pendingStars { payloads[prefix + "pending-stars"] = try encoder.encode(draft.pendingStars) }
            // Supplements have no delete operation. Clear deleted progress and keep
            // obsolete edition bytes unreachable behind catalog membership checks.
            for id in Set(cache.catalog.courses.map(\.id)).subtracting(visibleIDs) {
                payloads[prefix + "progress:" + id.uuidString] = try encoder.encode(CourseProgress(courseID: id))
            }
            payloads[prefix + "index"] = try encoder.encode(nextIndex)
            try repository.saveSupplements(payloads)
        }
        if draft.progress != cache.progress { progressGeneration += 1 }
        index = nextIndex; cache = draft
    }
    func completedCount(for summary: CourseSummary) -> Int {
        if visibleCache.editions[summary.id]?.revision == summary.revision {
            return visibleCache.progress[summary.id]?.completedLessonIDs.count ?? 0
        }
        return loadedScope == scope && index.completedRevisions[summary.id] == summary.revision ? index.completedCounts[summary.id] ?? 0 : 0
    }
    private func restoreCourse(_ id: UUID, scope: String) async throws {
        try Task.checkCancellation()
        guard cache.catalog.courses.contains(where: { $0.id == id }), cache.editions[id] == nil, !isDemoMode else { return }
        let startingCourseGeneration = courseGenerations[id, default: 0]
        let startingProgressGeneration = progressGeneration
        let preparation: (id: UUID, task: Task<(CourseEdition, CourseProgress?), Error>)
        if let current = coursePreparations[id] {
            preparation = current
        } else {
            let prefix = "courses:" + scope + ":"
            guard let data = try repository.loadSupplementData(key: prefix + "edition:" + id.uuidString) else { return }
            let progressData = try repository.loadSupplementData(key: prefix + "progress:" + id.uuidString)
            preparation = (UUID(), Task(priority: .utility) {
                try await CourseLibraryCodec.shared.restore(editionData: data, progressData: progressData, id: id)
            })
            coursePreparations[id] = preparation
        }
        let restored: (CourseEdition, CourseProgress?)
        do {
            restored = try await preparation.task.value
        } catch {
            // A failed shared decode has no reusable result. Caller cancellation
            // is checked separately so another waiter can still adopt success.
            if coursePreparations[id]?.id == preparation.id { coursePreparations[id] = nil }
            throw error
        }
        try Task.checkCancellation()
        defer { if coursePreparations[id]?.id == preparation.id { coursePreparations[id] = nil } }
        let (edition, progress) = restored
        guard self.scope == scope, loadedScope == scope,
              coursePreparations[id]?.id == preparation.id,
              startingCourseGeneration == courseGenerations[id, default: 0], cache.editions[id] == nil else { return }
        guard cache.catalog.courses.contains(where: { $0.id == id && $0.revision == edition.revision }) else { return }
        cache.editions[id] = edition
        if startingProgressGeneration == progressGeneration, cache.progress[id] == nil { cache.progress[id] = progress }
    }
    func refresh() async {
        await prepareForInteraction(preloadFirstCourse: false)
        if isDemoMode {
            await AppContentService.shared.refresh()
            guard !Task.isCancelled else { return }
            updatePublishedDemoIfNeeded()
            return
        }
        guard !Task.isCancelled, let scope, !isDemoMode, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let startingGeneration = catalogGeneration
            let result = try await backend.courseCatalog()
            guard self.scope == scope, loadedScope == scope else { return }
            guard startingGeneration == catalogGeneration else { await flush(scope: scope); return }
            var draft = cache; draft.catalog = result
            let visibleIDs = Set(result.courses.map(\.id))
            for summary in cache.catalog.courses where !result.courses.contains(where: { $0.id == summary.id && $0.revision == summary.revision }) {
                courseGenerations[summary.id, default: 0] += 1
            }
            draft.editions = draft.editions.filter { visibleIDs.contains($0.key) }
            draft.progress = draft.progress.filter { visibleIDs.contains($0.key) }
            draft.pending.removeAll { !visibleIDs.contains($0.courseID) }
            draft.pendingStars = draft.pendingStars.filter { visibleIDs.contains($0.key) }
            for (id, starred) in draft.pendingStars { draft.catalog.setStarred(id, starred: starred) }
            try persist(draft, scope: scope)
            error = nil
            await flush(scope: scope)
        } catch { report(error, scope: scope) }
    }
    func open(_ id: UUID) async {
        await prepareForInteraction(preloadFirstCourse: false)
        if isDemoMode { updatePublishedDemoIfNeeded(); return }
        guard !Task.isCancelled, let scope, !isDemoMode, cache.catalog.courses.contains(where: { $0.id == id }) else { return }
        do {
            let startingCourseGeneration = courseGenerations[id, default: 0]
            try await restoreCourse(id, scope: scope)
            guard self.scope == scope, loadedScope == scope,
                  startingCourseGeneration == courseGenerations[id, default: 0],
                  let summary = cache.catalog.courses.first(where: { $0.id == id }) else { return }
            let startingGeneration = progressGeneration
            async let fetchedProgress = backend.courseProgress(id)
            var edition: CourseEdition
            var reusedEdition = false
            var encodedEditions: [UUID: Data] = [:]
            if let downloaded = cache.editions[id], downloaded.revision == summary.revision {
                edition = downloaded
                reusedEdition = true
            } else {
                edition = try await backend.courseEdition(id)
                encodedEditions[id] = try await CourseLibraryCodec.shared.encode(edition)
            }
            let progress = try await fetchedProgress
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope,
                  startingCourseGeneration == courseGenerations[id, default: 0] else { return }
            // Progress may reveal a publication newer than the last catalog poll.
            // Refresh the document only in that case rather than on every open.
            if reusedEdition, let revision = progress.courseRevision, revision != edition.revision {
                edition = try await backend.courseEdition(id)
                encodedEditions[id] = try await CourseLibraryCodec.shared.encode(edition)
            }
            guard self.scope == scope, loadedScope == scope else { return }
            guard cache.catalog.courses.contains(where: { $0.id == id }),
                  startingCourseGeneration == courseGenerations[id, default: 0] else { return }
            guard progress.courseRevision == nil || progress.courseRevision == edition.revision else { throw NativeBackendError.conflict }
            var draft = cache
            draft.editions[id] = edition
            // A local answer may have been acknowledged while this GET was in flight.
            // Keep that newer state instead of replacing it with an older response.
            let current = startingGeneration != progressGeneration && cache.progress[id]?.courseRevision == edition.revision ? cache.progress[id] ?? progress : progress
            draft.progress[id] = overlayPending(current, edition: edition, pending: draft.pending)
            try persist(draft, scope: scope, encodedEditions: encodedEditions)
            error = nil
            await flush(scope: scope)
        } catch { report(error, scope: scope) }
    }
    /// Resolve a direct lesson destination without loading every course's content.
    /// Use saved progress for ordering, then refresh only the courses needed to find a lesson.
    func quickStart() async throws -> CourseLearningTarget? {
        await prepareForInteraction(preloadFirstCourse: false)
        try Task.checkCancellation()
        guard let scope, loadedScope == scope else { throw NativeBackendError.configuration }
        var savedProgress = cache.progress
        if !isDemoMode {
            var payloads: [UUID: Data] = [:]
            for course in cache.catalog.courses where savedProgress[course.id] == nil {
                try Task.checkCancellation()
                guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
                payloads[course.id] = try repository.loadSupplementData(key: "courses:" + scope + ":progress:" + course.id.uuidString)
                await Task.yield()
            }
            let restored = try await CourseLibraryCodec.shared.restoreProgress(payloads)
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
            savedProgress.merge(restored) { current, _ in current }
            savedProgress.merge(cache.progress) { _, current in current }
        }
        let ordered = CourseLearningContinuation.orderedCourses(cache.catalog.courses, progress: savedProgress)
        for summary in ordered {
            try Task.checkCancellation()
            await open(summary.id)
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
            guard let edition = cache.editions[summary.id], edition.revision >= summary.revision else {
                throw WorkspaceFailure.invalid(error ?? WorkspaceLocalization.string("暂时无法打开课程，请连接网络后重试。"))
            }
            if let lesson = CourseLearningContinuation.nextLesson(in: edition, progress: cache.progress[summary.id]) {
                return CourseLearningTarget(courseID: summary.id, lessonID: lesson.id, revision: edition.revision)
            }
        }
        return nil
    }
    /// Refresh the server-owned renderer on each entry, even when course content
    /// has not changed. Offline fallback never crosses an account/workspace or revision.
    func playerPackage(edition: CourseEdition, lesson: CourseLesson) async throws -> CoursePlayerPackage {
        guard let scope, loadedScope == scope,
              cache.editions[edition.course.id]?.revision == edition.revision else { throw NativeBackendError.configuration }
        let key = "course-player:" + scope + ":" + edition.course.id.uuidString + ":" + lesson.id.uuidString
        do {
            let package: CoursePlayerPackage
            if isDemoMode {
                package = try await URLSessionBackend().demoCoursePlayer(baseURL: BackendService.serviceURL,
                    courseID: edition.course.id, lessonID: lesson.id)
            } else {
                package = try await backend.coursePlayer(courseID: edition.course.id, lessonID: lesson.id)
            }
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
            if isDemoMode, package.courseRevision != edition.revision {
                // A public sample may update independently of the installed App.
                // Refresh its data before letting the new page accept old-revision answers.
                await AppContentService.shared.refresh(force: true)
                try Task.checkCancellation()
                guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
                let published = AppContentService.shared.availableEntries.filter { $0.kind == "course" }
                    .compactMap { AppContentService.shared.course($0.id) }
                    .first { $0.course.id == edition.course.id && $0.revision == package.courseRevision }
                if let published {
                    try installPublishedSample(published)
                    // The view's revision identity changes and starts a fresh load.
                    throw CancellationError()
                }
            }
            try package.validate(courseID: edition.course.id, lessonID: lesson.id, revision: edition.revision)
            let bytes = try await CoursePlayerCodec.shared.encode(package)
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
            // A full disk must not prevent an already downloaded lesson from opening.
            let indexKey = "course-player:" + scope + ":cache-index"
            var entries = (try? repository.loadSupplement([CoursePlayerCacheEntry].self, key: indexKey)) ?? []
            entries.removeAll { $0.key == key }
            entries.append(CoursePlayerCacheEntry(key: key, bytes: bytes.count))
            var payloads = [key: bytes]
            while entries.count > 12 || entries.reduce(0, { $0 + $1.bytes }) > 16 * 1024 * 1024 {
                let removed = entries.removeFirst()
                if removed.key.hasPrefix("course-player:" + scope + ":") { payloads[removed.key] = Data() }
            }
            payloads[indexKey] = try JSONEncoder().encode(entries)
            try? repository.saveSupplements(payloads)
            return package
        } catch {
            let network = error as NSError
            guard network.domain == NSURLErrorDomain,
                  [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                   NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(network.code) else { throw error }
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope,
                  let data = try repository.loadSupplementData(key: key) else { throw error }
            let package = try await CoursePlayerCodec.shared.decode(data)
            try Task.checkCancellation()
            guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
            try package.validate(courseID: edition.course.id, lessonID: lesson.id, revision: edition.revision)
            return package
        }
    }

    func submit(courseID: UUID, update: CourseProgressUpdate) throws {
        guard let scope, loadedScope == scope, let edition = cache.editions[courseID] else { throw NativeBackendError.configuration }
        var draft = cache
        var progress = draft.progress[courseID] ?? CourseProgress(courseID: courseID)
        try progress.apply(update: update, edition: edition)
        guard try WorkspaceCoding.encoder().encode(progress).count <= 2 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
        guard isDemoMode || draft.pending.count < 1_000 else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("待同步的练习较多，请连接网络后继续。")) }
        draft.progress[courseID] = progress
        // Preserve mutation IDs across retries: a timed-out request may already
        // have reached the server even though this device has no response yet.
        draft.pending.append(PendingCourseUpdate(courseID: courseID, update: update))
        if isDemoMode { draft.pending.removeAll() }
        try persist(draft, scope: scope)
        error = nil
        scheduleFlush(scope: scope)
    }
    /// A public sample is an existing publication, not a newly uploaded course.
    /// Retain its published revision so the server page and local answers agree.
    func installPublishedSample(_ edition: CourseEdition) throws {
        guard isDemoMode, let scope, loadedScope == scope, edition.revision > 0 else { throw NativeBackendError.configuration }
        try CourseValidation.validate(edition.course)
        var draft = cache
        let id = edition.course.id
        draft.editions[id] = edition
        draft.catalog.courses.removeAll { $0.id == id }
        draft.catalog.courses.insert(CourseSummary(id: id, title: edition.course.title, summary: edition.course.summary,
            revision: edition.revision, updatedAt: edition.updatedAt, lessonCount: edition.course.lessons.count), at: 0)
        if draft.progress[id]?.courseRevision != edition.revision {
            draft.progress[id] = CourseProgress(courseID: id, courseRevision: edition.revision)
            draft.pending.removeAll { $0.courseID == id }
        }
        try persist(draft, scope: scope)
        bundledDemoRevisions[id] = edition.revision
        catalogGeneration += 1; courseGenerations[id, default: 0] += 1
        error = nil
    }

    /// Save the acknowledged publication without another full-content download.
    /// The publishing account/workspace must still be the visible context.
    func upload(_ course: CourseDocument, expectedRevision: Int?, mutationID: UUID) async throws -> Int {
        await prepareForInteraction(preloadFirstCourse: false)
        try Task.checkCancellation()
        try CourseValidation.validate(course)
        guard let scope, loadedScope == scope else { throw NativeBackendError.configuration }
        let publication: CoursePublication
        if isDemoMode {
            publication = CoursePublication(id: course.id, revision: (cache.editions[course.id]?.revision ?? 0) + 1, updatedAt: Date(), replayed: false)
        } else {
            publication = try await backend.publishCourse(course, expectedRevision: expectedRevision, mutationID: mutationID)
        }
        guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
        var draft = cache
        draft.editions[course.id] = CourseEdition(course: course, revision: publication.revision, updatedAt: publication.updatedAt)
        draft.catalog.courses.removeAll { $0.id == course.id }
        draft.catalog.courses.insert(CourseSummary(id: course.id, title: course.title, summary: course.summary,
            revision: publication.revision, updatedAt: publication.updatedAt, lessonCount: course.lessons.count), at: 0)
        if draft.progress[course.id]?.courseRevision != publication.revision {
            var progress = CourseProgress(courseID: course.id)
            progress.courseRevision = publication.revision
            draft.progress[course.id] = progress
        }
        try persist(draft, scope: scope)
        catalogGeneration += 1; courseGenerations[course.id, default: 0] += 1
        error = nil
        return publication.revision
    }
    func isStarred(_ id: UUID) -> Bool { visibleCache.catalog.isStarred(id) }

    /// Personal stars are scoped to this account and workspace, including in shared spaces.
    func setStarred(_ id: UUID, starred: Bool) throws {
        prepare()
        guard let scope, loadedScope == scope, cache.catalog.courses.contains(where: { $0.id == id }) else {
            throw NativeBackendError.configuration
        }
        var draft = cache
        draft.catalog.setStarred(id, starred: starred)
        if !isDemoMode { draft.pendingStars[id] = starred }
        try persist(draft, scope: scope)
        catalogGeneration += 1
        error = nil
        scheduleFlush(scope: scope)
    }

    func delete(_ id: UUID, expectedRevision: Int) async throws {
        await prepareForInteraction(preloadFirstCourse: false)
        try Task.checkCancellation()
        guard let scope, loadedScope == scope, expectedRevision > 0,
              cache.catalog.courses.contains(where: { $0.id == id }),
              cache.catalog.courses.contains(where: { $0.id == id && $0.revision == expectedRevision }) || cache.editions[id]?.revision == expectedRevision else {
            throw NativeBackendError.conflict
        }
        if !isDemoMode { try await backend.deleteCourse(id, expectedRevision: expectedRevision) }
        guard self.scope == scope, loadedScope == scope else { throw CancellationError() }
        var draft = cache
        draft.catalog.courses.removeAll { $0.id == id }
        draft.catalog.setStarred(id, starred: false)
        draft.editions[id] = nil; draft.progress[id] = nil; draft.pendingStars[id] = nil
        draft.pending.removeAll { $0.courseID == id }
        try persist(draft, scope: scope)
        catalogGeneration += 1; courseGenerations[id, default: 0] += 1
        error = nil
    }

    private func scheduleFlush(scope: String) {
        guard !isDemoMode, submissionTask == nil else { return }
        submissionTask = Task {
            await flush(scope: scope)
            submissionTask = nil
        }
    }

    func hasEarlierDrafts(_ id: UUID) -> Bool {
        guard let edition = visibleCache.editions[id] else { return false }
        return visibleCache.pending.contains { $0.courseID == id && $0.update.courseRevision != edition.revision }
    }
    private func overlayPending(_ progress: CourseProgress, edition: CourseEdition, pending: [PendingCourseUpdate]) -> CourseProgress {
        var result = progress
        for item in pending where item.courseID == edition.course.id && item.update.courseRevision == edition.revision {
            try? result.apply(update: item.update, edition: edition)
        }
        return result
    }
    private func flush(scope: String) async {
        guard self.scope == scope, !isDemoMode, flushingScope == nil else { return }
        flushingScope = scope
        defer { flushingScope = nil }
        while !Task.isCancelled, self.scope == scope, loadedScope == scope {
            if let (id, starred) = cache.pendingStars.first {
                do {
                    try await backend.setCourseStar(id, starred: starred)
                    guard self.scope == scope, loadedScope == scope else { return }
                    // A newer toggle or deletion may have happened during the PUT.
                    if cache.pendingStars[id] == starred {
                        var draft = cache; draft.pendingStars[id] = nil
                        try persist(draft, scope: scope)
                    }
                    catalogGeneration += 1
                    continue
                } catch {
                    guard self.scope == scope, loadedScope == scope else { return }
                    if !cache.catalog.courses.contains(where: { $0.id == id }) { continue }
                    report(error, scope: scope); return
                }
            }
            guard let item = cache.pending.first(where: { item in
                cache.catalog.courses.first(where: { $0.id == item.courseID })?.revision == item.update.courseRevision
            }) else { return }
            do {
                try await restoreCourse(item.courseID, scope: scope)
                guard self.scope == scope, loadedScope == scope else { return }
                let result = try await backend.courseProgress(item.courseID, update: item.update)
                guard self.scope == scope, loadedScope == scope else { return }
                guard cache.catalog.courses.contains(where: { $0.id == item.courseID }),
                      let edition = cache.editions[item.courseID], edition.revision == item.update.courseRevision else { continue }
                var draft = cache
                draft.pending.removeAll { $0.update.mutationID == item.update.mutationID }
                draft.progress[item.courseID] = overlayPending(result, edition: edition, pending: draft.pending)
                try persist(draft, scope: scope)
            } catch {
                guard self.scope == scope, loadedScope == scope else { return }
                if !cache.catalog.courses.contains(where: { $0.id == item.courseID }) { continue }
                report(error, scope: scope)
                return
            }
        }
    }
    private func report(_ failure: Error, scope: String) {
        guard !(failure is CancellationError), !Task.isCancelled, self.scope == scope, loadedScope == scope else { return }
        error = failure.localizedDescription
    }
}

private actor CoursePlayerCodec {
    static let shared = CoursePlayerCodec()
    func encode(_ package: CoursePlayerPackage) throws -> Data { try JSONEncoder().encode(package) }
    func decode(_ data: Data) throws -> CoursePlayerPackage { try JSONDecoder().decode(CoursePlayerPackage.self, from: data) }
}

private struct CoursePlayerCacheEntry: Codable {
    var key: String
    var bytes: Int
}
