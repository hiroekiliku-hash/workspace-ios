import Foundation

/// Rebuilt when records change, then shared by the store's list queries. Hidden
/// parents propagate once instead of scanning the entire workspace for each row.
struct WorkspaceRecordIndex {
    let byID: [UUID: WorkspaceRecord]
    let visibleRecords: [WorkspaceRecord]
    private let recordsByKind: [ItemKind: [WorkspaceRecord]]
    private let visibleIDs: Set<UUID>
    private let membersByParent: [UUID: [WorkspaceRecord]]
    private let actionMoments: [UUID: Date]

    init(_ records: [WorkspaceRecord]) {
        byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [UUID: [UUID]] = [:]
        var hidden: Set<UUID> = []
        for record in records {
            if !record.isLive { hidden.insert(record.id) }
            for parent in [record.projectID, record.areaID].compactMap({ $0 }) {
                children[parent, default: []].append(record.id)
                if byID[parent] == nil { hidden.insert(record.id) }
            }
        }
        var pending = Array(hidden), cursor = 0
        while cursor < pending.count {
            let parent = pending[cursor]
            cursor += 1
            for child in children[parent] ?? [] where hidden.insert(child).inserted {
                pending.append(child)
            }
        }
        visibleRecords = records.filter { !hidden.contains($0.id) }
        visibleIDs = Set(visibleRecords.map(\.id))
        var members: [UUID: [WorkspaceRecord]] = [:]
        for record in visibleRecords {
            // A record may reference the same parent through both relationships.
            for parent in Set([record.projectID, record.areaID].compactMap({ $0 })) where parent != record.id {
                members[parent, default: []].append(record)
            }
        }
        membersByParent = members
        recordsByKind = Dictionary(grouping: records.filter { $0.deletedAt == nil }, by: \.kind)
        // The order depends on stored dates, not the wall clock. Overdue badges
        // and countdown grouping remain live calculations in their own views.
        actionMoments = Dictionary(uniqueKeysWithValues: visibleRecords.compactMap { record in
            (record.dueDate.map(record.effectiveDueDate) ?? record.remindAt ?? record.scheduledAt ?? record.targetDate)
                .map { (record.id, $0) }
        })
    }

    func isVisible(_ id: UUID) -> Bool { visibleIDs.contains(id) }

    func records(_ kind: ItemKind, includeArchived: Bool = false) -> [WorkspaceRecord] {
        (recordsByKind[kind] ?? []).filter { includeArchived || visibleIDs.contains($0.id) }
            .sorted { left, right in
                if kind != .deadline, left.pinned != right.pinned { return left.pinned }
                if kind == .deadline || kind == .reminder {
                    if left.isFinished != right.isFinished { return !left.isFinished }
                    let a = left.dueDate.map { kind == .deadline ? left.effectiveDueDate($0) : $0 } ?? left.remindAt ?? .distantFuture
                    let b = right.dueDate.map { kind == .deadline ? right.effectiveDueDate($0) : $0 } ?? right.remindAt ?? .distantFuture
                    if a != b { return a < b }
                }
                if kind == .deadline, left.pinned != right.pinned { return left.pinned }
                return left.updatedAt > right.updatedAt
            }
    }

    var actionRecords: [WorkspaceRecord] {
        visibleRecords.filter { $0.kind.isItem }.sorted(by: actionPrecedes)
    }
    var projectGroupRecords: [WorkspaceRecord] {
        visibleRecords.filter { $0.kind.isProjectGroup }.sorted(by: actionPrecedes)
    }
    func members(of group: WorkspaceRecord) -> [WorkspaceRecord] {
        (membersByParent[group.id] ?? []).sorted(by: actionPrecedes)
    }
    private func actionPrecedes(_ left: WorkspaceRecord, _ right: WorkspaceRecord) -> Bool {
        if left.pinned != right.pinned { return left.pinned }
        if left.isFinished != right.isFinished { return !left.isFinished }
        let leftMoment = actionMoments[left.id], rightMoment = actionMoments[right.id]
        if let leftMoment, let rightMoment, leftMoment != rightMoment { return leftMoment < rightMoment }
        if (leftMoment != nil) != (rightMoment != nil) { return leftMoment != nil }
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.id.uuidString < right.id.uuidString
    }
}

struct DeadlineCountdownGroup: Identifiable {
    private(set) var records: [WorkspaceRecord]
    private(set) var dueDates: [Date]
    var id: UUID { records[0].id }

