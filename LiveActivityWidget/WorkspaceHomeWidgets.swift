import AppIntents
import SwiftUI
import WidgetKit
import UIKit

// Home Screen widgets read a presentation-only snapshot, never the app's database.
enum WorkspaceWidgetContent: String, AppEnum {
    case all, tasks, deadlines
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "内容"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "事项与截止事项", .tasks: "一般事项", .deadlines: "截止事项"
    ]
}

enum WorkspaceWidgetRange: String, AppEnum {
    case today, week, all
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "时间范围"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "今天", .week: "未来七天", .all: "全部"
    ]
    var label: String { switch self { case .today: WorkspaceLocalization.string("今天"); case .week: WorkspaceLocalization.string("未来七天"); case .all: WorkspaceLocalization.string("全部待办") } }
}

enum WorkspaceWidgetSort: String, AppEnum {
    case smart, time
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "排序"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.smart: "默认优先级", .time: "时间先后"]
}

enum WorkspaceWidgetPalette: String, AppEnum {
    case theme, blue, lilac, sage, graphite, cobalt, emerald, vermilion, rose, sand
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "配色"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .theme: "跟随 App", .blue: "远峰蓝", .lilac: "紫色", .sage: "松针绿", .graphite: "石墨灰",
        .cobalt: "蓝色", .emerald: "绿色", .vermilion: "红色", .rose: "玫红", .sand: "橙色"
    ]
    func color(theme: String) -> Color {
        let value = self == .theme ? theme : rawValue
        let light: (Double, Double, Double)
        let dark: (Double, Double, Double)
        switch value {
        case "lilac": light = (0.4392156862745098, 0.2549019607843137, 0.8431372549019608); dark = (0.7411764705882353, 0.6039215686274509, 1.0)
        case "sage": light = (0.29, 0.46, 0.37); dark = (0.61, 0.79, 0.68)
        case "rose": light = (0.7568627450980392, 0.14901960784313725, 0.403921568627451); dark = (1.0, 0.5568627450980392, 0.7254901960784313)
        case "sand": light = (0.7490196078431373, 0.3137254901960784, 0.0); dark = (1.0, 0.7058823529411765, 0.3686274509803922)
        case "cobalt": light = (0.1411764705882353, 0.34509803921568627, 0.8705882352941177); dark = (0.4745098039215686, 0.6313725490196078, 1.0)
        case "emerald": light = (0.03137254901960784, 0.4980392156862745, 0.3568627450980392); dark = (0.2980392156862745, 0.8588235294117647, 0.6588235294117647)
        case "vermilion": light = (0.8, 0.22745098039215686, 0.16470588235294117); dark = (1.0, 0.5686274509803921, 0.49411764705882355)
        case "graphite": light = (0.38, 0.41, 0.46); dark = (0.73, 0.77, 0.83)
        default: light = (0.32, 0.45, 0.57); dark = (0.65, 0.77, 0.88)
        }
        return Color(uiColor: UIColor { traits in
            let color = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        })
    }

}

struct WorkspaceWidgetProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "项目组"
    static let defaultQuery = WorkspaceWidgetProjectQuery()
    var id: UUID
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct WorkspaceWidgetProjectQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [WorkspaceWidgetProjectEntity] {
        projects.filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [WorkspaceWidgetProjectEntity] {
        projects.filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [WorkspaceWidgetProjectEntity] { projects }
    private var projects: [WorkspaceWidgetProjectEntity] {
        guard let snapshot = WorkspaceWidgetStorage.load(), snapshot.enabled else { return [] }
        return snapshot.projects.map { WorkspaceWidgetProjectEntity(id: $0.id, title: $0.title) }
    }
}

struct WorkspaceHomeWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "自定义工作坊小组件"
    static let description = IntentDescription("按项目组、时间和优先级安排你的桌面。截止倒计时仅显示截止事项。")
    @Parameter(title: "内容", default: .all) var content: WorkspaceWidgetContent
    @Parameter(title: "时间范围", default: .all) var range: WorkspaceWidgetRange
    @Parameter(title: "项目组") var project: WorkspaceWidgetProjectEntity?
    @Parameter(title: "排序", default: .smart) var sort: WorkspaceWidgetSort
    @Parameter(title: "仅显示星标", default: false) var starredOnly: Bool
    @Parameter(title: "包含逾期", default: true) var includeOverdue: Bool
    @Parameter(title: "显示所属项目组", default: true) var showProject: Bool
    @Parameter(title: "配色", default: .theme) var palette: WorkspaceWidgetPalette
    @Parameter(title: "隐藏内容，仅显示数量", default: false) var privacy: Bool
    @Parameter(title: "允许原地翻页", default: true) var interactive: Bool
    @Parameter(title: "紧凑列表", default: false) var dense: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$content) · \(\.$range)") {
            \.$project
            \.$sort
            \.$starredOnly
            \.$includeOverdue
            \.$showProject
            \.$palette
            \.$privacy
            \.$interactive
            \.$dense
        }
    }
}

