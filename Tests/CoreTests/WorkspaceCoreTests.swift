import XCTest
import Observation
#if SWIFT_PACKAGE
@testable import WorkspaceCore
#endif

final class WorkspaceCoreTests: XCTestCase {
    private func date(_ text: String) -> Date { WorkspaceDates.parse(text)! }
    func testRegroupMovesItemsAndDeadlinesToProjectAreaAndUngrouped() throws {
        let project = WorkspaceRecord(kind: .project, title: "目标项目")
        let area = WorkspaceRecord(kind: .area, title: "原领域")
        var task = WorkspaceRecord(kind: .task, title: "事项")
        var reminder = WorkspaceRecord(kind: .reminder, title: "提醒")
        var deadline = WorkspaceRecord(kind: .deadline, title: "截止事项")
        task.areaID = area.id; reminder.areaID = area.id; deadline.areaID = area.id
        deadline.dueDate = date("2026-10-24")
        var state = WorkspaceState(records: [project, area, task, reminder, deadline])
        let ids: Set<UUID> = [task.id, reminder.id, deadline.id]
        let now = date("2026-10-22T10:00:00+08:00")
        XCTAssertTrue(try WorkspaceLogic.regroup(ids, to: project.id, in: &state, now: now))
        for record in state.records.suffix(3) {
            XCTAssertEqual(record.projectID, project.id); XCTAssertNil(record.areaID)
            XCTAssertEqual(record.version, 2); XCTAssertEqual(record.updatedAt, now)
        }
        XCTAssertTrue(try WorkspaceLogic.regroup(ids, to: area.id, in: &state))
        for record in state.records.suffix(3) {
            XCTAssertNil(record.projectID); XCTAssertEqual(record.areaID, area.id)
        }
        XCTAssertTrue(try WorkspaceLogic.regroup(ids, to: nil, in: &state))
        for record in state.records.suffix(3) { XCTAssertNil(record.projectID); XCTAssertNil(record.areaID) }
        XCTAssertEqual(Array(state.records.prefix(2)), [project, area])
        try WorkspaceLogic.validate(state)
    }
    func testRegroupSameDestinationIsNoOpIncludingRecurringOccurrence() throws {
        let project = WorkspaceRecord(kind: .project, title: "项目")
        var task = WorkspaceRecord(kind: .task, title: "每日事项")
        task.projectID = project.id; task.scheduledAt = date("2026-10-22T09:00:00+08:00")
        var state = WorkspaceState(records: [project, task])
        try RecurrenceEngine.start(task.id, rule: RecurrenceRule(frequency: .daily), in: &state,
                                   now: date("2026-10-22"))
        let occurrence = try XCTUnwrap(state.records.first { $0.kind.isItem })
        let before = state
        XCTAssertFalse(try WorkspaceLogic.regroup([occurrence.id], to: project.id, in: &state))
        XCTAssertFalse(try WorkspaceLogic.regroup([], to: nil, in: &state))
        XCTAssertEqual(state, before)
    }
    func testRegroupRejectsInvalidTargetsAndSourcesAtomically() throws {
        let project = WorkspaceRecord(kind: .project, title: "项目")
        let area = WorkspaceRecord(kind: .area, title: "领域")
        var hidden = WorkspaceRecord(kind: .project, title: "归档项目")
        hidden.archivedAt = date("2026-10-21")
        var nested = WorkspaceRecord(kind: .project, title: "隐藏子项目"); nested.projectID = hidden.id
        var task = WorkspaceRecord(kind: .task, title: "正常事项"); task.projectID = project.id
        var archived = WorkspaceRecord(kind: .task, title: "归档事项"); archived.archivedAt = date("2026-10-21")
        var deleted = WorkspaceRecord(kind: .task, title: "已删除事项"); deleted.deletedAt = date("2026-10-21")
        var hiddenTask = WorkspaceRecord(kind: .task, title: "隐藏事项"); hiddenTask.projectID = nested.id
        let knowledge = WorkspaceRecord(kind: .knowledge, title: "笔记")
        var overflow = WorkspaceRecord(kind: .task, title: "版本溢出"); overflow.version = Int.max
        var state = WorkspaceState(records: [project, area, hidden, nested, task, archived, deleted, hiddenTask, knowledge, overflow])
        let before = state
        for target in [UUID(), hidden.id, nested.id, task.id, knowledge.id] {
            XCTAssertThrowsError(try WorkspaceLogic.regroup([task.id], to: target, in: &state))
            XCTAssertEqual(state, before)
        }
        for source in [UUID(), project.id, area.id, archived.id, deleted.id, hiddenTask.id, knowledge.id, overflow.id] {
            XCTAssertThrowsError(try WorkspaceLogic.regroup([task.id, source], to: area.id, in: &state))
            XCTAssertEqual(state, before)
        }
    }
    func testRegroupRecurringOccurrencePreservesTemplateSiblingsAndGenerationProgress() throws {
        let first = WorkspaceRecord(kind: .project, title: "原项目")
        let second = WorkspaceRecord(kind: .project, title: "目标项目")
        var task = WorkspaceRecord(kind: .task, title: "每日事项")
        task.projectID = first.id; task.scheduledAt = date("2026-10-22T09:00:00+08:00")
        var state = WorkspaceState(records: [first, second, task])
        try RecurrenceEngine.start(task.id, rule: RecurrenceRule(frequency: .daily), in: &state,
                                   now: date("2026-10-22"))
        let selected = try XCTUnwrap(state.records.first { $0.occurrenceDate == "2026-10-23" })
        let before = state
        XCTAssertTrue(try WorkspaceLogic.regroup([selected.id], to: second.id, in: &state))
        let moved = try XCTUnwrap(state.records.first { $0.id == selected.id })
        XCTAssertEqual(moved.projectID, second.id); XCTAssertTrue(moved.isException)
        XCTAssertEqual(moved.recurrenceSeriesID, selected.recurrenceSeriesID)
        XCTAssertEqual(moved.occurrenceDate, selected.occurrenceDate)
        XCTAssertEqual(state.series, before.series)
        XCTAssertEqual(state.records.filter { $0.id != selected.id }, before.records.filter { $0.id != selected.id })
        XCTAssertEqual(state.records.count, before.records.count)
        try WorkspaceLogic.validate(state)
    }
    func testRegroupPreservesMilestoneWithinProjectAndClearsItAcrossProjects() throws {
        let first = WorkspaceRecord(kind: .project, title: "原项目")
        let second = WorkspaceRecord(kind: .project, title: "目标项目")
        let area = WorkspaceRecord(kind: .area, title: "旧领域")
        var milestone = WorkspaceRecord(kind: .milestone, title: "关联事项"); milestone.projectID = first.id
        var task = WorkspaceRecord(kind: .task, title: "事项")
        task.projectID = first.id; task.areaID = area.id; task.milestoneID = milestone.id
        var state = WorkspaceState(records: [first, second, area, milestone, task])
        XCTAssertTrue(try WorkspaceLogic.regroup([task.id], to: first.id, in: &state))
        XCTAssertEqual(state.records.last?.milestoneID, milestone.id); XCTAssertNil(state.records.last?.areaID)
        XCTAssertTrue(try WorkspaceLogic.regroup([task.id], to: second.id, in: &state))
        XCTAssertNil(state.records.last?.milestoneID)
        try WorkspaceLogic.validate(state)
    }
    func testRegroupLinkedMilestoneRejectsBrokenReferencesAtomically() throws {
        let first = WorkspaceRecord(kind: .project, title: "原项目")
        let second = WorkspaceRecord(kind: .project, title: "目标项目")
        var milestone = WorkspaceRecord(kind: .milestone, title: "关联事项"); milestone.projectID = first.id
        var task = WorkspaceRecord(kind: .task, title: "事项")
        task.projectID = first.id; task.milestoneID = milestone.id
        var state = WorkspaceState(records: [first, second, milestone, task])
        let before = state
        XCTAssertThrowsError(try WorkspaceLogic.regroup([milestone.id], to: second.id, in: &state))
        XCTAssertEqual(state, before)
        XCTAssertTrue(try WorkspaceLogic.regroup([milestone.id, task.id], to: second.id, in: &state))
        XCTAssertEqual(state.records[2].projectID, second.id)
        XCTAssertEqual(state.records[3].projectID, second.id); XCTAssertNil(state.records[3].milestoneID)
        try WorkspaceLogic.validate(state)
    }
    func testPreferenceStorageRepeatedWritesNormalizePersistAndNotifyWithoutRecursion() throws {
        let suite = "workshop-preference-regression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WorkspacePreferenceStorage(defaults: defaults)
        var observed = false
        withObservationTracking({ _ = storage.value.taskRemindersEnabled }, onChange: { observed = true })
        storage.value.taskRemindersEnabled = true
        XCTAssertTrue(observed)
        for index in 0..<200 {
            storage.value.taskRemindersEnabled = index.isMultiple(of: 2)
            storage.value.deadlineRemindersEnabled = !index.isMultiple(of: 2)
            storage.value.notificationLeadMinutes = index * 100
            storage.value.customProjectCategories = ["  实验  ", "实验", "", "RESEARCH"]
        }
        XCTAssertEqual(storage.value.notificationLeadMinutes, 10_080)
        XCTAssertEqual(storage.value.customProjectCategories, ["实验"])
        let restored = WorkspacePreferenceStorage(defaults: defaults)
        XCTAssertEqual(restored.value, storage.value)
    }
    func testPreferenceStorageDemoCopiesRemainIsolatedFromPersistentPreferences() throws {
        let suite = "workshop-preference-demo-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let real = WorkspacePreferenceStorage(defaults: defaults)
        real.value.taskRemindersEnabled = true
        real.value.customProjectCategories = ["真实分类"]
        let before = defaults.data(forKey: WorkspacePreferenceStorage.key)
        let demo = WorkspacePreferenceStorage(defaults: defaults, persists: false)
        demo.value = real.value
        demo.value.taskRemindersEnabled = false
        demo.value.customProjectCategories.append("演示分类")
        XCTAssertEqual(defaults.data(forKey: WorkspacePreferenceStorage.key), before)
        XCTAssertEqual(WorkspacePreferenceStorage(defaults: defaults).value, real.value)
        XCTAssertFalse(real.value.customProjectCategories.contains("演示分类"))
    }
    func testRenamedBuiltinCategoryPersistsAndAppliesToNewProjectGroups() throws {
        let value = WorkspacePreferences(customProjectCategories: ["课程学习"],
            hiddenBuiltinProjectCategories: ["RESEARCH", "RESEARCH", "unknown"], defaultProjectCategory: "课程学习")
        let decoded = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.hiddenBuiltinProjectCategories, ["RESEARCH"])
        XCTAssertEqual(decoded.defaultProjectCategory, "课程学习")
        var project = WorkspaceRecord(kind: .project)
        decoded.apply(to: &project)
        XCTAssertEqual(project.projectKind, "课程学习")
    }

    func testRenameProjectCategoryMigratesNestedAndArchivedGroupsOnly() throws {
        let now = date("2026-10-17T10:00:00+08:00")
        var parent = WorkspaceRecord(kind: .project, title: "父项目")
        parent.projectKind = "课程"; parent.version = 4
        var child = WorkspaceRecord(kind: .project, title: "子项目")
        child.projectID = parent.id; child.projectKind = "课程"
        child.archivedAt = date("2026-10-16")
        var area = WorkspaceRecord(kind: .area, title: "归档领域")
        area.projectKind = "课程"; area.archivedAt = date("2026-10-16")
        var task = WorkspaceRecord(kind: .task, title: "事项")
        task.projectID = child.id; task.projectKind = "课程"
        var deleted = WorkspaceRecord(kind: .project, title: "已删除")
        deleted.projectKind = "课程"; deleted.deletedAt = date("2026-10-16")
        var other = WorkspaceRecord(kind: .project, title: "其他分类")
        other.projectKind = "生活"
        var state = WorkspaceState()
        state.records = [parent, child, area, task, deleted, other]
        state.revisions = [KnowledgeRevision(record: parent, action: "历史")]
        let before = state
        XCTAssertEqual(try WorkspaceLogic.renameProjectCategory(from: "课程", to: " 学习 ", in: &state, now: now), 3)
        for index in 0..<3 {
            var expected = before.records[index]
            expected.projectKind = "学习"; expected.version += 1; expected.updatedAt = now
            XCTAssertEqual(state.records[index], expected)
            let activity = state.activities[index]
            XCTAssertEqual(activity.entityID, expected.id)
            XCTAssertEqual(activity.title, expected.title)
            XCTAssertEqual(activity.projectID, expected.kind == .project ? expected.id : expected.projectID)
            XCTAssertEqual(activity.message, "修改项目组分类")
            XCTAssertEqual(activity.date, now)
        }
        XCTAssertEqual(Array(state.records.dropFirst(3)), Array(before.records.dropFirst(3)))
        XCTAssertEqual(state.revisions, before.revisions)
        XCTAssertEqual(state.activities.count, 3)
    }
    func testRenameProjectCategoryRejectsInvalidInputAtomically() throws {
        var record = WorkspaceRecord(kind: .project, title: "项目")
        record.projectKind = "课程"
        var state = WorkspaceState(); state.records = [record]
        let before = state
        for value in [" \n ", "学\u{0000}习", "学\t习", String(repeating: "🧠", count: 121)] {
            XCTAssertThrowsError(try WorkspaceLogic.renameProjectCategory(from: "课程", to: value, in: &state))
            XCTAssertEqual(state, before)
        }
        XCTAssertEqual(try WorkspaceLogic.renameProjectCategory(from: "课程", to: " 课程 ", in: &state), 0)
        XCTAssertEqual(state, before)
        var overflow = record; overflow.id = UUID(); overflow.version = Int.max
        state.records.append(overflow)
        let beforeOverflow = state
        XCTAssertThrowsError(try WorkspaceLogic.renameProjectCategory(from: "课程", to: "学习", in: &state))
        XCTAssertEqual(state, beforeOverflow)
    }
    func testRenameProjectCategoryUsesUTF16LimitAndMissingCategoryIsNoOp() throws {
        var state = WorkspaceState()
        var record = WorkspaceRecord(kind: .project, title: "项目")
        record.projectKind = "课程"; state.records = [record]
        let before = state
        XCTAssertEqual(try WorkspaceLogic.renameProjectCategory(from: "不存在", to: "学习", in: &state), 0)
        XCTAssertEqual(state, before)
        let category = String(repeating: "🧠", count: 120)
        XCTAssertEqual(try WorkspaceLogic.renameProjectCategory(from: "课程", to: category, in: &state), 1)
        XCTAssertEqual(state.records[0].projectKind, category)
    }
    func testRemovingAllProjectCategoriesPersistsUnclassifiedDefault() throws {
        var preferences = WorkspacePreferences(customProjectCategories: ["课程"])
        preferences.removeProjectCategory("课程")
        for key in WorkspacePreferences.builtinProjectCategoryKeys { preferences.removeProjectCategory(key) }
        let restored = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored.customProjectCategories.isEmpty)
        XCTAssertEqual(Set(restored.hiddenBuiltinProjectCategories), Set(WorkspacePreferences.builtinProjectCategoryKeys))
        XCTAssertEqual(restored.defaultProjectCategory, "")
        var group = WorkspaceRecord(kind: .project, title: "不分类项目组")
        restored.apply(to: &group)
        XCTAssertEqual(group.projectKind, "")
        XCTAssertEqual(WorkspacePreferences(defaultProjectCategory: "").normalized().defaultProjectCategory, "")
    }

    func testRemoveProjectCategoryPreservesGroupsAndMembership() throws {
        var group = WorkspaceRecord(kind: .project, title: "项目组")
        group.projectKind = "RESEARCH"
        var archived = WorkspaceRecord(kind: .area, title: "已归档项目组")
        archived.projectKind = "RESEARCH"; archived.archivedAt = date("2026-10-16")
        var task = WorkspaceRecord(kind: .task, title: "事项")
        task.projectID = group.id; task.projectKind = "RESEARCH"
        var deleted = WorkspaceRecord(kind: .project, title: "回收站项目组")
        deleted.projectKind = "RESEARCH"; deleted.deletedAt = date("2026-10-16")
        var state = WorkspaceState(); state.records = [group, archived, task, deleted]
        let now = date("2026-10-18T10:00:00+08:00")
        XCTAssertEqual(try WorkspaceLogic.removeProjectCategory("RESEARCH", in: &state, now: now), 2)
        for index in 0..<2 {
            var expected = [group, archived][index]
            expected.projectKind = ""; expected.version += 1; expected.updatedAt = now
            XCTAssertEqual(state.records[index], expected)
        }
        XCTAssertEqual(Array(state.records.suffix(2)), [task, deleted])
        XCTAssertEqual(state.activities.count, 2)
        try WorkspaceLogic.validate(state)
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(try WorkspaceLogic.removeProjectCategory("", in: &state), 0)
    }

    func testRemoveProjectCategoryRejectsVersionOverflowAtomically() {
        var group = WorkspaceRecord(kind: .project, title: "项目组")
        var overflow = WorkspaceRecord(kind: .project, title: "版本溢出")
        overflow.version = Int.max
        var state = WorkspaceState(); state.records = [group, overflow]
        let before = state
        XCTAssertThrowsError(try WorkspaceLogic.removeProjectCategory("RESEARCH", in: &state))
        XCTAssertEqual(state, before)
    }

    func testPersonalPreferencesDecodeDefaultsAndRoundTrip() throws {
        let defaults = WorkspacePreferences()
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: Data("{}".utf8)), defaults)
        let damaged = Data(#"{"taskRemindersEnabled":"invalid","deadlineRemindersEnabled":false,"notificationLeadMinutes":999999,"customProjectCategories":["课程"]}"#.utf8)
        let restored = try JSONDecoder().decode(WorkspacePreferences.self, from: damaged)
        XCTAssertFalse(restored.taskRemindersEnabled)
        XCTAssertFalse(restored.deadlineRemindersEnabled)
        XCTAssertTrue(restored.dateOnlyDeadlines)
        XCTAssertEqual(restored.notificationLeadMinutes, 10_080)
        XCTAssertEqual(restored.customProjectCategories, ["课程"])
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(restored)), restored)
    }
    func testPersonalPreferencesNormalizeCategoriesAndLeadTime() {
        let categories = [" 课程 ", "课程", "", " \n ", "RESEARCH", String(repeating: "a", count: 241)]
            + (0..<70).map { "分类\($0)" }
        let preferences = WorkspacePreferences(notificationLeadMinutes: -1, customProjectCategories: categories)
        XCTAssertEqual(preferences.notificationLeadMinutes, 0)
        XCTAssertEqual(preferences.customProjectCategories.count, 50)
        XCTAssertEqual(preferences.customProjectCategories.first, "课程")
        XCTAssertEqual(Set(preferences.customProjectCategories).count, 50)
        XCTAssertFalse(preferences.customProjectCategories.contains("RESEARCH"))
    }
    func testPersonalPreferencesApplyOnlyCreationRelevantFields() {
        let preferences = WorkspacePreferences(taskRemindersEnabled: true, deadlineRemindersEnabled: false,
                                              notificationLeadMinutes: 15, dateOnlyDeadlines: false)
        for kind in [ItemKind.task, .reminder, .milestone] {
            var item = WorkspaceRecord(kind: kind)
            item.timezone = "Europe/London"
            preferences.apply(to: &item)
            XCTAssertTrue(item.notificationsEnabled)
            XCTAssertEqual(item.notificationLeadMinutes, 15)
            XCTAssertEqual(item.timezone, "Europe/London")
        }
        var deadline = WorkspaceRecord(kind: .deadline)
        preferences.apply(to: &deadline)
        XCTAssertFalse(deadline.notificationsEnabled)
        XCTAssertFalse(deadline.dateOnly)
        XCTAssertEqual(deadline.notificationLeadMinutes, 15)
        var project = WorkspaceRecord(kind: .project)
        let original = project
        preferences.apply(to: &project)
        XCTAssertEqual(project, original)
    }
    func testRecordIndexKeepsVisibilityAndRebuildsAfterParentChanges() {
        var state = WorkspaceDemo.make(now: date("2026-10-16T09:00:00+08:00"))
        func check(_ state: WorkspaceState) {
            let index = WorkspaceRecordIndex(state.records)
            XCTAssertEqual(index.visibleRecords.map(\.id), state.records.filter { WorkspaceLogic.visible($0, in: state) }.map(\.id))
            for record in state.records {
                XCTAssertEqual(index.byID[record.id], record)
                XCTAssertEqual(index.isVisible(record.id), WorkspaceLogic.visible(record, in: state))
            }
        }
        check(state)
        let parentIndex = state.records.firstIndex { $0.kind == .project }!
        state.records[parentIndex].archivedAt = date("2026-10-16T10:00:00+08:00")
        check(state)
        state.records[parentIndex].archivedAt = nil
        check(state)

        var area = WorkspaceRecord(kind: .area, title: "循环父级")
        var project = WorkspaceRecord(kind: .project, title: "循环项目组")
        area.projectID = project.id; project.areaID = area.id
        var task = WorkspaceRecord(kind: .task, title: "循环中的事项")
        task.projectID = project.id
        var orphan = WorkspaceRecord(kind: .task, title: "缺失父级")
        orphan.projectID = UUID()
        state.records = [area, project, task, orphan]
        check(state)
        XCTAssertEqual(Set(WorkspaceRecordIndex(state.records).visibleRecords.map(\.id)), [area.id, project.id, task.id])
        state.records[0].archivedAt = Date()
        check(state)
        XCTAssertTrue(WorkspaceRecordIndex(state.records).visibleRecords.isEmpty)
    }
    func testRecordIndexPreservesPinnedCompletionAndDateOrdering() {
        let base = date("2026-10-16T09:00:00+08:00")
        var project = WorkspaceRecord(kind: .project, title: "课程")
        project.updatedAt = base
        func item(_ title: String, moment: Date? = nil, pinned: Bool = false, finished: Bool = false) -> WorkspaceRecord {
            var item = WorkspaceRecord(kind: .task, title: title)
            item.projectID = project.id; item.scheduledAt = moment
            item.pinned = pinned; item.status = finished ? "DONE" : "TODO"
            item.updatedAt = base
            return item
        }
        let completed = item("已完成", moment: base.addingTimeInterval(-3600), finished: true)
        let unscheduled = item("尚未安排")
        let tomorrow = item("明天", moment: base.addingTimeInterval(86400))
        let today = item("今天", moment: base)
        let pinned = item("标星", moment: base.addingTimeInterval(172800), pinned: true)
        var archived = item("归档"); archived.archivedAt = base
        let state = WorkspaceState(records: [completed, unscheduled, tomorrow, archived, today, pinned, project])
        let index = WorkspaceRecordIndex(state.records)
        let expected = [pinned, today, tomorrow, unscheduled, completed].map(\.id)
        XCTAssertEqual(index.actionRecords.map(\.id), expected)
        XCTAssertEqual(index.members(of: project).map(\.id), expected)
        XCTAssertEqual(index.projectGroupRecords.map(\.id), [project.id])
        XCTAssertFalse(index.records(.task).contains { $0.id == archived.id })
        XCTAssertTrue(index.records(.task, includeArchived: true).contains { $0.id == archived.id })

        var nextDeadline = WorkspaceRecord(kind: .deadline, title: "最近截止")
        nextDeadline.dateOnly = false; nextDeadline.dueDate = base; nextDeadline.updatedAt = base
        var laterDeadline = WorkspaceRecord(kind: .deadline, title: "稍后截止")
        laterDeadline.dateOnly = false; laterDeadline.dueDate = base.addingTimeInterval(3600); laterDeadline.updatedAt = base
        var finishedDeadline = WorkspaceRecord(kind: .deadline, title: "已经完成")
        finishedDeadline.status = "DONE"; finishedDeadline.dueDate = base.addingTimeInterval(-3600)
        XCTAssertEqual(WorkspaceRecordIndex([laterDeadline, finishedDeadline, nextDeadline]).records(.deadline).map(\.id),
            [nextDeadline.id, laterDeadline.id, finishedDeadline.id])
    }
    func testBinaryCompletionPresentationPreservesEveryLegacyWireState() throws {
        let legacyStates: [ItemKind: [String]] = [
            .project: ["PLANNED", "ACTIVE", "WAITING", "PAUSED", "COMPLETED"],
            .task: ["TODO", "IN_PROGRESS", "WAITING", "DONE", "CANCELLED"],
            .milestone: ["PLANNED", "ACTIVE", "DONE", "CANCELLED"],
            .deadline: ["OPEN", "DONE", "CANCELLED"], .reminder: ["OPEN", "DONE"],
            .area: ["OPEN"], .knowledge: ["OPEN"]
        ]
        var records: [WorkspaceRecord] = []
        for kind in ItemKind.allCases {
            XCTAssertEqual(kind.states, legacyStates[kind])
            for status in kind.states {
                var record = WorkspaceRecord(kind: kind, title: "保留旧记录 \(status)")
                record.status = status
                record.createdAt = date("2026-10-16T09:00:00+08:00")
                record.updatedAt = record.createdAt
                let finished = ["DONE", "COMPLETED", "CANCELLED"].contains(status)
                XCTAssertEqual(record.isFinished, finished)
                XCTAssertEqual(StateLabels.title(status), finished ? "已完成" : "未完成")
                records.append(record)
            }
        }
        let original = WorkspaceState(records: records)
        try WorkspaceLogic.validate(original)
        let restored = try WorkspaceCoding.decoder().decode(WorkspaceState.self,
            from: WorkspaceCoding.encoder().encode(original))
        try WorkspaceLogic.validate(restored)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.records.map(\.status), records.map(\.status))
    }
    func testCanonicalCompletionAndReopeningRemainValidForEachSupportedKind() throws {
        let expectedCompleted: [ItemKind: String] = [.project: "COMPLETED", .task: "DONE",
            .milestone: "DONE", .deadline: "DONE", .reminder: "DONE"]
        let expectedIncomplete: [ItemKind: String] = [.project: "PLANNED", .milestone: "PLANNED",
            .task: "TODO", .deadline: "OPEN", .reminder: "OPEN", .area: "OPEN", .knowledge: "OPEN"]
        for kind in ItemKind.allCases {
            XCTAssertEqual(kind.completedStatus, expectedCompleted[kind])
            XCTAssertEqual(kind.incompleteStatus, expectedIncomplete[kind])
            var record = WorkspaceRecord(kind: kind, title: "完成切换")
            record.createdAt = date("2026-10-16T09:00:00+08:00")
            record.updatedAt = record.createdAt
            XCTAssertEqual(record.status, kind.incompleteStatus)
            guard let completed = kind.completedStatus else { continue }
            let originalID = record.id
            record.status = completed
            XCTAssertTrue(record.isFinished)
            var state = WorkspaceState(records: [record])
            try WorkspaceLogic.validate(state)
            state = try WorkspaceCoding.decoder().decode(WorkspaceState.self,
                from: WorkspaceCoding.encoder().encode(state))
            XCTAssertEqual(state.records.count, 1)
            XCTAssertEqual(state.records[0].id, originalID)
            XCTAssertTrue(state.records[0].isFinished)
            state.records[0].status = kind.incompleteStatus
            XCTAssertFalse(state.records[0].isFinished)
            try WorkspaceLogic.validate(state)
            let reopened = try WorkspaceCoding.decoder().decode(WorkspaceState.self,
                from: WorkspaceCoding.encoder().encode(state))
            XCTAssertEqual(reopened, state)
            XCTAssertEqual(reopened.records[0].id, originalID)
        }
    }
    func testWebLoginUsesRFC7636SHA256Challenge() throws {
        let request = try WebLoginRequest(state: String(repeating: "s", count: 43),
            codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(request.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testWebLoginCreatesFreshSecretsWithoutDisclosingVerifier() throws {
        let request = WebLoginRequest(), other = WebLoginRequest()
        for value in [request.state, request.codeVerifier, other.state, other.codeVerifier] {
            XCTAssertNotNil(value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
        }
        XCTAssertNotEqual(request.state, other.state)
        XCTAssertNotEqual(request.codeVerifier, other.codeVerifier)
        XCTAssertNotEqual(request.state, request.codeVerifier)
        for server in ["https://workspace.example", "https://workspace.example/"] {
            let url = try request.authorizationURL(server: XCTUnwrap(URL(string: server)))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "workspace.example")
            XCTAssertEqual(components.path, "/native-login")
            let query = try XCTUnwrap(components.queryItems)
            XCTAssertEqual(query.count, 3)
            XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, request.codeChallenge)
            XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
            XCTAssertEqual(query.first { $0.name == "state" }?.value, request.state)
            XCTAssertFalse(url.absoluteString.contains(request.codeVerifier))
            XCTAssertFalse(query.contains { $0.name == "code_verifier" })
        }
    }
    func testWebLoginAcceptsBoundCallbackAndRejectsForgedCallbacks() throws {
        let state = String(repeating: "s", count: 43), code = String(repeating: "c", count: 43)
        let request = try WebLoginRequest(state: state, codeVerifier: String(repeating: "v", count: 43))
        let callback = "guangyi-workspace://auth/callback?code=\(code)&state=\(state)"
        XCTAssertEqual(try request.authorizationCode(from: XCTUnwrap(URL(string: callback))), code)
        XCTAssertEqual(try request.authorizationCode(from: XCTUnwrap(URL(string:
            "guangyi-workspace://auth/callback?state=\(state)&code=\(code)"))), code)
        let invalidCallbacks = [
            callback.replacingOccurrences(of: "guangyi-workspace:", with: "https:"),
            callback.replacingOccurrences(of: "://auth/", with: "://attacker/"),
            callback.replacingOccurrences(of: "/callback?", with: "/callback/extra?"),
            callback.replacingOccurrences(of: "://auth/", with: "://intruder@auth/"),
            callback.replacingOccurrences(of: "://auth/", with: "://auth:443/"),
            callback + "#fragment", callback + "&code=\(code)", callback + "&state=\(state)",
            callback + "&unexpected=value",
            callback.replacingOccurrences(of: "state=\(state)", with: "state=\(String(repeating: "t", count: 43))"),
            callback.replacingOccurrences(of: "&state=\(state)", with: ""),
            callback.replacingOccurrences(of: "code=\(code)", with: "code=short"),
            callback.replacingOccurrences(of: "code=\(code)", with: "code=\(String(repeating: "c", count: 42))%2B")
        ]
        for callback in invalidCallbacks {
            XCTAssertThrowsError(try request.authorizationCode(from: XCTUnwrap(URL(string: callback))), callback)
        }
    }
    func testWebLoginRejectsMalformedInputsAndUnsafeServerURLs() throws {
        let state = String(repeating: "s", count: 43), verifier = String(repeating: "v", count: 43)
        for invalidState in ["", String(repeating: "s", count: 42), String(repeating: "s", count: 44),
                             String(repeating: "s", count: 42) + "+"] {
            XCTAssertThrowsError(try WebLoginRequest(state: invalidState, codeVerifier: verifier))
        }
        for invalidVerifier in ["", String(repeating: "v", count: 42), String(repeating: "v", count: 129),
                                String(repeating: "v", count: 42) + "+"] {
            XCTAssertThrowsError(try WebLoginRequest(state: state, codeVerifier: invalidVerifier))
        }
        XCTAssertNoThrow(try WebLoginRequest(state: state, codeVerifier: String(repeating: "v", count: 124) + "._~-"))
        let request = try WebLoginRequest(state: state, codeVerifier: verifier)
        for server in ["http://workspace.example", "file:///tmp/workspace", "https://user:secret@workspace.example",
                       "https://workspace.example/path", "https://workspace.example?query=value",
                       "https://workspace.example#fragment"] {
            XCTAssertThrowsError(try request.authorizationURL(server: XCTUnwrap(URL(string: server))), server)
        }
    }
    func testMonthlyRecurrenceClampsWithoutDrifting() {
        let dates = RecurrenceEngine.dates(anchor: date("2028-01-31"), rule: RecurrenceRule(frequency: .monthly),
            from: date("2028-01-31"), through: date("2028-03-31"), timezone: "Asia/Shanghai")
        XCTAssertEqual(dates.map { WorkspaceDates.dayKey($0, timezone: "Asia/Shanghai") }, ["2028-01-31", "2028-02-29", "2028-03-31"])
    }
    func testWeeklyRuleAnchorsToMondayAndPreservesExtraFirst() {
        let dates = RecurrenceEngine.dates(anchor: date("2026-10-16"), rule: RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [1, 3]),
            from: date("2026-10-16"), through: date("2026-10-31"), timezone: "Asia/Shanghai")
        XCTAssertEqual(dates.map { WorkspaceDates.dayKey($0, timezone: "Asia/Shanghai") }, ["2026-10-16", "2026-10-26", "2026-10-28"])
    }
    func testMaterializationIsIdempotentAndBounded() {
        var record = WorkspaceRecord(kind: .deadline, title: "每日检查")
        record.dueDate = date("2026-10-14")
        let series = DeadlineSeries(template: record, rule: RecurrenceRule(frequency: .daily))
        record.recurrenceSeriesID = series.id; record.occurrenceDate = "2026-10-14"
        var state = WorkspaceState(records: [record], series: [series])
        RecurrenceEngine.materialize(&state, now: date("2026-10-14"))
        let count = state.records.count
        XCTAssertEqual(count, RecurrenceEngine.futureWindowDays + 1)
        RecurrenceEngine.materialize(&state, now: date("2026-10-14"))
        XCTAssertEqual(state.records.count, count)
        XCTAssertEqual(Set(state.records.compactMap(\.occurrenceDate)).count, count)
    }
    func testStoppedRecurrenceDoesNotGenerate() {
        var record = WorkspaceRecord(kind: .deadline, title: "已停止")
        record.dueDate = date("2026-10-14")
        let series = DeadlineSeries(template: record, rule: RecurrenceRule(frequency: .daily), stoppedAt: date("2026-10-14"))
        var state = WorkspaceState(series: [series])
        RecurrenceEngine.materialize(&state, now: date("2026-10-14"))
        XCTAssertTrue(state.records.isEmpty)
    }
    func testInstantRecurrencePreservesWallClockAcrossDST() {
        var record = WorkspaceRecord(kind: .deadline, title: "晨间检查")
        record.timezone = "America/New_York"; record.dateOnly = false
        record.dueDate = date("2026-03-07T09:00:00-05:00")
        let series = DeadlineSeries(template: record, rule: RecurrenceRule(frequency: .daily, until: date("2026-03-10T12:00:00Z")))
        var state = WorkspaceState(series: [series])
        RecurrenceEngine.materialize(&state, now: record.dueDate!)
        XCTAssertEqual(state.records.count, 4)
        XCTAssertTrue(state.records.allSatisfy { record.calendar.component(.hour, from: $0.dueDate!) == 9 })
    }
    func testCascadeTrashRestoresRelationships() throws {
        let project = WorkspaceRecord(kind: .project, title: "研究")
        var milestone = WorkspaceRecord(kind: .milestone, title: "里程碑"); milestone.projectID = project.id
        var task = WorkspaceRecord(kind: .task, title: "行动"); task.projectID = project.id; task.milestoneID = milestone.id
        var state = WorkspaceState(records: [project, milestone, task])
        let preview = try WorkspaceLogic.preview(project, in: state)
        try WorkspaceLogic.delete(preview, from: &state)
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt != nil })
        try WorkspaceLogic.restore(state.trash[0], in: &state)
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(state.records.first { $0.id == task.id }?.milestoneID, milestone.id)
        try WorkspaceLogic.validate(state)
    }
    func testNestedProjectCascadeRestoresEveryLevelAndRejectsStaleGrandchild() throws {
        let root = WorkspaceRecord(kind: .project, title: "大学生活")
        var child = WorkspaceRecord(kind: .project, title: "课程"); child.projectID = root.id
        var grandchild = WorkspaceRecord(kind: .project, title: "高等数学"); grandchild.projectID = child.id
        var milestone = WorkspaceRecord(kind: .milestone, title: "期中复习"); milestone.projectID = grandchild.id
        var task = WorkspaceRecord(kind: .task, title: "完成练习")
        task.projectID = grandchild.id; task.milestoneID = milestone.id
        var deadline = WorkspaceRecord(kind: .deadline, title: "交作业"); deadline.projectID = grandchild.id
        let unrelated = WorkspaceRecord(kind: .project, title: "其他")
        let branchIDs: Set<UUID> = [root.id, child.id, grandchild.id, milestone.id, task.id, deadline.id]
        var state = WorkspaceState(records: [root, child, grandchild, milestone, task, deadline, unrelated])
        try WorkspaceLogic.validate(state)
        state.records[0].archivedAt = date("2026-10-16")
        XCTAssertEqual(Set(WorkspaceRecordIndex(state.records).visibleRecords.map(\.id)), [unrelated.id])
        XCTAssertFalse(WorkspaceLogic.visible(task, in: state))
        state.records[0].archivedAt = nil
        XCTAssertEqual(Set(WorkspaceLogic.descendants(of: root, in: state).map(\.id)), branchIDs)
        let stale = try WorkspaceLogic.preview(root, in: state)
        state.records[4].version += 1
        let before = state
        XCTAssertThrowsError(try WorkspaceLogic.delete(stale, from: &state))
        XCTAssertEqual(state, before)
        try WorkspaceLogic.delete(WorkspaceLogic.preview([root.id, child.id], in: state), from: &state)
        XCTAssertEqual(Set(state.trash[0].itemIDs), branchIDs)
        XCTAssertEqual(Set(state.records.filter { $0.deletedAt == nil }.map(\.id)), [unrelated.id])
        try WorkspaceLogic.restore(state.trash[0], in: &state)
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(state.records[1].projectID, root.id)
        XCTAssertEqual(state.records[2].projectID, child.id)
        XCTAssertEqual(state.records[4].milestoneID, milestone.id)
        try WorkspaceLogic.validate(state)
    }
    func testNestedProjectRejectsSelfAndCyclicParentsWithoutLoopingDeletion() throws {
        var first = WorkspaceRecord(kind: .project, title: "第一组")
        first.projectID = first.id
        XCTAssertThrowsError(try WorkspaceLogic.validate(WorkspaceState(records: [first])))
        var second = WorkspaceRecord(kind: .project, title: "第二组"); second.projectID = first.id
        first.projectID = second.id
        var task = WorkspaceRecord(kind: .task, title: "循环中的事项"); task.projectID = second.id
        let state = WorkspaceState(records: [first, second, task])
        XCTAssertThrowsError(try WorkspaceLogic.validate(state))
        XCTAssertEqual(Set(WorkspaceLogic.descendants(of: first, in: state).map(\.id)), [first.id, second.id, task.id])
        XCTAssertEqual(Set(try WorkspaceLogic.preview(first, in: state).records.map(\.id)), [first.id, second.id, task.id])
    }
    func testPreviewRejectsNewChildAndMakesNoChanges() throws {
        let project = WorkspaceRecord(kind: .project, title: "项目")
        var state = WorkspaceState(records: [project])
        let preview = try WorkspaceLogic.preview(project, in: state)
        var child = WorkspaceRecord(kind: .task, title: "另一个窗口新增"); child.projectID = project.id
        state.records.append(child)
        XCTAssertThrowsError(try WorkspaceLogic.delete(preview, from: &state))
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(state.trash.isEmpty)
    }
    func testTrashExpiryPreservesExactBoundary() throws {
        let record = WorkspaceRecord(kind: .task, title: "边界")
        let now = Date()
        var state = WorkspaceState(records: [record])
        try WorkspaceLogic.delete(WorkspaceLogic.preview(record, in: state), from: &state, now: now)
        let batch = state.trash[0]
        var expired = state
        XCTAssertThrowsError(try WorkspaceLogic.restore(batch, in: &expired, now: batch.expiresAt!.addingTimeInterval(1)))
        try WorkspaceLogic.restore(batch, in: &state, now: batch.expiresAt!)
        XCTAssertNil(state.records[0].deletedAt)
    }
    func testKnowledgeTrashHasNoThirtyDayLimit() throws {
        let note = WorkspaceRecord(kind: .knowledge, title: "笔记")
        var state = WorkspaceState(records: [note])
        try WorkspaceLogic.delete(WorkspaceLogic.preview(note, in: state), from: &state)
        XCTAssertNil(state.trash[0].expiresAt)
        try WorkspaceLogic.restore(state.trash[0], in: &state, now: Date().addingTimeInterval(365 * 86400))
    }
    func testSnoozeDoesNotChangeDeadline() {
        var record = WorkspaceRecord(kind: .deadline, title: "不改期")
        record.notificationsEnabled = true; record.dueDate = date("2040-10-14"); record.snoozedUntil = date("2040-10-14T12:00:00+08:00")
        XCTAssertEqual(record.notificationDate, record.snoozedUntil)
        XCTAssertEqual(record.dueDate, date("2040-10-14"))
        record.status = "DONE"
        XCTAssertNil(record.notificationDate)
    }
    func testMalformedRelationshipsAndDuplicateIDsAreRejected() {
        var record = WorkspaceRecord(kind: .task, title: "关联缺失"); record.projectID = UUID()
        XCTAssertThrowsError(try WorkspaceLogic.validate(WorkspaceState(records: [record])))
        record.projectID = nil
        XCTAssertThrowsError(try WorkspaceLogic.validate(WorkspaceState(records: [record, record])))
    }
    func testDateOnlyDeadlineEndsAtWorkspaceMidnight() {
        var record = WorkspaceRecord(kind: .deadline, title: "仅日期")
        record.dueDate = date("2026-10-14")
        XCTAssertEqual(record.calendar.component(.hour, from: record.effectiveDueDate(record.dueDate!)), 23)
        XCTAssertEqual(record.calendar.component(.minute, from: record.effectiveDueDate(record.dueDate!)), 59)
    }
    func testUnifiedActionsSortAcrossKindsByImportance() {
        let now = date("2026-10-15T12:00:00Z")
        var task = WorkspaceRecord(kind: .task, title: "普通行动")
        task.updatedAt = now.addingTimeInterval(20)
        var project = WorkspaceRecord(kind: .project, title: "行动组")
        project.updatedAt = now.addingTimeInterval(30)
        var reminder = WorkspaceRecord(kind: .reminder, title: "有时间的提醒")
        reminder.remindAt = now.addingTimeInterval(3_600)
        var milestone = WorkspaceRecord(kind: .milestone, title: "置顶里程碑")
        milestone.pinned = true
        var completed = WorkspaceRecord(kind: .task, title: "已完成行动")
        completed.status = "DONE"; completed.updatedAt = now.addingTimeInterval(60)
        var deadline = WorkspaceRecord(kind: .deadline, title: "不属于行动入口")
        deadline.dueDate = now.addingTimeInterval(1_800)
        let sorted = WorkspaceLogic.actionRecords(in: WorkspaceState(records: [task, project, reminder, milestone, completed, deadline]))
        XCTAssertEqual(sorted.map(\.title), ["置顶里程碑", "有时间的提醒", "普通行动", "已完成行动"])
    }
    func testUnifiedGroupsAndItemsRetainLegacyRelationships() throws {
        let area = WorkspaceRecord(kind: .area, title: "学习")
        var project = WorkspaceRecord(kind: .project, title: "课程报告")
        project.areaID = area.id
        var task = WorkspaceRecord(kind: .task, title: "写正文"); task.projectID = project.id
        var reminder = WorkspaceRecord(kind: .reminder, title: "查通知"); reminder.areaID = area.id
        var milestone = WorkspaceRecord(kind: .milestone, title: "完成初稿"); milestone.projectID = project.id
        let state = WorkspaceState(records: [area, project, task, reminder, milestone])
        try WorkspaceLogic.validate(state)
        XCTAssertEqual(Set(WorkspaceLogic.projectGroupRecords(in: state).map(\.id)), [area.id, project.id])
        XCTAssertEqual(Set(WorkspaceLogic.actionRecords(in: state).map(\.id)), [task.id, reminder.id, milestone.id])
        XCTAssertEqual(Set(WorkspaceLogic.members(of: area, in: state).map(\.id)), [project.id, reminder.id])
        XCTAssertEqual(Set(WorkspaceLogic.members(of: project, in: state).map(\.id)), [task.id, milestone.id])
        XCTAssertFalse(milestone.isKeyItem)
    }
    func testArchivedGroupHidesNestedGroupsAndItems() {
        var area = WorkspaceRecord(kind: .area, title: "学习")
        area.archivedAt = Date()
        var group = WorkspaceRecord(kind: .project, title: "报告"); group.areaID = area.id
        var item = WorkspaceRecord(kind: .task, title: "正文"); item.projectID = group.id
        var state = WorkspaceState(records: [area, group, item])
        XCTAssertTrue(WorkspaceLogic.projectGroupRecords(in: state).isEmpty)
        XCTAssertTrue(WorkspaceLogic.actionRecords(in: state).isEmpty)
        state.records[0].archivedAt = nil
        XCTAssertEqual(WorkspaceLogic.projectGroupRecords(in: state).count, 2)
        XCTAssertEqual(WorkspaceLogic.actionRecords(in: state).map(\.id), [item.id])
    }
    func testManualItemStarsSurviveSnapshotRoundTrip() throws {
        var records = [ItemKind.task, .reminder, .milestone].map { WorkspaceRecord(kind: $0, title: "事项") }
        XCTAssertTrue(records.allSatisfy { !$0.isKeyItem })
        records[1].pinned = true
        let data = try WorkspaceCoding.encoder().encode(WorkspaceState(records: records))
        let decoded = try WorkspaceCoding.decoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded.records.map(\.id), records.map(\.id))
        XCTAssertEqual(decoded.records.map(\.kind), records.map(\.kind))
        XCTAssertEqual(decoded.records.map(\.isKeyItem), [false, true, false])
    }
    func testMergedItemsUseExplicitReminderBeforeTheirDeadline() {
        for kind in [ItemKind.task, .reminder, .milestone] {
            var item = WorkspaceRecord(kind: kind, title: "事项")
            item.notificationsEnabled = true; item.dateOnly = false
            item.dueDate = date("2026-10-16T12:00:00Z")
            item.remindAt = date("2026-10-16T10:00:00Z")
            XCTAssertEqual(item.notificationDate, item.remindAt)
        }
    }
    func testJSONExportRoundingIsNotAContentConflict() throws {
        var record = WorkspaceRecord(kind: .knowledge, title: "保留内容")
        record.body = "**原生笔记**\n数学源码：$x^2$"
        let data = try WorkspaceCoding.encoder().encode(record)
        let decoded = try WorkspaceCoding.decoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertTrue(WorkspaceCoding.equivalent(record, decoded))
        var edited = decoded; edited.body += "不同的修改"
        XCTAssertFalse(WorkspaceCoding.equivalent(record, edited))
    }
}

