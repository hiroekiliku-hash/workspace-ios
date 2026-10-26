import Foundation
import EventKit

enum SystemCalendarService {
    @MainActor static func add(_ record: WorkspaceRecord) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请在系统隐私设置中允许日历访问。"))
        }
        let start = record.scheduledAt ?? record.dueDate ?? record.targetDate ?? Date()
        let preferenceKey = "calendarEvent." + record.id.uuidString
        let existingID = UserDefaults.standard.string(forKey: preferenceKey)
        let event = existingID.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        event.title = record.title; event.notes = record.summary + "\n" + record.body
        event.startDate = start
        event.isAllDay = record.scheduledAt == nil && record.dateOnly
        event.endDate = event.isAllDay ? record.calendar.date(byAdding: .day, value: 1, to: start) : start.addingTimeInterval(3600)
        event.timeZone = record.calendar.timeZone
        event.url = URL(string: "guangyi-workspace://record/\(record.id.uuidString)")
        event.calendar = event.calendar ?? store.defaultCalendarForNewEvents
        guard event.calendar != nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("系统尚未设置默认日历。")) }
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("系统日历未返回事件标识。")) }
        UserDefaults.standard.set(id, forKey: preferenceKey)
        return id
    }
}