    fileprivate init(record: WorkspaceRecord, due: Date) {
        records = [record]; dueDates = [due]
    }
    fileprivate mutating func append(_ group: Self) {
        records.append(contentsOf: group.records)
        dueDates.append(contentsOf: group.dueDates)
    }
    func countdownDate(at now: Date) -> Date {
        dueDates.first { $0 > now } ?? dueDates[dueDates.count - 1]
    }
}

enum WorkspaceLogic {
    /// Rename the current classification without rewriting deleted records or historical snapshots.
    @discardableResult
    static func renameProjectCategory(from old: String, to new: String,
                                      in state: inout WorkspaceState, now: Date = Date()) throws -> Int {
        let category = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, category.utf16.count <= 240,
              !category.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("分类名称须为 1 至 240 个字符，且不能包含控制字符。"))
        }
        return try reclassifyProjectGroups(from: old, to: category, in: &state, now: now)
    }

    /// Removing a category preserves its groups, contents, and relationships.
    @discardableResult
    static func removeProjectCategory(_ category: String, in state: inout WorkspaceState,
                                      now: Date = Date()) throws -> Int {
        guard !category.isEmpty else { return 0 }
        return try reclassifyProjectGroups(from: category, to: "", in: &state, now: now)
    }

    private static func reclassifyProjectGroups(from old: String, to category: String,
                                               in state: inout WorkspaceState, now: Date) throws -> Int {
        guard old != category else { return 0 }
        let indices = state.records.indices.filter {
            let record = state.records[$0]
            return record.deletedAt == nil && record.kind.isProjectGroup && record.projectKind == old
        }
        // Validate the entire change before the first mutation, including safe version increments.
        guard indices.allSatisfy({ state.records[$0].version < Int.max }) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("项目组版本已超出范围，无法修改分类。"))
        }
        for index in indices {
            state.records[index].projectKind = category
            state.records[index].version += 1
            state.records[index].updatedAt = now
            let record = state.records[index]
            state.activities.append(ActivityEntry(entityID: record.id,
                projectID: record.kind == .project ? record.id : record.projectID,
                title: record.title, message: category.isEmpty ? "移除项目组分类" : "修改项目组分类", date: now))
        }
        return indices.count
    }
    static func deadlineCountdownGroups(_ records: [WorkspaceRecord], now: Date = Date(), timezone: String = "Asia/Shanghai") -> [DeadlineCountdownGroup] {
        let calendar = WorkspaceDates.calendar(timezone)
        let today = calendar.startOfDay(for: now)
        let dated = records.compactMap { record -> (record: WorkspaceRecord, due: Date)? in
            guard record.kind == .deadline, record.isLive, !record.isFinished, let due = record.dueDate else { return nil }
            return (record, record.effectiveDueDate(due))
        }.sorted {
            $0.due == $1.due ? $0.record.id.uuidString < $1.record.id.uuidString : $0.due < $1.due
        }
        var dayGroups: [DeadlineCountdownGroup] = []
        for entry in dated {
            let group = DeadlineCountdownGroup(record: entry.record, due: entry.due)
            if let first = dayGroups.last?.dueDates.first,
               calendar.isDate(first, inSameDayAs: entry.due),
               first >= today || entry.due.timeIntervalSince(first) <= 3600 {
                // Keep today's and future calendar days intact before merging across midnight.
                dayGroups[dayGroups.count - 1].append(group)
                continue
            }
            dayGroups.append(group)
        }
        var groups: [DeadlineCountdownGroup] = []
        for group in dayGroups {
            if let first = groups.last?.dueDates.first, let last = group.dueDates.last,
               last.timeIntervalSince(first) <= 3600 {
                groups[groups.count - 1].append(group)
            } else { groups.append(group) }
        }
        return groups
    }
    static func actionRecords(in state: WorkspaceState) -> [WorkspaceRecord] {
        WorkspaceRecordIndex(state.records).actionRecords
    }
    static func projectGroupRecords(in state: WorkspaceState) -> [WorkspaceRecord] {
        WorkspaceRecordIndex(state.records).projectGroupRecords
    }
    static func members(of group: WorkspaceRecord, in state: WorkspaceState) -> [WorkspaceRecord] {
        WorkspaceRecordIndex(state.records).members(of: group)
    }
    static func visible(_ record: WorkspaceRecord, in state: WorkspaceState) -> Bool {
        var pending = [record]
        var visited: Set<UUID> = []
        while let current = pending.popLast() {
            guard current.isLive else { return false }
            guard visited.insert(current.id).inserted else { continue }
            for parentID in [current.projectID, current.areaID].compactMap({ $0 }) {
                guard let parent = state.records.first(where: { $0.id == parentID }) else { return false }
                pending.append(parent)
            }
        }
        return true
    }
    /// Move existing, visible occurrences only. A recurring occurrence becomes
    /// an exception; its series template and generated siblings stay unchanged.
    @discardableResult
    static func regroup(_ ids: Set<UUID>, to groupID: UUID?, in state: inout WorkspaceState,
                        now: Date = Date()) throws -> Bool {
        guard !ids.isEmpty else { return false }
        let index = WorkspaceRecordIndex(state.records)
        let target: WorkspaceRecord?
        if let groupID {
            guard let group = index.byID[groupID], group.kind.isProjectGroup,
                  index.isVisible(groupID) else { throw WorkspaceFailure.missingParent }
            target = group
        } else { target = nil }
        let indices = state.records.indices.filter { ids.contains(state.records[$0].id) }
        guard indices.count == ids.count,
              indices.allSatisfy({
                  let record = state.records[$0]
                  return (record.kind.isItem || record.kind == .deadline) && index.isVisible(record.id)
              }) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("只能移动仍然可用且未归档的事项或截止事项。"))
        }
        let projectID = target?.kind == .project ? target?.id : nil
        let areaID = target?.kind == .area ? target?.id : nil
        var changes: [(index: Int, record: WorkspaceRecord)] = []
        for recordIndex in indices {
            var record = state.records[recordIndex]
            let milestoneID = record.projectID == projectID ? record.milestoneID : nil
            guard record.projectID != projectID || record.areaID != areaID || record.milestoneID != milestoneID else { continue }
            guard record.version < Int.max else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("事项版本已超出范围，无法移动。"))
            }
            record.projectID = projectID; record.areaID = areaID; record.milestoneID = milestoneID
            record.version += 1; record.updatedAt = now
            if record.recurrenceSeriesID != nil { record.isException = true }
            changes.append((recordIndex, record))
        }
        guard !changes.isEmpty else { return false }
        // Legacy milestones can still own linked items. Moving only their
        // parent must never leave those unselected records with broken links.
        let movedMilestones = Set(changes.compactMap { change -> UUID? in
            let before = state.records[change.index]
            return before.kind == .milestone && before.projectID != change.record.projectID ? before.id : nil
        })
        if !movedMilestones.isEmpty {
            let resultingRecords = Dictionary(changes.map { ($0.record.id, $0.record) }, uniquingKeysWith: { first, _ in first })
            let hasLinkedRecord = state.records.contains { record in
                guard let milestoneID = (resultingRecords[record.id] ?? record).milestoneID else { return false }
                return movedMilestones.contains(milestoneID)
            }
            let hasLinkedTemplate = state.series.contains { series in
                series.template.milestoneID.map(movedMilestones.contains) == true
            }
            guard !hasLinkedRecord && !hasLinkedTemplate else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此事项仍被其他事项关联，请先解除关联后再移动。"))
            }
        }
        // All checks precede mutation, so a failed multi-selection is atomic.
        for change in changes { state.records[change.index] = change.record }
        return true
    }
    /// Change only this record's category. Saving, conflict checks and any date
    /// required by the destination editor remain the caller's responsibility.
    static func conversionDraft(_ record: WorkspaceRecord, to target: ItemKind,
                                in state: WorkspaceState) throws -> WorkspaceRecord {
        guard (record.kind.isItem || record.kind == .deadline), target == .task || target == .deadline else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("只能在事项与截止事项之间转换。"))
        }
        guard visible(record, in: state) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("只能转换未归档且仍然可用的事项。"))
        }
        if let id = record.milestoneID {
            guard let parent = state.records.first(where: { $0.id == id && $0.kind == .milestone }),
                  visible(parent, in: state) else { throw WorkspaceFailure.missingParent }
        }
        guard record.kind != target else { return record }
        if record.kind == .milestone,
           state.records.contains(where: { $0.milestoneID == record.id }) ||
           state.series.contains(where: { $0.template.milestoneID == record.id }) {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此事项仍被其他事项关联，请先解除关联后再转换。"))
        }
        var draft = record
        draft.kind = target
        if record.status == "CANCELLED" { draft.status = "CANCELLED" }
        else if record.isFinished { draft.status = "DONE" }
        else if !target.states.contains(record.status) { draft.status = target.incompleteStatus }
        if record.recurrenceSeriesID != nil { draft.isException = true }
        return draft
    }
    static func descendants(of root: WorkspaceRecord, in state: WorkspaceState) -> [WorkspaceRecord] {
        deletionSelection([root.id], in: state)
    }
    static func preview(_ root: WorkspaceRecord, in state: WorkspaceState) throws -> DeletionPreview {
        try preview([root.id], in: state)
    }
    static func preview(_ ids: Set<UUID>, scope: RecurrenceDeletionScope = .occurrence,
                        in state: WorkspaceState, now: Date = Date()) throws -> DeletionPreview {
        let selection = deletionSelection(ids, in: state)
        guard let root = selection.first(where: { ids.contains($0.id) }),
              Set(selection.filter { ids.contains($0.id) }.map(\.id)) == ids else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请选择仍然存在的记录。"))
        }
        let cuts = recurrenceCuts(selection, scope: scope, in: state)
        var records = selection
        if scope != .occurrence {
            let selected = Set(selection.map(\.id))
            records += state.records.filter { record in
                guard record.deletedAt == nil, !selected.contains(record.id),
                      let seriesID = record.recurrenceSeriesID, let cut = cuts[seriesID] else { return false }
                return cut.isEmpty || occurrenceKey(record).map { $0 >= cut } == true
            }
        }
        records.sort { $0.id.uuidString < $1.id.uuidString }
        let deleting = Set(records.map(\.id))
        for record in state.records where record.deletedAt == nil && !deleting.contains(record.id) {
            if record.areaID.map(deleting.contains) == true {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此项目组仍有关联记录，请先调整它们的归属，或一起选择删除。"))
            }
            if record.milestoneID.map(deleting.contains) == true {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此事项仍有关联事项，请先解除关联，或一起选择删除。"))
            }
        }
        let seriesIDs = Set(selection.compactMap(\.recurrenceSeriesID))
        return DeletionPreview(root: root, records: records, createdAt: now,
            selectedIDs: ids.sorted { $0.uuidString < $1.uuidString }, recurrenceScope: scope,
            affectedSeries: state.series.filter { seriesIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    static func delete(_ preview: DeletionPreview, from state: inout WorkspaceState, now: Date = Date()) throws {
        let ids = Set(preview.selectedIDs.isEmpty ? [preview.root.id] : preview.selectedIDs)
        let current = try self.preview(ids, scope: preview.recurrenceScope, in: state, now: now)
        guard now.timeIntervalSince(preview.createdAt) < 600,
              current.records.map(\.id) == preview.records.map(\.id),
              current.records.map(\.version) == preview.records.map(\.version),
              current.affectedSeries == preview.affectedSeries else { throw WorkspaceFailure.stalePreview }
        let cuts = recurrenceCuts(deletionSelection(ids, in: state), scope: preview.recurrenceScope, in: state)
        var changes: [TrashedRecurrence] = []
        for index in state.series.indices {
            guard let cut = cuts[state.series[index].id] else { continue }
            let before = state.series[index]
            if cut.isEmpty {
                state.series[index].stoppedAt = now
                state.series[index].deletedAt = now
            } else if let day = recurrenceDay(cut, calendar: before.template.calendar),
                      let until = before.template.calendar.date(byAdding: .day, value: -1, to: day) {
                state.series[index].rule.until = min(before.rule.until ?? .distantFuture, until)
            }
            changes.append(TrashedRecurrence(before: before, after: state.series[index], fromDay: cut.isEmpty ? nil : cut))
        }
        let batch = TrashBatch(rootID: preview.root.id, title: preview.title, itemIDs: current.records.map(\.id),
            deletedAt: now, expiresAt: current.records.allSatisfy { $0.kind == .knowledge } ? nil : now.addingTimeInterval(30 * 86400),
            recurrence: changes.isEmpty ? nil : changes)
        let deleting = Set(batch.itemIDs)
        for index in state.records.indices where deleting.contains(state.records[index].id) {
            state.records[index].deletedAt = now; state.records[index].trashBatchID = batch.id
            state.records[index].version += 1; state.records[index].updatedAt = now
        }
        state.trash.append(batch)
    }
    static func restore(_ batch: TrashBatch, in state: inout WorkspaceState, now: Date = Date()) throws {
        if let expires = batch.expiresAt, now > expires { throw WorkspaceFailure.expiredTrash }
        func withoutProgress(_ series: DeadlineSeries) -> DeadlineSeries {
            var series = series; series.generatedThrough = nil; return series
        }
        // Restore the rule and instances together; never overwrite a rule edited since deletion.
        for change in batch.recurrence ?? [] {
            guard let current = state.series.first(where: { $0.id == change.after.id }),
                  withoutProgress(current) == withoutProgress(change.after) else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("重复规则在删除后发生了变化，请先处理该系列，再恢复此批记录。"))
            }
        }
        let ids = Set(batch.itemIDs)
        for record in state.records where record.trashBatchID == batch.id {
            if let parent = record.projectID, !ids.contains(parent),
               !state.records.contains(where: { $0.id == parent && $0.deletedAt == nil }) { throw WorkspaceFailure.missingParent }
        }
        for index in state.records.indices where state.records[index].trashBatchID == batch.id {
            state.records[index].deletedAt = nil; state.records[index].trashBatchID = nil
            state.records[index].version += 1; state.records[index].updatedAt = now
        }
        for change in batch.recurrence ?? [] {
            if let index = state.series.firstIndex(where: { $0.id == change.before.id }) {
                state.series[index] = change.before
                state.series[index].generatedThrough = nil
            }
        }
        state.trash.removeAll { $0.id == batch.id }
    }
    private static func deletionSelection(_ ids: Set<UUID>, in state: WorkspaceState) -> [WorkspaceRecord] {
        let live = state.records.filter { $0.deletedAt == nil }
        let children = Dictionary(grouping: live.filter { $0.projectID != nil }, by: { $0.projectID! })
        var selected = ids
        var pending = live.filter { ids.contains($0.id) && $0.kind == .project }.map(\.id)
        var cursor = 0
        while cursor < pending.count {
            let parent = pending[cursor]
            cursor += 1
            for child in children[parent] ?? [] where selected.insert(child.id).inserted {
                if child.kind == .project { pending.append(child.id) }
            }
        }
        return live.filter { selected.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private static func occurrenceKey(_ record: WorkspaceRecord) -> String? {
        record.occurrenceDate ?? record.recurrenceAnchor.map { WorkspaceDates.dayKey($0, timezone: record.timezone) }
    }
    private static func recurrenceDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    /// An empty cutoff denotes deleting the whole series. Cutoffs use the original
    /// occurrence day even when that one instance was moved to another date.
    private static func recurrenceCuts(_ records: [WorkspaceRecord], scope: RecurrenceDeletionScope,
                                       in state: WorkspaceState) -> [UUID: String] {
        guard scope != .occurrence else { return [:] }
        let series = Dictionary(uniqueKeysWithValues: state.series.map { ($0.id, $0) })
        var cuts: [UUID: String] = [:]
        for record in records {
            guard let id = record.recurrenceSeriesID, let value = series[id],
                  let day = occurrenceKey(record), let anchor = value.template.recurrenceAnchor else { continue }
            let cut = scope == .series || day <= WorkspaceDates.dayKey(anchor, timezone: value.template.timezone) ? "" : day
            cuts[id] = min(cuts[id] ?? cut, cut)
        }
        return cuts
    }
    /// A stale offline client may send cached future instances after a group was
    /// deleted. Keep their payload recoverable in the same batch, without reviving it.
    static func reconcileRecurrenceDeletions(in state: inout WorkspaceState) {
        let series = Dictionary(uniqueKeysWithValues: state.series.map { ($0.id, $0) })
        for batchIndex in state.trash.indices {
            let batch = state.trash[batchIndex]
            var recoveredIDs = Set(batch.itemIDs)
            for change in batch.recurrence ?? [] {
                guard let current = series[change.after.id] else { continue }
                let isActive: Bool
                if let cutoff = change.fromDay {
                    isActive = current.rule.until.map { WorkspaceDates.dayKey($0, timezone: current.template.timezone) < cutoff } == true
                } else { isActive = current.deletedAt == change.after.deletedAt && current.deletedAt != nil }
                guard isActive else { continue }
                for index in state.records.indices {
                    let record = state.records[index]
                    guard record.recurrenceSeriesID == current.id, record.deletedAt == nil,
                          change.fromDay.map({ cutoff in occurrenceKey(record).map { $0 >= cutoff } == true }) ?? true else { continue }
                    state.records[index].deletedAt = batch.deletedAt
                    state.records[index].trashBatchID = batch.id
                    state.records[index].version += 1; state.records[index].updatedAt = max(record.updatedAt, batch.deletedAt)
                    recoveredIDs.insert(record.id)
                }
            }
            state.trash[batchIndex].itemIDs = recoveredIDs.sorted { $0.uuidString < $1.uuidString }
        }
    }
    static func validate(_ state: WorkspaceState) throws {
        guard !state.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.profile.name.count <= 80, TimeZone(identifier: state.profile.timezone) != nil,
              (state.profile.avatar?.count ?? 0) <= 5 * 1024 * 1024 else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("个人资料的姓名、时区或头像无效。"))
        }
        guard state.format == "guangyi-native", state.schemaVersion == 1,
              state.records.count <= 100_000, state.assets.count <= 10_000,
              Set(state.records.map(\.id)).count == state.records.count,
              Set(state.assets.map(\.id)).count == state.assets.count,
              Set(state.series.map(\.id)).count == state.series.count,
              Set(state.trash.map(\.id)).count == state.trash.count else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("归档版本或记录标识无效，无法导入。"))
        }
        guard Set(state.revisions.map(\.id)).count == state.revisions.count,
              Set(state.activities.map(\.id)).count == state.activities.count else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("历史记录包含重复标识。"))
        }
        let projects = Set(state.records.filter { $0.kind == .project }.map(\.id))
        let milestones = Dictionary(uniqueKeysWithValues: state.records.filter { $0.kind == .milestone }.map { ($0.id, $0) })
        let areas = Set(state.records.filter { $0.kind == .area }.map(\.id))
        let notes = Set(state.records.filter { $0.kind == .knowledge }.map(\.id))
        let series = Set(state.series.map(\.id))
        let batches = Set(state.trash.map(\.id))
        // Project groups may nest, but a parent chain must always reach a root.
        // Memoize finished paths so validation remains linear for deep trees.
        let projectParents = Dictionary(uniqueKeysWithValues: state.records.compactMap { record -> (UUID, UUID)? in
            guard record.kind == .project, let parent = record.projectID else { return nil }
            return (record.id, parent)
        })
        var checkedProjects: Set<UUID> = []
        for project in projects where !checkedProjects.contains(project) {
            var path: Set<UUID> = []
            var current: UUID? = project
            while let id = current, !checkedProjects.contains(id) {
                guard path.insert(id).inserted else {
                    throw WorkspaceFailure.invalid(WorkspaceLocalization.string("项目组不能归属于自身或自己的子项目组。"))
                }
                current = projectParents[id]
            }
            checkedProjects.formUnion(path)
        }
        for record in state.records {
            guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.title.count <= 240, record.version > 0, record.body.count <= 250_000,
                  TimeZone(identifier: record.timezone) != nil, record.kind.states.contains(record.status) else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("记录内容、状态或时区无效。"))
            }
            if let id = record.projectID, !projects.contains(id) { throw WorkspaceFailure.missingParent }
            if let id = record.milestoneID, milestones[id]?.projectID != record.projectID || milestones[id] == nil { throw WorkspaceFailure.missingParent }
            if let id = record.areaID, !areas.contains(id) { throw WorkspaceFailure.missingParent }
            if let id = record.recurrenceSeriesID, !series.contains(id) { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("循环系列缺失。")) }
            if let id = record.trashBatchID, !batches.contains(id) { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("删除批次缺失。")) }
            if let start = record.startDate, let target = record.targetDate, target < start {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("项目组目标日期不能早于开始日期。"))
            }
        }
        for asset in state.assets {
            guard notes.contains(asset.ownerID), asset.data.count <= 10 * 1024 * 1024,
                  asset.data.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("PDF 附件无效或超过 10 MB。")) }
        }
        for series in state.series {
            if let error = RecurrenceEngine.validationError(record: series.template, rule: series.rule) {
                throw WorkspaceFailure.invalid(error)
            }
        }
    }
}

