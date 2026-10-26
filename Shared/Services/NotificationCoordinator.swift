import Foundation
import Observation
import UserNotifications

@MainActor @Observable final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    @ObservationIgnored weak var store: WorkspaceStore?
    let isDemoMode: Bool
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var pendingCount = 0
    private(set) var unscheduledCount = 0
    private var demoEnabled = false
    var enabled: Bool {
        get { isDemoMode ? demoEnabled : UserDefaults.standard.bool(forKey: "notificationsEnabled") }
        set {
            if isDemoMode { demoEnabled = newValue }
            else { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
        }
    }
    @ObservationIgnored private var scheduling: Task<Void, Never>?
    private var canManageSystemNotifications: Bool { !isDemoMode && store?.demoStore == nil }
    init(isDemoMode: Bool = false) {
        self.isDemoMode = isDemoMode
        super.init()
        guard !isDemoMode else { return }
        UNUserNotificationCenter.current().delegate = self
        let complete = UNNotificationAction(identifier: "COMPLETE", title: WorkspaceLocalization.string("完成"), options: .authenticationRequired)
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: WorkspaceLocalization.string("十分钟后提醒"), options: .authenticationRequired)
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "WORKSPACE_REMINDER", actions: [complete, snooze], intentIdentifiers: [])
        ])
    }
    func refreshAuthorization() async {
        guard canManageSystemNotifications else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        authorization = settings.authorizationStatus
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        pendingCount = pending.filter { $0.identifier.hasPrefix("gw:") }.count
    }
    func requestAuthorization() async throws {
        guard !isDemoMode else {
            demoEnabled = true
            store?.information = WorkspaceLocalization.string("演示提醒已开启，不会发送系统通知。")
            return
        }
        guard canManageSystemNotifications else { return }
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        enabled = allowed
        await refreshAuthorization()
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        if allowed, let store { reschedule(store.state) }
        if !allowed { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("系统未允许通知。请在系统通知设置中开启工作坊。")) }
    }
    func reschedule(_ state: WorkspaceState, debounce: Bool = false) {
        guard canManageSystemNotifications else { return }
        let previous = scheduling
        previous?.cancel()
        scheduling = Task { [weak self] in
            await previous?.value
            if debounce {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            await self.applySchedule(state)
        }
    }
    private func applySchedule(_ state: WorkspaceState) async {
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        // Reconcile against the system every time. A request may have fired or
        // been removed even when none of the workspace records have changed.
        let pending = await center.pendingNotificationRequests()
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        let owned = Dictionary(uniqueKeysWithValues: pending.filter { $0.identifier.hasPrefix("gw:") }
            .map { ($0.identifier, $0) })
        let visibleRecords = WorkspaceRecordIndex(state.records).visibleRecords
        let liveRecords = Dictionary(uniqueKeysWithValues: visibleRecords.map { ($0.id.uuidString, $0) })
        let delivered = await center.deliveredNotifications()
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        let obsolete = delivered.filter { notification in
            let content = notification.request.content
            let managed = notification.request.identifier.hasPrefix("gw:") || content.categoryIdentifier == "WORKSPACE_REMINDER"
            guard managed, let id = content.userInfo["id"] as? String else { return false }
            guard let record = liveRecords[id] else { return true }
            let scheduledAt = (content.userInfo["scheduledAt"] as? NSNumber)?.doubleValue
            return !WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduledAt)
        }.map { $0.request.identifier }
        if !obsolete.isEmpty { center.removeDeliveredNotifications(withIdentifiers: obsolete) }
        let overdue = visibleRecords.filter(\.isOverdue).count
        try? await center.setBadgeCount(enabled ? overdue : 0)
        guard canManageSystemNotifications, !Task.isCancelled else { return }
        let now = Date()
        let candidates = visibleRecords.compactMap { record -> (WorkspaceRecord, Date)? in
            guard let date = record.notificationDate, date > now else { return nil }
            return (record, date)
        }.sorted { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 < $1.1 }
        unscheduledCount = max(0, candidates.count - 60)
        var formatters: [String: DateFormatter] = [:]
        let desired = enabled ? candidates.prefix(60).map {
            makeRequest(for: $0.0, at: $0.1, formatters: &formatters)
        } : []
        let desiredIDs = Set(desired.map(\.identifier))
        let removed = owned.keys.filter { !desiredIDs.contains($0) }
        if !removed.isEmpty { center.removePendingNotificationRequests(withIdentifiers: removed) }
        for request in desired {
            guard canManageSystemNotifications, !Task.isCancelled else { return }
            if let existing = owned[request.identifier], requestsMatch(existing, request) { continue }
            // Adding an existing identifier replaces it without first leaving a
            // gap in its schedule. Unchanged requests keep their system state.
            do { try await center.add(request) }
            catch {
                guard canManageSystemNotifications, !Task.isCancelled else { return }
                store?.errorMessage = WorkspaceLocalization.format("通知安排失败：%@", String(describing: error.localizedDescription))
            }
        }
        await refreshAuthorization()
    }
    private func makeRequest(for record: WorkspaceRecord, at date: Date,
        formatters: inout [String: DateFormatter]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = WorkspaceLocalization.format("工作坊 · %@", String(describing: record.kind.title))
        content.body = record.title
        content.sound = .default
        content.threadIdentifier = record.projectID?.uuidString ?? "workspace-\(record.kind.rawValue)"
        if record.kind.isItem || record.kind == .deadline { content.categoryIdentifier = "WORKSPACE_REMINDER" }
        let calendar = record.calendar
        if let due = record.dueDate {
            let key = "\(calendar.timeZone.identifier)|\(record.dateOnly)"
            let formatter: DateFormatter
            if let cached = formatters[key] { formatter = cached }
            else {
                formatter = DateFormatter()
                formatter.locale = WorkspaceLocalization.locale
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = record.dateOnly ? WorkspaceLocalization.string("M月d日截止") : WorkspaceLocalization.string("M月d日 HH:mm截止")
                formatters[key] = formatter
            }
            content.subtitle = formatter.string(from: due)
        }
        content.userInfo = ["id": record.id.uuidString, "scheduledAt": Int64((date.timeIntervalSince1970 * 1000).rounded())]
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: "gw:\(record.id)", content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
    private func requestsMatch(_ actual: UNNotificationRequest, _ expected: UNNotificationRequest) -> Bool {
        guard actual.identifier == expected.identifier,
              let actualTrigger = actual.trigger as? UNCalendarNotificationTrigger,
              let expectedTrigger = expected.trigger as? UNCalendarNotificationTrigger,
              actualTrigger.repeats == expectedTrigger.repeats,
              actualTrigger.dateComponents == expectedTrigger.dateComponents else { return false }
        let left = actual.content, right = expected.content
        #if os(iOS)
        guard left.launchImageName == right.launchImageName else { return false }
        #endif
        return left.title == right.title && left.subtitle == right.subtitle && left.body == right.body
            && left.threadIdentifier == right.threadIdentifier && left.categoryIdentifier == right.categoryIdentifier
            && left.badge == right.badge
            && left.attachments.isEmpty && right.attachments.isEmpty
            && left.interruptionLevel == right.interruptionLevel && left.relevanceScore == right.relevanceScore
            && NSDictionary(dictionary: left.userInfo).isEqual(to: right.userInfo)
            && ((left.sound == nil && right.sound == nil) || left.sound?.isEqual(right.sound) == true)
    }
    func sendTest() async throws {
        guard !isDemoMode else {
            store?.information = WorkspaceLocalization.string("演示提醒：该去完成下一项安排了。")
            return
        }
        guard canManageSystemNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = WorkspaceLocalization.string("工作坊 · 通知测试")
        content.body = WorkspaceLocalization.string("系统通知已接通。提醒安排后，关闭应用也可以收到通知。")
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "workspace-test",
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard await MainActor.run(body: { !self.isDemoMode && self.store?.demoStore == nil }) else { return [] }
        return [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let rawID = response.notification.request.content.userInfo["id"] as? String
        let scheduledAt = (response.notification.request.content.userInfo["scheduledAt"] as? NSNumber)?.doubleValue
        let action = response.actionIdentifier
        guard let rawID, let id = UUID(uuidString: rawID) else { return }
        await handleNotification(id: id, action: action, scheduledAt: scheduledAt)
    }
    private func handleNotification(id: UUID, action: String, scheduledAt: Double?) async {
        guard let store, !store.isDemoMode, store.demoStore == nil else { return }
        if store.record(id) == nil, store.canAutomaticallySync {
            do { try await store.synchronize() }
            catch {
                guard !store.isDemoMode, store.demoStore == nil else { return }
                store.errorMessage = WorkspaceLocalization.format("无法取得这项提醒的最新资料：%@", String(describing: error.localizedDescription))
                return
            }
        }
        guard !store.isDemoMode, store.demoStore == nil else { return }
        guard let record = store.record(id) else {
            store.information = WorkspaceLocalization.string("此提醒对应的记录尚未同步到本机。请确认已登录同一账号并开启自动同步。")
            return
        }
        if action == "COMPLETE" || action == "SNOOZE" {
            guard WorkspaceLogic.visible(record, in: store.state), !record.isFinished,
                  (record.kind.isItem || record.kind == .deadline),
                  WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduledAt) else {
                store.information = WorkspaceLocalization.string("这项提醒已经完成、关闭或改期，旧通知没有修改当前记录。")
                return
            }
        }
        if action == "COMPLETE" { store.perform { try store.setStatus(id, record.kind == .project ? "COMPLETED" : "DONE") } }
        else if action == "SNOOZE" {
            var changed = record
            changed.snoozedUntil = Date().addingTimeInterval(600)
            store.perform { try store.save(changed, expectedVersion: record.version) }
        } else {
            store.navigation = record.kind == .knowledge ? .knowledge : record.kind == .deadline ? .deadlines : .actions
            store.openedRecordID = id
        }
    }
}