extension WorkspaceCoreTests {
    func testDeadlineStarsDoNotOverrideChronologicalOrder() {
        let base = date("2026-10-17T12:00:00+08:00")
        var near = WorkspaceRecord(kind: .deadline, title: "最近截止"); near.dueDate = base
        var equalStarred = WorkspaceRecord(kind: .deadline, title: "同时间标星")
        equalStarred.dueDate = base; equalStarred.pinned = true
        var distantStarred = WorkspaceRecord(kind: .deadline, title: "明年标星")
        distantStarred.dueDate = base.addingTimeInterval(365 * 86_400); distantStarred.pinned = true
        var finishedStarred = WorkspaceRecord(kind: .deadline, title: "已完成标星")
        finishedStarred.dueDate = base.addingTimeInterval(-86_400); finishedStarred.status = "DONE"
        finishedStarred.pinned = true
        let index = WorkspaceRecordIndex([finishedStarred, distantStarred, near, equalStarred])
        XCTAssertEqual(index.records(.deadline).map(\.id), [equalStarred, near, distantStarred, finishedStarred].map(\.id))

        var dateOnly = WorkspaceRecord(kind: .deadline, title: "今天结束前")
        dateOnly.dueDate = date("2026-10-17"); dateOnly.dateOnly = true
        var timed = WorkspaceRecord(kind: .deadline, title: "今天中午")
        timed.dueDate = base; timed.dateOnly = false
        XCTAssertEqual(WorkspaceRecordIndex([dateOnly, timed]).records(.deadline).map(\.id), [timed.id, dateOnly.id])

        near.kind = .reminder; distantStarred.kind = .reminder
        XCTAssertEqual(WorkspaceRecordIndex([near, distantStarred]).records(.reminder).map(\.id),
            [distantStarred.id, near.id])
    }


