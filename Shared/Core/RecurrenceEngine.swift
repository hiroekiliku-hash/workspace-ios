import Foundation
import CryptoKit

enum RecurrenceEngine {
    static func monday(containing date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: day) ?? day
    }
    static func validationError(record: WorkspaceRecord, rule: RecurrenceRule) -> String? {
        guard record.kind.isItem || record.kind == .deadline, let anchor = record.recurrenceAnchor else {
            return WorkspaceLocalization.string("请先设置计划时间或截止日期；已有自定义提醒时间也可以作为重复起点。")
        }
        guard (1...365).contains(rule.interval), rule.weekdays.allSatisfy({ (1...7).contains($0) }),
              rule.frequency.supportsInterval || rule.interval == 1 else { return WorkspaceLocalization.string("重复间隔或星期选择无效。") }
        let calendar = record.calendar
        if let until = rule.until, calendar.startOfDay(for: until) < calendar.startOfDay(for: anchor) {
            return WorkspaceLocalization.string("重复结束日期不能早于首次日期。")
        }
        if rule.frequency.usesWeekParity, let first = rule.weekOneStart,
           monday(containing: first, calendar: calendar) > monday(containing: anchor, calendar: calendar) {
            return WorkspaceLocalization.string("第1周不能晚于首次事项所在周。")
        }
        if rule.frequency == .workdays, ChinaWorkCalendar.isWorkday(anchor, calendar: calendar) == nil {
            return WorkspaceLocalization.string("该年份的调休日历尚未内置。当前支持2025—2026年，可更新日历后使用，或选择周一至周五重复。")
        }
        return nil
    }
    static func dates(anchor: Date, rule: RecurrenceRule, from: Date, through: Date, timezone: String, limit: Int? = nil) -> [Date] {
        let calendar = WorkspaceDates.calendar(timezone)
        let anchorDay = calendar.startOfDay(for: anchor)
        var day = max(anchorDay, calendar.startOfDay(for: from))
        var last = min(calendar.startOfDay(for: through), rule.until.map { calendar.startOfDay(for: $0) } ?? through)
        if rule.frequency == .workdays {
            guard let covered = ChinaWorkCalendar.coverageEnd(from: day, calendar: calendar) else { return [] }
            last = min(last, covered)
        }
        guard day <= last, (1...365).contains(rule.interval), limit.map({ $0 > 0 }) ?? true else { return [] }
        let isoWeekday = (calendar.component(.weekday, from: anchorDay) + 5) % 7 + 1
        let anchorMonday = monday(containing: anchorDay, calendar: calendar)
        let firstMonday = monday(containing: rule.weekOneStart ?? anchorDay, calendar: calendar)
        let selectedWeekdays = rule.weekdays.isEmpty ? [isoWeekday] : rule.weekdays
        let anchorDayNumber = calendar.component(.day, from: anchorDay)
        let anchorMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: anchorDay)) ?? anchorDay
        var result: [Date] = []
        for _ in 0..<1200 {
            guard day <= last else { break }
            let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
            // Preserve the legacy first occurrence for existing daily/weekly/monthly rules.
            var matches = rule.frequency.supportsInterval && day == anchorDay
            switch rule.frequency {
            case .daily:
                let days = calendar.dateComponents([.day], from: anchorDay, to: day).day ?? 0
                matches = matches || days % rule.interval == 0
            case .weekly:
                let days = calendar.dateComponents([.day], from: anchorMonday, to: day).day ?? 0
                matches = matches || ((days / 7) % rule.interval == 0 && selectedWeekdays.contains(weekday))
            case .oddWeeks, .evenWeeks:
                let days = calendar.dateComponents([.day], from: firstMonday, to: day).day ?? 0
                let parity = rule.frequency == .oddWeeks ? 0 : 1
                matches = days >= 0 && (days / 7) % 2 == parity && selectedWeekdays.contains(weekday)
            case .weekdays: matches = weekday <= 5
            case .workdays: matches = ChinaWorkCalendar.isWorkday(day, calendar: calendar) == true
            case .monthly:
                let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
                let months = calendar.dateComponents([.month], from: anchorMonth, to: month).month ?? 0
                let lastDay = calendar.range(of: .day, in: .month, for: day)?.count ?? 28
                matches = matches || (months % rule.interval == 0 && calendar.component(.day, from: day) == min(anchorDayNumber, lastDay))
            }
            if matches {
                result.append(day)
                if let limit, result.count >= limit { break }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
    static func start(_ id: UUID, rule: RecurrenceRule, in state: inout WorkspaceState, now: Date = Date()) throws {
        guard let index = state.records.firstIndex(where: { $0.id == id }),
              WorkspaceLogic.visible(state.records[index], in: state), !state.records[index].isFinished,
              state.records[index].recurrenceSeriesID == nil else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("只能为未完成且尚未重复的事项或截止事项设置重复。"))
        }
        let template = state.records[index]
        if let error = validationError(record: template, rule: rule) { throw WorkspaceFailure.invalid(error) }
        guard let anchor = template.recurrenceAnchor else { return }
        let series = DeadlineSeries(template: template, rule: rule)
        state.series.append(series)
        state.records[index].recurrenceSeriesID = series.id
        state.records[index].occurrenceDate = WorkspaceDates.dayKey(anchor, timezone: template.timezone)
        state.records[index].isException = dates(anchor: anchor, rule: rule, from: anchor, through: anchor, timezone: template.timezone).isEmpty
        state.records[index].version += 1; state.records[index].updatedAt = now
        materialize(&state, now: now)
    }
    @discardableResult static func stop(_ id: UUID, in state: inout WorkspaceState, now: Date = Date()) -> [UUID] {
        guard let series = state.series.firstIndex(where: { $0.id == id }) else { return [] }
        state.series[series].stoppedAt = now
        var changed: [UUID] = []
        for index in state.records.indices where state.records[index].recurrenceSeriesID == id &&
            !state.records[index].isFinished && state.records[index].isLive &&
            state.records[index].recurrenceEffectiveDate.map({ $0 >= now }) == true {
            close(&state.records[index], at: now)
            changed.append(state.records[index].id)
        }
        return changed
    }
    static func reconcileStoppedSeries(in state: inout WorkspaceState) {
        let stopped = Dictionary(uniqueKeysWithValues: state.series.compactMap { series in
            series.stoppedAt.map { (series.id, $0) }
        })
        // Another offline device can generate additional cache entries after a stop.
        // Close those untouched entries without overriding individually edited instances.
        for index in state.records.indices {
            let record = state.records[index]
            guard let id = record.recurrenceSeriesID, let at = stopped[id],
                  record.version == 1, !record.isException, record.isLive, !record.isFinished,
                  record.recurrenceEffectiveDate.map({ $0 >= at }) == true else { continue }
            close(&state.records[index], at: at)
        }
    }
    private static func close(_ record: inout WorkspaceRecord, at date: Date) {
        if record.kind.states.contains("CANCELLED") {
            record.status = "CANCELLED"; record.cancelledAt = date
        } else { record.archivedAt = date }
        record.version += 1; record.updatedAt = date
    }
    /// Persist a small window for lists, reminders and offline use. The rule is
    /// the source of truth; generatedThrough is only old-client cache metadata.
    static let futureWindowDays = 30

    static func materialize(_ state: inout WorkspaceState, now: Date = Date()) {
        normalizeGeneratedCache(&state, now: now)
        let visible = WorkspaceRecordIndex(state.records)
        var existingBySeries = Dictionary(grouping: state.records.compactMap { record -> (UUID, String)? in
            guard let id = record.recurrenceSeriesID, let key = record.occurrenceDate else { return nil }
            return (id, key)
        }, by: { $0.0 }).mapValues { Set($0.map(\.1)) }
        for index in state.series.indices {
            let series = state.series[index]
            guard series.stoppedAt == nil, series.deletedAt == nil, let anchor = series.template.recurrenceAnchor,
                  visibleRecord(series.template, using: visible), let horizon = windowEnd(for: series, now: now) else { continue }
            let today = series.template.calendar.startOfDay(for: now)
            var days = dates(anchor: anchor, rule: series.rule, from: max(today, anchor),
                through: horizon, timezone: series.template.timezone)
            // A first date outside the cache window must still appear in lists.
            // Also keep sparse monthly/annual patterns discoverable between dates.
            if days.isEmpty, let next = nextOccurrenceDay(for: series, from: today) { days = [next] }
            var existing = existingBySeries[series.id] ?? []
            for day in days {
                let key = WorkspaceDates.dayKey(day, timezone: series.template.timezone)
                guard existing.insert(key).inserted else { continue }
                state.records.append(occurrence(for: series, on: day))
            }
            existingBySeries[series.id] = existing
            // Never use this marker to skip filling holes: old clients wrote a
            // three-year horizon, and a prior cache eviction is not a deletion.
            state.series[index].generatedThrough = horizon
        }
    }

    /// Drop only proven generated future cache entries. No tombstones are made:
    /// these are projections, and a later visible date range can recreate them.
    /// Cross-device merge passes the same time and shared protected IDs to each
    /// snapshot so evicting cache cannot masquerade as a delete-versus-edit.
    @discardableResult
    static func normalizeGeneratedCache(_ state: inout WorkspaceState, now: Date = Date(),
                                        protecting protectedIDs: Set<UUID> = []) -> Set<UUID> {
        var protected = protectedIDs
        for record in state.records {
            protected.formUnion([record.projectID, record.milestoneID, record.areaID].compactMap { $0 })
        }
        for series in state.series {
            protected.insert(series.template.id)
            protected.formUnion([series.template.projectID, series.template.milestoneID, series.template.areaID].compactMap { $0 })
        }
        for asset in state.assets { protected.insert(asset.ownerID) }
        for activity in state.activities {
            protected.insert(activity.entityID)
            if let projectID = activity.projectID { protected.insert(projectID) }
        }
        for revision in state.revisions {
            protected.insert(revision.record.id)
            protected.formUnion([revision.record.projectID, revision.record.milestoneID, revision.record.areaID].compactMap { $0 })
        }
        for batch in state.trash {
            protected.insert(batch.rootID); protected.formUnion(batch.itemIDs)
        }
        let seriesByID = Dictionary(uniqueKeysWithValues: state.series.map { ($0.id, $0) })
        let windows = Dictionary(uniqueKeysWithValues: state.series.compactMap { series -> (UUID, (end: Date, next: Date?))? in
            guard series.stoppedAt == nil, series.deletedAt == nil, let end = windowEnd(for: series, now: now) else { return nil }
            return (series.id, (end, nextOccurrenceDay(for: series, from: series.template.calendar.startOfDay(for: now))))
        })
        var removed: Set<UUID> = []
        state.records.removeAll { record in
            guard !protected.contains(record.id), let id = record.recurrenceSeriesID,
                  let series = seriesByID[id], let window = windows[id],
                  let key = record.occurrenceDate, let day = occurrenceDay(key, calendar: series.template.calendar),
                  day > window.end, day != window.next,
                  // Comparing every field protects even an unversioned manual
                  // change to title, dates, flags, links or notification settings.
                  record == occurrence(for: series, on: day) else { return false }
            removed.insert(record.id)
            return true
        }
        for index in state.series.indices {
            if let end = windows[state.series[index].id]?.end,
               state.series[index].generatedThrough.map({ $0 > end }) == true {
                state.series[index].generatedThrough = end
            }
        }
        return removed
    }

    /// Existing records plus virtual occurrences needed for the requested range.
    /// This does not alter storage or rolling progress. Existing exceptions and
    /// tombstones win by occurrence key, so deleted dates never reappear.
    static func projectedRecords(in state: WorkspaceState, from: Date, through: Date) -> [WorkspaceRecord] {
        guard from <= through else { return state.records }
        let visible = WorkspaceRecordIndex(state.records)
        let existing = Dictionary(grouping: state.records.compactMap { record -> (UUID, String)? in
            guard let id = record.recurrenceSeriesID, let key = record.occurrenceDate else { return nil }
            return (id, key)
        }, by: { $0.0 }).mapValues { Set($0.map(\.1)) }
        var result = state.records
        for series in state.series where series.stoppedAt == nil && series.deletedAt == nil && visibleRecord(series.template, using: visible) {
            guard let anchor = series.template.recurrenceAnchor else { continue }
            for day in dates(anchor: anchor, rule: series.rule, from: from, through: through, timezone: series.template.timezone) {
                let key = WorkspaceDates.dayKey(day, timezone: series.template.timezone)
                guard existing[series.id]?.contains(key) != true else { continue }
                result.append(occurrence(for: series, on: day))
            }
        }
        return result
    }

    private static func visibleRecord(_ record: WorkspaceRecord, using index: WorkspaceRecordIndex) -> Bool {
        guard record.isLive else { return false }
        return [record.projectID, record.areaID].compactMap { $0 }.allSatisfy(index.isVisible)
    }

    private static func windowEnd(for series: DeadlineSeries, now: Date) -> Date? {
        let calendar = series.template.calendar
        let today = calendar.startOfDay(for: now)
        guard var end = calendar.date(byAdding: .day, value: futureWindowDays, to: today) else { return nil }
        if let until = series.rule.until { end = min(end, calendar.startOfDay(for: until)) }
        if series.rule.frequency == .workdays {
            guard let anchor = series.template.recurrenceAnchor,
                  let covered = ChinaWorkCalendar.coverageEnd(from: max(today, calendar.startOfDay(for: anchor)), calendar: calendar) else { return nil }
            end = min(end, covered)
        }
        return end
    }

    private static func nextOccurrenceDay(for series: DeadlineSeries, from: Date) -> Date? {
        guard let anchor = series.template.recurrenceAnchor, (1...365).contains(series.rule.interval) else { return nil }
        let calendar = series.template.calendar, rule = series.rule
        let anchorDay = calendar.startOfDay(for: anchor)
        let first = max(anchorDay, calendar.startOfDay(for: from))
        var search = first
        var searchDays = 14
        switch rule.frequency {
        case .daily:
            let elapsed = calendar.dateComponents([.day], from: anchorDay, to: first).day ?? 0
            let offset = ((elapsed + rule.interval - 1) / rule.interval) * rule.interval
            search = calendar.date(byAdding: .day, value: offset, to: anchorDay) ?? first
            searchDays = 0
        case .weekly:
            if first == anchorDay { return allowed(anchorDay, by: series) }
            let anchorWeek = monday(containing: anchor, calendar: calendar)
            let elapsed = calendar.dateComponents([.day], from: anchorWeek, to: first).day ?? 0
            let week = elapsed / 7
            let offset = ((week + rule.interval - 1) / rule.interval) * rule.interval
            search = calendar.date(byAdding: .weekOfYear, value: offset, to: anchorWeek) ?? first
            // The eligible week can have already passed this week's weekdays.
            let end = calendar.date(byAdding: .day, value: 6, to: search) ?? search
            if let result = dates(anchor: anchor, rule: rule, from: max(first, search), through: end,
                                  timezone: series.template.timezone, limit: 1).first { return result }
            search = calendar.date(byAdding: .weekOfYear, value: rule.interval, to: search) ?? first
            searchDays = 6
        case .monthly:
            let anchorMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: anchorDay)) ?? anchorDay
            let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: first)) ?? first
            let elapsed = calendar.dateComponents([.month], from: anchorMonth, to: firstMonth).month ?? 0
            var offset = ((elapsed + rule.interval - 1) / rule.interval) * rule.interval
            for _ in 0..<2 {
                guard let month = calendar.date(byAdding: .month, value: offset, to: anchorMonth),
                      let days = calendar.range(of: .day, in: .month, for: month),
                      let candidate = calendar.date(byAdding: .day, value: min(calendar.component(.day, from: anchorDay), days.count) - 1, to: month) else { return nil }
                if candidate >= first { return allowed(candidate, by: series) }
                offset += rule.interval
            }
            return nil
        case .oddWeeks, .evenWeeks, .weekdays: break
        case .workdays:
            guard let covered = ChinaWorkCalendar.coverageEnd(from: first, calendar: calendar) else { return nil }
            return dates(anchor: anchor, rule: rule, from: first, through: covered,
                         timezone: series.template.timezone, limit: 1).first
        }
        let end = calendar.date(byAdding: .day, value: searchDays, to: search) ?? search
        return dates(anchor: anchor, rule: rule, from: search, through: end,
                     timezone: series.template.timezone, limit: 1).first
    }

    private static func allowed(_ day: Date, by series: DeadlineSeries) -> Date? {
        guard series.rule.until.map({ day <= series.template.calendar.startOfDay(for: $0) }) ?? true else { return nil }
        return day
    }

    private static func occurrenceDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              WorkspaceDates.dayKey(date, timezone: calendar.timeZone.identifier) == key else { return nil }
        return date
    }

    private static func occurrence(for series: DeadlineSeries, on day: Date) -> WorkspaceRecord {
        let calendar = series.template.calendar
        let anchor = series.template.recurrenceAnchor ?? day
        let key = WorkspaceDates.dayKey(day, timezone: series.template.timezone)
        var record = series.template
        record.id = occurrenceID(seriesID: series.id, dayKey: key); record.version = 1
        record.createdAt = series.template.createdAt; record.updatedAt = record.createdAt
        record.status = record.kind.states.first ?? "OPEN"
        record.completedAt = nil; record.cancelledAt = nil
        record.archivedAt = nil; record.deletedAt = nil; record.trashBatchID = nil
        record.recurrenceSeriesID = series.id; record.occurrenceDate = key; record.isException = false
        record.calendarEventID = nil; record.snoozedUntil = nil
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor), to: day).day ?? 0
        func shift(_ value: Date?) -> Date? { value.flatMap { calendar.date(byAdding: .day, value: offset, to: $0) } }
        record.scheduledAt = shift(series.template.scheduledAt)
        record.remindAt = shift(series.template.remindAt)
        record.dueDate = shift(series.template.dueDate)
        if record.dateOnly, let due = record.dueDate { record.dueDate = calendar.startOfDay(for: due) }
        return record
    }
    private static func occurrenceID(seriesID: UUID, dayKey: String) -> UUID {
        var namespace = seriesID.uuid
        var data = withUnsafeBytes(of: &namespace) { Data($0) }
        data.append(contentsOf: dayKey.utf8)
        // UUID v5 is an identifier, not an authentication or integrity primitive.
        var b = Array(Insecure.SHA1.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

enum ChinaWorkCalendar {
    static let coveredYears: Set<Int> = [2025, 2026]
    static let source2025 = "https://www.forestry.gov.cn/c/www/szxx/594663.jhtml"
    static let source2026 = "https://www.beijing.gov.cn/fuwu/bmfw/sy/jrts/202511/t20251104_4258838.html"
    // State Council notices 国办发明电〔2024〕12号 and〔2025〕7号.
    private static let holidays: [ClosedRange<String>] = [
        "2025-01-01"..."2025-01-01", "2025-01-28"..."2025-02-04", "2025-04-04"..."2025-04-06",
        "2025-05-01"..."2025-05-05", "2025-05-31"..."2025-06-02", "2025-10-01"..."2025-10-08",
        "2026-01-01"..."2026-01-03", "2026-02-15"..."2026-02-23", "2026-04-04"..."2026-04-06",
        "2026-05-01"..."2026-05-05", "2026-06-19"..."2026-06-21", "2026-09-25"..."2026-09-27",
        "2026-10-01"..."2026-10-07"
    ]
    private static let workingWeekends: Set<String> = [
        "2025-01-26", "2025-02-08", "2025-04-27", "2025-09-28", "2025-10-11",
        "2026-01-04", "2026-02-14", "2026-02-28", "2026-05-09", "2026-09-20", "2026-10-10"
    ]
    static func isWorkday(_ day: Date, calendar: Calendar) -> Bool? {
        guard coveredYears.contains(calendar.component(.year, from: day)) else { return nil }
        let key = WorkspaceDates.dayKey(day, timezone: calendar.timeZone.identifier)
        if workingWeekends.contains(key) { return true }
        if holidays.contains(where: { $0.contains(key) }) { return false }
        return !calendar.isDateInWeekend(day)
    }
    static func coverageEnd(from day: Date, calendar: Calendar) -> Date? {
        var year = calendar.component(.year, from: day)
        guard coveredYears.contains(year) else { return nil }
        while coveredYears.contains(year + 1) { year += 1 }
        return calendar.date(from: DateComponents(year: year, month: 12, day: 31))
    }
}
