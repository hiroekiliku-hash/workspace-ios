import Foundation
import Observation

enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case area = "AREA", project = "PROJECT", milestone = "MILESTONE"
    case task = "TASK", deadline = "DEADLINE", reminder = "REMINDER", knowledge = "KNOWLEDGE"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area, .project: WorkspaceLocalization.string("项目组")
        case .milestone, .task, .reminder: WorkspaceLocalization.string("事项")
        case .deadline: WorkspaceLocalization.string("截止事项")
        case .knowledge: WorkspaceLocalization.string("知识笔记")
        }
    }
    // Preserve wire values for existing archives and clients; expose one category in the UI.
    var isProjectGroup: Bool { self == .area || self == .project }
    var isItem: Bool { [.task, .reminder, .milestone].contains(self) }
    var creationKind: ItemKind { isProjectGroup ? .project : isItem ? .task : self }
    var symbol: String {
        switch self {
        case .area, .project: "folder"
        case .milestone, .task, .reminder: "checkmark.circle"
        case .deadline: "hourglass"
        case .knowledge: "book.closed"
        }
    }
    var states: [String] {
        switch self {
        case .project: ["PLANNED", "ACTIVE", "WAITING", "PAUSED", "COMPLETED"]
        case .task: ["TODO", "IN_PROGRESS", "WAITING", "DONE", "CANCELLED"]
        case .milestone: ["PLANNED", "ACTIVE", "DONE", "CANCELLED"]
        case .deadline: ["OPEN", "DONE", "CANCELLED"]
        case .reminder: ["OPEN", "DONE"]
        default: ["OPEN"]
        }
    }
    // New completion controls use canonical wire values while older states remain readable.
    var completedStatus: String? {
        switch self {
        case .project: "COMPLETED"
        case .task, .milestone, .deadline, .reminder: "DONE"
        case .area, .knowledge: nil
        }
    }
    var incompleteStatus: String {
        switch self {
        case .project, .milestone: "PLANNED"
        case .task: "TODO"
        case .area, .deadline, .reminder, .knowledge: "OPEN"
        }
    }
}

enum StateLabels {
    static func title(_ status: String) -> String {
        switch status {
        case "DONE", "COMPLETED", "CANCELLED": "已完成"
        case "PLANNED", "ACTIVE", "WAITING", "PAUSED", "TODO", "IN_PROGRESS", "OPEN": "未完成"
        default: status
        }
    }
}

/// Device preferences are deliberately separate from the shared workspace snapshot.
struct WorkspacePreferences: Codable, Equatable {
    var taskRemindersEnabled = false
    var deadlineRemindersEnabled = true
    var notificationLeadMinutes = 0
    var dateOnlyDeadlines = true
    var customProjectCategories: [String] = []
    var hiddenBuiltinProjectCategories: [String] = []
    var defaultProjectCategory = "RESEARCH"

    static let builtinProjectCategoryKeys = ["RESEARCH", "PAPER", "VERTICAL_PROJECT", "INDUSTRY_PROJECT", "LEARNING", "ADMINISTRATIVE", "PERSONAL"]

