#if os(iOS)
import ActivityKit
import Observation
import Foundation
import UIKit

@MainActor @Observable final class DeadlineLiveActivityCoordinator {
    private(set) var activeRecordID: UUID?
    private(set) var activeRecordIDs: Set<UUID> = []
    private(set) var automaticTracking: Bool
    private(set) var lockScreenAppearance: String
    @ObservationIgnored private var automaticDismissed = false
    private(set) var working = false
    private(set) var message: String?
    let demoSessionID: UUID?
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var suspended = false
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    @ObservationIgnored private var latestState = WorkspaceState()
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]

    init(isDemoMode: Bool = false) {
        demoSessionID = isDemoMode ? UUID() : nil
        lockScreenAppearance = isDemoMode ? "system" : (UserDefaults.standard.string(forKey: "liveActivityLockScreenAppearance") ?? "system")
        automaticTracking = UserDefaults.standard.object(forKey: "automaticLiveActivityTracking") as? Bool ?? true
        if !isDemoMode {
            // Capture only leftovers already present at launch. A later demo
            // session must not be removed by the real workspace's refreshes.
            let abandoned = Activity<DeadlineActivityAttributes>.activities.filter { $0.attributes.demoSessionID != nil }
            if !abandoned.isEmpty {
                submit { for activity in abandoned { await activity.end(nil, dismissalPolicy: .immediate) } }
            }
        }
    }
    private var owned: [Activity<DeadlineActivityAttributes>] {
        Activity<DeadlineActivityAttributes>.activities.filter { $0.attributes.demoSessionID == demoSessionID }
    }
    private var active: [Activity<DeadlineActivityAttributes>] {
        owned.filter { $0.activityState == .active || $0.activityState == .stale }
    }
    func setLockScreenAppearance(_ appearance: String, in state: WorkspaceState) {
        guard ["system", "light", "dark"].contains(appearance) else { return }
        lockScreenAppearance = appearance
        if demoSessionID == nil { UserDefaults.standard.set(appearance, forKey: "liveActivityLockScreenAppearance") }
        synchronize(state)
    }
    func setAutomaticTracking(_ enabled: Bool, in state: WorkspaceState) {
        automaticTracking = enabled
        automaticDismissed = false
        if demoSessionID == nil { UserDefaults.standard.set(enabled, forKey: "automaticLiveActivityTracking") }
        if enabled { synchronize(state) } else { end() }
    }
    /// Hidden workspaces must not publish activities while another workspace is visible.
    func suspend() {
        suspended = true
        end()
    }
    func resume(in state: WorkspaceState) {
        guard !retired else { return }
        suspended = false
        synchronize(state)
    }
    func start(_ id: UUID, in state: WorkspaceState) {
        guard !retired, !suspended else { return }
        latestState = state
        submit {
            guard !self.retired, !self.suspended else { return }
            guard self.enabled else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请在系统设置中允许工作坊的实时活动。")) }
            let now = Date()
            guard let record = self.latestState.records.first(where: { $0.id == id }),
                  let due = DeadlineTrackingPolicy.dueDate(for: record, in: self.latestState, now: now) else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此事项当前不符合实时活动追踪条件。"))
            }
            for old in self.owned { await old.end(nil, dismissalPolicy: .immediate) }
            // Exiting demo can occur while an old activity is being ended.
            guard !self.retired, !self.suspended else { return }
            let activity = try Activity.request(attributes: DeadlineActivityAttributes(recordID: id, startedAt: now, demoSessionID: self.demoSessionID),
                content: ActivityContent(state: .init(title: record.title, dueDate: due, lockScreenAppearance: self.lockScreenAppearance), staleDate: due), pushType: nil)
            self.watch(activity)
            self.refreshActiveRecords()
        }
    }
    func end() {
        guard !retired else { return }
        submit {
            for activity in self.owned { await activity.end(nil, dismissalPolicy: .immediate) }
            self.activeRecordID = nil
            self.activeRecordIDs = []
        }
    }
    /// Retire permanently so late editor/import tasks cannot recreate an activity
    /// after this in-memory demo has been discarded.
    func retireDemoSession() {
        guard demoSessionID != nil, !retired else { return }
        retired = true
        submit {
            for activity in self.owned { await activity.end(nil, dismissalPolicy: .immediate) }
            for watcher in self.watchers.values { watcher.cancel() }
            self.watchers.removeAll()
            self.activeRecordID = nil
            self.activeRecordIDs = []
        }
    }
    func synchronize(_ state: WorkspaceState) {
        guard !retired, !suspended else { return }
        latestState = state
        submit {
            guard !self.retired, !self.suspended else { return }
            if self.automaticTracking {
                try await self.synchronizeAutomatic()
                return
            }
            let values = self.active.sorted { $0.attributes.startedAt > $1.attributes.startedAt }
            for duplicate in values.dropFirst() { await duplicate.end(nil, dismissalPolicy: .immediate) }
            guard !self.retired, !self.suspended else { return }
            guard let activity = values.first else { self.activeRecordID = nil; return }
            self.watch(activity)
            guard let record = self.latestState.records.first(where: { $0.id == activity.attributes.recordID }),
                  let due = DeadlineTrackingPolicy.dueDate(for: record, in: self.latestState, startedAt: activity.attributes.startedAt) else {
                await activity.end(nil, dismissalPolicy: .immediate); self.activeRecordID = nil; return
            }
            let content = DeadlineActivityAttributes.ContentState(title: record.title, dueDate: due, lockScreenAppearance: self.lockScreenAppearance)
            if content != activity.content.state { await activity.update(ActivityContent(state: content, staleDate: due)) }
            self.activeRecordID = activity.attributes.recordID
        }
    }
    private func synchronizeAutomatic() async throws {
        let now = Date()
        let records = DeadlineTrackingPolicy.nearestRecords(in: latestState, now: now)
        let existing = active.sorted { $0.attributes.startedAt > $1.attributes.startedAt }
        for duplicate in existing.dropFirst() { await duplicate.end(nil, dismissalPolicy: .immediate) }
        guard !retired, !suspended else { return }
        guard enabled, !records.isEmpty else {
            for activity in owned { await activity.end(nil, dismissalPolicy: .immediate) }
            refreshActiveRecords()
            return
        }
        var activity = existing.first
        let lastDue = records.compactMap { record in record.dueDate.map(record.effectiveDueDate) }.max()!
        if let current = activity, lastDue > current.attributes.startedAt.addingTimeInterval(DeadlineTrackingPolicy.maximumDuration) {
            // A new foreground session is needed to extend beyond ActivityKit's lifetime.
            guard UIApplication.shared.applicationState == .active else { return }
            await current.end(nil, dismissalPolicy: .immediate)
            guard !retired else { return }
            activity = nil
        }
        guard !retired, !suspended else { return }
        let startedAt = activity?.attributes.startedAt ?? now
        let entries = records.compactMap { record -> DeadlineActivityAttributes.Entry? in
            guard let due = DeadlineTrackingPolicy.dueDate(for: record, in: latestState, now: now, startedAt: startedAt) else { return nil }
            // Keep the combined ActivityKit payload comfortably below the 4 KB limit.
            return .init(id: record.id, title: String(record.title.prefix(120)), dueDate: due)
        }
        guard let first = entries.first else { return }
        let content = DeadlineActivityAttributes.ContentState(title: first.title, dueDate: first.dueDate, entries: entries, lockScreenAppearance: lockScreenAppearance)
        let staleDate = entries.map(\.dueDate).max()
        if let current = activity {
            watch(current)
            if current.content.state != content { await current.update(ActivityContent(state: content, staleDate: staleDate)) }
        } else if !automaticDismissed && UIApplication.shared.applicationState == .active {
            let created = try Activity.request(attributes: DeadlineActivityAttributes(recordID: first.id, startedAt: now, demoSessionID: demoSessionID),
                content: ActivityContent(state: content, staleDate: staleDate), pushType: nil)
            watch(created)
        }
        refreshActiveRecords()
    }
    private func refreshActiveRecords() {
        let current = active.first
        activeRecordID = current?.content.state.entries?.first?.id ?? current?.attributes.recordID
        activeRecordIDs = Set(current.map { activity in
            activity.content.state.entries?.map(\.id) ?? [activity.attributes.recordID]
        } ?? [])
    }
    private func submit(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.working = true; self.message = nil
            do { try await operation() } catch { self.message = error.localizedDescription }
            self.refreshActiveRecords()
            self.working = false
        }
    }
    private func watch(_ activity: Activity<DeadlineActivityAttributes>) {
        guard watchers[activity.id] == nil else { return }
        watchers[activity.id] = Task { [weak self] in
            for await status in activity.activityStateUpdates {
                guard let self else { return }
                if status == .ended || status == .dismissed {
                    if status == .dismissed && self.automaticTracking { self.automaticDismissed = true }
                    self.refreshActiveRecords()
                    self.watchers[activity.id] = nil
                    return
                }
            }
        }
    }
}
#endif