private enum HomeWidgetKind: String, CaseIterable {
    case today = "WorkspaceTodayWidget"
    case deadline = "WorkspaceDeadlineWidget"
    case focus = "WorkspaceFocusWidget"
    var title: String { switch self { case .today: WorkspaceLocalization.string("工作台"); case .deadline: WorkspaceLocalization.string("截止倒计时"); case .focus: WorkspaceLocalization.string("此刻关注") } }
    var symbol: String { switch self { case .today: "square.grid.2x2"; case .deadline: "hourglass"; case .focus: "scope" } }
}

struct WorkspaceWidgetPageIntent: AppIntent {
    static let title: LocalizedStringResource = "查看下一页事项"
    static let description = IntentDescription("在桌面小组件中切换展示内容，不改变事项状态。")
    static let openAppWhenRun = false
    static let isDiscoverable = false
    @Parameter(title: "组件") var kind: String
    @Parameter(title: "上下文") var contextID: String
    @Parameter(title: "页码存储") var pageKey: String
    @Parameter(title: "总页数") var pageCount: Int
    init() {}
    init(kind: String, contextID: String, pageKey: String, pageCount: Int) {
        self.kind = kind
        self.contextID = contextID
        self.pageKey = pageKey
        self.pageCount = pageCount
    }
    func perform() async throws -> some IntentResult {
        guard HomeWidgetKind(rawValue: kind) != nil,
              let snapshot = WorkspaceWidgetStorage.load(), snapshot.enabled,
              snapshot.contextID == contextID,
              pageKey.hasPrefix("workspace.widgets.page.\(contextID).\(kind)."),
              let defaults = WorkspaceWidgetStorage.defaults else { return .result() }
        let count = max(1, min(pageCount, 10_000))
        defaults.set((max(0, defaults.integer(forKey: pageKey)) + 1) % count, forKey: pageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        return .result()
    }
}

private struct HomeWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WorkspaceWidgetSnapshot?
    var configuration: WorkspaceHomeWidgetConfiguration
    var kind: HomeWidgetKind
    var family: WidgetFamily
    var items: [WorkspaceWidgetItem]
    var page: Int
    var pageCount: Int
    var pageKey: String
    var totalCount: Int
    var isPreview = false
    var available: Bool { snapshot?.enabled == true }
    var tint: Color { configuration.palette.color(theme: snapshot?.theme ?? "blue") }
    var overdueCount: Int { items.filter { $0.isOverdue(at: date) }.count }
    var appURL: URL? {
        guard let snapshot else { return URL(string: "guangyi-workspace://widget/overview") }
        var components = URLComponents()
        components.scheme = "guangyi-workspace"
        components.host = "widget"
        components.path = "/overview"
        components.queryItems = [URLQueryItem(name: "context", value: snapshot.contextID)]
        if snapshot.isDemo, let session = snapshot.demoSessionID { components.queryItems?.append(URLQueryItem(name: "demo", value: session)) }
        return components.url
    }
    func url(for item: WorkspaceWidgetItem) -> URL? {
        guard !isPreview, let snapshot, snapshot.enabled, snapshot.items.contains(where: { $0.id == item.id }) else { return nil }
        var components = URLComponents()
        components.scheme = "guangyi-workspace"
        components.host = "record"
        components.path = "/" + item.id.uuidString
        components.queryItems = [URLQueryItem(name: "context", value: snapshot.contextID)]
        if snapshot.isDemo, let session = snapshot.demoSessionID { components.queryItems?.append(URLQueryItem(name: "demo", value: session)) }
        return components.url
    }
}