/// Three-way reconciliation for same-account devices. The acknowledged server
/// snapshot is the base; simultaneous edits to one entity require review.
enum WorkspaceSyncResolution: String, CaseIterable, Identifiable {
    case local = "保留本机冲突版本", remote = "使用服务器冲突版本"
    var id: String { rawValue }
}

enum WorkspaceSyncMerge {
    static func reconcile(base: WorkspaceState?, local: WorkspaceState, remote: WorkspaceState, resolution: WorkspaceSyncResolution? = nil,
                          now: Date = Date()) throws -> WorkspaceState {
        // Reuse date formatting/parsing work across the three immutable snapshots.
        let encoder = WorkspaceCoding.encoder(), decoder = WorkspaceCoding.decoder()
        func normalized(_ state: WorkspaceState) throws -> WorkspaceState {
            try WorkspaceLogic.validate(state)
            var result = try decoder.decode(WorkspaceState.self, from: encoder.encode(state))
            WorkspaceLogic.reconcileRecurrenceDeletions(in: &result)
            // Cache eviction is not a user deletion. Normalize the same window on
            // all three sides, so an edited remote occurrence survives a local eviction.
            RecurrenceEngine.normalizeGeneratedCache(&result, now: now)
            return result
        }
        let localInput = local, remoteInput = remote
        let local = try normalized(localInput)
        let remote = try localInput == remoteInput ? local : normalized(remoteInput)
        let base = try base.map { snapshot in
            if snapshot == localInput { return local }
            if snapshot == remoteInput { return remote }
            return try normalized(snapshot)
        }
        var result = remote
        result.records = try entities(base?.records ?? [], local.records, remote.records, label: WorkspaceLocalization.string("记录"), resolution: resolution)
        // Rolling generation progress is cache metadata, not a conflicting user edit.
        func withoutProgress(_ values: [DeadlineSeries]) -> [DeadlineSeries] {
            values.map { var value = $0; value.generatedThrough = nil; return value }
        }
        result.series = try entities(withoutProgress(base?.series ?? []), withoutProgress(local.series), withoutProgress(remote.series), label: WorkspaceLocalization.string("循环规则"), resolution: resolution)
        for index in result.series.indices {
            let selected = result.series[index]
            result.series[index].generatedThrough = (local.series + remote.series).compactMap { candidate in
                var comparable = candidate; comparable.generatedThrough = nil
                return comparable == selected ? candidate.generatedThrough : nil
            }.max()
        }
        result.assets = try entities(base?.assets ?? [], local.assets, remote.assets, label: WorkspaceLocalization.string("附件"), resolution: resolution)
        result.activities = try entities(base?.activities ?? [], local.activities, remote.activities, label: WorkspaceLocalization.string("历史"), resolution: resolution)
        result.revisions = try entities(base?.revisions ?? [], local.revisions, remote.revisions, label: WorkspaceLocalization.string("笔记版本"), resolution: resolution)
        result.trash = try entities(base?.trash ?? [], local.trash, remote.trash, label: WorkspaceLocalization.string("回收站"), resolution: resolution)
        let initialProfile = base?.profile ?? WorkspaceProfile()
        if local.profile == remote.profile || local.profile == initialProfile { result.profile = remote.profile }
        else if remote.profile == initialProfile { result.profile = local.profile }
        else if let resolution { result.profile = resolution == .local ? local.profile : remote.profile }
        else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("两台设备都修改了个人资料，请比较后选择要保留的版本。")) }
        WorkspaceLogic.reconcileRecurrenceDeletions(in: &result)
        RecurrenceEngine.reconcileStoppedSeries(in: &result)
        RecurrenceEngine.normalizeGeneratedCache(&result, now: now)
        // Restoring a record on either side must remove an obsolete trash batch.
        result.trash = result.trash.filter { batch in result.records.contains { $0.trashBatchID == batch.id } }
        try WorkspaceLogic.validate(result)
        return result
    }
    private static func entities<T: Identifiable & Equatable>(_ base: [T], _ local: [T], _ remote: [T], label: String, resolution: WorkspaceSyncResolution?) throws -> [T] where T.ID == UUID {
        func index(_ values: [T]) throws -> [UUID: T] {
            var result: [UUID: T] = [:]
            for value in values {
                guard result[value.id] == nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.format("同步数据包含重复的%@标识。", String(describing: label))) }
                result[value.id] = value
            }
            return result
        }
        let baseline = try index(base), ours = try index(local), theirs = try index(remote)
        let identifiers = Set(baseline.keys).union(ours.keys).union(theirs.keys)
        return try identifiers.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let old = baseline[id], left = ours[id], right = theirs[id]
            if left == right { return left }
            if left == old { return right }
            if right == old { return left }
            if let resolution { return resolution == .local ? left : right }
            throw WorkspaceFailure.invalid(WorkspaceLocalization.format("两台设备同时修改了同一%@（%@）。同步已停止，双方数据保留，请先解决冲突。", String(describing: label), String(describing: id.uuidString)))
        }
    }
}

