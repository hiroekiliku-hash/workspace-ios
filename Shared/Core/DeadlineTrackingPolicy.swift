import Foundation

enum DeadlineTrackingPolicy {
    static let maximumDuration: TimeInterval = 8 * 3600
    static func dueDate(for record: WorkspaceRecord, in state: WorkspaceState, now: Date = Date(), startedAt: Date? = nil) -> Date? {
        guard let due = eligibleDueDate(for: record, now: now, startedAt: startedAt),
              WorkspaceLogic.visible(record, in: state) else { return nil }
        return due
    }
    private static func eligibleDueDate(for record: WorkspaceRecord, now: Date, startedAt: Date?) -> Date? {
        guard (record.kind.isItem || record.kind == .deadline), !record.isFinished,
              let date = record.dueDate else { return nil }
        let due = record.effectiveDueDate(date)
        guard due > now, due.timeIntervalSince(now) <= maximumDuration,
              startedAt.map({ due <= $0.addingTimeInterval(maximumDuration) }) ?? true else { return nil }
        return due
    }
    static func nearestRecords(in state: WorkspaceState, now: Date = Date(), startedAt: Date? = nil) -> [WorkspaceRecord] {
        // Resolve parent visibility once, rather than scanning all records at each
        // ancestor for every candidate during automatic activity refreshes.
        WorkspaceRecordIndex(state.records).visibleRecords.compactMap { record -> (WorkspaceRecord, Date)? in
            guard let due = eligibleDueDate(for: record, now: now, startedAt: startedAt) else { return nil }
            return (record, due)
        }.sorted {
            $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 < $1.1
        }.prefix(3).map { $0.0 }
    }
    static func explanation(for record: WorkspaceRecord, in state: WorkspaceState, now: Date = Date()) -> String {
        if !record.kind.isItem && record.kind != .deadline { return WorkspaceLocalization.string("实时活动用于有截止时间的事项和截止事项。") }
        if record.isFinished || !WorkspaceLogic.visible(record, in: state) { return WorkspaceLocalization.string("完成、取消或归档的事项不能开始追踪。") }
        guard let date = record.dueDate else { return WorkspaceLocalization.string("设置截止时间后可开始追踪。") }
        if record.effectiveDueDate(date) <= now { return WorkspaceLocalization.string("此事项已到截止时间。") }
        if record.effectiveDueDate(date).timeIntervalSince(now) > maximumDuration { return WorkspaceLocalization.string("截止前 8 小时内可开始锁屏追踪。") }
        return WorkspaceLocalization.string("标题与倒计时会显示在锁屏和灵动岛，点击可回到详情。")
    }
}