    init(taskRemindersEnabled: Bool = false, deadlineRemindersEnabled: Bool = true,
         notificationLeadMinutes: Int = 0, dateOnlyDeadlines: Bool = true,
         customProjectCategories: [String] = [], hiddenBuiltinProjectCategories: [String] = [],
         defaultProjectCategory: String = "RESEARCH") {
        self.taskRemindersEnabled = taskRemindersEnabled
        self.deadlineRemindersEnabled = deadlineRemindersEnabled
        self.notificationLeadMinutes = notificationLeadMinutes
        self.dateOnlyDeadlines = dateOnlyDeadlines
        self.customProjectCategories = customProjectCategories
        self.hiddenBuiltinProjectCategories = hiddenBuiltinProjectCategories
        self.defaultProjectCategory = defaultProjectCategory
        self = normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case taskRemindersEnabled, deadlineRemindersEnabled, notificationLeadMinutes
        case dateOnlyDeadlines, customProjectCategories, hiddenBuiltinProjectCategories, defaultProjectCategory
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            taskRemindersEnabled: (try? values.decode(Bool.self, forKey: .taskRemindersEnabled)) ?? false,
            deadlineRemindersEnabled: (try? values.decode(Bool.self, forKey: .deadlineRemindersEnabled)) ?? true,
            notificationLeadMinutes: (try? values.decode(Int.self, forKey: .notificationLeadMinutes)) ?? 0,
            dateOnlyDeadlines: (try? values.decode(Bool.self, forKey: .dateOnlyDeadlines)) ?? true,
            customProjectCategories: (try? values.decode([String].self, forKey: .customProjectCategories)) ?? [],
            hiddenBuiltinProjectCategories: (try? values.decode([String].self, forKey: .hiddenBuiltinProjectCategories)) ?? [],
            defaultProjectCategory: (try? values.decode(String.self, forKey: .defaultProjectCategory)) ?? "RESEARCH")
    }

    func normalized() -> WorkspacePreferences {
        var value = self
        value.notificationLeadMinutes = min(10_080, max(0, notificationLeadMinutes))
        var seen = Set(Self.builtinProjectCategoryKeys)
        value.customProjectCategories = customProjectCategories.compactMap { category in
            let clean = category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.utf16.count <= 240, seen.insert(clean).inserted else { return nil }
            return clean
        }.prefix(50).map { $0 }
        let builtin = Set(Self.builtinProjectCategoryKeys)
        value.hiddenBuiltinProjectCategories = Array(Set(hiddenBuiltinProjectCategories).intersection(builtin)).sorted()
        let available = Self.builtinProjectCategoryKeys.filter { !value.hiddenBuiltinProjectCategories.contains($0) } + value.customProjectCategories
        if !defaultProjectCategory.isEmpty, !available.contains(defaultProjectCategory) {
            value.defaultProjectCategory = available.first ?? ""
        }
        return value
    }

    mutating func removeProjectCategory(_ key: String) {
        customProjectCategories.removeAll { $0 == key }
        if Self.builtinProjectCategoryKeys.contains(key) {
            hiddenBuiltinProjectCategories.append(key)
        }
        if defaultProjectCategory == key { defaultProjectCategory = "" }
        self = normalized()
    }

    /// Call only when constructing a new record, never while editing existing content.
    func apply(to record: inout WorkspaceRecord) {
        let value = normalized()
        if record.kind.isItem {
            record.notificationsEnabled = value.taskRemindersEnabled
            record.notificationLeadMinutes = value.notificationLeadMinutes
        } else if record.kind == .deadline {
            record.notificationsEnabled = value.deadlineRemindersEnabled
            record.notificationLeadMinutes = value.notificationLeadMinutes
            record.dateOnly = value.dateOnlyDeadlines
        } else if record.kind.isProjectGroup {
            record.projectKind = value.defaultProjectCategory
        }
    }
}

/// Normalize once at the write boundary. Never assign an observed property inside its didSet.
@Observable final class WorkspacePreferenceStorage {
    static let key = "workspacePersonalPreferences.v1"
    private var storedValue: WorkspacePreferences
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persists: Bool

    var value: WorkspacePreferences {
        get { storedValue }
        set {
            let normalized = newValue.normalized()
            guard normalized != storedValue else { return }
            storedValue = normalized
            if persists, let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }
    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        storedValue = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(WorkspacePreferences.self, from: $0) } ?? WorkspacePreferences()
    }
}