    func testDeadlineStarsSurviveExistingSnapshotRoundTrip() throws {
        var deadline = WorkspaceRecord(kind: .deadline, title: "旧版置顶截止事项")
        deadline.pinned = true; deadline.dueDate = date("2026-10-18")
        let data = try WorkspaceCoding.encoder().encode(WorkspaceState(records: [deadline]))
        let decoded = try WorkspaceCoding.decoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded.records.first?.id, deadline.id)
        XCTAssertEqual(decoded.records.first?.isKeyItem, true)
        XCTAssertEqual(decoded.records.first?.pinned, true)
        deadline.pinned = false
        XCTAssertFalse(deadline.isKeyItem)
        var note = WorkspaceRecord(kind: .knowledge, title: "笔记"); note.pinned = true
        XCTAssertFalse(note.isKeyItem)
    }

    func testItemKindConversionRoundTripPreservesIdentityFieldsDatesAndReminder() throws {
        let area = WorkspaceRecord(kind: .area, title: "学习")
        var project = WorkspaceRecord(kind: .project, title: "报告"); project.areaID = area.id
        var milestone = WorkspaceRecord(kind: .milestone, title: "初稿"); milestone.projectID = project.id
        var item = WorkspaceRecord(kind: .task, title: "整理材料")
        item.version = 7; item.createdAt = date("2026-10-10"); item.updatedAt = date("2026-10-15")
        item.projectID = project.id; item.areaID = area.id; item.milestoneID = milestone.id
        item.summary = "摘要"; item.body = "**材料**"; item.tags = ["学习", "报告"]; item.pinned = true
        item.category = "课程"; item.projectKind = "PERSONAL"; item.calendarEventID = "linked-event"
        item.startDate = date("2026-10-11"); item.targetDate = date("2026-10-20")
        item.dateOnly = false; item.timezone = "Europe/London"
        item.scheduledAt = date("2026-10-17T09:00:00Z")
        item.remindAt = date("2026-10-17T08:30:00Z"); item.dueDate = date("2026-10-18T18:00:00Z")
        item.notificationsEnabled = true; item.notificationLeadMinutes = 45
        let state = WorkspaceState(records: [area, project, milestone, item])
        let draft = try WorkspaceLogic.conversionDraft(item, to: .deadline, in: state)
        var expected = item; expected.kind = .deadline; expected.status = "OPEN"
        XCTAssertEqual(draft, expected)
        XCTAssertTrue(draft.isKeyItem)
        XCTAssertEqual(draft.notificationDate, item.remindAt)
        let restored = try WorkspaceLogic.conversionDraft(draft, to: .task, in: state)
        XCTAssertEqual(restored, item)
        XCTAssertEqual(restored.notificationDate, item.notificationDate)
        var saved = state; saved.records[saved.records.count - 1] = draft
        try WorkspaceLogic.validate(saved)
        XCTAssertEqual(state.records.last, item)

        var snoozed = item; snoozed.snoozedUntil = date("2026-10-17T08:45:00Z")
        let convertedSnooze = try WorkspaceLogic.conversionDraft(snoozed, to: .deadline, in: state)
        XCTAssertEqual(convertedSnooze.snoozedUntil, snoozed.snoozedUntil)
        XCTAssertEqual(convertedSnooze.notificationDate, snoozed.notificationDate)
    }

    func testItemKindConversionNormalizesStatusesWithoutChangingCompletionMetadata() throws {
        for kind in [ItemKind.task, .reminder, .milestone, .deadline] {
            for status in kind.states {
                var item = WorkspaceRecord(kind: kind, title: "状态转换")
                item.status = status
                item.completedAt = status == "DONE" ? date("2026-10-16") : nil
                item.cancelledAt = status == "CANCELLED" ? date("2026-10-15") : nil
                let state = WorkspaceState(records: [item])
                for target in [ItemKind.task, .deadline] {
                    let draft = try WorkspaceLogic.conversionDraft(item, to: target, in: state)
                    let expectedStatus = target.states.contains(status) ? status : target.incompleteStatus
                    XCTAssertEqual(draft.status, expectedStatus, "\(kind) / \(status) → \(target)")
                    XCTAssertEqual(draft.completedAt, item.completedAt)
                    XCTAssertEqual(draft.cancelledAt, item.cancelledAt)
                    XCTAssertEqual(draft.version, item.version)
                    XCTAssertEqual(draft.updatedAt, item.updatedAt)
                    XCTAssertEqual(draft.isFinished, item.isFinished)
                    try WorkspaceLogic.validate(WorkspaceState(records: [draft]))
                }
            }
        }
    }

    func testItemKindConversionLeavesMissingDeadlineForEditorToChoose() throws {
        var item = WorkspaceRecord(kind: .task, title: "尚未定截止时间")
        item.scheduledAt = date("2026-10-17T09:00:00+08:00")
        item.remindAt = date("2026-10-17T08:30:00+08:00"); item.notificationsEnabled = true
        let state = WorkspaceState(records: [item])
        let draft = try WorkspaceLogic.conversionDraft(item, to: .deadline, in: state)
        XCTAssertNil(draft.dueDate)
        XCTAssertEqual(draft.scheduledAt, item.scheduledAt)
        XCTAssertEqual(draft.remindAt, item.remindAt)
        XCTAssertEqual(draft.notificationDate, item.remindAt)
        XCTAssertEqual(state.records, [item])
    }

    func testItemKindConversionRejectsUnsupportedOrUnavailableRecords() throws {
        for kind in [ItemKind.area, .project, .knowledge] {
            let record = WorkspaceRecord(kind: kind, title: "不支持的内容")
            XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(record, to: .deadline,
                in: WorkspaceState(records: [record])))
        }
        let item = WorkspaceRecord(kind: .task, title: "事项")
        for target in [ItemKind.area, .project, .milestone, .reminder, .knowledge] {
            XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(item, to: target,
                in: WorkspaceState(records: [item])))
        }
        var unavailable = item; unavailable.archivedAt = date("2026-10-16")
        XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(unavailable, to: .deadline,
            in: WorkspaceState(records: [unavailable])))
        unavailable.archivedAt = nil; unavailable.deletedAt = date("2026-10-16")
        XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(unavailable, to: .deadline,
            in: WorkspaceState(records: [unavailable])))
        var area = WorkspaceRecord(kind: .area, title: "隐藏的父级"); area.archivedAt = date("2026-10-16")
        var project = WorkspaceRecord(kind: .project, title: "子项目组"); project.areaID = area.id
        var child = item; child.projectID = project.id
        XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(child, to: .deadline,
            in: WorkspaceState(records: [area, project, child])))
        child.projectID = UUID()
        XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(child, to: .deadline,
            in: WorkspaceState(records: [child])))
        var milestone = WorkspaceRecord(kind: .milestone, title: "隐藏的关联事项")
        milestone.archivedAt = date("2026-10-16"); child.projectID = nil; child.milestoneID = milestone.id
        XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(child, to: .deadline,
            in: WorkspaceState(records: [milestone, child])))
    }

    func testItemKindConversionRejectsLinkedMilestoneWithoutDiscardingRelationships() throws {
        let project = WorkspaceRecord(kind: .project, title: "项目组")
        var milestone = WorkspaceRecord(kind: .milestone, title: "关联节点"); milestone.projectID = project.id
        var child = WorkspaceRecord(kind: .task, title: "依赖节点")
        child.projectID = project.id; child.milestoneID = milestone.id
        let state = WorkspaceState(records: [project, milestone, child])
        try WorkspaceLogic.validate(state)
        for target in [ItemKind.task, .deadline] {
            XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(milestone, to: target, in: state))
        }
        child.scheduledAt = date("2026-10-18T10:00:00+08:00")
        let series = DeadlineSeries(template: child, rule: RecurrenceRule(frequency: .daily))
        let templateLinkedState = WorkspaceState(records: [project, milestone], series: [series])
        XCTAssertThrowsError(try WorkspaceLogic.conversionDraft(milestone, to: .deadline, in: templateLinkedState))
        let unlinkedState = WorkspaceState(records: [project, milestone])
        let draft = try WorkspaceLogic.conversionDraft(milestone, to: .deadline, in: unlinkedState)
        XCTAssertEqual(draft.projectID, project.id)
        try WorkspaceLogic.validate(WorkspaceState(records: [project, draft]))
        XCTAssertEqual(state.records.last?.milestoneID, milestone.id)
        XCTAssertEqual(templateLinkedState.series.first?.template.milestoneID, milestone.id)
    }

    func testItemKindConversionChangesOnlyOneRecurringOccurrenceThroughMaterialization() throws {
        for kind in [ItemKind.task, .deadline] {
            var item = WorkspaceRecord(kind: kind, title: "每天整理")
            item.dateOnly = false; item.pinned = true
            item.scheduledAt = date("2026-10-17T10:00:00+08:00")
            item.dueDate = date("2026-10-17T12:00:00+08:00")
            item.remindAt = date("2026-10-17T09:00:00+08:00"); item.notificationsEnabled = true
            var state = WorkspaceState(records: [item])
            let now = date("2026-10-17T08:00:00+08:00")
            try RecurrenceEngine.start(item.id,
                rule: RecurrenceRule(frequency: .daily, until: date("2026-10-19")), in: &state, now: now)
            let index = try XCTUnwrap(state.records.firstIndex { $0.occurrenceDate == "2026-10-18" })
            let original = state.records[index], before = state
            XCTAssertEqual(try WorkspaceLogic.conversionDraft(original, to: kind, in: state), original)
            let target: ItemKind = kind == .task ? .deadline : .task
            let draft = try WorkspaceLogic.conversionDraft(original, to: target, in: state)
            XCTAssertEqual(draft.id, original.id)
            XCTAssertEqual(draft.recurrenceSeriesID, original.recurrenceSeriesID)
            XCTAssertEqual(draft.occurrenceDate, original.occurrenceDate)
            XCTAssertTrue(draft.isException)
            XCTAssertEqual(draft.notificationDate, original.notificationDate)
            state.records[index] = draft
            RecurrenceEngine.materialize(&state, now: now)
            RecurrenceEngine.materialize(&state, now: date("2026-10-18T08:00:00+08:00"))
            XCTAssertEqual(state.series, before.series)
            XCTAssertEqual(state.records.first { $0.id == draft.id }, draft)
            XCTAssertEqual(state.records.filter { $0.id != draft.id }, before.records.filter { $0.id != draft.id })
            XCTAssertTrue(state.records.filter { $0.id != draft.id }.allSatisfy { $0.kind == kind })
            try WorkspaceLogic.validate(state)
        }
    }
}


