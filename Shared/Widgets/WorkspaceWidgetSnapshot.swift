import Foundation

/// A deliberately small read-only projection. Credentials, notes and course content never leave the app.
struct WorkspaceWidgetItem: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var projectID: UUID?
    var projectName: String?
    var date: Date?
    var dateOnly: Bool
    var isDeadline: Bool
    var isStarred: Bool
    var priorityRank: Double
    var hasDueDate: Bool? = nil

    func isOverdue(at now: Date) -> Bool {
        (hasDueDate ?? isDeadline) && date.map { $0 < now } == true
    }
}

struct WorkspaceWidgetProject: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
}

struct WorkspaceWidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    var items: [WorkspaceWidgetItem]
    var projects: [WorkspaceWidgetProject]
    var theme: String
    var isDemo: Bool
    var demoSessionID: String?
    var contextID: String
    var enabled: Bool


    /// Date filtering is shared with the provider so scheduled times are never mistaken for overdue deadlines.
    func selectedItems(showTasks: Bool, showDeadlines: Bool, rangeDays: Int?, projectID: UUID?,
                       starredOnly: Bool, includeOverdue: Bool, sortByTime: Bool,
                       at now: Date, calendar: Calendar = .current) -> [WorkspaceWidgetItem] {
        guard enabled else { return [] }
        let today = calendar.startOfDay(for: now)
        let end = rangeDays.flatMap { calendar.date(byAdding: .day, value: $0, to: today) }
        return items.filter { item in
            guard item.isDeadline ? showDeadlines : showTasks else { return false }
            if let projectID, item.projectID != projectID { return false }
            if starredOnly && !item.isStarred { return false }
            let overdue = item.isOverdue(at: now)
            if overdue && !includeOverdue { return false }
            if let end {
                guard let date = item.date, date < end else { return false }
                if date < today && !overdue { return false }
            }
            return true
        }.sorted {
            if !sortByTime && $0.priorityRank != $1.priorityRank { return $0.priorityRank < $1.priorityRank }
            let a = $0.date ?? .distantFuture, b = $1.date ?? .distantFuture
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }

    /// Used only in the gallery and Xcode previews, never as a fallback for missing user data.
    static var placeholder: Self {
        let day = Calendar.current.startOfDay(for: Date())
        let group = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return Self(generatedAt: Date(), items: [
            .init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, title: "高等数学 · 第三组习题", projectID: group, projectName: "本周学习", date: day.addingTimeInterval(20 * 3600), dateOnly: false, isDeadline: true, isStarred: true, priorityRank: 0),
            .init(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, title: "整理实验记录", projectID: group, projectName: "本周学习", date: day.addingTimeInterval(16 * 3600), dateOnly: false, isDeadline: false, isStarred: false, priorityRank: 1),
            .init(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, title: "英语展示开场稿", projectID: nil, projectName: nil, date: day.addingTimeInterval(2 * 86400 + 18 * 3600), dateOnly: false, isDeadline: true, isStarred: false, priorityRank: 2)
        ], projects: [.init(id: group, title: "本周学习")], theme: "blue", isDemo: false, demoSessionID: nil, contextID: "gallery", enabled: true)
    }
}

enum WorkspaceWidgetStorage {
    static let appGroup = "group.org.example.workspace"
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    static var isSharingEnabled: Bool {
        get { defaults?.object(forKey: "widgetSharingEnabled") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "widgetSharingEnabled") }
    }
    static var containerURL: URL? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #else
        nil
        #endif
    }
    static func load() -> WorkspaceWidgetSnapshot? {
        guard let containerURL else { return nil }
        guard var snapshot = load(from: containerURL.appendingPathComponent("widget-snapshot-v1.json")) else { return nil }
        if !snapshot.isDemo && !isSharingEnabled { snapshot.enabled = false; snapshot.items = []; snapshot.projects = [] }
        return snapshot
    }
    static func load(from url: URL) -> WorkspaceWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count <= 8_000_000,
              let snapshot = try? JSONDecoder().decode(WorkspaceWidgetSnapshot.self, from: data) else { return nil }
        return snapshot
    }
    @discardableResult static func save(_ snapshot: WorkspaceWidgetSnapshot) throws -> Bool {
        guard let containerURL else { return false }
        return try save(snapshot, to: containerURL.appendingPathComponent("widget-snapshot-v1.json"))
    }
    /// Atomic replacement makes concurrent reads safe. A disabled snapshot contains no user summaries.
    @discardableResult static func save(_ snapshot: WorkspaceWidgetSnapshot, to url: URL) throws -> Bool {
        guard let data = try preparedData(snapshot, to: url) else { return false }
        try installPreparedData(data, to: url)
        return true
    }
    /// Prepare off the UI executor, then install only after the publisher confirms
    /// that the captured workspace and privacy settings are still current.
    static func preparedData(_ snapshot: WorkspaceWidgetSnapshot, to url: URL) throws -> Data? {
        var safe = snapshot
        if !safe.enabled { safe.items = []; safe.projects = [] }
        if var old = load(from: url) {
            old.generatedAt = safe.generatedAt
            if old == safe { return nil }
        }
        return try JSONEncoder().encode(safe)
    }
    static func installPreparedData(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