struct VersionedWorkspace: Codable {
    var revision: Int
    var snapshot: WorkspaceState
    var accessRole: String? = nil
}
struct WorkspaceSyncCheckpoint: Codable {
    var scope: String
    var remote: VersionedWorkspace
}
enum WorkspaceSyncError: Error { case revisionChanged, accountChanged }

@MainActor enum WorkspaceSyncDriver {
    /// Re-read local state around awaits. Never apply a response from a different
    /// account, and preserve edits made while networking or merging is in flight.
    static func run(base: WorkspaceState?, readLocal: () -> WorkspaceState,
                    isCurrentAccount: () -> Bool,
                    download: () async throws -> VersionedWorkspace,
                    upload: (WorkspaceState, Int) async throws -> VersionedWorkspace,
                    rebase: @MainActor (WorkspaceState, WorkspaceState, WorkspaceState) async throws -> WorkspaceState = rebaseInBackground,
                    apply: (WorkspaceState, VersionedWorkspace) throws -> Void) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard isCurrentAccount() else { throw WorkspaceSyncError.accountChanged }
            let remote = try await download()
            try Task.checkCancellation()
            guard isCurrentAccount() else { throw WorkspaceSyncError.accountChanged }
            let localBeforeUpload = readLocal()
            // Only immutable snapshots cross this boundary. Keep normalization
            // and comparison together so their full JSON work leaves the UI actor.
            let preparation = Task.detached(priority: .utility) {
                Result { () throws -> (snapshot: WorkspaceState, matchesRemote: Bool) in
                    try Task.checkCancellation()
                    let merged = try WorkspaceSyncMerge.reconcile(base: base, local: localBeforeUpload, remote: remote.snapshot)
                    let matchesRemote = try equivalent(merged, remote.snapshot)
                    try Task.checkCancellation()
                    return (merged, matchesRemote)
                }
            }
            let preparedResult = await withTaskCancellationHandler(operation: {
                await preparation.value
            }, onCancel: { preparation.cancel() })
            try Task.checkCancellation()
            guard isCurrentAccount() else { throw WorkspaceSyncError.accountChanged }
            let prepared = try preparedResult.get()
            let acknowledged: VersionedWorkspace
            if prepared.matchesRemote { acknowledged = remote }
            else {
                do { acknowledged = try await upload(prepared.snapshot, remote.revision) }
                catch WorkspaceSyncError.revisionChanged {
                    try Task.checkCancellation()
                    guard isCurrentAccount() else { throw WorkspaceSyncError.accountChanged }
                    if attempt < 2 { continue }
                    throw WorkspaceFailure.invalid(WorkspaceLocalization.string("服务器持续有新改动，本机资料已保留，请稍后重试同步。"))
                }
            }
            try Task.checkCancellation()
            guard isCurrentAccount() else { throw WorkspaceSyncError.accountChanged }
            for _ in 0..<3 {
                let captured = readLocal()
                let result: Result<WorkspaceState, Error>
                do { result = .success(try await rebase(localBeforeUpload, captured, acknowledged.snapshot)) }
                catch { result = .failure(error) }
                try Task.checkCancellation()
                guard isCurrentAccount() else { throw WorkspaceSyncError.accountChanged }
                // An edit may arrive while background computation is suspended.
                // Rebase the new value, including when the stale computation failed.
                guard readLocal() == captured else { continue }
                let current = try result.get()
                // No suspension between the final local/account checks and apply.
                try apply(current, acknowledged)
                return
            }
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("同步期间本机内容持续变化，已保留最新修改，请稍后重试同步。"))
        }
    }
    nonisolated static func rebaseInBackground(_ base: WorkspaceState, _ local: WorkspaceState,
        _ remote: WorkspaceState) async throws -> WorkspaceState {
        try await reconcileInBackground(base: base, local: local, remote: remote)
    }
    nonisolated static func reconcileInBackground(base: WorkspaceState?, local: WorkspaceState,
        remote: WorkspaceState) async throws -> WorkspaceState {
        try Task.checkCancellation()
        let computation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let merged = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote)
            try Task.checkCancellation()
            return merged
        }
        let result = try await withTaskCancellationHandler(operation: {
            try await computation.value
        }, onCancel: { computation.cancel() })
        try Task.checkCancellation()
        return result
    }
    /// The failure path is just as expensive as a normal merge. Keep all three
    /// conflict probes off MainActor, including their date/attachment conversions.
    nonisolated static func requiresReviewInBackground(base: WorkspaceState?, local: WorkspaceState,
        remote: WorkspaceState) async throws -> Bool {
        try Task.checkCancellation()
        let computation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let now = Date()
            if (try? WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, now: now)) != nil { return false }
            try Task.checkCancellation()
            guard (try? WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, resolution: .local, now: now)) != nil else { return false }
            try Task.checkCancellation()
            let resolvable = (try? WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, resolution: .remote, now: now)) != nil
            try Task.checkCancellation()
            return resolvable
        }
        let result = try await withTaskCancellationHandler(operation: {
            try await computation.value
        }, onCancel: { computation.cancel() })
        try Task.checkCancellation()
        return result
    }
    nonisolated private static func equivalent(_ lhs: WorkspaceState, _ rhs: WorkspaceState) throws -> Bool {
        func sorted(_ value: WorkspaceState) -> WorkspaceState {
            var value = value
            value.records.sort { $0.id.uuidString < $1.id.uuidString }
            value.series.sort { $0.id.uuidString < $1.id.uuidString }
            value.assets.sort { $0.id.uuidString < $1.id.uuidString }
            value.activities.sort { $0.id.uuidString < $1.id.uuidString }
            value.revisions.sort { $0.id.uuidString < $1.id.uuidString }
            value.trash.sort { $0.id.uuidString < $1.id.uuidString }
            return value
        }
        return try WorkspaceCoding.encoder().encode(sorted(lhs)) == WorkspaceCoding.encoder().encode(sorted(rhs))
    }
}