extension WorkspaceCoreTests {
    private func countdownDeadline(_ title: String, _ stamp: String, id: UUID = UUID()) -> WorkspaceRecord {
        var record = WorkspaceRecord(kind: .deadline, title: title, id: id)
        record.dateOnly = false; record.dueDate = date(stamp)
        return record
    }

    func testCountdownGroupsMergeTodayAndFutureCalendarDays() {
        let todayEarly = countdownDeadline("今日上午", "2026-10-16T08:00:00+08:00")
        let todayLate = countdownDeadline("今日晚上", "2026-10-16T23:00:00+08:00")
        let tomorrowEarly = countdownDeadline("明日中午", "2026-10-17T12:00:00+08:00")
        let tomorrowLate = countdownDeadline("明日晚上", "2026-10-17T22:00:00+08:00")
        let now = date("2026-10-16T12:00:00+08:00")
        let groups = WorkspaceLogic.deadlineCountdownGroups(
            [tomorrowLate, todayLate, tomorrowEarly, todayEarly], now: now)

        XCTAssertEqual(groups.map { $0.records.map(\.id) },
            [[todayEarly.id, todayLate.id], [tomorrowEarly.id, tomorrowLate.id]])
        XCTAssertEqual(groups.first?.countdownDate(at: now), todayLate.dueDate)
    }

    func testCountdownGroupsBoundPastClustersToFirstDeadlineIncludingOneHour() {
        let first = countdownDeadline("起点", "2026-10-15T08:00:00+08:00")
        let boundary = countdownDeadline("一小时整", "2026-10-15T09:00:00+08:00")
        let outside = countdownDeadline("超过一秒", "2026-10-15T09:00:01+08:00")
        let neighbor = countdownDeadline("后续近邻", "2026-10-15T09:40:00+08:00")
        let groups = WorkspaceLogic.deadlineCountdownGroups([neighbor, boundary, outside, first],
            now: date("2026-10-16T12:00:00+08:00"))

        XCTAssertEqual(groups.map { $0.records.map(\.id) },
            [[first.id, boundary.id], [outside.id, neighbor.id]])
        XCTAssertEqual(groups.first?.dueDates, [first.dueDate!, boundary.dueDate!])
    }

    func testCountdownGroupsMergeAcrossMidnightOnlyWhenWholeDayFits() {
        let beforeMidnight = countdownDeadline("昨日深夜", "2026-10-15T23:40:00+08:00")
        let afterMidnight = countdownDeadline("今日凌晨", "2026-10-16T00:10:00+08:00")
        let tonight = countdownDeadline("今日晚上", "2026-10-16T23:00:00+08:00")
        let now = date("2026-10-16T12:00:00+08:00")
        let nearGroups = WorkspaceLogic.deadlineCountdownGroups([afterMidnight, beforeMidnight], now: now)
        XCTAssertEqual(nearGroups.map { $0.records.map(\.id) }, [[beforeMidnight.id, afterMidnight.id]])

        let wholeDayGroups = WorkspaceLogic.deadlineCountdownGroups([tonight, afterMidnight, beforeMidnight], now: now)
        XCTAssertEqual(wholeDayGroups.map { $0.records.map(\.id) },
            [[beforeMidnight.id], [afterMidnight.id, tonight.id]])
    }

