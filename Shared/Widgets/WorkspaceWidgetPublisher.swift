#if os(iOS)
import Foundation
import CryptoKit
import WidgetKit

extension WorkspaceStore {
    /// Debounce one transaction's state/scope changes until all assignments have completed.
    func scheduleWidgetSnapshot() {
        enqueueWidgetSnapshot(deferred: true)
    }
    var widgetContextID: String {
        let key = "widgetLocalContextID"
        let local: String
        if let existing = UserDefaults.standard.string(forKey: key) { local = existing }
        else { local = UUID().uuidString; UserDefaults.standard.set(local, forKey: key) }
        let scope = widgetWorkspaceScope ?? "local"
        let session = liveActivity.demoSessionID?.uuidString ?? "real"
        return SHA256.hash(data: Data("\(local)|\(scope)|\(session)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func publishWidgetSnapshot(forceReload: Bool = false) {
        enqueueWidgetSnapshot(forceReload: forceReload, deferred: false)
    }
    private func enqueueWidgetSnapshot(forceReload: Bool = false, deferred: Bool) {
        guard isActiveForWidgets else { return }
        widgetSnapshotTask?.cancel()
        let request = WorkspaceWidgetPublication.begin(forceReload: forceReload)
        widgetSnapshotTask = Task(priority: .utility) { [weak self] in
            if deferred { await Task.yield() }
            guard !Task.isCancelled, let self, self.isActiveForWidgets,
                  WorkspaceWidgetPublication.isCurrent(request),
                  let directory = WorkspaceWidgetStorage.containerURL else { return }
            let url = directory.appendingPathComponent("widget-snapshot-v1.json")
            let input = WorkspaceWidgetPublicationInput(records: self.state.records, now: Date(),
                theme: self.widgetPublicationTheme, isDemo: self.isDemoMode,
                demoSessionID: self.liveActivity.demoSessionID?.uuidString,
                contextID: self.widgetContextID, accountScope: self.backend.accountScope,
                enabled: self.widgetSharingEnabled, accessDenied: self.widgetAccessDenied)
            do {
                // Privacy changes clear the small file immediately, without waiting
                // for an older projection or decoding its possibly large contents.
                if !input.enabled || input.accessDenied {
                    let bytes = try JSONEncoder().encode(input.snapshot())
                    try WorkspaceWidgetStorage.installPreparedData(bytes, to: url)
                    _ = WorkspaceWidgetPublication.complete(request)
                    WidgetCenter.shared.reloadAllTimelines()
                    return
                }
                let bytes = try await WorkspaceWidgetProjectionWorker.shared.prepare(input, to: url)
                guard !Task.isCancelled, self.isActiveForWidgets,
                      WorkspaceWidgetPublication.isCurrent(request),
                      input.contextID == self.widgetContextID,
                      input.accountScope == self.backend.accountScope,
                      input.enabled == self.widgetSharingEnabled,
                      input.accessDenied == self.widgetAccessDenied,
                      input.theme == self.widgetPublicationTheme else { return }
                // Do not suspend between the context check and atomic installation:
                // an old account or demo cannot overwrite a newer visible workspace.
                if let bytes { try WorkspaceWidgetStorage.installPreparedData(bytes, to: url) }
                let forced = WorkspaceWidgetPublication.complete(request)
                if bytes != nil || forced { WidgetCenter.shared.reloadAllTimelines() }
            } catch {
                // Publication is optional. Preserve the previous atomic file on
                // failure and retry on the next workspace refresh.
            }
        }
    }
    private var widgetPublicationTheme: String {
        isDemoMode ? demoColorTheme : UserDefaults.standard.string(forKey: "colorTheme") ?? "blue"
    }
}

/// Main-actor generations cover real/demo stores sharing the same app-group file.
@MainActor private enum WorkspaceWidgetPublication {
    private static var generation: UInt = 0
    private static var forceReload = false
    static func begin(forceReload: Bool) -> UInt {
        generation &+= 1
        self.forceReload = self.forceReload || forceReload
        return generation
    }
    static func isCurrent(_ request: UInt) -> Bool { request == generation }
    static func complete(_ request: UInt) -> Bool {
        guard isCurrent(request) else { return false }
        defer { forceReload = false }
        return forceReload
    }
}

private struct WorkspaceWidgetPublicationInput {
    let records: [WorkspaceRecord]
    let now: Date
    let theme: String
    let isDemo: Bool
    let demoSessionID: String?
    let contextID: String
    let accountScope: String?
    let enabled: Bool
    let accessDenied: Bool

    func snapshot() -> WorkspaceWidgetSnapshot {
        var snapshot = WorkspaceWidgetSnapshot(generatedAt: now, items: [], projects: [],
            theme: theme, isDemo: isDemo, demoSessionID: demoSessionID,
            contextID: contextID, enabled: enabled)
        guard enabled, !accessDenied else { return snapshot }
        let index = WorkspaceRecordIndex(records)
        let pending = HomePresentationOrder.pending(index.visibleRecords, now: now)
        let items = pending.enumerated().map { offset, record in
            let parent = (record.projectID ?? record.areaID).flatMap { index.byID[$0] }
            return WorkspaceWidgetItem(id: record.id, title: String(record.title.prefix(240)),
                projectID: parent?.id, projectName: parent.map { String($0.title.prefix(240)) },
                date: HomePresentationOrder.moment(record), dateOnly: record.dateOnly,
                isDeadline: record.kind == .deadline, isStarred: record.isKeyItem, priorityRank: Double(offset), hasDueDate: record.dueDate != nil)
        }
        let groups = index.projectGroupRecords.map {
            WorkspaceWidgetProject(id: $0.id, title: String($0.title.prefix(240)))
        }
        snapshot.items = items; snapshot.projects = groups
        return snapshot
    }
}

/// Sorting, indexing, disk comparison and JSON encoding stay off the UI executor.
/// Serial preparation also bounds simultaneous work during rapid edits.
private actor WorkspaceWidgetProjectionWorker {
    static let shared = WorkspaceWidgetProjectionWorker()
    func prepare(_ input: WorkspaceWidgetPublicationInput, to url: URL) throws -> Data? {
        guard !Task.isCancelled else { return nil }
        let snapshot = input.snapshot()
        guard !Task.isCancelled else { return nil }
        return try WorkspaceWidgetStorage.preparedData(snapshot, to: url)
    }
}
#endif