private struct HomeWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = WorkspaceHomeWidgetConfiguration
    typealias Entry = HomeWidgetEntry
    let kind: HomeWidgetKind
    func placeholder(in context: Context) -> Entry {
        makeEntry(configuration: .init(), family: context.family, snapshot: .placeholder, at: .now, preview: true)
    }
    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        let snapshot = context.isPreview ? WorkspaceWidgetSnapshot.placeholder : WorkspaceWidgetStorage.load()
        return makeEntry(configuration: configuration, family: context.family, snapshot: snapshot, at: .now, preview: context.isPreview)
    }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let now = Date()
        let snapshot = WorkspaceWidgetStorage.load()
        var dates = [now]
        // Future entries handle midnight and imminent deadlines without a background server call.
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) { dates.append(midnight) }
        dates += (snapshot?.items ?? []).compactMap(\.date).map { $0.addingTimeInterval(1) }.filter { $0 > now && $0 < now.addingTimeInterval(1800) }
        let entries = Array(Set(dates)).sorted().prefix(12).map {
            makeEntry(configuration: configuration, family: context.family, snapshot: snapshot, at: $0, preview: false)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800)))
    }
    private func makeEntry(configuration: Intent, family: WidgetFamily, snapshot: WorkspaceWidgetSnapshot?, at date: Date, preview: Bool) -> Entry {
        let items = snapshot?.selectedItems(
            showTasks: kind != .deadline && configuration.content != .deadlines,
            showDeadlines: kind == .deadline || configuration.content != .tasks,
            rangeDays: configuration.range == .all ? nil : configuration.range == .week ? 7 : 1,
            projectID: configuration.project?.id, starredOnly: configuration.starredOnly,
            includeOverdue: configuration.includeOverdue, sortByTime: kind == .deadline || configuration.sort == .time,
            at: date) ?? []
        let pageSize = kind == .today ? (family == .systemSmall ? 1 : family == .systemLarge ? (configuration.dense ? 7 : 5) : (configuration.dense ? 3 : 2)) : 1
        let pageCount = max(1, Int(ceil(Double(items.count) / Double(pageSize))))
        let filters = [configuration.content.rawValue, configuration.range.rawValue, configuration.project?.id.uuidString ?? "all", configuration.sort.rawValue, String(configuration.starredOnly), String(configuration.includeOverdue), String(pageSize)].joined(separator: ".")
        let key = "workspace.widgets.page.\(snapshot?.contextID ?? "none").\(kind.rawValue).\(filters)"
        let page = preview ? 0 : max(0, WorkspaceWidgetStorage.defaults?.integer(forKey: key) ?? 0) % pageCount
        let visible = Array(items.dropFirst(page * pageSize).prefix(pageSize))
        return Entry(date: date, snapshot: snapshot, configuration: configuration, kind: kind, family: family, items: visible, page: page, pageCount: pageCount, pageKey: key, totalCount: items.count, isPreview: preview)
    }
}