    func testCountdownGroupAdvancesAndUsesLastDeadlineWhenAllArePast() throws {
        let first = countdownDeadline("第一项", "2026-10-16T10:00:00+08:00")
        let second = countdownDeadline("第二项", "2026-10-16T11:00:00+08:00")
        let last = countdownDeadline("第三项", "2026-10-16T12:00:00+08:00")
        let records = [last, first, second]
        let group = try XCTUnwrap(WorkspaceLogic.deadlineCountdownGroups(records,
            now: date("2026-10-16T09:00:00+08:00")).first)

        XCTAssertEqual(group.countdownDate(at: date("2026-10-16T09:00:00+08:00")), first.dueDate)
        XCTAssertEqual(group.countdownDate(at: date("2026-10-16T10:30:00+08:00")), second.dueDate)
        XCTAssertEqual(group.countdownDate(at: date("2026-10-16T11:30:00+08:00")), last.dueDate)
        XCTAssertEqual(group.countdownDate(at: date("2026-10-16T13:00:00+08:00")), last.dueDate)
        let reordered = try XCTUnwrap(WorkspaceLogic.deadlineCountdownGroups(Array(records.reversed()),
            now: date("2026-10-16T13:00:00+08:00")).first)
        XCTAssertEqual(group.id, reordered.id)
    }

    func testCountdownGroupsFilterAndSortEffectiveDateOnlyDeadlines() throws {
        let now = date("2026-10-16T12:00:00+08:00")
        var dateOnly = countdownDeadline("当日截止", "2026-10-16T00:00:00+08:00",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        dateOnly.dateOnly = true
        let exact = countdownDeadline("同刻截止", "2026-10-16T23:59:59+08:00",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var task = countdownDeadline("非 DDL", "2026-10-16T13:00:00+08:00"); task.kind = .task
        var done = countdownDeadline("已完成", "2026-10-16T13:00:00+08:00"); done.status = "DONE"
        var cancelled = countdownDeadline("已取消", "2026-10-16T13:00:00+08:00"); cancelled.status = "CANCELLED"
        var archived = countdownDeadline("已归档", "2026-10-16T13:00:00+08:00"); archived.archivedAt = now
        var deleted = countdownDeadline("已删除", "2026-10-16T13:00:00+08:00"); deleted.deletedAt = now
        let undated = WorkspaceRecord(kind: .deadline, title: "未设日期")
        let groups = WorkspaceLogic.deadlineCountdownGroups(
            [dateOnly, task, done, cancelled, archived, deleted, undated, exact], now: now)
        let group = try XCTUnwrap(groups.first)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.records.map(\.id), [exact.id, dateOnly.id])
        XCTAssertEqual(group.dueDates.first, dateOnly.effectiveDueDate(dateOnly.dueDate!))
        XCTAssertEqual(group.countdownDate(at: now), exact.dueDate)
    }
}

final class WorkspaceSyncMergeTests: XCTestCase {
    func testDisjointOfflineEditsAndNewRecordsArePreserved() throws {
        let first = WorkspaceRecord(kind: .task, title: "行动一")
        let second = WorkspaceRecord(kind: .deadline, title: "DDL 二")
        let base = WorkspaceState(records: [first, second])
        var local = base, remote = base
        local.records[0].title = "本机修改"; local.records[0].version += 1
        remote.records[1].title = "其他设备修改"; remote.records[1].version += 1
        remote.records.append(WorkspaceRecord(kind: .task, title: "远程新增"))
        let merged = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertEqual(Set(merged.records.map(\.title)), ["本机修改", "其他设备修改", "远程新增"])
    }
    func testConcurrentSameVersionEditsRequireReview() throws {
        let base = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "原始")])
        var local = base, remote = base
        local.records[0].title = "本机"; local.records[0].version += 1
        remote.records[0].title = "远程"; remote.records[0].version += 1
        XCTAssertThrowsError(try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote))
        XCTAssertEqual(local.records[0].title, "本机")
        XCTAssertEqual(remote.records[0].title, "远程")
    }
    func testRemoteDeletionOnlyWinsWhenLocalIsUnchanged() throws {
        let base = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "原始")])
        let remote = WorkspaceState()
        XCTAssertTrue(try WorkspaceSyncMerge.reconcile(base: base, local: base, remote: remote).records.isEmpty)
        var local = base; local.records[0].title = "离线修改"
        XCTAssertThrowsError(try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote))
    }
    func testFirstSyncDoesNotOverwriteCollidingLocalContent() throws {
        let local = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "本机")])
        var remote = local; remote.records[0].title = "服务器"
        XCTAssertThrowsError(try WorkspaceSyncMerge.reconcile(base: nil, local: local, remote: remote))
    }
}

@MainActor final class WorkspaceSyncDriverTests: XCTestCase {
    func testBackgroundConflictProbePreservesReviewCriteria() async throws {
        let base = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "原始")])
        let clean = try await WorkspaceSyncDriver.requiresReviewInBackground(base: base, local: base, remote: base)
        XCTAssertFalse(clean)
        var local = base, remote = base
        local.records[0].title = "本机修改"; remote.records[0].title = "云端修改"
        let conflict = try await WorkspaceSyncDriver.requiresReviewInBackground(base: base, local: local, remote: remote)
        XCTAssertTrue(conflict)
        remote.records.append(remote.records[0])
        let invalid = try await WorkspaceSyncDriver.requiresReviewInBackground(base: base, local: local, remote: remote)
        XCTAssertFalse(invalid, "Invalid data must remain a failure, not a resolvable conflict")
    }
    func testBackgroundConflictProbeLetsMainActorProcessOtherWork() async throws {
        let base = WorkspaceState(records: (0..<100).map { WorkspaceRecord(kind: .task, title: "记录 \($0)") })
        var responsive = false
        let heartbeat = Task { @MainActor in responsive = true }
        _ = try await WorkspaceSyncDriver.requiresReviewInBackground(base: base, local: base, remote: base)
        XCTAssertTrue(responsive, "The conflict probe must release the UI actor while merging")
        await heartbeat.value
    }
    func testCancelledBackgroundConflictProbeDoesNotReturnAReview() async throws {
        let state = WorkspaceState()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceSyncDriver.requiresReviewInBackground(base: state, local: state, remote: state)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not present a review")
        } catch is CancellationError { }
    }
    func testTwoDeviceRoundTripPreservesOfflineChanges() async throws {
        let initial = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "初始")])
        var server = VersionedWorkspace(revision: 0, snapshot: initial)
        var phone = initial, mac = initial
        phone.records.append(WorkspaceRecord(kind: .task, title: "手机新增"))
        mac.records[0].title = "Mac 修改"
        func sync(_ local: inout WorkspaceState) async throws {
            // Value captured outside the inout access mirrors each device's store.
            var current = local
            try await WorkspaceSyncDriver.run(base: initial, readLocal: { current }, isCurrentAccount: { true },
                download: { server }, upload: { value, revision in
                    guard revision == server.revision else { throw WorkspaceSyncError.revisionChanged }
                    server = VersionedWorkspace(revision: revision + 1, snapshot: value); return server
                }, apply: { value, _ in current = value })
            local = current
        }
        try await sync(&phone)
        try await sync(&mac)
        XCTAssertEqual(Set(server.snapshot.records.map(\.title)), ["手机新增", "Mac 修改"])
        XCTAssertEqual(Set(mac.records.map(\.title)), ["手机新增", "Mac 修改"])
    }
    func testVersionConflictDownloadsAgainBeforeRetrying() async throws {
        let base = WorkspaceState()
        var current = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "本机")])
        var server = VersionedWorkspace(revision: 0, snapshot: base)
        var attempts = 0, downloads = 0
        try await WorkspaceSyncDriver.run(base: base, readLocal: { current }, isCurrentAccount: { true }, download: {
            downloads += 1; return server
        }, upload: { value, revision in
            attempts += 1
            if attempts == 1 {
                server.snapshot.records.append(WorkspaceRecord(kind: .task, title: "另一设备")); server.revision += 1
                throw WorkspaceSyncError.revisionChanged
            }
            XCTAssertEqual(revision, server.revision)
            server = VersionedWorkspace(revision: revision + 1, snapshot: value); return server
        }, apply: { value, _ in current = value })
        XCTAssertEqual(downloads, 2)
        XCTAssertEqual(Set(current.records.map(\.title)), ["本机", "另一设备"])
    }
    func testEditingDuringUploadRemainsPendingWithoutLosingLocalEdit() async throws {
        let base = WorkspaceState()
        var current = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "已上传版本")])
        var checkpoint: VersionedWorkspace?
        try await WorkspaceSyncDriver.run(base: base, readLocal: { current }, isCurrentAccount: { true }, download: {
            VersionedWorkspace(revision: 0, snapshot: base)
        }, upload: { value, _ in
            current.records[0].title = "上传期间继续编辑"
            return VersionedWorkspace(revision: 1, snapshot: value)
        }, apply: { value, remote in current = value; checkpoint = remote })
        XCTAssertEqual(current.records[0].title, "上传期间继续编辑")
        XCTAssertEqual(checkpoint?.snapshot.records[0].title, "已上传版本")
    }
    func testAccountChangeRejectsResponseAndNoopSkipsUpload() async throws {
        let empty = WorkspaceState()
        var isCurrent = true, applied = false, uploaded = false
        do {
            try await WorkspaceSyncDriver.run(base: empty, readLocal: { empty }, isCurrentAccount: { isCurrent }, download: {
                isCurrent = false; return VersionedWorkspace(revision: 0, snapshot: empty)
            }, upload: { _, _ in uploaded = true; return VersionedWorkspace(revision: 1, snapshot: empty) }, apply: { _, _ in applied = true })
            XCTFail("Must reject old-account response")
        } catch WorkspaceSyncError.accountChanged { }
        XCTAssertFalse(applied); XCTAssertFalse(uploaded)
        try await WorkspaceSyncDriver.run(base: empty, readLocal: { empty }, isCurrentAccount: { true }, download: {
            VersionedWorkspace(revision: 0, snapshot: empty)
        }, upload: { _, _ in uploaded = true; return VersionedWorkspace(revision: 1, snapshot: empty) }, apply: { _, _ in applied = true })
        XCTAssertTrue(applied); XCTAssertFalse(uploaded)
    }
    func testEditingAfterBackgroundRebaseCaptureRecomputesBeforeApplying() async throws {
        let base = WorkspaceState()
        var current = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "已上传版本")])
        var rebases = 0
        var checkpoint: VersionedWorkspace?
        try await WorkspaceSyncDriver.run(base: base, readLocal: { current }, isCurrentAccount: { true }, download: {
            VersionedWorkspace(revision: 0, snapshot: base)
        }, upload: { value, _ in
            VersionedWorkspace(revision: 1, snapshot: value)
        }, rebase: { baseline, captured, remote in
            rebases += 1
            let merged = try await WorkspaceSyncDriver.rebaseInBackground(baseline, captured, remote)
            if rebases == 1 {
                // Deterministically return an already stale background result.
                current.records[0].title = "重合并期间继续编辑"
                current.records[0].version += 1
            }
            return merged
        }, apply: { value, remote in current = value; checkpoint = remote })
        XCTAssertEqual(rebases, 2)
        XCTAssertEqual(current.records[0].title, "重合并期间继续编辑")
        XCTAssertEqual(checkpoint?.snapshot.records[0].title, "已上传版本")
    }
    func testAccountChangeDuringBackgroundRebaseRejectsApply() async throws {
        let state = WorkspaceState()
        var isCurrent = true, applied = false
        do {
            try await WorkspaceSyncDriver.run(base: state, readLocal: { state }, isCurrentAccount: { isCurrent }, download: {
                VersionedWorkspace(revision: 0, snapshot: state)
            }, upload: { _, _ in
                XCTFail("Unchanged content must not upload")
                return VersionedWorkspace(revision: 1, snapshot: state)
            }, rebase: { baseline, captured, remote in
                let merged = try await WorkspaceSyncDriver.rebaseInBackground(baseline, captured, remote)
                isCurrent = false
                return merged
            }, apply: { _, _ in applied = true })
            XCTFail("A background result from the previous account must be rejected")
        } catch WorkspaceSyncError.accountChanged { }
        XCTAssertFalse(applied)
    }
    func testContinuousEditsDuringRebaseStopWithoutOverwritingLocalContent() async throws {
        let base = WorkspaceState(records: [WorkspaceRecord(kind: .task, title: "初始")])
        var current = base
        var rebases = 0, applied = false
        do {
            try await WorkspaceSyncDriver.run(base: base, readLocal: { current }, isCurrentAccount: { true }, download: {
                VersionedWorkspace(revision: 0, snapshot: base)
            }, upload: { _, _ in
                XCTFail("Initial unchanged content must not upload")
                return VersionedWorkspace(revision: 1, snapshot: base)
            }, rebase: { baseline, captured, remote in
                rebases += 1
                let merged = try await WorkspaceSyncDriver.rebaseInBackground(baseline, captured, remote)
                current.records[0].title = "连续编辑 \(rebases)"
                current.records[0].version += 1
                return merged
            }, apply: { _, _ in applied = true })
            XCTFail("Continuous edits should leave a retryable result")
        } catch WorkspaceFailure.invalid(let message) {
            XCTAssertTrue(message.contains("重试"))
        }
        XCTAssertEqual(rebases, 3)
        XCTAssertFalse(applied)
        XCTAssertEqual(current.records[0].title, "连续编辑 3")
    }
    func testCancellationDuringBackgroundRebaseDoesNotApply() async throws {
        let state = WorkspaceState()
        var applied = false
        let operation = Task { @MainActor in
            try await WorkspaceSyncDriver.run(base: state, readLocal: { state }, isCurrentAccount: { true }, download: {
                VersionedWorkspace(revision: 0, snapshot: state)
            }, upload: { _, _ in
                VersionedWorkspace(revision: 1, snapshot: state)
            }, rebase: { baseline, captured, remote in
                let merged = try await WorkspaceSyncDriver.rebaseInBackground(baseline, captured, remote)
                withUnsafeCurrentTask { $0?.cancel() }
                return merged
            }, apply: { _, _ in applied = true })
        }
        do {
            try await operation.value
            XCTFail("A cancelled background result must not be applied")
        } catch is CancellationError { }
        XCTAssertFalse(applied)
    }
}