struct WorkspaceRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: ItemKind
    var title: String
    var version = 1
    var createdAt = Date()
    var updatedAt = Date()
    var archivedAt: Date?
    var deletedAt: Date?
    var completedAt: Date?
    var cancelledAt: Date?
    var projectID: UUID?
    var milestoneID: UUID?
    var areaID: UUID?
    var status: String
    var summary = ""
    var body = ""
    var category = "笔记"
    var tags: [String] = []
    var pinned = false
    var projectKind = "RESEARCH"
    var startDate: Date?
    var targetDate: Date?
    var dueDate: Date?
    var dateOnly = true
    var scheduledAt: Date?
    var remindAt: Date?
    var timezone = "Asia/Shanghai"
    var notificationsEnabled = false
    var notificationLeadMinutes = 0
    var snoozedUntil: Date?
    var recurrenceSeriesID: UUID?
    var occurrenceDate: String?
    var isException = false
    var trashBatchID: UUID?
    var calendarEventID: String?

    init(kind: ItemKind, title: String = "", id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.title = title
        status = kind.states.first ?? "OPEN"
        notificationsEnabled = kind == .reminder || kind == .deadline
    }
    var isFinished: Bool { ["DONE", "COMPLETED", "CANCELLED"].contains(status) }
    var isKeyItem: Bool { (kind.isItem || kind == .deadline) && pinned }
    var isLive: Bool { deletedAt == nil && archivedAt == nil }
    var isOverdue: Bool { !isFinished && dueDate.map { effectiveDueDate($0) < Date() } == true }
    var calendar: Calendar { WorkspaceDates.calendar(timezone) }
    func effectiveDueDate(_ value: Date) -> Date {
        guard dateOnly else { return value }
        return calendar.date(byAdding: .second, value: -1,
            to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: value)) ?? value) ?? value
    }
    var recurrenceAnchor: Date? {
        kind.isItem ? scheduledAt ?? dueDate ?? remindAt : kind == .deadline ? dueDate : nil
    }
    var recurrenceEffectiveDate: Date? {
        if kind.isItem, let scheduledAt { return scheduledAt }
        if let dueDate { return effectiveDueDate(dueDate) }
        return kind.isItem ? remindAt : nil
    }
    var notificationDate: Date? {
        guard notificationsEnabled, isLive, !isFinished else { return nil }
        if let snoozedUntil { return snoozedUntil }
        // An explicit reminder is already the exact notification time.
        if kind.isItem || kind == .deadline, let remindAt { return remindAt }
        let date: Date?
        if let dueDate {
            date = dateOnly ? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dueDate) : dueDate
        } else { date = scheduledAt }
        return date?.addingTimeInterval(-Double(notificationLeadMinutes) * 60)
    }
}

enum WorkspaceNotificationPolicy {
    /// Notification actions must belong to the record's current reminder
    /// occurrence. This prevents an old delivered banner from completing or
    /// snoozing a record after its reminder was disabled, moved, or replaced.
    static func isCurrentAction(for record: WorkspaceRecord, scheduledAtMilliseconds: Double?) -> Bool {
        guard let supplied = scheduledAtMilliseconds, supplied.isFinite,
              let current = record.notificationDate else { return false }
        let expected = current.timeIntervalSince1970 * 1000
        return abs(expected - supplied) < 1000
    }
}

struct RecurrenceRule: Codable, Hashable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY"
        case oddWeeks = "ODD_WEEKS", evenWeeks = "EVEN_WEEKS"
        case weekdays = "WEEKDAYS", workdays = "CHINA_WORKDAYS"
        static let allCases: [Frequency] = [.daily, .weekly, .oddWeeks, .evenWeeks, .weekdays, .workdays, .monthly]
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: WorkspaceLocalization.string("每天"); case .weekly: WorkspaceLocalization.string("每周"); case .monthly: WorkspaceLocalization.string("每月")
            case .oddWeeks: WorkspaceLocalization.string("单周"); case .evenWeeks: WorkspaceLocalization.string("双周")
            case .weekdays: WorkspaceLocalization.string("周一至周五"); case .workdays: WorkspaceLocalization.string("工作日（含调休）")
            }
        }
        var intervalUnit: String { self == .daily ? WorkspaceLocalization.string("天") : self == .monthly ? WorkspaceLocalization.string("月") : WorkspaceLocalization.string("周") }
        var supportsInterval: Bool { [.daily, .weekly, .monthly].contains(self) }
        var usesWeekParity: Bool { self == .oddWeeks || self == .evenWeeks }
        var usesWeekdays: Bool { self == .weekly || usesWeekParity }
    }
    var frequency: Frequency = .weekly
    var interval = 1
    var weekdays: [Int] = [] // ISO: Monday = 1, Sunday = 7.
    var until: Date?
    var weekOneStart: Date?
    var label: String {
        let base = frequency.supportsInterval && interval > 1 ? WorkspaceLocalization.format("每%@%@", String(describing: interval), String(describing: frequency.intervalUnit)) : frequency.title
        return base + (frequency.usesWeekdays && !weekdays.isEmpty ? " · " + weekdays.sorted().map { WorkspaceDates.weekdayName($0) }.joined(separator: "、") : "")
    }
}