struct WorkspaceTodayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HomeWidgetKind.today.rawValue, intent: WorkspaceHomeWidgetConfiguration.self, provider: HomeWidgetProvider(kind: .today)) { entry in
            HomeWidgetView(entry: entry)
        }
        .configurationDisplayName("今日工作台")
        .description("桌面上的轻量工作台。浏览事项，按项目组、星标和时间筛选，原地翻页。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WorkspaceDeadlineWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HomeWidgetKind.deadline.rawValue, intent: WorkspaceHomeWidgetConfiguration.self, provider: HomeWidgetProvider(kind: .deadline)) { entry in
            HomeWidgetView(entry: entry)
        }
        .configurationDisplayName("截止倒计时")
        .description("给重要的截止时间留一个位置。清晰的时间数字，逾期提示，轻点切换下一项。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WorkspaceFocusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HomeWidgetKind.focus.rawValue, intent: WorkspaceHomeWidgetConfiguration.self, provider: HomeWidgetProvider(kind: .focus)) { entry in
            HomeWidgetView(entry: entry)
        }
        .configurationDisplayName("专注事项")
        .description("一次只关注一件事。随时换一个关注目标，点击内容回到对应详情。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HomeWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: HomeWidgetEntry
    private var compact: Bool { entry.family == .systemSmall }
    var body: some View {
        Group {
            if !entry.available { emptyState(disabled: entry.snapshot != nil) }
            else if entry.configuration.privacy { privateState }
            else if entry.items.isEmpty { noMatches }
            else {
                switch entry.kind {
                case .today: dashboard
                case .deadline: deadline
                case .focus: focus
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { background }
        .widgetURL(compact && !entry.configuration.privacy ? entry.items.first.flatMap { entry.url(for: $0) } ?? entry.appURL : entry.appURL)
        .privacySensitive()
        .environment(\.locale, WorkspaceLocalization.locale)
    }
    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(colors: [entry.tint.opacity(colorScheme == .dark ? 0.22 : 0.12), entry.tint.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : entry.family == .systemMedium ? 6 : 10) {
            header(title: "工作台", symbol: "square.grid.2x2")
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(entry.totalCount, format: .number).font(.system(size: 36, weight: .bold, design: .default)).monospacedDigit().widgetAccentable()
                    Text("待办").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    pageControl
                }
                if let item = entry.items.first { itemLink(item) { Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2) } }
            } else {
                ForEach(entry.items) { item in
                    itemLink(item) { row(item) }
                    if item.id != entry.items.last?.id { Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5) }
                }
                Spacer(minLength: 0)
                HStack {
                    Text("\(entry.totalCount) 项 · \(entry.configuration.range.label)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    pageControl
                }
            }
        }
    }
    private var deadline: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack {
                header(title: "截止", symbol: "hourglass")
                if compact { pageControl }
            }
            if let item = entry.items.first {
                itemLink(item) {
                    Group {
                        if compact {
                            VStack(alignment: .leading, spacing: 6) {
                                countdown(item)
                                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 16) {
                                countdown(item).frame(maxWidth: 128, alignment: .leading)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    metadata(item)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                if !compact {
                    HStack(spacing: 6) {
                        if let due = item.date { Text(due, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        pageControl
                    }
                }
            }
        }
    }
    private var focus: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            header(title: "此刻关注", symbol: "scope")
            if let item = entry.items.first {
                itemLink(item) {
                    HStack(alignment: .top, spacing: 12) {
                        if !compact {
                            RoundedRectangle(cornerRadius: 3).fill(entry.tint).frame(width: 5).widgetAccentable()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(compact ? .headline : .title3.weight(.bold)).foregroundStyle(.primary).lineLimit(compact ? 3 : 2).minimumScaleFactor(0.85)
                            if !compact { metadata(item) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    if compact { Image(systemName: item.isStarred ? "star.fill" : item.isDeadline ? "hourglass" : "circle").foregroundStyle(entry.tint).font(.caption).widgetAccentable() }
                    else { Text(WorkspaceLocalization.string(item.isDeadline ? "截止事项" : "一般事项")).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    pageControl
                }
            }
        }
    }
    private func header(title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text(WorkspaceLocalization.string(title)).font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            if entry.snapshot?.isDemo == true { Text("演示").font(.caption2).foregroundStyle(.secondary) }
            else if !compact && !dynamicTypeSize.isAccessibilitySize { Text(entry.date, format: .dateTime.month().day().weekday(.abbreviated)).font(.caption2).foregroundStyle(.secondary) }
        }
        .foregroundStyle(entry.tint)
        .widgetAccentable()
    }
    private func row(_ item: WorkspaceWidgetItem) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: item.isStarred ? "star.fill" : item.isDeadline ? "hourglass" : "circle.fill")
                .font(.system(size: item.isStarred ? 12 : item.isDeadline ? 11 : 6, weight: .semibold))
                .foregroundStyle(isOverdue(item) ? Color.red : entry.tint).frame(width: 13).widgetAccentable()
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                if entry.configuration.showProject, !dynamicTypeSize.isAccessibilitySize, !entry.configuration.dense, let project = item.projectName, !project.isEmpty {
                    Text(project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let due = item.date {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(due, format: Calendar.current.isDate(due, inSameDayAs: entry.date) && !item.dateOnly ? .dateTime.hour().minute() : .dateTime.month().day())
                        .font(.caption.weight(.medium)).monospacedDigit()
                    if isOverdue(item) { Text("逾期").font(.system(size: 9, weight: .medium)) }
                }
                .foregroundStyle(isOverdue(item) ? Color.red : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private func countdown(_ item: WorkspaceWidgetItem) -> some View {
        let overdue = isOverdue(item)
        let seconds = abs((item.date ?? entry.date).timeIntervalSince(entry.date))
        let dateOnlyDays = abs(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date), to: Calendar.current.startOfDay(for: item.date ?? entry.date)).day ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if seconds >= 86400 || item.dateOnly {
                    Text(item.dateOnly ? dateOnlyDays : max(0, Int(ceil(seconds / 86400))), format: .number)
                        .font(.system(size: compact ? 34 : 44, weight: .bold, design: .default)).monospacedDigit().minimumScaleFactor(0.65)
                    Text("天").font(.subheadline.weight(.semibold))
                } else if let due = item.date, !overdue {
                    Text(timerInterval: entry.date...max(entry.date, due), countsDown: true, showsHours: true)
                        .font(.system(size: compact ? 29 : 38, weight: .bold, design: .default)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                } else {
                    Text(item.date ?? entry.date, style: .relative).font(.system(size: compact ? 27 : 34, weight: .bold)).lineLimit(1).minimumScaleFactor(0.65)
                }
            }
            Text(WorkspaceLocalization.string(overdue ? "已逾期" : "距离截止")).font(.caption2.weight(.medium))
        }
        .foregroundStyle(overdue ? Color.red : entry.tint)
        .widgetAccentable()
        .accessibilityElement(children: .combine)
    }
    private func metadata(_ item: WorkspaceWidgetItem) -> some View {
        HStack(spacing: 6) {
            if entry.configuration.showProject, let name = item.projectName, !name.isEmpty { Text(name).lineLimit(1) }
            if let due = item.date {
                if entry.configuration.showProject, item.projectName != nil { Text("·") }
                Text(due, format: item.dateOnly ? .dateTime.month().day() : .dateTime.month().day().hour().minute()).lineLimit(1)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var pageControl: some View {
        if entry.configuration.interactive, entry.pageCount > 1, let snapshot = entry.snapshot, !entry.isPreview {
            Button(intent: WorkspaceWidgetPageIntent(kind: entry.kind.rawValue, contextID: snapshot.contextID, pageKey: entry.pageKey, pageCount: entry.pageCount)) {
                HStack(spacing: 4) {
                    if !compact { Text(entry.kind == .today ? "\(entry.page + 1) / \(entry.pageCount)" : WorkspaceLocalization.string("换一个")).font(.caption2.weight(.medium)) }
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                }
                .foregroundStyle(entry.tint)
                .padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 5 : 4)
                .background(entry.tint.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WorkspaceLocalization.string(entry.kind == .today ? "下一页事项" : "换一个关注事项"))
            .accessibilityValue("第 \(entry.page + 1) 页，共 \(entry.pageCount) 页")
            .widgetAccentable()
        }
    }
    @ViewBuilder private func itemLink<Content: View>(_ item: WorkspaceWidgetItem, @ViewBuilder content: () -> Content) -> some View {
        if let url = entry.url(for: item) { Link(destination: url, label: content) }
        else { content() }
    }
    private var privateState: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: entry.kind.title, symbol: "lock")
            Spacer(minLength: 0)
            Text(entry.totalCount, format: .number).font(.system(size: 42, weight: .bold)).monospacedDigit().foregroundStyle(entry.tint).widgetAccentable()
            Text("待办事项").font(.subheadline.weight(.medium))
            Text("内容已隐藏").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
    private var noMatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: entry.kind.title, symbol: entry.kind.symbol)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle").font(.title).foregroundStyle(entry.tint).widgetAccentable()
            Text("暂时没有待办").font(.headline)
            Text("可长按小组件调整时间范围").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
    private func emptyState(disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("工作坊", systemImage: "square.grid.2x2").font(.caption.weight(.semibold)).foregroundStyle(entry.tint).widgetAccentable()
            Spacer(minLength: 0)
            Text(WorkspaceLocalization.string(disabled ? "桌面内容已关闭" : "从 App 开始")).font(.headline)
            Text(WorkspaceLocalization.string(disabled ? "在设置中开启小组件内容" : "打开工作坊，同步你的事项")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
        }
    }
    private func isOverdue(_ item: WorkspaceWidgetItem) -> Bool {
        item.isOverdue(at: entry.date)
    }
}

#if DEBUG
private func homeWidgetPreview(_ kind: HomeWidgetKind, family: WidgetFamily) -> HomeWidgetEntry {
    let snapshot = WorkspaceWidgetSnapshot.placeholder
    let items = kind == .deadline ? snapshot.items.filter(\.isDeadline) : snapshot.items
    return HomeWidgetEntry(date: .now, snapshot: snapshot, configuration: .init(), kind: kind,
        family: family, items: Array(items.prefix(kind == .today ? 2 : 1)), page: 0, pageCount: 1,
        pageKey: "preview", totalCount: items.count, isPreview: true)
}
#Preview("工作台 · 中号", as: .systemMedium) {
    WorkspaceTodayWidget()
} timeline: {
    homeWidgetPreview(.today, family: .systemMedium)
}
#Preview("倒计时 · 小号", as: .systemSmall) {
    WorkspaceDeadlineWidget()
} timeline: {
    homeWidgetPreview(.deadline, family: .systemSmall)
}
#Preview("专注 · 中号", as: .systemMedium) {
    WorkspaceFocusWidget()
} timeline: {
    homeWidgetPreview(.focus, family: .systemMedium)
}
#endif