final class DeadlineTrackingPolicyTests: XCTestCase {
    func testEligibilityAndEightHourBoundary() {
        let now = Date(timeIntervalSince1970: 1791964800)
        var record = WorkspaceRecord(kind: .deadline, title: "测试")
        record.dateOnly = false; record.dueDate = now.addingTimeInterval(8 * 3600)
        var state = WorkspaceState(records: [record])
        XCTAssertEqual(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now), record.dueDate)
        record.dueDate = now.addingTimeInterval(8 * 3600 + 1); state.records = [record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
        record.dueDate = now; state.records = [record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
        record.dueDate = nil; state.records = [record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
    }
    func testHiddenFinishedAndUnsupportedRecordsAreIneligible() {
        let now = Date()
        var project = WorkspaceRecord(kind: .project, title: "项目")
        var record = WorkspaceRecord(kind: .task, title: "行动")
        record.dateOnly = false; record.dueDate = now.addingTimeInterval(60); record.projectID = project.id
        var state = WorkspaceState(records: [project, record])
        XCTAssertNotNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
        project.archivedAt = now; state.records = [project, record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
        record.projectID = nil; record.status = "DONE"; state.records = [record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
        record.status = "OPEN"; record.kind = .knowledge; state.records = [record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now))
    }
    func testAllMergedItemKindsCanTrackTheirDeadline() {
        let now = Date()
        for kind in [ItemKind.task, .reminder, .milestone] {
            var item = WorkspaceRecord(kind: kind, title: "事项")
            item.dateOnly = false; item.dueDate = now.addingTimeInterval(300)
            XCTAssertEqual(DeadlineTrackingPolicy.dueDate(for: item, in: WorkspaceState(records: [item]), now: now), item.dueDate)
        }
    }
    func testDateOnlyUsesRecordTimezoneAndRescheduleDoesNotExtendActivityLifetime() {
        let now = Date(timeIntervalSince1970: 1791964800)
        var record = WorkspaceRecord(kind: .deadline, title: "仅日期")
        record.timezone = "Asia/Shanghai"; record.dueDate = now
        var state = WorkspaceState(records: [record])
        XCTAssertEqual(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now), record.effectiveDueDate(now))
        record.dateOnly = false; record.dueDate = now.addingTimeInterval(3600); state.records = [record]
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: state, now: now, startedAt: now.addingTimeInterval(-8 * 3600)))
    }
}

extension DeadlineTrackingPolicyTests {
    func testCancelledArchivedDeletedAndPastDeadlineCannotStart() {
        let now = Date()
        var record = WorkspaceRecord(kind: .deadline, title: "资格")
        record.dateOnly = false; record.dueDate = now.addingTimeInterval(60)
        for status in ["DONE", "CANCELLED"] {
            record.status = status
            XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: WorkspaceState(records: [record]), now: now))
        }
        record.status = "OPEN"; record.archivedAt = now
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: WorkspaceState(records: [record]), now: now))
        record.archivedAt = nil; record.deletedAt = now
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: WorkspaceState(records: [record]), now: now))
        record.deletedAt = nil; record.dueDate = now.addingTimeInterval(-1)
        XCTAssertNil(DeadlineTrackingPolicy.dueDate(for: record, in: WorkspaceState(records: [record]), now: now))
    }
}

extension WorkspaceSyncMergeTests {
    func testReviewResolutionOnlySelectsConflictsAndKeepsNonconflictingEdits() throws {
        let a = WorkspaceRecord(kind: .task, title: "冲突原始")
        let b = WorkspaceRecord(kind: .task, title: "另一记录")
        let c = WorkspaceRecord(kind: .task, title: "服务器删除")
        let base = WorkspaceState(records: [a,b,c])
        var local = base, remote = base
        local.records[0].title = "本机冲突"
        remote.records[0].title = "服务器冲突"
        remote.records[1].title = "服务器独有改动"
        remote.records.removeAll { $0.id == c.id }
        local.records.append(WorkspaceRecord(kind: .task, title: "本机新增"))
        let keepLocal = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, resolution: .local)
        XCTAssertEqual(Set(keepLocal.records.map(\.title)), ["本机冲突","服务器独有改动","本机新增"])
        let keepRemote = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, resolution: .remote)
        XCTAssertEqual(Set(keepRemote.records.map(\.title)), ["服务器冲突","服务器独有改动","本机新增"])
    }
}

extension WorkspaceCoreTests {
    func testNewDeadlineReminderIsEnabledAndStopsAfterCompletion() {
        var record = WorkspaceRecord(kind: .deadline, title: "DDL")
        record.dateOnly = false; record.dueDate = date("2040-10-14T12:00:00+08:00")
        record.notificationLeadMinutes = 30
        XCTAssertTrue(record.notificationsEnabled)
        XCTAssertEqual(record.notificationDate, record.dueDate?.addingTimeInterval(-1800))
        record.status = "DONE"
        XCTAssertNil(record.notificationDate)
        record.status = "CANCELLED"
        XCTAssertNil(record.notificationDate)
    }
    func testNotificationActionsRejectStaleDisabledAndRescheduledAlerts() {
        var record = WorkspaceRecord(kind: .deadline, title: "DDL")
        record.dateOnly = false; record.dueDate = date("2040-10-14T12:00:00+08:00")
        record.notificationLeadMinutes = 30
        let scheduled = record.notificationDate!.timeIntervalSince1970 * 1000
        XCTAssertTrue(WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduled))
        XCTAssertTrue(WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduled + 500))
        record.dueDate = record.dueDate!.addingTimeInterval(3600)
        XCTAssertFalse(WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduled))
        record.dueDate = date("2040-10-14T12:00:00+08:00"); record.notificationsEnabled = false
        XCTAssertFalse(WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduled))
        record.notificationsEnabled = true; record.status = "DONE"
        XCTAssertFalse(WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: scheduled))
        XCTAssertFalse(WorkspaceNotificationPolicy.isCurrentAction(for: record, scheduledAtMilliseconds: nil))
    }
}