struct DeadlineSeries: Identifiable, Codable, Hashable {
    var id = UUID()
    var template: WorkspaceRecord
    var rule: RecurrenceRule
    var stoppedAt: Date?
    var generatedThrough: Date?
    /// A series tombstone prevents an offline device from recreating a deleted group.
    var deletedAt: Date?
}
enum RecurrenceDeletionScope: String, CaseIterable, Identifiable {
    case occurrence, following, series
    var id: String { rawValue }
    var title: String {
        switch self {
        case .occurrence: WorkspaceLocalization.string("仅这一次")
        case .following: WorkspaceLocalization.string("这次及以后")
        case .series: WorkspaceLocalization.string("整个重复系列")
        }
    }
}
struct TrashedRecurrence: Codable, Hashable {
    var before: DeadlineSeries
    var after: DeadlineSeries
    /// nil means the entire series; otherwise the original occurrence day, in its timezone.
    var fromDay: String?
}
struct ActivityEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var entityID: UUID
    var projectID: UUID?
    var title: String
    var message: String
    var date = Date()
}
struct KnowledgeRevision: Identifiable, Codable, Hashable {
    var id = UUID()
    var record: WorkspaceRecord
    var action: String
    var date = Date()
}
struct WorkspaceAsset: Identifiable, Codable, Hashable {
    var id = UUID()
    var ownerID: UUID
    var name: String
    var data: Data
    var createdAt = Date()
}
struct TrashBatch: Identifiable, Codable, Hashable {
    var id = UUID()
    var rootID: UUID
    var title: String
    var itemIDs: [UUID]
    var deletedAt = Date()
    var expiresAt: Date?
    var recurrence: [TrashedRecurrence]?
}
struct WorkspaceProfile: Codable, Hashable {
    var name = "用户"
    var timezone = "Asia/Shanghai"
    var avatar: Data?
}
struct WorkspaceState: Codable, Equatable {
    var format = "guangyi-native"
    var schemaVersion = 1
    var records: [WorkspaceRecord] = []
    var series: [DeadlineSeries] = []
    var activities: [ActivityEntry] = []
    var revisions: [KnowledgeRevision] = []
    var assets: [WorkspaceAsset] = []
    var trash: [TrashBatch] = []
    var profile = WorkspaceProfile()
}
struct DeletionPreview: Identifiable {
    var id = UUID()
    var root: WorkspaceRecord
    var records: [WorkspaceRecord]
    var createdAt = Date()
    var selectedIDs: [UUID] = []
    var recurrenceScope = RecurrenceDeletionScope.occurrence
    var affectedSeries: [DeadlineSeries] = []
    var projectedRecords: [WorkspaceRecord] = []
    var title: String { selectedIDs.count > 1 ? WorkspaceLocalization.format("选中的 %@ 项", String(describing: selectedIDs.count)) : root.title }
}
enum WorkspaceFailure: LocalizedError {
    case invalid(String), conflict, missingParent, stalePreview, expiredTrash, remainingTasks(Int), tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .conflict: WorkspaceLocalization.string("内容已在其他窗口修改。请关闭编辑器，重新打开后比较。")
        case .missingParent: WorkspaceLocalization.string("关联项目组或事项不可用，请先恢复或重新选择。")
        case .stalePreview: WorkspaceLocalization.string("关联内容已变化，请重新确认删除范围。")
        case .expiredTrash: WorkspaceLocalization.string("此删除批次已超过 30 天恢复期限。")
        case .remainingTasks(let count): WorkspaceLocalization.format("项目组还有 %@ 项未完成事项，请先确认。", String(describing: count))
        case .tooLarge: WorkspaceLocalization.string("文件过大，或内容超过支持的上限。")
        }
    }
}

