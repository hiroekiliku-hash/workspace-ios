import SwiftUI

/// A read-only projection. The wheel never reschedules or completes a record.
struct TimelinePresentation: Equatable {
    struct Event: Identifiable, Equatable {
        let id: UUID
        let title: String
        let date: Date
        let allDay: Bool
        let projectTitle: String?
        let pinned: Bool
        let finished: Bool
        let overdue: Bool
        let deadline: Bool
        let timeLabel: String
        let accessibilityLabel: String
    }

    struct Group: Identifiable, Equatable {
        var events: [Event]
        var dayLabel = ""
        var timeLabel = ""
        var monthLabel = ""
        var dateLabel = ""
        var focusLabel = ""
        var id: UUID { events[0].id }
        var date: Date { events[0].date }
        var end: Date { events[events.count - 1].date }
        var allDay: Bool { events[0].allDay }
    }

    let groups: [Group]
    let calendar: Calendar

    init(records: [WorkspaceRecord], timezone: String) {
        let calendar = WorkspaceDates.calendar(timezone)
        self.calendar = calendar
        // Match list/notification visibility, including every hidden or missing ancestor.
        let visibleRecords = WorkspaceRecordIndex(records).visibleRecords
        let projects = Dictionary(visibleRecords.filter { $0.kind.isProjectGroup }
            .map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let events = visibleRecords.compactMap { record -> Event? in
            guard record.kind.isItem || record.kind == .deadline else { return nil }
            let date = record.kind == .deadline ? record.dueDate : record.scheduledAt ?? record.remindAt ?? record.dueDate
            guard var date else { return nil }
            let hasItemTime = record.kind.isItem && (record.scheduledAt != nil || record.remindAt != nil)
            let allDay = record.dateOnly && !hasItemTime
            if allDay {
                // Preserve date-only calendar days across workspace timezones.
                date = calendar.date(from: record.calendar.dateComponents([.year, .month, .day], from: date)) ?? date
            }
            let time = allDay ? WorkspaceLocalization.string("全天") : Self.formatted(date,
                style: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits), calendar: calendar)
            let day = Self.dayLabel(date, calendar: calendar)
            return Event(id: record.id, title: record.title, date: date, allDay: allDay,
                projectTitle: (record.projectID ?? record.areaID).flatMap { projects[$0] },
                pinned: record.pinned, finished: record.isFinished, overdue: record.isOverdue,
                deadline: record.kind == .deadline, timeLabel: time,
                accessibilityLabel: record.title + (record.isFinished ? WorkspaceLocalization.string("，已完成") : "") + "，" + day + " " + time)
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        var groups: [Group] = []
        for event in events {
            if let last = groups.last, last.events.count < 3,
               last.allDay == event.allDay, calendar.isDate(last.date, inSameDayAs: event.date),
               event.allDay || event.date.timeIntervalSince(last.date) <= 45 * 60 {
                groups[groups.count - 1].events.append(event)
            } else {
                groups.append(Group(events: [event]))
            }
        }
        // Formatting belongs to data preparation, never to the display-link render loop.
        for index in groups.indices {
            let group = groups[index]
            let first = group.events[0].timeLabel, last = group.events[group.events.count - 1].timeLabel
            groups[index].dayLabel = Self.dayLabel(group.date, calendar: calendar)
            groups[index].timeLabel = first == last ? first : first + " – " + last
            groups[index].monthLabel = Self.formatted(group.date, style: .dateTime.year().month(), calendar: calendar)
            groups[index].dateLabel = Self.formatted(group.date, style: .dateTime.day().weekday(.wide), calendar: calendar)
            groups[index].focusLabel = WorkspaceLocalization.string("居中查看，") + groups[index].dayLabel + "，" + groups[index].timeLabel
        }
        self.groups = groups
    }

    func initialIndex(now: Date = .now) -> Int {
        // Prefer the next timed group today, then the next available date.
        groups.firstIndex { group in
            group.allDay ? calendar.isDate(group.date, inSameDayAs: now) || group.date > now : group.end >= now
        } ?? max(0, groups.count - 1)
    }

    private static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return WorkspaceLocalization.string("今天") }
        if calendar.isDateInTomorrow(date) { return WorkspaceLocalization.string("明天") }
        if calendar.isDateInYesterday(date) { return WorkspaceLocalization.string("昨天") }
        return formatted(date, style: .dateTime.month().day().weekday(.abbreviated), calendar: calendar)
    }

    private static func formatted(_ date: Date, style: Date.FormatStyle, calendar: Calendar) -> String {
        var style = style
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = WorkspaceLocalization.locale
        return date.formatted(style)
    }
}

struct TimelineWheelLayout: Equatable {
    let anchors: [CGFloat]
    let heights: [CGFloat]
    let headerHeight: CGFloat

    init(presentation: TimelinePresentation, rowHeight: CGFloat) {
        // The date header needs to grow with Dynamic Type along with its event rows.
        let headerHeight = max(22, rowHeight * 22 / 64)
        self.headerHeight = headerHeight
        heights = presentation.groups.map { 36 + headerHeight + CGFloat($0.events.count) * rowHeight }
        var anchors: [CGFloat] = []
        var offset: CGFloat = 0
        for index in presentation.groups.indices {
            if index > 0 {
                // Consistent compact spacing, including between calendar days.
                offset += (heights[index - 1] + heights[index]) / 2 + 10
            }
            anchors.append(offset)
        }
        self.anchors = anchors
    }

    /// A fisheye projection: precise near the center, compressed toward the ends.
    static func projected(_ distance: CGFloat, height: CGFloat) -> CGFloat {
        let radius = max(240, height * 0.58)
        return radius * asinh(distance / radius)
    }
}