extension WorkspaceCoreTests {
    func testItemRepeatsWithoutRequiringADeadline() throws {
        var item = WorkspaceRecord(kind: .task, title: "每天读书")
        item.scheduledAt = date("2026-10-16T19:00:00+08:00")
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily, until: date("2026-10-18")),
            in: &state, now: date("2026-10-16"))
        XCTAssertEqual(state.records.count, 3)
        XCTAssertTrue(state.records.allSatisfy { $0.status == "TODO" && $0.dueDate == nil })
        XCTAssertEqual(state.records.compactMap(\.occurrenceDate).sorted(), ["2026-10-16", "2026-10-17", "2026-10-18"])
        try WorkspaceLogic.validate(state)
    }
    func testAllItemKindsGenerateValidInitialStates() throws {
        for kind in [ItemKind.task, .milestone, .reminder] {
            var item = WorkspaceRecord(kind: kind, title: "重复事项")
            item.remindAt = date("2026-10-16T09:00:00+08:00")
            var state = WorkspaceState(records: [item])
            try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily, until: date("2026-10-17")),
                in: &state, now: date("2026-10-16"))
            XCTAssertEqual(state.records.count, 2)
            XCTAssertTrue(state.records.allSatisfy { $0.status == kind.states.first })
            try WorkspaceLogic.validate(state)
        }
    }
    func testRepeatingItemShiftsAllThreeTimesAcrossDST() throws {
        var item = WorkspaceRecord(kind: .task, title: "上午实验")
        item.timezone = "America/New_York"; item.dateOnly = false
        item.scheduledAt = date("2026-03-07T09:00:00-05:00")
        item.dueDate = date("2026-03-08T17:00:00-04:00")
        item.remindAt = date("2026-03-06T20:00:00-05:00")
        item.notificationsEnabled = true; item.notificationLeadMinutes = 30
        item.snoozedUntil = date("2026-03-07T10:00:00-05:00")
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily, until: date("2026-03-09T12:00:00Z")),
            in: &state, now: date("2026-03-07T00:00:00-05:00"))
        let next = try XCTUnwrap(state.records.first { $0.occurrenceDate == "2026-03-08" })
        XCTAssertEqual(next.scheduledAt, date("2026-03-08T09:00:00-04:00"))
        XCTAssertEqual(next.dueDate, date("2026-03-09T17:00:00-04:00"))
        XCTAssertEqual(next.remindAt, date("2026-03-07T20:00:00-05:00"))
        XCTAssertEqual(next.notificationDate, next.remindAt)
        XCTAssertNil(next.snoozedUntil)
        try WorkspaceLogic.validate(state)
    }
    func testCustomReminderIsExactAndRelativeReminderHasVisiblePrecedence() {
        var item = WorkspaceRecord(kind: .task, title: "分清三个时间")
        item.notificationsEnabled = true; item.dateOnly = false; item.notificationLeadMinutes = 15
        item.scheduledAt = date("2026-10-16T09:00:00+08:00")
        XCTAssertEqual(item.notificationDate, date("2026-10-16T08:45:00+08:00"))
        item.dueDate = date("2026-10-16T18:00:00+08:00")
        XCTAssertEqual(item.notificationDate, date("2026-10-16T17:45:00+08:00"))
        item.remindAt = date("2026-10-16T10:00:00+08:00")
        XCTAssertEqual(item.notificationDate, item.remindAt)
        item.status = "DONE"
        XCTAssertNil(item.notificationDate)
    }
    func testOddAndEvenWeeksContinueAcrossNewYearFromAcademicReference() {
        let start = date("2026-12-28")
        let odd = RecurrenceRule(frequency: .oddWeeks, weekdays: [1], weekOneStart: date("2026-12-21"))
        let even = RecurrenceRule(frequency: .evenWeeks, weekdays: [1], weekOneStart: date("2026-12-21"))
        func keys(_ rule: RecurrenceRule) -> [String] {
            RecurrenceEngine.dates(anchor: start, rule: rule, from: start, through: date("2027-01-18"), timezone: "Asia/Shanghai")
                .map { WorkspaceDates.dayKey($0, timezone: "Asia/Shanghai") }
        }
        XCTAssertEqual(keys(odd), ["2027-01-04", "2027-01-18"])
        XCTAssertEqual(keys(even), ["2026-12-28", "2027-01-11"])
    }
    func testChinaWorkdaysSkipSpringFestivalAndIncludeMakeupSaturdays() {
        let days = RecurrenceEngine.dates(anchor: date("2026-02-13"), rule: RecurrenceRule(frequency: .workdays),
            from: date("2026-02-13"), through: date("2026-03-02"), timezone: "Asia/Shanghai")
        XCTAssertEqual(days.map { WorkspaceDates.dayKey($0, timezone: "Asia/Shanghai") },
            ["2026-02-13", "2026-02-14", "2026-02-24", "2026-02-25", "2026-02-26", "2026-02-27", "2026-02-28", "2026-03-02"])
    }
    func testChinaCalendarCoversOfficialMakeupDaysAndRejectsUnknownYears() {
        let calendar = WorkspaceDates.calendar()
        for key in ["2026-01-04", "2026-02-14", "2026-02-28", "2026-05-09", "2026-09-20", "2026-10-10", "2025-09-28"] {
            XCTAssertEqual(ChinaWorkCalendar.isWorkday(date(key), calendar: calendar), true, key)
        }
        for key in ["2026-01-01", "2026-01-02", "2026-02-16", "2026-04-06", "2026-05-04", "2026-06-19", "2026-09-25", "2026-10-07", "2025-10-08"] {
            XCTAssertEqual(ChinaWorkCalendar.isWorkday(date(key), calendar: calendar), false, key)
        }
        XCTAssertNil(ChinaWorkCalendar.isWorkday(date("2027-01-04"), calendar: calendar))
        let ordinary = RecurrenceEngine.dates(anchor: date("2026-10-01"), rule: RecurrenceRule(frequency: .weekdays),
            from: date("2026-10-01"), through: date("2026-10-04"), timezone: "Asia/Shanghai")
        XCTAssertEqual(ordinary.count, 2)
    }
    func testWorkdayGenerationKeepsUnverifiedFutureYearsResumable() throws {
        var item = WorkspaceRecord(kind: .task, title: "工作日签到")
        item.scheduledAt = date("2026-12-30T09:00:00+08:00")
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .workdays), in: &state, now: date("2026-12-30"))
        XCTAssertEqual(state.records.compactMap(\.occurrenceDate).sorted(), ["2026-12-30", "2026-12-31"])
        XCTAssertEqual(state.series[0].generatedThrough, date("2026-12-31"))
        let before = state
        RecurrenceEngine.materialize(&state, now: date("2027-01-04"))
        XCTAssertEqual(state, before)
    }
    func testHolidayFirstItemIsPreservedAsAnException() throws {
        var item = WorkspaceRecord(kind: .task, title: "保留手动首次日期")
        item.scheduledAt = date("2026-10-01T09:00:00+08:00")
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .workdays, until: date("2026-10-11")),
            in: &state, now: date("2026-10-01"))
        XCTAssertEqual(state.records.compactMap(\.occurrenceDate).sorted(), ["2026-10-01", "2026-10-08", "2026-10-09", "2026-10-10"])
        XCTAssertTrue(try XCTUnwrap(state.records.first { $0.id == item.id }).isException)
    }
    func testStopRepetitionPreservesPastAndCompletedItemsAndDisablesFutureReminders() throws {
        var item = WorkspaceRecord(kind: .task, title: "停止重复")
        item.scheduledAt = date("2026-10-16T09:00:00+08:00"); item.notificationsEnabled = true
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily, until: date("2026-10-18")),
            in: &state, now: date("2026-10-15"))
        let completed = try XCTUnwrap(state.records.firstIndex { $0.occurrenceDate == "2026-10-18" })
        state.records[completed].status = "DONE"
        let seriesID = state.series[0].id
        RecurrenceEngine.stop(seriesID, in: &state, now: date("2026-10-16T10:00:00+08:00"))
        XCTAssertEqual(state.records.first { $0.id == item.id }?.status, "TODO")
        let cancelled = try XCTUnwrap(state.records.first { $0.occurrenceDate == "2026-10-17" })
        XCTAssertEqual(cancelled.status, "CANCELLED"); XCTAssertNil(cancelled.notificationDate)
        XCTAssertEqual(state.records[completed].status, "DONE")
        let count = state.records.count
        RecurrenceEngine.materialize(&state, now: date("2026-10-20"))
        XCTAssertEqual(state.records.count, count)
        try WorkspaceLogic.validate(state)
    }
    func testLegacyReminderStopArchivesFutureInstancesWithSupportedStatus() throws {
        var item = WorkspaceRecord(kind: .reminder, title: "旧提醒")
        item.remindAt = date("2026-10-16T09:00:00+08:00")
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily, until: date("2026-10-17")),
            in: &state, now: date("2026-10-15"))
        RecurrenceEngine.stop(state.series[0].id, in: &state, now: date("2026-10-16T10:00:00+08:00"))
        let future = try XCTUnwrap(state.records.first { $0.occurrenceDate == "2026-10-17" })
        XCTAssertNotNil(future.archivedAt); XCTAssertNil(future.notificationDate)
        try WorkspaceLogic.validate(state)
    }
    func testOfflineGenerationUsesStableIdentifiersAndMergesCacheProgress() throws {
        var item = WorkspaceRecord(kind: .task, title: "两设备重复")
        item.scheduledAt = date("2026-10-16T09:00:00+08:00")
        var base = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily), in: &base, now: date("2026-10-16"))
        var first = base, second = base
        RecurrenceEngine.materialize(&first, now: date("2026-10-17"))
        RecurrenceEngine.materialize(&second, now: date("2026-10-18"))
        let sharedDay = try XCTUnwrap(first.records.first { $0.occurrenceDate == "2026-11-16" })
        XCTAssertEqual(sharedDay, second.records.first { $0.occurrenceDate == "2026-11-16" })
        let merged = try WorkspaceSyncMerge.reconcile(base: base, local: first, remote: second, now: date("2026-10-18"))
        XCTAssertEqual(merged.records.filter { $0.occurrenceDate == "2026-11-16" }.count, 1)
        XCTAssertEqual(merged.series[0].generatedThrough, second.series[0].generatedThrough)
    }
    func testInvalidRecurrenceDoesNotPartiallyMutateState() {
        var item = WorkspaceRecord(kind: .task, title: "未覆盖年份")
        item.scheduledAt = date("2027-01-04T09:00:00+08:00")
        var state = WorkspaceState(records: [item]); let before = state
        XCTAssertThrowsError(try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .workdays), in: &state))
        XCTAssertEqual(state, before)
        let futureReference = RecurrenceRule(frequency: .oddWeeks, weekOneStart: date("2027-02-01"))
        XCTAssertNotNil(RecurrenceEngine.validationError(record: item, rule: futureReference))
    }
    func testRemoteStopClosesFutureInstancesGeneratedWhileOtherDeviceWasOffline() throws {
        var item = WorkspaceRecord(kind: .task, title: "离线期间停止重复")
        item.scheduledAt = date("2026-10-16T09:00:00+08:00"); item.notificationsEnabled = true
        var base = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily), in: &base, now: date("2026-10-16"))
        var local = base, remote = base
        RecurrenceEngine.materialize(&local, now: date("2026-10-17"))
        RecurrenceEngine.stop(remote.series[0].id, in: &remote, now: date("2026-10-17"))
        let merged = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, now: date("2026-10-17"))
        let extra = try XCTUnwrap(merged.records.first { $0.occurrenceDate == "2026-11-16" })
        XCTAssertEqual(extra.status, "CANCELLED"); XCTAssertNil(extra.notificationDate)
        XCTAssertEqual(merged.records.first { $0.id == item.id }?.status, "TODO")
    }
    private func legacyDailyCache(kind: ItemKind = .task) throws -> WorkspaceState {
        var item = WorkspaceRecord(kind: kind, title: "记得记得")
        item.scheduledAt = date("2026-10-16T09:00:00+08:00")
        item.createdAt = date("2026-10-16T08:00:00+08:00"); item.updatedAt = item.createdAt
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily), in: &state, now: date("2026-10-16"))
        state.records = RecurrenceEngine.projectedRecords(in: state, from: date("2026-10-16"), through: date("2029-10-16"))
        state.series[0].generatedThrough = date("2029-10-16")
        return state
    }
    func testLegacyThreeYearCacheCollapsesWithoutDeletingTheOriginalOrRule() throws {
        var state = try legacyDailyCache()
        XCTAssertGreaterThan(state.records.count, 1000)
        let original = try XCTUnwrap(state.records.first { $0.id == state.series[0].template.id })
        let seriesID = state.series[0].id
        let removed = RecurrenceEngine.normalizeGeneratedCache(&state, now: date("2026-10-16"))
        XCTAssertGreaterThan(removed.count, 1000)
        XCTAssertEqual(state.records.count, 31)
        XCTAssertEqual(state.records.first { $0.id == original.id }, original)
        XCTAssertEqual(state.series[0].id, seriesID)
        XCTAssertEqual(state.series[0].generatedThrough, date("2026-11-15"))
        XCTAssertTrue(state.trash.isEmpty)
        let normalized = state
        RecurrenceEngine.materialize(&state, now: date("2026-10-16"))
        XCTAssertEqual(state, normalized)
        try WorkspaceLogic.validate(state)
    }
    func testCacheCleanupPreservesEveryUserEditExceptionAndReference() throws {
        var state = try legacyDailyCache(kind: .milestone)
        let futureIndices = state.records.indices.filter { state.records[$0].occurrenceDate! > "2026-11-15" }
        func change(_ offset: Int, _ update: (inout WorkspaceRecord) -> Void) {
            update(&state.records[futureIndices[offset]])
        }
        change(0) { $0.version += 1 }
        change(1) { $0.title = "单独修改，甚至忘记增加版本" }
        change(2) { $0.isException = true }
        change(3) { $0.status = "DONE"; $0.completedAt = date("2026-10-16") }
        change(4) { $0.archivedAt = date("2026-10-16") }
        change(5) { $0.deletedAt = date("2026-10-16") }
        change(6) { $0.pinned = true }
        change(7) { $0.calendarEventID = "external-calendar-event" }
        change(8) { $0.snoozedUntil = date("2026-12-01T10:00:00+08:00") }
        let activityOwner = state.records[futureIndices[9]]
        state.activities.append(ActivityEntry(entityID: activityOwner.id, title: "操作记录", message: "保留已使用的实例"))
        let revisionOwner = state.records[futureIndices[10]]
        state.revisions.append(KnowledgeRevision(record: revisionOwner, action: "历史引用"))
        let parentOwner = state.records[futureIndices[11]]
        var child = WorkspaceRecord(kind: .task, title: "关联事项"); child.milestoneID = parentOwner.id
        state.records.append(child)
        let protectedOwner = state.records[futureIndices[12]]
        let preserved = futureIndices.prefix(13).map { state.records[$0] }
        RecurrenceEngine.normalizeGeneratedCache(&state, now: date("2026-10-16"), protecting: [protectedOwner.id])
        for record in preserved { XCTAssertEqual(state.records.first { $0.id == record.id }, record) }
        XCTAssertEqual(state.records.count, 31 + 13 + 1)
        XCTAssertTrue(state.records.contains { $0.id == child.id })
        try WorkspaceLogic.validate(state)
    }
    func testRollingWindowRefillsDespiteLegacyProgressAndHonorsDeletedDates() throws {
        var state = try legacyDailyCache()
        let deletedIndex = try XCTUnwrap(state.records.firstIndex { $0.occurrenceDate == "2026-11-01" })
        state.records[deletedIndex].deletedAt = date("2026-10-16")
        state.records[deletedIndex].version += 1
        let deleted = state.records[deletedIndex]
        state.records.removeAll { $0.occurrenceDate == "2026-11-10" }
        RecurrenceEngine.materialize(&state, now: date("2026-10-16"))
        XCTAssertEqual(state.records.count, 31)
        XCTAssertEqual(state.records.filter { $0.occurrenceDate == "2026-11-10" }.count, 1)
        XCTAssertEqual(state.records.first { $0.id == deleted.id }, deleted)
        XCTAssertEqual(state.records.filter { $0.occurrenceDate == "2026-11-01" }.count, 1)
        RecurrenceEngine.materialize(&state, now: date("2026-10-17"))
        // Past reminders are history, even when they were never completed.
        XCTAssertEqual(state.records.count, 32)
        XCTAssertNotNil(state.records.first { $0.occurrenceDate == "2026-11-16" })
        let second = state
        RecurrenceEngine.materialize(&state, now: date("2026-10-17"))
        XCTAssertEqual(state, second)
        try WorkspaceLogic.validate(state)
    }
    func testLegacyCacheEvictionMergesWithRemoteEditWithoutResurrectingCopies() throws {
        let base = try legacyDailyCache()
        var local = base, remote = base
        RecurrenceEngine.materialize(&local, now: date("2026-10-16"))
        let remoteIndex = try XCTUnwrap(remote.records.firstIndex { $0.occurrenceDate == "2027-01-01" })
        remote.records[remoteIndex].title = "远端单独修改的一次"
        remote.records[remoteIndex].version += 1
        remote.records[remoteIndex].updatedAt = date("2026-10-16T10:00:00+08:00")
        let edited = remote.records[remoteIndex]
        let merged = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, now: date("2026-10-16"))
        XCTAssertEqual(merged.records.count, 32)
        XCTAssertEqual(merged.records.first { $0.id == edited.id }, edited)
        let reverse = try WorkspaceSyncMerge.reconcile(base: base, local: remote, remote: local, now: date("2026-10-16"))
        XCTAssertEqual(merged, reverse)
        var refreshed = merged
        RecurrenceEngine.materialize(&refreshed, now: date("2026-10-16"))
        XCTAssertEqual(Set(refreshed.records.map(\.id)), Set(merged.records.map(\.id)))
    }
    func testCalendarProjectionIsTemporaryAndUsesTheSameStableIdentifiers() throws {
        var state = WorkspaceState()
        var item = WorkspaceRecord(kind: .task, title: "远期日历")
        item.scheduledAt = date("2026-10-16T09:00:00+08:00")
        state.records = [item]
        try RecurrenceEngine.start(item.id, rule: RecurrenceRule(frequency: .daily), in: &state, now: date("2026-10-16"))
        let original = state
        let projected = RecurrenceEngine.projectedRecords(in: state, from: date("2028-02-01"), through: date("2028-02-29"))
        XCTAssertEqual(projected.count, state.records.count + 29)
        XCTAssertEqual(state, original)
        let virtual = try XCTUnwrap(projected.first { $0.occurrenceDate == "2028-02-29" })
        RecurrenceEngine.materialize(&state, now: date("2028-02-29"))
        XCTAssertEqual(state.records.first { $0.id == virtual.id }, virtual)
        XCTAssertEqual(Set(state.records.map(\.id)).count, state.records.count)
    }
    func testFarFutureAndSparseSeriesKeepOneUpcomingInstance() throws {
        var future = WorkspaceRecord(kind: .task, title: "明年的第一天")
        future.scheduledAt = date("2027-01-01T09:00:00+08:00")
        var state = WorkspaceState(records: [future])
        try RecurrenceEngine.start(future.id, rule: RecurrenceRule(frequency: .daily), in: &state, now: date("2026-10-16"))
        XCTAssertEqual(state.records.count, 1)
        XCTAssertEqual(state.records[0].id, future.id)
        var sparse = WorkspaceRecord(kind: .deadline, title: "每三年检查")
        sparse.dueDate = date("2024-01-31")
        state = WorkspaceState(records: [sparse])
        try RecurrenceEngine.start(sparse.id, rule: RecurrenceRule(frequency: .monthly, interval: 36), in: &state, now: date("2026-10-16"))
        XCTAssertEqual(state.records.compactMap(\.occurrenceDate).sorted(), ["2024-01-31", "2027-01-31"])
        let before = state
        RecurrenceEngine.materialize(&state, now: date("2026-10-16"))
        XCTAssertEqual(state, before)
    }
    func testOldRulesDecodeAndNewRulesRoundTrip() throws {
        let old = try WorkspaceCoding.decoder().decode(RecurrenceRule.self, from: Data(#"{"frequency":"WEEKLY","interval":2,"weekdays":[1,3]}"#.utf8))
        XCTAssertEqual(old.interval, 2); XCTAssertNil(old.weekOneStart)
        let rule = RecurrenceRule(frequency: .evenWeeks, weekdays: [2, 4], until: date("2027-01-20"), weekOneStart: date("2026-09-07"))
        let restored = try WorkspaceCoding.decoder().decode(RecurrenceRule.self, from: WorkspaceCoding.encoder().encode(rule))
        XCTAssertEqual(restored, rule)
    }
}

final class WorkspaceDemoTests: XCTestCase {
    private let now = WorkspaceDates.parse("2026-10-16T11:30:00+08:00")!

    func testDemoIsDeterministicAndContainsAWholeUsableWorkspace() throws {
        let state = WorkspaceDemo.make(now: now)
        try WorkspaceLogic.validate(state)
        XCTAssertEqual(state, WorkspaceDemo.make(now: now))
        XCTAssertGreaterThan(state.records.count, 100)
        XCTAssertEqual(Set(state.records.map(\.kind)), Set(ItemKind.allCases))
        XCTAssertEqual(state.series.count, 8)
        XCTAssertFalse(state.activities.isEmpty)
        XCTAssertEqual(state.revisions.count, 8)
        XCTAssertEqual(state.assets.count, 1)
        XCTAssertTrue(state.assets[0].data.starts(with: Data("%PDF-".utf8)))
        XCTAssertEqual(state.trash.count, 1)
        let restored = try WorkspaceCoding.decoder().decode(WorkspaceState.self,
            from: WorkspaceCoding.encoder().encode(state))
        XCTAssertEqual(restored, state)
    }

    func testDemoIncludesTodaysWorkOverdueCompletedAndGroupedDeadlines() throws {
        let state = WorkspaceDemo.make(now: now)
        let calendar = WorkspaceDates.calendar()
        let todayItems = state.records.filter { record in
            record.scheduledAt.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        XCTAssertGreaterThanOrEqual(todayItems.count, 10)
        XCTAssertTrue(state.records.contains { $0.kind == .deadline && !$0.isFinished && $0.dueDate! < now })
        XCTAssertTrue(state.records.contains { $0.kind == .deadline && $0.dateOnly })
        XCTAssertTrue(state.records.contains { $0.completedAt != nil })
        XCTAssertTrue(state.records.contains { $0.cancelledAt != nil })
        XCTAssertTrue(state.records.contains { $0.snoozedUntil != nil })
        XCTAssertTrue(state.records.contains { $0.archivedAt != nil })
        let groups = WorkspaceLogic.deadlineCountdownGroups(state.records, now: now)
        XCTAssertTrue(groups.contains { group in
            group.records.count == 3 && calendar.isDate(group.countdownDate(at: now), inSameDayAs: now)
        })
        let note = try XCTUnwrap(state.records.first { $0.kind == .knowledge && $0.pinned })
        XCTAssertTrue(state.revisions.contains { $0.record.id == note.id && $0.record.version < note.version })
        for record in state.records where record.projectID != nil {
            XCTAssertTrue(state.records.contains { $0.id == record.projectID && $0.kind == .project })
        }
    }

    func testDemoExercisesEveryRecurrenceFrequencyAndRemainsBounded() throws {
        let state = WorkspaceDemo.make(now: now)
        XCTAssertEqual(Set(state.series.map { $0.rule.frequency }), Set(RecurrenceRule.Frequency.allCases))
        XCTAssertTrue(state.series.contains { $0.rule.frequency == .weekly && $0.rule.interval == 2 })
        XCTAssertLessThan(state.records.count, 250)
        let before = state.records.count
        var regenerated = state
        RecurrenceEngine.materialize(&regenerated, now: now)
        XCTAssertEqual(regenerated.records.count, before)
        try WorkspaceLogic.validate(regenerated)
    }

    func testDemoMovesWithCurrentDayWithoutInventingFutureWorkdayCalendars() throws {
        let future = WorkspaceDates.parse("2028-02-29T11:30:00+08:00")!
        let state = WorkspaceDemo.make(now: future)
        try WorkspaceLogic.validate(state)
        let classRecord = try XCTUnwrap(state.records.first { $0.title == "高等数学课 · 例题与课堂笔记" })
        XCTAssertEqual(WorkspaceDates.dayKey(try XCTUnwrap(classRecord.scheduledAt), timezone: "Asia/Shanghai"), "2028-02-29")
        let workday = try XCTUnwrap(state.series.first { $0.rule.frequency == .workdays })
        XCTAssertNotNil(workday.stoppedAt)
        XCTAssertEqual(WorkspaceDates.calendar().component(.year, from: try XCTUnwrap(workday.template.scheduledAt)), 2026)
    }
}


extension DeadlineTrackingPolicyTests {
    func testAutomaticTrackingSelectsNearestThreeAndReplacesFinishedItem() {
        let now = Date(timeIntervalSince1970: 1791964800)
        func item(_ hours: Double, pinned: Bool = false) -> WorkspaceRecord {
            var value = WorkspaceRecord(kind: .deadline, title: "截止 \(hours)")
            value.dateOnly = false
            value.dueDate = now.addingTimeInterval(hours * 3600)
            value.pinned = pinned
            return value
        }
        var first = item(1)
        let second = item(2), third = item(3), fourth = item(4, pinned: true)
        var finished = item(0.5); finished.status = "DONE"
        var archived = item(0.25); archived.archivedAt = now
        let tooFar = item(9), overdue = item(-1)
        var state = WorkspaceState(records: [fourth, finished, tooFar, third, archived, overdue, second, first])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id), [first.id, second.id, third.id])
        first.status = "DONE"
        state.records = [fourth, second, first, third]
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id), [second.id, third.id, fourth.id])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now, startedAt: now.addingTimeInterval(-5 * 3600)).map(\.id), [second.id, third.id])
        XCTAssertTrue(DeadlineTrackingPolicy.nearestRecords(in: WorkspaceState(), now: now).isEmpty)
    }
}