enum WorkspaceDates {
    static func calendar(_ timezone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        calendar.locale = WorkspaceLocalization.locale
        calendar.firstWeekday = 2
        return calendar
    }
    static func dayKey(_ date: Date, timezone: String) -> String {
        let parts = calendar(timezone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
    static func weekdayName(_ day: Int) -> String {
        [1: WorkspaceLocalization.string("周一"), 2: WorkspaceLocalization.string("周二"), 3: WorkspaceLocalization.string("周三"), 4: WorkspaceLocalization.string("周四"), 5: WorkspaceLocalization.string("周五"), 6: WorkspaceLocalization.string("周六"), 7: WorkspaceLocalization.string("周日")][day] ?? ""
    }
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        let onlyDate = DateFormatter()
        onlyDate.calendar = calendar(); onlyDate.timeZone = calendar().timeZone
        onlyDate.locale = Locale(identifier: "en_US_POSIX"); onlyDate.dateFormat = "yyyy-MM-dd"
        onlyDate.isLenient = false
        return onlyDate.date(from: value)
    }
}

/// Fictional campus life, kept separate from any account or verified timetable.
/// A fixed clock produces the same identifiers, content, and relative dates.
enum WorkspaceDemo {
    static func make(now: Date = Date()) -> WorkspaceState {
        let calendar = WorkspaceDates.calendar()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func id(_ number: Int) -> UUID {
            UUID(uuidString: String(format: "DE000000-0000-4000-8000-%012d", number))!
        }
        var state = WorkspaceState()
        state.profile.name = "演示用户"
        var next = 1
        @discardableResult func add(_ kind: ItemKind, _ title: String, project: UUID? = nil,
                                   area: UUID? = nil, change: (inout WorkspaceRecord) -> Void = { _ in }) -> UUID {
            var record = WorkspaceRecord(kind: kind, title: title, id: id(next))
            next += 1
            record.createdAt = day(-14, 9); record.updatedAt = day(-1, 20)
            record.projectID = project; record.areaID = area
            change(&record)
            state.records.append(record)
            return record.id
        }
        let study = add(.area, "学习与课程") { $0.summary = "虚构的学习与生活日常，用于体验各项功能。" }
        let life = add(.area, "校园与生活")
        let growth = add(.area, "兴趣与成长")
        let math = add(.project, "高等数学 · 本周学习", area: study) {
            $0.status = "ACTIVE"; $0.pinned = true; $0.startDate = day(-7); $0.targetDate = day(7)
            $0.summary = "听课、例题、错题和每周回顾。"; $0.tags = ["课程", "数学"]
        }
        let english = add(.project, "大学英语 · 小组展示", area: study) {
            $0.status = "ACTIVE"; $0.targetDate = day(5); $0.tags = ["课程", "小组合作"]
        }
        let coding = add(.project, "程序设计 · 校园记账本", area: study) {
            $0.status = "ACTIVE"; $0.targetDate = day(10); $0.tags = ["课程", "编程"]
        }
        let physics = add(.project, "物理实验 · 数据与报告", area: study) { $0.status = "WAITING"; $0.targetDate = day(8) }
        let campus = add(.project, "校园生活清单", area: life) { $0.status = "ACTIVE"; $0.projectKind = "LIFE" }
        let health = add(.project, "规律作息与运动", area: life) { $0.status = "ACTIVE"; $0.projectKind = "LIFE" }
        let photo = add(.project, "公园散步影像", area: growth) { $0.status = "PLANNED"; $0.projectKind = "PERSONAL" }
        let reading = add(.project, "读书与随手记", area: growth) { $0.status = "PAUSED"; $0.projectKind = "PERSONAL" }
        let oldProject = add(.project, "迎新准备 · 已完成", area: life) {
            $0.status = "COMPLETED"; $0.completedAt = day(-5, 18); $0.archivedAt = day(-3, 18)
        }
        let firstDraft = add(.milestone, "完成展示初稿", project: english) {
            $0.status = "ACTIVE"; $0.dueDate = day(2, 20); $0.dateOnly = false; $0.pinned = true
        }
        let runnable = add(.milestone, "记账本可以完整运行", project: coding) {
            $0.status = "PLANNED"; $0.dueDate = day(6); $0.tags = ["里程碑"]
        }
        add(.milestone, "数学第一轮复习完成", project: math) {
            $0.status = "DONE"; $0.completedAt = day(-2, 21); $0.dueDate = day(-2)
        }

        // A readable day instead of numbered stress-test placeholders.
        let agenda: [(String, UUID, Int, Int, Int, String)] = [
            ("晨间整理：挑出今天最重要的三件事", health, 0, 7, 30, "DONE"),
            ("高数课前：回顾极限的三个易错点", math, 0, 8, 0, "DONE"),
            ("高等数学课 · 例题与课堂笔记", math, 0, 8, 30, "TODO"),
            ("课后十分钟：补齐笔记中的证明", math, 0, 10, 15, "IN_PROGRESS"),
            ("食堂午饭，顺便休息一下", health, 0, 11, 40, "TODO"),
            ("大学英语 · 展示分工讨论", english, 0, 13, 30, "TODO"),
            ("图书馆自习：实现收支分类", coding, 0, 15, 0, "IN_PROGRESS"),
            ("操场慢跑，结束后拉伸", health, 0, 17, 20, "TODO"),
            ("英语展示：录一遍两分钟开场", english, 0, 19, 0, "TODO"),
            ("睡前整理：记录今天的收获", health, 0, 22, 0, "TODO"),
            ("物理实验预习：列出测量步骤", physics, 1, 8, 30, "TODO"),
            ("程序设计课 · 数组与函数", coding, 1, 10, 0, "TODO"),
            ("整理实验数据并画出散点图", physics, 1, 14, 0, "WAITING"),
            ("小组展示：统一配色和字体", english, 1, 19, 0, "TODO"),
            ("高数习题：先独立完成再对答案", math, 2, 9, 0, "TODO"),
            ("和同学一起核对实验误差", physics, 2, 15, 30, "TODO"),
            ("公园散步，拍一组光影", photo, 3, 16, 0, "TODO"),
            ("周末长阅读：读完一个章节", reading, 4, 10, 0, "TODO"),
            ("一周回顾：把未完成的事重新安排", campus, 5, 20, 0, "TODO"),
            ("英语听力精听与跟读", english, -1, 19, 0, "DONE"),
            ("整理上周数学错题", math, -2, 16, 0, "DONE"),
            ("补交程序运行截图", coding, -1, 21, 0, "TODO"),
            ("原定拍摄：下雨后取消", photo, -1, 17, 0, "CANCELLED")
        ]
        for (title, project, offset, hour, minute, status) in agenda {
            add(.task, title, project: project) {
                $0.scheduledAt = day(offset, hour, minute); $0.dateOnly = false; $0.status = status
                $0.dueDate = day(offset, min(hour + 1, 23), minute)
                $0.notificationsEnabled = true; $0.notificationLeadMinutes = 10
                $0.tags = offset == 0 ? ["今日"] : ["本周"]
                if status == "DONE" { $0.completedAt = day(offset, min(hour + 1, 23), minute) }
                if status == "CANCELLED" { $0.cancelledAt = day(offset, hour, minute) }
            }
        }
        add(.task, "和组员确认展示顺序", project: english) {
            $0.status = "WAITING"; $0.milestoneID = firstDraft; $0.dueDate = day(1, 20); $0.dateOnly = false
            $0.summary = "等大家回复后，把最终顺序写进展示稿。"; $0.pinned = true
        }
        add(.task, "补上金额输入的边界检查", project: coding) {
            $0.milestoneID = runnable; $0.status = "IN_PROGRESS"; $0.tags = ["编程", "细节"]
            $0.body = "尝试空输入、负数、小数和超长数字；把提示写得清楚一点。"
        }
        add(.task, "找一本适合周末慢慢读的书", project: reading)
        add(.task, "把想拍的校园角落列成清单", project: photo) { $0.pinned = true }

        let deadlines: [(String, UUID, Int, Int, Int, Bool)] = [
            ("高数作业 · 第三组习题", math, 0, 20, 0, false),
            ("英语展示开场稿", english, 0, 20, 30, false),
            ("程序设计阶段提交", coding, 0, 23, 0, false),
            ("实验预习单", physics, 1, 8, 0, false),
            ("英语展示初稿发给组员", english, 1, 8, 40, false),
            ("本周数学错题整理", math, 2, 0, 0, true),
            ("记账本 · 第一版演示", coding, 3, 18, 0, false),
            ("实验报告初稿", physics, 4, 0, 0, true),
            ("英语小组正式展示", english, 5, 14, 0, false),
            ("月度阅读札记", reading, 12, 0, 0, true),
            ("待补：上次实验数据复核", physics, -1, 18, 0, false),
            ("已提交：上周程序练习", coding, -3, 20, 0, false)
        ]
        for (title, project, offset, hour, minute, dateOnly) in deadlines {
            add(.deadline, title, project: project) {
                $0.dueDate = day(offset, hour, minute); $0.dateOnly = dateOnly
                $0.notificationLeadMinutes = dateOnly ? 0 : 30
                $0.tags = ["提交"]; $0.pinned = offset == 0
                if offset == -3 { $0.status = "DONE"; $0.completedAt = day(-3, 19, 40) }
            }
        }
        let reminders: [(String, Int, Int, UUID)] = [
            ("出门带上水杯和校园卡", 0, 8, campus),
            ("午休前把手机充上电", 0, 12, campus),
            ("晚饭后收一下晾着的衣服", 0, 18, campus),
            ("明天上课前带实验记录本", 1, 8, physics),
            ("买一点水果和早餐", 1, 18, campus),
            ("周末整理桌面和书包", 3, 11, campus),
            ("给家里打个电话", 4, 20, campus),
            ("检查自行车车灯和胎压", 5, 17, campus)
        ]
        for (title, offset, hour, project) in reminders {
            add(.reminder, title, project: project) {
                $0.remindAt = day(offset, hour); $0.dateOnly = false; $0.tags = ["生活"]
            }
        }
        add(.reminder, "喝水，离开屏幕活动一下", project: health) {
            $0.remindAt = now.addingTimeInterval(-300); $0.snoozedUntil = now.addingTimeInterval(1800)
            $0.dateOnly = false; $0.summary = "已稍后提醒的演示事项。"
        }

        let notes: [(String, UUID, String, String, [String])] = [
            ("极限与连续 · 错题卡", math, "学习", "## 先找条件，再套结论\n\n- 看清左右极限。\n- 分母为零时先尝试因式分解。\n- 把容易遗漏的定义域单独圈出。", ["数学", "错题"]),
            ("展示开场的三个版本", english, "草稿", "## 先提出一个问题\n\n用一个校园小场景引出主题，再给出今天要讨论的两个观点。\n\n结尾留一个大家可以回答的问题。", ["英语", "表达"]),
            ("记账本的数据结构", coding, "学习", "## 一笔记录需要什么\n\n金额、类别、时间与备注。\n\n先保证增删改查顺畅，再补统计图和导出。", ["编程", "设计"]),
            ("实验误差从哪里来", physics, "学习", "## 分开记录\n\n仪器精度、读数误差与操作误差分别说明。保留原始数据，别只留最后结果。", ["实验", "复盘"]),
            ("图书馆自习 · 我的准备清单", campus, "生活", "水杯、耳机、充电线、今天要做的三件事。到座位后先把最难的一项打开。", ["校园", "清单"]),
            ("慢跑后舒服的拉伸顺序", health, "生活", "先慢走放松，再做轻柔拉伸。当天状态不好就缩短距离。\n\n这是一张演示笔记。", ["运动", "习惯"]),
            ("光影观察手记", photo, "灵感", "留意树叶边缘的光、路面的影子和晚霞。先拍一张，再想想它哪里吸引我。", ["摄影", "校园"]),
            ("读书摘记 · 留一点空白", reading, "阅读", "读完一节后先合上书，用自己的话写三句话，再把最有共鸣的部分标出来。", ["阅读", "摘记"])
        ]
        for (title, project, category, body, tags) in notes {
            let noteID = add(.knowledge, title, project: project) {
                $0.category = category; $0.body = body; $0.tags = tags; $0.pinned = project == math
                $0.version = 2
            }
            var previous = state.records.last!
            previous.version = 1; previous.body = "初稿：" + title; previous.updatedAt = day(-4, 20)
            state.revisions.append(KnowledgeRevision(id: id(10_000 + next), record: previous,
                                                     action: "编辑前", date: day(-1, 20)))
            if project == physics {
                state.assets.append(WorkspaceAsset(id: id(20_000), ownerID: noteID,
                    name: "实验记录示例.pdf", data: samplePDF(), createdAt: day(-2, 16)))
            }
        }

        // Short horizons provide realistic repeated tasks without filling three years.
        let repeatSpecs: [(String, UUID, RecurrenceRule.Frequency, Int, Int)] = [
            ("晚间五分钟回顾", health, .daily, 1, 21),
            ("每周整理数学错题", math, .weekly, 1, 19),
            ("隔周清理电脑文件", campus, .weekly, 2, 20),
            ("单周 · 程序设计交流", coding, .oddWeeks, 1, 18),
            ("双周 · 实验小组复盘", physics, .evenWeeks, 1, 18),
            ("平日晨读十分钟", english, .weekdays, 1, 7),
            ("工作日检查校园待办", campus, .workdays, 1, 9),
            ("每月预算回顾", campus, .monthly, 1, 20)
        ]
        for (index, spec) in repeatSpecs.enumerated() {
            let (title, project, frequency, interval, hour) = spec
            // The embedded adjustment calendar only covers 2025–2026. Keep the
            // workday example historical in later years rather than invent dates.
            let supported = ChinaWorkCalendar.coveredYears.contains(calendar.component(.year, from: now))
            let anchor = frequency == .workdays && !supported
                ? WorkspaceDates.parse("2026-10-12T09:00:00+08:00")! : day(0, hour)
            let end = calendar.date(byAdding: .day, value: 20, to: anchor) ?? anchor
            let seriesID = id(30_000 + index)
            let recordID = add(.task, title, project: project) {
                $0.scheduledAt = anchor; $0.dateOnly = false; $0.notificationsEnabled = true
                $0.notificationLeadMinutes = 5; $0.tags = ["习惯", "重复"]
                $0.recurrenceSeriesID = seriesID
                $0.occurrenceDate = WorkspaceDates.dayKey(anchor, timezone: $0.timezone)
            }
            var template = state.records.first { $0.id == recordID }!
            template.recurrenceSeriesID = nil; template.occurrenceDate = nil
            let weekday = (calendar.component(.weekday, from: anchor) + 5) % 7 + 1
            let rule = RecurrenceRule(frequency: frequency, interval: interval,
                weekdays: frequency.usesWeekdays ? [weekday] : [], until: end,
                weekOneStart: calendar.date(byAdding: .day, value: -14, to: today))
            state.series.append(DeadlineSeries(id: seriesID, template: template, rule: rule,
                stoppedAt: frequency == .workdays && !supported ? now : nil))
            state.records[state.records.count - 1].isException = RecurrenceEngine.dates(anchor: anchor,
                rule: rule, from: anchor, through: anchor, timezone: template.timezone).isEmpty
        }
        RecurrenceEngine.materialize(&state, now: now)

        add(.task, "迎新用品清单归档", project: oldProject) {
            $0.status = "DONE"; $0.completedAt = day(-6, 16); $0.archivedAt = day(-3, 18)
        }
        add(.knowledge, "上个月的学习回顾", project: math) {
            $0.body = "已经完成的练习和下一阶段想改进的地方。"; $0.archivedAt = day(-2, 20)
        }
        let removedID = add(.task, "重复创建的采购清单", project: campus) {
            $0.deletedAt = day(-1, 18); $0.trashBatchID = id(40_000)
        }
        state.trash.append(TrashBatch(id: id(40_000), rootID: removedID, title: "重复创建的采购清单",
            itemIDs: [removedID], deletedAt: day(-1, 18), expiresAt: day(29, 18)))
        for (index, record) in state.records.prefix(24).enumerated() {
            state.activities.append(ActivityEntry(id: id(50_000 + index), entityID: record.id,
                projectID: record.projectID, title: record.title,
                message: record.isFinished ? "完成了事项" : "添加了演示内容", date: day(-index % 4, 18)))
        }
        return state
    }

    private static func samplePDF() -> Data {
        let stream = "BT /F1 20 Tf 50 760 Td (Demo: Physics lab notes) Tj 0 -32 Td /F1 12 Tf (Fictional sample attachment. No personal data.) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