final class RecurrenceDeletionTests: XCTestCase {
    private func date(_ value: String) -> Date { WorkspaceDates.parse(value)! }
    private func dailyState(until: String? = "2026-10-23") throws -> WorkspaceState {
        var item = WorkspaceRecord(kind: .task, title: "每天记得")
        item.scheduledAt = date("2026-10-16T09:00:00+08:00")
        item.createdAt = date("2026-10-16T08:00:00+08:00"); item.updatedAt = item.createdAt
        var state = WorkspaceState(records: [item])
        try RecurrenceEngine.start(item.id,
            rule: RecurrenceRule(frequency: .daily, until: until.map(date)),
            in: &state, now: date("2026-10-16"))
        return state
    }
    func testDeletingOneOccurrencePreservesTheRuleAndDoesNotRegenerateIt() throws {
        var state = try dailyState()
        let originalRule = state.series[0]
        let item = try XCTUnwrap(state.records.first { $0.occurrenceDate == "2026-10-19" })
        let preview = try WorkspaceLogic.preview([item.id], scope: .occurrence, in: state, now: date("2026-10-16"))
        try WorkspaceLogic.delete(preview, from: &state, now: date("2026-10-16T00:01:00+08:00"))
        XCTAssertEqual(state.series[0], originalRule)
        XCTAssertEqual(state.trash[0].itemIDs, [item.id]); XCTAssertNil(state.trash[0].recurrence)
        RecurrenceEngine.materialize(&state, now: date("2026-10-17"))
        XCTAssertEqual(state.records.filter { $0.occurrenceDate == "2026-10-19" }.count, 1)
        XCTAssertNotNil(state.records.first { $0.id == item.id }?.deletedAt)
        XCTAssertEqual(state.records.filter { $0.deletedAt == nil }.count, 7)
        try WorkspaceLogic.validate(state)
    }
    func testDeletingFollowingUsesOriginalDayWhenTheSelectedOccurrenceWasMoved() throws {
        var state = try dailyState()
        let index = try XCTUnwrap(state.records.firstIndex { $0.occurrenceDate == "2026-10-19" })
        state.records[index].scheduledAt = date("2026-10-15T12:00:00+08:00")
        state.records[index].isException = true; state.records[index].version += 1
        let selectedID = state.records[index].id
        let preview = try WorkspaceLogic.preview([selectedID], scope: .following, in: state, now: date("2026-10-16"))
        XCTAssertEqual(Set(preview.records.compactMap(\.occurrenceDate)),
            ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23"])
        try WorkspaceLogic.delete(preview, from: &state, now: date("2026-10-16T00:01:00+08:00"))
        XCTAssertEqual(state.series[0].rule.until, date("2026-10-18"))
        XCTAssertNil(state.series[0].deletedAt)
        XCTAssertEqual(state.trash[0].recurrence?.first?.fromDay, "2026-10-19")
        RecurrenceEngine.materialize(&state, now: date("2026-10-20"))
        XCTAssertEqual(Set(state.records.filter { $0.deletedAt == nil }.compactMap(\.occurrenceDate)),
            ["2026-10-16", "2026-10-17", "2026-10-18"])
        let projected = RecurrenceEngine.projectedRecords(in: state, from: date("2026-11-01"), through: date("2026-11-30"))
        XCTAssertEqual(projected.count, state.records.count)
        try WorkspaceLogic.validate(state)
    }
    func testDeletingSeveralSeriesAndRestoringTheBatchRestoresRulesAndAllOccurrences() throws {
        var state = try dailyState()
        var second = WorkspaceRecord(kind: .deadline, title: "每周截止")
        second.dueDate = date("2026-10-16")
        second.createdAt = date("2026-10-16T08:00:00+08:00"); second.updatedAt = second.createdAt
        state.records.append(second)
        try RecurrenceEngine.start(second.id,
            rule: RecurrenceRule(frequency: .weekly, until: date("2026-11-06")),
            in: &state, now: date("2026-10-16"))
        let completed = try XCTUnwrap(state.records.firstIndex { $0.occurrenceDate == "2026-10-17" })
        state.records[completed].status = "DONE"; state.records[completed].version += 1
        let rules = state.series
        let records = state.records
        let first = try XCTUnwrap(state.records.first { $0.recurrenceSeriesID == rules[0].id && $0.occurrenceDate == "2026-10-19" })
        let preview = try WorkspaceLogic.preview([first.id, second.id], scope: .series,
            in: state, now: date("2026-10-16"))
        try WorkspaceLogic.delete(preview, from: &state, now: date("2026-10-16T00:01:00+08:00"))
        XCTAssertTrue(state.series.allSatisfy { $0.deletedAt != nil && $0.stoppedAt != nil })
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(state.trash.count, 1); XCTAssertEqual(state.trash[0].recurrence?.count, 2)
        RecurrenceEngine.materialize(&state, now: date("2026-10-18"))
        XCTAssertEqual(state.records.count, records.count)
        let batch = state.trash[0]
        try WorkspaceLogic.restore(batch, in: &state, now: date("2026-10-16T00:02:00+08:00"))
        XCTAssertTrue(state.trash.isEmpty)
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt == nil && $0.trashBatchID == nil })
        for rule in rules {
            let restored = try XCTUnwrap(state.series.first { $0.id == rule.id })
            XCTAssertEqual(restored.rule, rule.rule); XCTAssertEqual(restored.template, rule.template)
            XCTAssertNil(restored.stoppedAt); XCTAssertNil(restored.deletedAt)
        }
        for original in records {
            let restored = try XCTUnwrap(state.records.first { $0.id == original.id })
            XCTAssertEqual(restored.title, original.title); XCTAssertEqual(restored.status, original.status)
            XCTAssertEqual(restored.scheduledAt, original.scheduledAt); XCTAssertEqual(restored.dueDate, original.dueDate)
        }
        RecurrenceEngine.materialize(&state, now: date("2026-10-18"))
        XCTAssertEqual(Set(state.records.map(\.id)), Set(records.map(\.id)))
        try WorkspaceLogic.validate(state)
    }
    func testBatchDeletionIncludesProjectMembersAndRejectsStaleVersionsAtomically() throws {
        let project = WorkspaceRecord(kind: .project, title: "一起删除的项目组")
        let keptProject = WorkspaceRecord(kind: .project, title: "保留的项目组")
        var member = WorkspaceRecord(kind: .task, title: "项目中的事项"); member.projectID = project.id
        var standalone = WorkspaceRecord(kind: .task, title: "另一个组里选中的事项"); standalone.projectID = keptProject.id
        let kept = WorkspaceRecord(kind: .task, title: "保留事项")
        var state = WorkspaceState(records: [project, keptProject, member, standalone, kept])
        let selection: Set<UUID> = [project.id, standalone.id]
        let oldPreview = try WorkspaceLogic.preview(selection, in: state, now: date("2026-10-16"))
        XCTAssertEqual(Set(oldPreview.records.map(\.id)), [project.id, member.id, standalone.id])
        state.records[2].title = "预览后又修改"; state.records[2].version += 1
        let before = state
        XCTAssertThrowsError(try WorkspaceLogic.delete(oldPreview, from: &state, now: date("2026-10-16T00:01:00+08:00")))
        XCTAssertEqual(state, before)
        let preview = try WorkspaceLogic.preview(selection, in: state, now: date("2026-10-16T00:02:00+08:00"))
        try WorkspaceLogic.delete(preview, from: &state, now: date("2026-10-16T00:03:00+08:00"))
        XCTAssertEqual(state.trash.count, 1)
        XCTAssertEqual(Set(state.trash[0].itemIDs), [project.id, member.id, standalone.id])
        XCTAssertEqual(Set(state.records.filter { $0.deletedAt == nil }.map(\.id)), [keptProject.id, kept.id])
        try WorkspaceLogic.restore(state.trash[0], in: &state, now: date("2026-10-16T00:04:00+08:00"))
        XCTAssertTrue(state.records.allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(state.records[2].title, "预览后又修改")
        try WorkspaceLogic.validate(state)
    }
    func testBatchPreviewRejectsAddedProjectMemberAndChangedSeriesWithoutPartialDeletion() throws {
        let project = WorkspaceRecord(kind: .project, title: "项目组")
        var state = try dailyState()
        state.records.append(project)
        let ids: Set<UUID> = [project.id, state.records[0].id]
        let preview = try WorkspaceLogic.preview(ids, scope: .series, in: state, now: date("2026-10-16"))
        var child = WorkspaceRecord(kind: .task, title: "预览后新增的事项"); child.projectID = project.id
        state.records.append(child)
        let withChild = state
        XCTAssertThrowsError(try WorkspaceLogic.delete(preview, from: &state, now: date("2026-10-16T00:01:00+08:00")))
        XCTAssertEqual(state, withChild)
        let fresh = try WorkspaceLogic.preview(ids, scope: .series, in: state, now: date("2026-10-16T00:02:00+08:00"))
        state.series[0].rule.interval = 2
        let changedRule = state
        XCTAssertThrowsError(try WorkspaceLogic.delete(fresh, from: &state, now: date("2026-10-16T00:03:00+08:00")))
        XCTAssertEqual(state, changedRule)
    }
    func testDeletedSeriesStaysDeletedWhenOfflineDeviceSendsAdditionalOccurrence() throws {
        let base = try dailyState(until: nil)
        var local = base, remote = base
        let preview = try WorkspaceLogic.preview([base.records[0].id], scope: .series,
            in: local, now: date("2026-10-16"))
        try WorkspaceLogic.delete(preview, from: &local, now: date("2026-10-16T00:01:00+08:00"))
        RecurrenceEngine.materialize(&remote, now: date("2026-10-17"))
        let extra = try XCTUnwrap(remote.records.first { $0.occurrenceDate == "2026-11-16" })
        var merged = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, now: date("2026-10-17"))
        XCTAssertNotNil(merged.series[0].deletedAt)
        XCTAssertTrue(merged.records.allSatisfy { $0.deletedAt != nil })
        XCTAssertNotNil(merged.records.first { $0.id == extra.id }?.deletedAt)
        let batch = try XCTUnwrap(merged.trash.first)
        XCTAssertTrue(batch.itemIDs.contains(extra.id))
        let count = merged.records.count
        RecurrenceEngine.materialize(&merged, now: date("2026-10-18"))
        XCTAssertEqual(merged.records.count, count)
        try WorkspaceLogic.restore(batch, in: &merged, now: date("2026-10-17T11:00:00+08:00"))
        XCTAssertNil(merged.series[0].deletedAt)
        XCTAssertTrue(merged.records.allSatisfy { $0.deletedAt == nil })
        try WorkspaceLogic.validate(merged)
    }
    func testFollowingDeletionRemainsEffectiveAfterOfflineExtraOccurrenceArrives() throws {
        let base = try dailyState(until: nil)
        var local = base, remote = base
        let selected = try XCTUnwrap(local.records.first { $0.occurrenceDate == "2026-10-20" })
        let preview = try WorkspaceLogic.preview([selected.id], scope: .following,
            in: local, now: date("2026-10-16"))
        try WorkspaceLogic.delete(preview, from: &local, now: date("2026-10-16T00:01:00+08:00"))
        RecurrenceEngine.materialize(&remote, now: date("2026-10-17"))
        let extra = try XCTUnwrap(remote.records.first { $0.occurrenceDate == "2026-11-16" })
        var merged = try WorkspaceSyncMerge.reconcile(base: base, local: local, remote: remote, now: date("2026-10-17"))
        XCTAssertEqual(merged.series[0].rule.until, date("2026-10-19"))
        XCTAssertNil(merged.series[0].deletedAt)
        XCTAssertNotNil(merged.records.first { $0.id == extra.id }?.deletedAt)
        XCTAssertFalse(merged.records.contains { $0.deletedAt == nil && ($0.occurrenceDate ?? "") >= "2026-10-20" })
        XCTAssertTrue(merged.trash[0].itemIDs.contains(extra.id))
        RecurrenceEngine.materialize(&merged, now: date("2026-10-18"))
        XCTAssertFalse(merged.records.contains { $0.deletedAt == nil && ($0.occurrenceDate ?? "") >= "2026-10-20" })
        try WorkspaceLogic.validate(merged)
    }
    func testRestoreRejectsChangedRecurrenceBeforeTouchingAnyBatchRecord() throws {
        var state = try dailyState()
        let preview = try WorkspaceLogic.preview([state.records[0].id], scope: .series,
            in: state, now: date("2026-10-16"))
        try WorkspaceLogic.delete(preview, from: &state, now: date("2026-10-16T00:01:00+08:00"))
        let batch = state.trash[0]
        state.series[0].rule.interval = 2
        let before = state
        XCTAssertThrowsError(try WorkspaceLogic.restore(batch, in: &state, now: date("2026-10-16T00:02:00+08:00")))
        XCTAssertEqual(state, before)
    }
}

extension WorkspaceCoreTests {
    func testTimedItemsAndAutomaticTrackingShareNestedParentVisibility() {
        let now = Date(timeIntervalSince1970: 1_792_382_400)
        var area = WorkspaceRecord(kind: .area, title: "学业")
        var project = WorkspaceRecord(kind: .project, title: "代码课程")
        project.projectID = area.id
        var scheduled = WorkspaceRecord(kind: .task, title: "完成互动练习")
        scheduled.projectID = project.id
        scheduled.scheduledAt = now.addingTimeInterval(600)
        scheduled.dueDate = now.addingTimeInterval(1200)
        scheduled.dateOnly = false
        var deadline = WorkspaceRecord(kind: .deadline, title: "提交作业")
        deadline.areaID = area.id
        deadline.dueDate = now.addingTimeInterval(1800)
        deadline.dateOnly = false
        var standalone = WorkspaceRecord(kind: .deadline, title: "独立安排")
        standalone.dueDate = now.addingTimeInterval(2400)
        standalone.dateOnly = false
        var orphan = WorkspaceRecord(kind: .deadline, title: "父组已不存在")
        orphan.projectID = UUID()
        orphan.dueDate = now.addingTimeInterval(900)
        orphan.dateOnly = false
        var state = WorkspaceState(records: [area, project, scheduled, deadline, standalone, orphan])
        let original = state
        func visibleTimedIDs() -> Set<UUID> {
            Set(WorkspaceRecordIndex(state.records).visibleRecords.filter {
                $0.kind.isItem || $0.kind == .deadline
            }.map(\.id))
        }
        XCTAssertEqual(visibleTimedIDs(), [scheduled.id, deadline.id, standalone.id])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id),
                       [scheduled.id, deadline.id, standalone.id])
        area.archivedAt = now
        state.records[0] = area
        XCTAssertEqual(visibleTimedIDs(), [standalone.id])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id), [standalone.id])
        area.archivedAt = nil
        area.deletedAt = now
        state.records[0] = area
        XCTAssertEqual(visibleTimedIDs(), [standalone.id])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id), [standalone.id])
        state.records.removeFirst()
        XCTAssertEqual(visibleTimedIDs(), [standalone.id])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id), [standalone.id])
        state = original
        XCTAssertEqual(visibleTimedIDs(), [scheduled.id, deadline.id, standalone.id])
        XCTAssertEqual(DeadlineTrackingPolicy.nearestRecords(in: state, now: now).map(\.id),
                       [scheduled.id, deadline.id, standalone.id])
    }
}
