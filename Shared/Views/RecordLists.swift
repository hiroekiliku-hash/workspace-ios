import SwiftUI
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum WorkspaceColorTheme: String, CaseIterable, Identifiable, Sendable {
    case blue, sage, lilac, rose, sand, graphite, cobalt, emerald, vermilion
    static let preferenceKey = "colorTheme"
    static let vividThemes: [Self] = [.cobalt, .emerald, .vermilion, .lilac, .rose, .sand]
    static let quietThemes: [Self] = [.blue, .sage, .graphite]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blue: WorkspaceLocalization.string("远峰蓝")
        case .sage: WorkspaceLocalization.string("松针绿")
        case .lilac: WorkspaceLocalization.string("紫色")
        case .rose: WorkspaceLocalization.string("玫红")
        case .sand: WorkspaceLocalization.string("橙色")
        case .graphite: WorkspaceLocalization.string("石墨灰")
        case .cobalt: WorkspaceLocalization.string("蓝色")
        case .emerald: WorkspaceLocalization.string("绿色")
        case .vermilion: WorkspaceLocalization.string("红色")
        }
    }
    var assetPrefix: String {
        switch self {
        case .blue: "ThemeBlue"
        case .sage: "ThemeSage"
        case .lilac: "ThemeLilac"
        case .rose: "ThemeRose"
        case .sand: "ThemeSand"
        case .graphite: "ThemeGraphite"
        case .cobalt: "ThemeCobalt"
        case .emerald: "ThemeEmerald"
        case .vermilion: "ThemeVermilion"
        }
    }
    var palette: WorkspacePalette { WorkspacePalette(theme: self) }
}

/// A small value keeps theme changes separate from task data and scroll updates.
struct WorkspacePalette: Equatable, Sendable {
    var theme: WorkspaceColorTheme = .blue
    var accent: Color { Color(theme.assetPrefix) }
    var action: Color { Color(theme.assetPrefix + "Fill") }
    var confirmation: Color { Color(theme.assetPrefix + "Confirmation") }
    var surface: Color { Color(theme.assetPrefix + "Surface") }
}

extension EnvironmentValues {
    @Entry var workspacePalette = WorkspacePalette()
}

extension Color {
    /// Adaptive deep gray keeps completed content readable in either appearance.
    static var workspaceCompleted: Color { Color.primary.opacity(0.62) }
}

extension WorkspaceRecord {
    var kindConversionTarget: ItemKind { kind == .deadline ? .task : .deadline }
    var kindConversionTitle: String {
        WorkspaceLocalization.string("转为") + kindConversionTarget.title + (recurrenceSeriesID == nil ? "" : WorkspaceLocalization.string("（仅此次）"))
    }
}

struct RecordRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let record: WorkspaceRecord
    var showsCountdown = true
    var recurrenceLabel: String?
    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            Image(systemName: record.isFinished ? "checkmark.circle.fill" : record.pinned ? "star.fill" : record.kind.symbol)
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : record.pinned ? Color.orange : record.isOverdue ? Color.red : palette.accent)
                .font(.title3).frame(width: 28)
                .accessibilityLabel(record.pinned ? WorkspaceLocalization.string("星标") : record.kind.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(record.kind == .deadline ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if record.kind == .knowledge {
                    Text(record.category + (record.summary.isEmpty ? "" : " · " + record.summary))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else if hasMetadata {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) { statusAndDate }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) { statusAndDate }
                                VStack(alignment: .leading, spacing: 4) { statusAndDate }
                            }
                        }
                    }.font(.caption).foregroundStyle(record.isOverdue ? .red : .secondary)
                }
                if showsCountdown, record.kind == .deadline, let due = record.dueDate, !record.isFinished {
                    DeadlineCountdownView(target: record.effectiveDueDate(due), isInline: true)
                }
            }
            Spacer(minLength: 4)
        }.padding(.vertical, 4).frame(minHeight: 44)
            .workspaceRecordDragSource(record)
            #if os(iOS)
            // Align every separator with the title, not a nested metadata Label.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 40 }
            #endif
            .accessibilityElement(children: .combine)
            .accessibilityValue(record.kind.completedStatus == nil ? "" : record.isFinished ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未完成"))
    }
    private var hasMetadata: Bool {
        record.isOverdue || record.dueDate != nil || record.remindAt != nil || record.scheduledAt != nil ||
            recurrenceLabel != nil || record.recurrenceSeriesID != nil
    }
    @ViewBuilder private var statusAndDate: some View {
        if record.isOverdue { Text(WorkspaceLocalization.string("已逾期")) }
        if let date = record.dueDate ?? record.remindAt ?? record.scheduledAt { Text(date, format: rowDateStyle) }
        if let recurrenceLabel {
            Label(recurrenceLabel, systemImage: "repeat").lineLimit(1)
        } else if record.recurrenceSeriesID != nil { Image(systemName: "repeat").accessibilityLabel(WorkspaceLocalization.string("重复事项")) }
    }
    private var rowDateStyle: Date.FormatStyle {
        var style: Date.FormatStyle = record.dateOnly && record.dueDate != nil ? .dateTime.month().day() : .dateTime.month().day().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
}
enum RecordSort: String, CaseIterable, Identifiable {
    case standard = "默认", updated = "最近编辑", title = "标题", date = "日期"
    var id: String { rawValue }
}
struct RecordListView: View {
    @Environment(\.workspaceRecordDragSession) private var recordDragSession
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: ItemKind
    var selection: Binding<UUID?>? = nil
    var includedKinds: [ItemKind] = []
    var projectSection: Binding<AppDestination>? = nil
    @State private var keyOnly = false
    @State private var sort = RecordSort.standard
    @State private var query = ""
    @State private var status = "all"
    @State private var category = "all"
    @State private var seriesOnly = true
    @State private var creating = false
    @State private var compactGroups = true
    @State private var ungroupedCollapsed = false
    @State private var ungroupedExpanded = false
    @State private var expandedGroups: Set<UUID> = []
    @State private var collapsedGroups: Set<UUID> = []
    @State private var landscapePreviewGroups: Set<UUID> = []
    @State private var openedGroup: UUID?
    @State private var selectedPreviewID: UUID?
    @State private var addingToGroup: WorkspaceRecord?
    @State private var groupCreationKind: ItemKind = .task
    @State private var convertingRecord: WorkspaceRecord?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var deletionPreview: DeletionPreview?
    #if os(macOS)
    @State private var desktopExpandedGroups: Set<UUID> = []
    @State private var desktopSelectedIDs: Set<UUID> = []
    @State private var desktopTableShowsOwner = false
    #endif
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDetailPane = false
    @State private var wantsDetailPane = false
    @State private var detailPresentationActive = false
    #endif
    init(kind: ItemKind, selection: Binding<UUID?>? = nil, includedKinds: [ItemKind] = [],
         initialSort: RecordSort = .standard, projectSection: Binding<AppDestination>? = nil) {
        self.kind = kind
        self.selection = selection
        self.includedKinds = includedKinds
        self.projectSection = projectSection
        _sort = State(initialValue: initialSort)
    }
    private var usesProjectDesign: Bool {
        #if os(iOS)
        projectSection != nil
        #else
        false
        #endif
    }
    private var rowSelection: Binding<UUID?>? {
        if let selection { return selection }
        #if os(iOS)
        if showsDetailPane {
            return Binding(get: { landscapeRecordID }, set: { selectedPreviewID = $0 })
        }
        #endif
        return nil
    }
    private var landscapeRecordID: UUID? {
        if let selectedPreviewID, let record = store.record(selectedPreviewID), record.isLive { return selectedPreviewID }
        return nil
    }
    private var ungroupedRecords: [WorkspaceRecord] {
        guard kind.isProjectGroup else { return [] }
        #if os(iOS)
        guard usesProjectDesign else { return [] }
        #endif
        let records = (store.actionRecords + store.records(.deadline)).filter {
            $0.projectID == nil && $0.areaID == nil
        }
        let members = RecurringRecordPresentation.representatives(in: records)
        let pending = HomePresentationOrder.pending(members)
        let pendingIDs = Set(pending.map(\.id))
        return pending + members.filter { !$0.isFinished && !pendingIDs.contains($0.id) }
            + members.filter { $0.isFinished }
    }
    private var filtered: [WorkspaceRecord] {
        let source = kind.isProjectGroup ? store.projectGroupRecords + ungroupedRecords : kind.isItem ? store.actionRecords : store.records(kind)
        var values = source.filter { record in
            (!keyOnly || record.pinned) &&
            (status == "all" || StateLabels.title(record.status) == status) && (category == "all" || record.category == category) &&
            (query.isEmpty || "\(record.title) \(record.summary) \(record.body) \(record.tags.joined(separator: " "))".localizedCaseInsensitiveContains(query))
        }
        if kind.isProjectGroup && !isSelecting && !hasFilters {
            let visibleGroupIDs = Set(values.map(\.id))
            values.removeAll { record in
                [record.projectID, record.areaID].compactMap { $0 }.contains(where: visibleGroupIDs.contains)
            }
        }
        if (kind.isItem || kind == .deadline) && seriesOnly {
            values = RecurringRecordPresentation.representatives(in: values)
        }
        if sort != .standard {
            let dates = sort == .date ? Dictionary(uniqueKeysWithValues: values.map { ($0.id, chronologicalDate($0)) }) : [:]
            values.sort { a, b in
                if kind == .knowledge && a.pinned != b.pinned { return a.pinned }
                switch sort {
                case .standard: return false
                case .updated: return a.updatedAt == b.updatedAt ? a.id.uuidString < b.id.uuidString : a.updatedAt > b.updatedAt
                case .title: return a.title == b.title ? a.id.uuidString < b.id.uuidString : a.title.localizedStandardCompare(b.title) == .orderedAscending
                case .date:
                    if kind == .deadline && a.isFinished != b.isFinished { return !a.isFinished }
                    let x = dates[a.id] ?? .distantFuture
                    let y = dates[b.id] ?? .distantFuture
                    if x != y { return x < y }
                    if kind == .deadline && a.pinned != b.pinned { return a.pinned }
                    return a.id.uuidString < b.id.uuidString
                }
            }
        }
        return values
    }
    private func chronologicalDate(_ record: WorkspaceRecord) -> Date {
        let due = record.dueDate.map(record.effectiveDueDate)
        if record.kind.isItem {
            return record.scheduledAt ?? due ?? record.remindAt ?? .distantFuture
        }
        return due ?? record.remindAt ?? record.scheduledAt ?? record.targetDate ?? .distantFuture
    }
    var body: some View {
        let filtered = filtered
        let recurrenceLabels = Dictionary(uniqueKeysWithValues: store.state.series.map { ($0.id, $0.rule.label) })
        responsiveList(filtered, recurrenceLabels: recurrenceLabels)
        .onChange(of: selectableRecordIDs(filtered), initial: true) { _, ids in
            let visibleIDs = Set(ids)
            if let id = selection?.wrappedValue, !visibleIDs.contains(id) { selection?.wrappedValue = nil }
            selectedIDs.formIntersection(visibleIDs)
            #if os(macOS)
            desktopSelectedIDs.formIntersection(visibleIDs)
            if !isSelecting, selection?.wrappedValue == nil {
                selection?.wrappedValue = ids.first(where: desktopSelectedIDs.contains)
            }
            #endif
            if let openedGroup, !visibleIDs.contains(openedGroup) {
                let record = store.record(openedGroup)
                let parentVisible = kind.isProjectGroup && [record?.projectID, record?.areaID].compactMap { $0 }.contains(where: visibleIDs.contains)
                if !parentVisible { self.openedGroup = nil }
            }
            #if os(iOS)
            if !detailPresentationActive {
                let record = selectedPreviewID.flatMap { store.record($0) }
                let parentVisible = kind.isProjectGroup && [record?.projectID, record?.areaID].compactMap { $0 }.contains(where: visibleIDs.contains)
                if selectedPreviewID.map({ visibleIDs.contains($0) }) != true && !parentVisible {
                    // This is selection state: resolve it when the visible collection changes,
                    // rather than refiltering and sorting that collection from every row.
                    selectedPreviewID = filtered.first(where: { !$0.isFinished })?.id ?? filtered.first?.id
                }
            }
            #endif
        }
        .navigationDestination(item: $openedGroup) { id in
            RecordDetailView(id: id, presentationChanged: detailPresentationChanged)
        }
        .navigationTitle(projectSection != nil ? WorkspaceLocalization.string("项目") : kind == .knowledge ? WorkspaceLocalization.string("知识库") : kind.title)
        .workspaceResponsiveTitle()
        .modifier(RecordListSearchModifier(query: $query, usesNativeSearch: projectSection == nil,
            prompt: kind == .knowledge ? WorkspaceLocalization.string("搜索标题、正文和标签") : WorkspaceLocalization.format("搜索%@", String(describing: kind.title))))
        .workspaceSelectionFeedback(trigger: keyOnly)
        .workspaceSelectionFeedback(trigger: sort)
        .workspaceSelectionFeedback(trigger: status)
        .workspaceSelectionFeedback(trigger: seriesOnly)
        .workspaceSelectionFeedback(trigger: category)
        .workspaceSelectionFeedback(trigger: compactGroups)
        .workspaceSelectionFeedback(trigger: isSelecting)
        .workspaceSelectionFeedback(trigger: selectedIDs)
        .workspaceSelectionFeedback(trigger: [collapsedGroups, expandedGroups, landscapePreviewGroups], feedback: .impact(weight: .medium, intensity: 0.9))
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: addingToGroup?.id) { _, value in
            store.hapticsEnabled && value != nil
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: openedGroup) { _, value in store.hapticsEnabled && value != nil }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WorkspaceLocalization.string("退出批量"), systemImage: "xmark") { endSelection() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("records-exit-selection")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(selectedIDs.count == filtered.count && !filtered.isEmpty ? WorkspaceLocalization.string("取消全选") : WorkspaceLocalization.string("全选"),
                           systemImage: selectedIDs.count == filtered.count && !filtered.isEmpty ? "checkmark.circle.fill" : "checkmark.circle") {
                        if selectedIDs.count == filtered.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(filtered.map(\.id)) }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("records-select-all")
                    .disabled(filtered.isEmpty)
                }
            } else {
            ToolbarItem {
                Button(WorkspaceLocalization.string("选择"), systemImage: "checkmark.circle") { isSelecting = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("records-start-selection")
                    .disabled(filtered.isEmpty || store.isReadOnlyWorkspace)
            }
            ToolbarItem { Menu {
                Toggle(WorkspaceLocalization.string("只看星标"), isOn: $keyOnly)
                Picker(WorkspaceLocalization.string("排序"), selection: $sort) { ForEach(RecordSort.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Divider()
                if kind != .knowledge && kind != .area {
                    Picker(WorkspaceLocalization.string("完成情况"), selection: $status) {
                        Text(WorkspaceLocalization.string("全部")).tag("all")
                        Text(WorkspaceLocalization.string("未完成")).tag("未完成")
                        Text(WorkspaceLocalization.string("已完成")).tag("已完成")
                    }
                }
                if kind == .knowledge {
                    Picker(WorkspaceLocalization.string("分类"), selection: $category) {
                        Text(WorkspaceLocalization.string("全部分类")).tag("all")
                        ForEach(Array(Set(store.records(.knowledge).map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                if kind.isItem || kind == .deadline { Toggle(WorkspaceLocalization.string("每组重复显示一条"), isOn: $seriesOnly) }
            } label: { Label(WorkspaceLocalization.string("筛选"), systemImage: "line.3.horizontal.decrease.circle") } }
            ToolbarItem(placement: .primaryAction) {
                if kind == .knowledge {
                    Button(WorkspaceLocalization.string("添加知识笔记"), systemImage: "plus") { store.createKind = .knowledge }
                        .disabled(store.isReadOnlyWorkspace)
                } else {
                    Menu { RecordCreationActions { store.createKind = $0 } }
                    label: { Label(WorkspaceLocalization.string("添加"), systemImage: "plus") }
                    .disabled(store.isReadOnlyWorkspace)
                }
            }
            }
        }
        .sheet(item: $addingToGroup) { group in
            NavigationStack {
                RecordEditorView(kind: groupCreationKind, projectID: group.kind == .project ? group.id : nil,
                                 areaID: group.kind == .area ? group.id : nil)
            }.nativeEditorPresentation()
        }
        .sheet(isPresented: $creating) { NavigationStack { RecordEditorView(kind: kind) }.nativeEditorPresentation() }
        .sheet(item: $convertingRecord) { draft in
            NavigationStack {
                RecordEditorView(kind: draft.kind, record: draft, isKindConversion: true)
            }.nativeEditorPresentation()
        }
        .sheet(item: $deletionPreview) { preview in
            NavigationStack { DeleteReviewView(preview: preview, onDeleted: endSelection) }.nativeSheetSize()
        }
        .refreshable { store.refresh() }
    }
    @ViewBuilder private func responsiveList(_ filtered: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
        #if os(iOS)
        GeometryReader { geometry in
            let masterWidth = showsDetailPane ? min(380, geometry.size.width * 0.44) : geometry.size.width
            HStack(spacing: 0) {
                recordsList(filtered, recurrenceLabels: recurrenceLabels)
                    .contentMargins(.horizontal, showsDetailPane ? 12 : 20, for: .scrollContent)
                    .contentMargins(.top, showsDetailPane || projectSection != nil ? 8 : nil, for: .scrollContent)
                    .frame(width: max(1, masterWidth))
                if showsDetailPane {
                    Divider()
                    Group {
                        if isSelecting {
                            ContentUnavailableView(WorkspaceLocalization.format("已选择 %@ 项", String(describing: selectedIDs.count)), systemImage: "checkmark.circle",
                                description: Text(WorkspaceLocalization.string("在左侧选择记录，使用列表下方的按钮批量处理。")))
                                .accessibilityIdentifier("project-selection-summary")
                        } else if let id = landscapeRecordID {
                            RecordDetailView(id: id, embedded: true, presentationChanged: detailPresentationChanged)
                        } else {
                            ContentUnavailableView(WorkspaceLocalization.string("选择一条记录"), systemImage: "sidebar.right",
                                description: Text(WorkspaceLocalization.string("从左侧选择，直接在这里查看和处理。")))
                        }
                    }
                    .id(landscapeRecordID)
                    .frame(width: max(1, geometry.size.width - masterWidth - 1), height: geometry.size.height)
                    .accessibilityIdentifier("record-browser-detail")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onGeometryChange(for: Bool.self) { geometry in
                selection == nil && geometry.size.width >= 680 && !typeSize.isAccessibilitySize
            } action: { wanted in
                wantsDetailPane = wanted
                // Keep a presented editor alive; resizing must not discard its draft.
                if !detailPresentationActive { showsDetailPane = wanted }
            }
            .onChange(of: landscapeRecordID) { _, _ in
                detailPresentationActive = false
                showsDetailPane = wantsDetailPane
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        #else
        recordsList(filtered, recurrenceLabels: recurrenceLabels)
        #endif
    }
    private func detailPresentationChanged(_ active: Bool) {
        #if os(iOS)
        if active && showsDetailPane && selectedPreviewID == nil {
            selectedPreviewID = landscapeRecordID
        }
        detailPresentationActive = active
        if !active {
            showsDetailPane = wantsDetailPane
            if landscapeRecordID == nil {
                let values = filtered
                selectedPreviewID = values.first(where: { !$0.isFinished })?.id ?? values.first?.id
            }
        }
        #endif
    }
    private func recordsList(_ filtered: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
        selectableRecordsList(filtered, recurrenceLabels: recurrenceLabels)
        .overlay {
            if filtered.isEmpty && showsEmptyRecordsOverlay {
                ContentUnavailableView {
                    Label(hasFilters ? WorkspaceLocalization.string("没有匹配的记录") : WorkspaceLocalization.format("还没有%@", String(describing: kind.title)), systemImage: hasFilters ? "magnifyingglass" : kind.symbol)
                } description: {
                    Text(hasFilters ? WorkspaceLocalization.string("调整搜索或清除筛选后再试。") : WorkspaceLocalization.string("创建第一条记录，开始安排工作空间。"))
                } actions: {
                    if hasFilters { Button(WorkspaceLocalization.string("清除筛选")) { clearFilters() } }
                    else {
                        Button(WorkspaceLocalization.format("新建%@", String(describing: kind.title)), systemImage: "plus") { creating = true }
                            .disabled(store.isReadOnlyWorkspace)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if hasFilters {
                HStack { Label(WorkspaceLocalization.string("已应用筛选"), systemImage: "line.3.horizontal.decrease.circle"); Spacer(); Button(WorkspaceLocalization.string("清除")) { clearFilters() } }
                    .font(.caption).padding(8).background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(WorkspaceLocalization.format("已选 %@ / %@ 项", String(describing: selectedIDs.count), String(describing: filtered.count))).font(.subheadline.weight(.medium))
                        Spacer()
                        Button(WorkspaceLocalization.string("删除所选"), systemImage: "trash", role: .destructive) {
                            store.perform { deletionPreview = try store.deletionPreview(selectedIDs) }
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(selectedIDs.isEmpty || store.isReadOnlyWorkspace)
                    }
                    if filtered.contains(where: { selectedIDs.contains($0.id) && $0.recurrenceSeriesID != nil }) {
                        Text(WorkspaceLocalization.string("下一步可选择删除这一次、后续重复或整个系列。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
    }
    private var showsEmptyRecordsOverlay: Bool {
        #if os(macOS)
        if selection != nil && kind.isProjectGroup { return hasFilters }
        #endif
        return !usesProjectDesign || !kind.isProjectGroup || hasFilters
    }
    @ViewBuilder private func selectableRecordsList(_ filtered: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
        #if os(iOS)
        if usesProjectDesign {
            List {
                if let projectSection {
                    ProjectListControls(section: projectSection, query: $query, prompt: WorkspaceLocalization.format("搜索%@", String(describing: kind.title)))
                        .disabled(isSelecting)
                        .padding(.horizontal, -8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                recordRows(filtered, recurrenceLabels: recurrenceLabels)
            }
                .listStyle(.plain)
                .listRowSpacing(0)
                .contentMargins(.bottom, 20, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 44)
                .scrollContentBackground(.hidden)
        } else {
            List { recordRows(filtered, recurrenceLabels: recurrenceLabels) }
        }
        #else
        if selection != nil {
            desktopRecordsBrowser(filtered, recurrenceLabels: recurrenceLabels)
        } else {
            List { recordRows(filtered, recurrenceLabels: recurrenceLabels) }
        }
        #endif
    }
    private func selectableRecordIDs(_ records: [WorkspaceRecord]) -> [UUID] {
        #if os(macOS)
        if kind.isProjectGroup {
            // Keep a selected member in the inspector while its folder is collapsed.
            var ids = Set(records.map(\.id))
            var groups = records.filter { $0.kind.isProjectGroup }
            var visited: Set<UUID> = []
            while let group = groups.popLast() {
                guard visited.insert(group.id).inserted else { continue }
                let members = store.members(of: group)
                ids.formUnion(members.map(\.id))
                groups += members.filter { $0.kind.isProjectGroup }
            }
            return ids.sorted { $0.uuidString < $1.uuidString }
        }
        #endif
        return records.map(\.id)
    }
    #if os(macOS)
    private var desktopTableSelection: Binding<Set<UUID>> {
        Binding {
            if isSelecting { return selectedIDs }
            return desktopSelectedIDs
        } set: { ids in
            let valid = Set(ids.filter { store.record($0) != nil })
            if isSelecting {
                selectedIDs = valid
            } else {
                let added = valid.subtracting(desktopSelectedIDs)
                desktopSelectedIDs = valid
                // Keep native Command/Shift selection intact. The inspector is
                // only a primary selection, not the source of the Table's Set.
                if added.count == 1 { selection?.wrappedValue = added.first }
                else if let current = selection?.wrappedValue, valid.contains(current) { return }
                else { selection?.wrappedValue = valid.min { $0.uuidString < $1.uuidString } }
            }
        }
    }
    private func desktopEntries(_ records: [WorkspaceRecord]) -> [DesktopRecordEntry] {
        guard kind.isProjectGroup && !isSelecting else {
            return records.map { desktopEntry($0) }
        }
        var entries: [DesktopRecordEntry] = []
        var inserted: Set<UUID> = []
        func append(_ record: WorkspaceRecord, depth: Int = 0, owner: String? = nil) {
            guard inserted.insert(record.id).inserted else { return }
            if record.kind.isProjectGroup {
                let members = compactGroupMembers(record)
                entries.append(desktopEntry(record, depth: depth, owner: owner, members: members))
                if desktopExpandedGroups.contains(record.id) {
                    for member in members { append(member, depth: depth + 1, owner: record.title) }
                }
            } else {
                entries.append(desktopEntry(record, depth: depth, owner: owner))
            }
        }
        for group in records where group.kind.isProjectGroup { append(group) }
        let ungrouped = records.filter { !$0.kind.isProjectGroup }
        if !ungrouped.isEmpty || !hasFilters {
            entries.append(DesktopRecordEntry(record: nil, owner: "", depth: 0,
                total: ungrouped.count, completed: ungrouped.filter(\.isFinished).count, date: nil))
            if !ungroupedCollapsed {
                entries += ungrouped.filter { inserted.insert($0.id).inserted }.map { desktopEntry($0, depth: 1) }
            }
        }
        return entries
    }
    private func desktopEntry(_ record: WorkspaceRecord, depth: Int = 0, owner: String? = nil,
                              members: [WorkspaceRecord] = []) -> DesktopRecordEntry {
        let ownerTitle = owner ?? [record.projectID, record.areaID].compactMap { $0 }
            .compactMap { store.record($0)?.title }.joined(separator: " · ")
        let date = chronologicalDate(record)
        return DesktopRecordEntry(record: record, owner: ownerTitle, depth: depth,
            total: members.count, completed: members.filter(\.isFinished).count,
            date: date == .distantFuture ? nil : date)
    }
    private func desktopRecordsBrowser(_ records: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
        let entries = desktopEntries(records)
        let dragSession = recordDragSession
        let workspace = store
        let allowsDrag = !isSelecting && !store.isReadOnlyWorkspace
        let animateDrag = !reduceMotion
        let groups = records.filter { $0.kind.isProjectGroup }
        let groupIDs = Set(selectableRecordIDs(records).filter { store.record($0)?.kind.isProjectGroup == true })
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.isProjectGroup ? WorkspaceLocalization.string("项目目录") : kind == .deadline ? WorkspaceLocalization.string("截止安排") : kind == .knowledge ? WorkspaceLocalization.string("知识库") : WorkspaceLocalization.string("工作清单"))
                        .font(.headline)
                    Text(kind.isProjectGroup ? WorkspaceLocalization.format("%@ 个项目组 · %@ 项未归组", String(describing: groups.count), String(describing: records.filter { !$0.kind.isProjectGroup }.count)) :
                        WorkspaceLocalization.format("%@ 项 · %@ 项未完成", String(describing: records.count), String(describing: records.filter { !$0.isFinished }.count)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if kind.isProjectGroup && !isSelecting {
                    let allExpanded = !groupIDs.isEmpty && groupIDs.isSubset(of: desktopExpandedGroups)
                    Button(allExpanded ? WorkspaceLocalization.string("收起全部") : WorkspaceLocalization.string("展开全部"), systemImage: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                        desktopExpandedGroups = allExpanded ? [] : groupIDs
                        ungroupedCollapsed = allExpanded
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help(allExpanded ? WorkspaceLocalization.string("收起所有项目组") : WorkspaceLocalization.string("展开所有项目组的成员"))
                }
                Picker(WorkspaceLocalization.string("排序"), selection: $sort) {
                    ForEach(RecordSort.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .labelsHidden().frame(width: 104).help(WorkspaceLocalization.string("排序方式"))
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(palette.surface.opacity(0.5))
            Divider()
            Group {
                if #available(macOS 14.4, *) {
                    desktopAdaptiveTable(entries, recurrenceLabels: recurrenceLabels)
                } else {
                    Table(of: DesktopRecordEntry.self, selection: desktopTableSelection) {
                        TableColumn(WorkspaceLocalization.string("标题")) { entry in
                            desktopTitle(entry, recurrenceLabel: entry.record?.recurrenceSeriesID.flatMap { recurrenceLabels[$0] })
                        }.width(min: 200, ideal: 280)
                        TableColumn(WorkspaceLocalization.string("时间")) { entry in
                            desktopDate(entry)
                        }.width(min: 100, ideal: 132, max: 160)
                    } rows: {
                        ForEach(entries) { entry in
                            TableRow(entry)
                                .itemProvider { desktopDragProvider(entry, workspace: workspace, session: dragSession, enabled: allowsDrag) }
                                .dropDestination(for: WorkspaceRecordDragPayload.self) { items in
                                    desktopReceiveDrop(items, at: entry, workspace: workspace, session: dragSession, animate: animateDrag)
                                }
                        }
                    }
                }
            }
            .tableStyle(.inset)
            .onGeometryChange(for: Bool.self) { geometry in
                if #available(macOS 14.4, *) { return geometry.size.width >= 680 }
                return false
            } action: { desktopTableShowsOwner = $0 }
            .contextMenu(forSelectionType: UUID.self) { ids in
                let records = ids.compactMap { store.record($0) }
                if records.count == 1, let record = records.first {
                    desktopRecordActions(record)
                } else if !records.isEmpty {
                    Button(WorkspaceLocalization.format("删除 %@ 项", String(describing: records.count)), systemImage: "trash", role: .destructive) {
                        store.perform { deletionPreview = try store.deletionPreview(Set(records.map(\.id))) }
                    }.disabled(store.isReadOnlyWorkspace)
                } else {
                    Button(WorkspaceLocalization.format("新建%@", String(describing: kind.title)), systemImage: "plus") { creating = true }
                        .disabled(store.isReadOnlyWorkspace)
                }
            } primaryAction: { ids in
                if !isSelecting, ids.count == 1, let id = ids.first, store.record(id) != nil {
                    selection?.wrappedValue = id
                    store.openedRecordID = id
                }
            }
            .onDeleteCommand {
                let ids = desktopTableSelection.wrappedValue
                guard !ids.isEmpty, !store.isReadOnlyWorkspace else { return }
                store.perform { deletionPreview = try store.deletionPreview(ids) }
            }
            .accessibilityIdentifier("desktop-records-table")
            #if DEBUG
            .onAppear { print("WORKSPACE_RECORD_TABLE_DRAG session=\(dragSession != nil) enabled=\(allowsDrag)") }
            #endif
        }
    }
    // Conditional table columns became available in macOS 14.4. Earlier
    // systems keep a two-column table with project context inside the title.
    @available(macOS 14.4, *)
    private func desktopAdaptiveTable(_ entries: [DesktopRecordEntry], recurrenceLabels: [UUID: String]) -> some View {
        let dragSession = recordDragSession
        let workspace = store
        let allowsDrag = !isSelecting && !store.isReadOnlyWorkspace
        let animateDrag = !reduceMotion
        return Table(of: DesktopRecordEntry.self, selection: desktopTableSelection) {
                TableColumn(WorkspaceLocalization.string("标题")) { entry in
                    desktopTitle(entry, recurrenceLabel: entry.record?.recurrenceSeriesID.flatMap { recurrenceLabels[$0] })
                }.width(min: 200, ideal: 280)
                if desktopTableShowsOwner {
                TableColumn(kind.isProjectGroup ? WorkspaceLocalization.string("成员 / 所属项目") : WorkspaceLocalization.string("所属项目")) { entry in
                    if entry.isGroup {
                        HStack(spacing: 6) {
                            Text("\(entry.completed) / \(entry.total)").monospacedDigit()
                            if entry.total > 0 {
                                ProgressView(value: Double(entry.completed), total: Double(entry.total))
                                    .frame(maxWidth: 70).tint(palette.accent)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .help(WorkspaceLocalization.format("%@ 项内容，已完成 %@ 项", String(describing: entry.total), String(describing: entry.completed)))
                    } else {
                        Text(entry.owner.isEmpty ? "—" : entry.owner)
                            .foregroundStyle(.secondary).lineLimit(1).help(entry.owner)
                    }
                }.width(min: 90, ideal: 130, max: 220)
                }
                TableColumn(WorkspaceLocalization.string("时间")) { entry in
                    desktopDate(entry)
                }.width(min: 100, ideal: 132, max: 160)
            } rows: {
                ForEach(entries) { entry in
                            TableRow(entry)
                                .itemProvider { desktopDragProvider(entry, workspace: workspace, session: dragSession, enabled: allowsDrag) }
                                .dropDestination(for: WorkspaceRecordDragPayload.self) { items in
                                    desktopReceiveDrop(items, at: entry, workspace: workspace, session: dragSession, animate: animateDrag)
                                }
                        }
            }
    }
    private func desktopDragProvider(_ entry: DesktopRecordEntry, workspace store: WorkspaceStore,
                                     session: WorkspaceRecordDragSession?, enabled: Bool) -> NSItemProvider? {
        #if DEBUG
        print("WORKSPACE_RECORD_PROVIDER requested kind=\(String(describing: entry.record?.kind)) enabled=\(enabled) session=\(session != nil)")
        #endif
        guard enabled, let session, let record = entry.record,
              record.kind.isItem || record.kind == .deadline, !store.isReadOnlyWorkspace else { return nil }
        let payload = session.begin(record, in: store)
        let data = Data(payload.token.uuidString.utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: WorkspaceRecordDragPayload.contentType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
    private func desktopReceiveDrop(_ items: [WorkspaceRecordDragPayload], at entry: DesktopRecordEntry,
                                    workspace store: WorkspaceStore, session: WorkspaceRecordDragSession?, animate: Bool) {
        #if DEBUG
        print("WORKSPACE_RECORD_ROW_DROP payloads=\(items.count) matched=\(items.first?.token == session?.token)")
        #endif
        guard let session, let payload = items.first, payload.token == session.token,
              let id = session.recordID else { return }
        let target = entry.isGroup ? entry.record?.id : entry.record?.projectID ?? entry.record?.areaID
        guard session.canMove(in: store, to: target) else { return }
        store.perform {
            let changed = try withAnimation(WorkspaceDragMotion.reorder(reduceMotion: !animate)) {
                try store.moveRecords([id], to: target)
            }
            if changed { session.completeDrop(token: payload.token, to: target, reduceMotion: !animate) }
            else { session.finish() }
        }
        if session.token == payload.token, !session.settling { session.finish() }
    }
    private func desktopTitle(_ entry: DesktopRecordEntry, recurrenceLabel: String?) -> some View {
        let settled = entry.isGroup && recordDragSession?.isSettling(to: entry.record?.id, in: store) == true
        return HStack(spacing: 8) {
            if entry.depth > 0 { Color.clear.frame(width: CGFloat(entry.depth) * 12, height: 1) }
            if entry.isGroup && !isSelecting {
                let expanded = entry.record.map { desktopExpandedGroups.contains($0.id) } ?? !ungroupedCollapsed
                Button {
                    if let id = entry.record?.id {
                        if expanded { desktopExpandedGroups.remove(id) } else { desktopExpandedGroups.insert(id) }
                    } else { ungroupedCollapsed.toggle() }
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(expanded ? WorkspaceLocalization.string("收起成员") : WorkspaceLocalization.string("展开成员"))
                .accessibilityLabel(WorkspaceLocalization.format("%@%@", String(describing: expanded ? WorkspaceLocalization.string("收起") : WorkspaceLocalization.string("展开")), String(describing: entry.record?.title ?? WorkspaceLocalization.string("未归组事项"))))
            } else if entry.depth > 0 {
                Color.clear.frame(width: 18, height: 1)
            }
            if let record = entry.record {
                Image(systemName: record.pinned ? "star.fill" : record.kind.isProjectGroup ? "folder.fill" : record.isFinished ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: record.pinned || record.kind.isProjectGroup || record.isFinished ? 13 : 6))
                    .foregroundStyle(record.pinned ? Color.orange : record.isFinished ? Color.workspaceCompleted : palette.accent)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.system(size: 13, weight: entry.isGroup ? .semibold : .medium))
                        .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                        .lineLimit(1).help(record.title)
                    if let recurrenceLabel {
                        Label(recurrenceLabel, systemImage: "repeat").font(.caption2)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !desktopTableShowsOwner {
                        if entry.isGroup {
                            Text("\(entry.completed) / \(entry.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        } else if !entry.owner.isEmpty {
                            Text(entry.owner).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                Image(systemName: "tray.fill").foregroundStyle(palette.accent).frame(width: 17)
                Text(WorkspaceLocalization.string("未归组事项")).font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceDropHighlight(targeted: false, settled: settled, accent: palette.accent, reduceMotion: reduceMotion))
    }
    @ViewBuilder private func desktopDate(_ entry: DesktopRecordEntry) -> some View {
        if let date = entry.date, let record = entry.record {
            var style: Date.FormatStyle {
                var style: Date.FormatStyle = record.dateOnly && record.dueDate != nil ? .dateTime.month().day() : .dateTime.month().day().hour().minute()
                style.locale = WorkspaceLocalization.locale
                style.timeZone = record.calendar.timeZone
                return style
            }
            Text(date, format: style).monospacedDigit().font(.caption)
                .foregroundStyle(record.isOverdue ? Color.red : Color.secondary)
                .lineLimit(1).help(date.formatted(style))
        } else { Text("—").foregroundStyle(.tertiary) }
    }
    @ViewBuilder private func desktopRecordActions(_ record: WorkspaceRecord) -> some View {
        Button(WorkspaceLocalization.string("查看详情"), systemImage: "sidebar.right") {
            selection?.wrappedValue = record.id
            store.openedRecordID = record.id
        }
        if record.kind.isProjectGroup {
            Menu(WorkspaceLocalization.string("添加内容"), systemImage: "plus") {
                RecordCreationActions(withinGroup: true) { kind in
                    groupCreationKind = kind
                    addingToGroup = record
                }
            }.disabled(store.isReadOnlyWorkspace)
        }
        Divider()
        if let completedStatus = record.kind.completedStatus, record.kind.isItem || record.kind == .deadline {
            Button(record.isFinished ? WorkspaceLocalization.string("标为未完成") : WorkspaceLocalization.string("完成"), systemImage: record.isFinished ? "arrow.counterclockwise" : "checkmark") {
                store.perform { try store.setStatus(record.id, record.isFinished ? record.kind.incompleteStatus : completedStatus) }
            }.disabled(store.isReadOnlyWorkspace)
        }
        Button(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"), systemImage: record.pinned ? "star.slash" : "star") {
            store.perform { try store.toggleKeyItem(record.id) }
        }.disabled(store.isReadOnlyWorkspace)
        if record.kind.isItem || record.kind == .deadline {
            Button(record.kindConversionTitle, systemImage: record.kindConversionTarget.symbol) { requestKindConversion(record) }
                .disabled(store.isReadOnlyWorkspace)
        }
        Divider()
        Button(WorkspaceLocalization.string("归档"), systemImage: "archivebox") { store.perform { try store.archive(record.id) } }
            .disabled(store.isReadOnlyWorkspace)
        Button(WorkspaceLocalization.string("删除"), systemImage: "trash", role: .destructive) {
            store.perform { deletionPreview = try store.deletionPreview(record.id) }
        }.disabled(store.isReadOnlyWorkspace)
    }
    #endif
    @ViewBuilder private func recordRows(_ filtered: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
            if isSelecting {
                ForEach(filtered) { record in
                    selectionRow(record, recurrenceLabel: record.recurrenceSeriesID.flatMap { recurrenceLabels[$0] })
                }
            } else if kind.isProjectGroup && compactGroups {
                compactProjectSections(filtered.filter { $0.kind.isProjectGroup }, recurrenceLabels: recurrenceLabels)
            } else if kind.isProjectGroup {
                // Keep the original layout available while trying the compact version.
                ForEach(filtered.filter { $0.kind.isProjectGroup }) { group in
                    let members = RecurringRecordPresentation.representatives(in: store.members(of: group))
                    Section {
                        recordCell(group, asProjectHeader: true)
                            .listRowBackground(projectGroupHeaderBackground)
                        if members.isEmpty {
                            Text(WorkspaceLocalization.string("暂无内容"))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(members.prefix(5)) { member in
                                recordCell(member, showsCountdown: false,
                                           recurrenceLabel: member.recurrenceSeriesID.flatMap { recurrenceLabels[$0] })
                                    .padding(.leading, 8)
                            }
                            if members.count > 5 {
                                projectGroupMoreLink(group, count: members.count)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            } else {
                ForEach(filtered) { record in
                    recordCell(record, recurrenceLabel: record.recurrenceSeriesID.flatMap { recurrenceLabels[$0] })
                }
            }
            #if os(iOS)
            if usesProjectDesign && kind.isProjectGroup && !isSelecting {
                let ungrouped = filtered.filter { !$0.kind.isProjectGroup }
                if !ungrouped.isEmpty || !hasFilters {
                    ungroupedProjectSection(ungrouped, recurrenceLabels: recurrenceLabels)
                }
            }
            #endif
    }
    @ViewBuilder private func compactProjectSections(_ groups: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
        #if os(iOS)
        if usesProjectDesign {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                projectDirectorySection(group, index: index + 1, recurrenceLabels: recurrenceLabels)
            }
        } else {
            legacyCompactProjectSections(groups, recurrenceLabels: recurrenceLabels)
        }
        #else
        legacyCompactProjectSections(groups, recurrenceLabels: recurrenceLabels)
        #endif
    }
    private func legacyCompactProjectSections(_ filtered: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
                ForEach(filtered) { group in
                    let collapsed = isGroupCollapsed(group.id)
                    let members = collapsed ? [] : compactGroupMembers(group)
                    let expanded = expandedGroups.contains(group.id)
                    let preview = Array(members.lazy.filter { !$0.isFinished }.prefix(5))
                    Section {
                        HStack(spacing: 0) {
                            projectGroupTitleLink(group)
                            groupCreationMenu(group)
                                .frame(width: 44, height: 52)
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                    expandedGroups.remove(group.id)
                                    toggleGroupPreview(group.id, collapsed: collapsed)
                                }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(WorkspaceLocalization.format("%@%@", String(describing: collapsed ? WorkspaceLocalization.string("展开") : WorkspaceLocalization.string("收起")), String(describing: group.title)))
                            .accessibilityValue(collapsed ? WorkspaceLocalization.string("已收起") : WorkspaceLocalization.string("已展开"))
                        }
                        .overlay(alignment: .leading) {
                            if isActiveGroup(group) {
                                Capsule().fill(palette.accent).frame(width: 3).padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(projectGroupHeaderBackground)
                        .tint(projectGroupControlTint)
                        .workspaceRecordGroupDropTarget(group.id)
                        .listRowSeparator(.hidden)
                        if !collapsed {
                            if members.isEmpty {
                                Text(WorkspaceLocalization.string("暂无事项"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                if !expanded && preview.isEmpty {
                                    Text(WorkspaceLocalization.string("暂无未完成事项")).font(.subheadline).foregroundStyle(.secondary)
                                }
                                ForEach(expanded ? members : preview) { member in
                                    recordCell(member, showsCountdown: false, compact: true,
                                               recurrenceLabel: member.recurrenceSeriesID.flatMap { recurrenceLabels[$0] })
                                }
                                if members.count > preview.count {
                                    Button {
                                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                            if expanded { expandedGroups.remove(group.id) }
                                            else { expandedGroups.insert(group.id) }
                                        }
                                    } label: {
                                        HStack {
                                            Text(expanded ? WorkspaceLocalization.string("收起更多事项") : preview.isEmpty ? WorkspaceLocalization.format("查看 %@ 项已完成事项", String(describing: members.count)) : WorkspaceLocalization.format("展开其余 %@ 项", String(describing: members.count - preview.count)))
                                            Spacer()
                                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                        }.font(.subheadline.weight(.semibold))
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
    }
    #if os(iOS)
    private func ungroupedProjectSection(_ members: [WorkspaceRecord], recurrenceLabels: [UUID: String]) -> some View {
        let preview = Array(members.lazy.filter { !$0.isFinished }.prefix(5))
        let displayed = ungroupedExpanded ? members : preview
        let hasMore = members.count > preview.count
        return Section {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    ungroupedCollapsed.toggle()
                    ungroupedExpanded = false
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray").foregroundStyle(palette.accent)
                    Text(WorkspaceLocalization.string("未归组事项")).font(.title3.bold()).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .rotationEffect(.degrees(ungroupedCollapsed ? 0 : 90))
                        .foregroundStyle(palette.accent)
                        .frame(width: 44, height: 48)
                }
                .padding(.leading, 18).padding(.trailing, 6)
                .padding(.top, 24).padding(.bottom, 8)
                .background(ProjectFolderCover().fill(palette.accent.opacity(colorScheme == .dark ? 0.22 : 0.15)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WorkspaceLocalization.string("未归组事项"))
            .accessibilityValue(ungroupedCollapsed ? WorkspaceLocalization.string("已收起") : WorkspaceLocalization.string("已展开"))
            .accessibilityHint(WorkspaceLocalization.string("点按展开或收起"))
            .accessibilityIdentifier("ungrouped-projects-heading")
            .workspaceRecordGroupDropTarget(nil)
            .padding(.top, 20).padding(.bottom, ungroupedCollapsed ? 0 : 6)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .workspaceSelectionFeedback(trigger: ungroupedCollapsed)
            if !ungroupedCollapsed {
                if displayed.isEmpty {
                    Text(members.isEmpty ? WorkspaceLocalization.string("暂无未归组事项") : WorkspaceLocalization.string("暂无未完成事项"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .listRowBackground(ProjectPaperBackground(starts: true, ends: !hasMore, selected: false))
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { position, record in
                        recordCell(record, showsCountdown: false, compact: true,
                            recurrenceLabel: record.recurrenceSeriesID.flatMap { recurrenceLabels[$0] },
                            startsPaper: position == 0, endsPaper: position == displayed.count - 1 && !hasMore)
                    }
                }
                if hasMore {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { ungroupedExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            Text(ungroupedExpanded ? WorkspaceLocalization.string("收起更多") : preview.isEmpty ? WorkspaceLocalization.format("已完成 %@ 项", String(describing: members.count)) : WorkspaceLocalization.format("其余 %@ 项", String(describing: members.count - preview.count)))
                            Image(systemName: ungroupedExpanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 16))
                    .listRowBackground(ProjectPaperBackground(starts: false, ends: true, selected: false))
                    .listRowSeparator(.hidden)
                    .workspaceSelectionFeedback(trigger: ungroupedExpanded)
                }
            }
        }.listSectionSeparator(.hidden)
    }
    private func projectDirectorySection(_ group: WorkspaceRecord, index: Int, recurrenceLabels: [UUID: String]) -> some View {
        let collapsed = isGroupCollapsed(group.id)
        let members = collapsed ? [] : compactGroupMembers(group)
        let expanded = expandedGroups.contains(group.id)
        let preview = Array(members.lazy.filter { !$0.isFinished }.prefix(5))
        let displayed = expanded ? members : preview
        let hasMore = members.count > preview.count
        return Section {
            projectDirectoryHeading(group, index: index, collapsed: collapsed)
                .padding(.top, index == 1 ? 6 : 20)
                .padding(.bottom, collapsed ? 0 : 6)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if !collapsed {
                if members.isEmpty {
                    Text(WorkspaceLocalization.string("暂无事项")).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .listRowBackground(ProjectPaperBackground(starts: true, ends: true, selected: false))
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { position, member in
                        recordCell(member, showsCountdown: false, compact: true,
                                   recurrenceLabel: member.recurrenceSeriesID.flatMap { recurrenceLabels[$0] },
                                   startsPaper: position == 0, endsPaper: position == displayed.count - 1 && !hasMore)
                    }
                    if hasMore {
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                if expanded { expandedGroups.remove(group.id) }
                                else { expandedGroups.insert(group.id) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                Text(expanded ? WorkspaceLocalization.string("收起更多") : preview.isEmpty ? WorkspaceLocalization.format("已完成 %@ 项", String(describing: members.count)) : WorkspaceLocalization.format("其余 %@ 项", String(describing: members.count - preview.count)))
                                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 16))
                        .listRowBackground(ProjectPaperBackground(starts: displayed.isEmpty, ends: true, selected: false))
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listSectionSeparator(.hidden)
    }
    private func projectDirectoryHeading(_ group: WorkspaceRecord, index: Int, collapsed: Bool) -> some View {
        HStack(spacing: 0) {
            Button { openProjectRecord(group.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if group.pinned {
                        Image(systemName: "star.fill").font(.subheadline)
                            .foregroundStyle(group.isFinished ? Color.workspaceCompleted : Color.orange)
                            .accessibilityLabel(WorkspaceLocalization.string("星标"))
                    }
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(group.isFinished ? Color.workspaceCompleted : Color.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityValue(group.isFinished ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未完成"))
            .accessibilityAddTraits(isActiveGroup(group) ? .isSelected : [])
            groupCreationMenu(group)
                .frame(width: 44, height: 48)
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    expandedGroups.remove(group.id)
                    toggleGroupPreview(group.id, collapsed: collapsed)
                }
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel(WorkspaceLocalization.format("%@%@", String(describing: collapsed ? WorkspaceLocalization.string("展开") : WorkspaceLocalization.string("收起")), String(describing: group.title)))
            .accessibilityValue(collapsed ? WorkspaceLocalization.string("已收起") : WorkspaceLocalization.string("已展开"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .background {
            ProjectFolderCover()
                .fill(palette.accent.opacity(isActiveGroup(group) ? 0.28 : colorScheme == .dark ? 0.22 : 0.15))
        }
        .overlay {
            ProjectFolderCover().stroke(palette.accent.opacity(isActiveGroup(group) ? 0.65 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Text(index, format: .number.precision(.integerLength(2...)))
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(palette.accent)
                .padding(.leading, 20).padding(.top, 5)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("project-directory-heading")
        .workspaceRecordGroupDropTarget(group.id)
    }
    #endif
    private func groupCreationMenu(_ group: WorkspaceRecord) -> some View {
        Menu {
            RecordCreationActions(withinGroup: true) { kind in
                groupCreationKind = kind
                addingToGroup = group
            }
        } label: {
            Label(WorkspaceLocalization.string("添加内容"), systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(store.isReadOnlyWorkspace)
        .accessibilityLabel(WorkspaceLocalization.format("向%@添加内容", String(describing: group.title)))
    }
    private func openProjectRecord(_ id: UUID) {
        if let selection = rowSelection { selection.wrappedValue = id }
        else { openedGroup = id }
    }
    private func isActiveGroup(_ group: WorkspaceRecord) -> Bool {
        guard let selected = rowSelection?.wrappedValue else { return false }
        if selected == group.id { return true }
        guard let record = store.record(selected) else { return false }
        return record.projectID == group.id || record.areaID == group.id
    }
    private func isGroupCollapsed(_ id: UUID) -> Bool {
        #if os(iOS)
        // The landscape browser starts as a directory; previews remain one tap away.
        if showsDetailPane { return !landscapePreviewGroups.contains(id) }
        #endif
        return collapsedGroups.contains(id)
    }
    private func toggleGroupPreview(_ id: UUID, collapsed: Bool) {
        #if os(iOS)
        if showsDetailPane {
            if collapsed { landscapePreviewGroups.insert(id) }
            else { landscapePreviewGroups.remove(id) }
            return
        }
        #endif
        if collapsed { collapsedGroups.remove(id) }
        else { collapsedGroups.insert(id) }
    }
    private func compactGroupMembers(_ group: WorkspaceRecord) -> [WorkspaceRecord] {
        let members = RecurringRecordPresentation.representatives(in: store.members(of: group))
        let pending = HomePresentationOrder.pending(members)
        let pendingIDs = Set(pending.map(\.id))
        return pending + members.filter { !$0.isFinished && !pendingIDs.contains($0.id) }
            + members.filter { $0.isFinished }
    }
    private var projectGroupHeaderBackground: Color {
        palette.surface
    }
    private var projectGroupControlTint: Color {
        palette.accent
    }
    private func projectGroupTitleLink(_ group: WorkspaceRecord) -> some View {
        Button {
            if let selection = rowSelection { selection.wrappedValue = group.id }
            else { openedGroup = group.id }
        } label: {
            ProjectGroupCardHeader(record: group)
                .padding(.leading, 16)
                .padding(.vertical, 6)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isActiveGroup(group) ? .isSelected : [])
    }
    private var hasFilters: Bool { keyOnly || !query.isEmpty || status != "all" || category != "all" || !seriesOnly }
    private func clearFilters() { keyOnly = false; query = ""; status = "all"; category = "all"; seriesOnly = true }
    private func endSelection() { isSelecting = false; selectedIDs.removeAll() }
    private func selectionRow(_ record: WorkspaceRecord, recurrenceLabel: String?) -> some View {
        Button {
            if selectedIDs.contains(record.id) { selectedIDs.remove(record.id) }
            else { selectedIDs.insert(record.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(selectedIDs.contains(record.id) ? palette.accent : Color.secondary)
                    .accessibilityHidden(true)
                if record.kind.isProjectGroup { ProjectGroupCardHeader(record: record) }
                else { RecordRow(record: record, showsCountdown: false, recurrenceLabel: recurrenceLabel) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selectedIDs.contains(record.id) ? WorkspaceLocalization.string("已选择") : WorkspaceLocalization.string("未选择"))
        .accessibilityAddTraits(selectedIDs.contains(record.id) ? .isSelected : [])
    }
    private func recordCell(_ record: WorkspaceRecord, showsCountdown: Bool = true, asProjectHeader: Bool = false,
                            compact: Bool = false, recurrenceLabel: String? = nil,
                            startsPaper: Bool = false, endsPaper: Bool = false) -> some View {
        recordLink(record, showsCountdown: showsCountdown, asProjectHeader: asProjectHeader,
                   compact: compact, recurrenceLabel: recurrenceLabel)
            .workspaceRecordDragSource(record, enabled: usesProjectDesign || compact)
            .workspaceRecordGroupDropTarget(record.id, enabled: record.kind.isProjectGroup)
            .tag(record.id)
            #if os(iOS)
            .accessibilityAddTraits(rowSelection?.wrappedValue == record.id ? .isSelected : [])
            .modifier(ProjectEditorialRowStyle(enabled: usesProjectDesign, compact: compact,
                selected: rowSelection?.wrappedValue == record.id, starts: startsPaper, ends: endsPaper))
            #endif
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"), systemImage: record.pinned ? "star.slash" : "star") {
                    store.perform { try store.toggleKeyItem(record.id) }
                }.tint(.orange).disabled(store.isReadOnlyWorkspace)
                if record.kind.isItem || record.kind == .deadline {
                    Button(record.kindConversionTitle, systemImage: record.kindConversionTarget.symbol) {
                        requestKindConversion(record)
                    }.tint(palette.accent).disabled(store.isReadOnlyWorkspace)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let completedStatus = record.kind.completedStatus, record.kind.isItem || record.kind == .deadline {
                    Button(record.isFinished ? WorkspaceLocalization.string("标为未完成") : WorkspaceLocalization.string("完成"), systemImage: record.isFinished ? "arrow.counterclockwise" : "checkmark") {
                        store.perform { try store.setStatus(record.id, record.isFinished ? record.kind.incompleteStatus : completedStatus) }
                    }.tint(.workspaceCompleted).disabled(store.isReadOnlyWorkspace)
                }
                Button(WorkspaceLocalization.string("归档"), systemImage: "archivebox") { store.perform { try store.archive(record.id) } }
                    .tint(.orange).disabled(store.isReadOnlyWorkspace)
                Button(WorkspaceLocalization.string("删除"), systemImage: "trash", role: .destructive) {
                    store.perform { deletionPreview = try store.deletionPreview(record.id) }
                }.disabled(store.isReadOnlyWorkspace)
            }
            .contextMenu {
                Button(WorkspaceLocalization.string("打开"), systemImage: "arrow.up.forward.app") { store.openedRecordID = record.id }
                Button(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"), systemImage: record.pinned ? "star.slash" : "star") {
                    store.perform { try store.toggleKeyItem(record.id) }
                }.disabled(store.isReadOnlyWorkspace)
                if record.kind.isItem || record.kind == .deadline {
                    Button(record.kindConversionTitle, systemImage: record.kindConversionTarget.symbol) {
                        requestKindConversion(record)
                    }.disabled(store.isReadOnlyWorkspace)
                }
                Button(WorkspaceLocalization.string("归档"), systemImage: "archivebox") { store.perform { try store.archive(record.id) } }
                    .disabled(store.isReadOnlyWorkspace)
                Button(WorkspaceLocalization.string("删除"), systemImage: "trash", role: .destructive) {
                    store.perform { deletionPreview = try store.deletionPreview(record.id) }
                }.disabled(store.isReadOnlyWorkspace)
            }
    }
    private func requestKindConversion(_ record: WorkspaceRecord) {
        store.perform {
            let draft = try WorkspaceLogic.conversionDraft(record, to: record.kindConversionTarget, in: store.state)
            if draft.kind == .deadline && draft.dueDate == nil { convertingRecord = draft }
            else { try store.save(draft, expectedVersion: record.version) }
        }
    }
    @ViewBuilder private func projectGroupMoreLink(_ group: WorkspaceRecord, count: Int) -> some View {
        if let selection = rowSelection {
            Button(WorkspaceLocalization.format("查看全部内容（%@）", String(describing: count))) { selection.wrappedValue = group.id }
                .buttonStyle(.plain).foregroundStyle(palette.accent)
        } else {
            NavigationLink { RecordDetailView(id: group.id) } label: { Text(WorkspaceLocalization.format("查看全部内容（%@）", String(describing: count))).foregroundStyle(palette.accent) }
        }
    }
    @ViewBuilder private func recordLink(_ record: WorkspaceRecord, showsCountdown: Bool, asProjectHeader: Bool,
                                        compact: Bool, recurrenceLabel: String?) -> some View {
        if usesProjectDesign && !asProjectHeader {
            #if os(iOS)
            Button { openProjectRecord(record.id) } label: {
                if record.kind.isProjectGroup {
                    ProjectNestedGroupRow(record: record, memberCount: store.members(of: record).count)
                } else if record.kind == .deadline && !compact {
                    ProjectBrowserDeadlineRow(record: record, recurrenceLabel: recurrenceLabel)
                } else {
                    ProjectBrowserItemRow(record: record, compact: compact, recurrenceLabel: recurrenceLabel)
                }
            }
            .buttonStyle(.plain)
            #endif
        } else if compact {
            if let selection = rowSelection {
                Button { selection.wrappedValue = record.id } label: { CompactProjectMemberRow(record: record, recurrenceLabel: recurrenceLabel) }
                    .buttonStyle(.plain)
            } else {
                NavigationLink { RecordDetailView(id: record.id) } label: { CompactProjectMemberRow(record: record, recurrenceLabel: recurrenceLabel) }
            }
        } else if asProjectHeader {
            if let selection = rowSelection {
                Button { selection.wrappedValue = record.id } label: { ProjectGroupCardHeader(record: record) }.buttonStyle(.plain)
            } else {
                NavigationLink { RecordDetailView(id: record.id) } label: { ProjectGroupCardHeader(record: record) }
            }
        } else if let selection = rowSelection {
            #if os(iOS)
            Button { selection.wrappedValue = record.id } label: {
                RecordRow(record: record, showsCountdown: showsCountdown, recurrenceLabel: recurrenceLabel)
            }.buttonStyle(.plain)
            #else
            RecordRow(record: record, showsCountdown: showsCountdown, recurrenceLabel: recurrenceLabel)
            #endif
        }
        else { NavigationLink { RecordDetailView(id: record.id) } label: { RecordRow(record: record, showsCountdown: showsCountdown, recurrenceLabel: recurrenceLabel) } }
    }

}
#if os(macOS)
/// Presentation rows keep the ungrouped section out of the persisted record model.
private struct DesktopRecordEntry: Identifiable {
    private static let ungroupedID = UUID(uuidString: "599A3E5E-84D8-4B9A-BDA9-9F6B764BE786")!
    let record: WorkspaceRecord?
    let owner: String
    let depth: Int
    let total: Int
    let completed: Int
    let date: Date?
    var id: UUID { record?.id ?? Self.ungroupedID }
    var isGroup: Bool { record?.kind.isProjectGroup ?? true }
}
#endif
private struct RecordListSearchModifier: ViewModifier {
    @Binding var query: String
    let usesNativeSearch: Bool
    let prompt: String
    @ViewBuilder func body(content: Content) -> some View {
        if usesNativeSearch { content.searchable(text: $query, prompt: Text(prompt)) }
        else { content }
    }
}

#if os(iOS)
/// A quiet ink underline gives the directory a clear, compact index.
private struct ProjectListControls: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var section: AppDestination
    @Binding var query: String
    let prompt: String
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if typeSize.isAccessibilitySize { categoryPicker.pickerStyle(.menu) }
                else {
                    HStack(spacing: 0) {
                        categoryButton(WorkspaceLocalization.string("项目组"), destination: .projects)
                        categoryButton(WorkspaceLocalization.string("事项"), destination: .actions)
                        categoryButton(WorkspaceLocalization.string("截止事项"), destination: .deadlines)
                    }
                    .accessibilityIdentifier("projects-content-picker")
                }
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        showsSearch.toggle()
                        if !showsSearch { query = "" }
                    }
                    searchFocused = showsSearch
                } label: {
                    Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(palette.accent)
                .accessibilityLabel(showsSearch ? WorkspaceLocalization.string("关闭搜索") : prompt)
                .accessibilityIdentifier("project-search-toggle")
            }
            if showsSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(prompt, text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused).submitLabel(.search)
                        .accessibilityIdentifier("project-search-field")
                    if !query.isEmpty {
                        Button(WorkspaceLocalization.string("清除搜索"), systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 4)
        .background(Color(uiColor: .systemGroupedBackground))
    }
    private func categoryButton(_ title: String, destination: AppDestination) -> some View {
        Button { section = destination } label: {
            Text(title).font(.subheadline.weight(section == destination ? .bold : .medium))
                .foregroundStyle(section == destination ? Color.primary : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(alignment: .bottom) {
                    Capsule().fill(section == destination ? palette.accent : Color.clear)
                        .frame(width: 24, height: 3).padding(.bottom, 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == destination ? .isSelected : [])
        .accessibilityIdentifier("project-category-" + destination.rawValue)
    }
    private var categoryPicker: some View {
        Picker(WorkspaceLocalization.string("项目内容"), selection: $section) {
            Text(WorkspaceLocalization.string("项目组")).tag(AppDestination.projects)
            Text(WorkspaceLocalization.string("事项")).tag(AppDestination.actions)
            Text(WorkspaceLocalization.string("截止事项")).tag(AppDestination.deadlines)
        }
        .accessibilityIdentifier("projects-content-picker")
    }
}

/// The raised tab is part of the folder contour rather than another badge.
private struct ProjectFolderCover: Shape {
    func path(in rect: CGRect) -> Path {
        let tab: CGFloat = 22
        let radius: CGFloat = 18
        let shoulder = min(100, rect.width * 0.32)
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: shoulder - 18, y: 0))
        path.addQuadCurve(to: CGPoint(x: shoulder - 10, y: 5), control: CGPoint(x: shoulder - 13, y: 0))
        path.addLine(to: CGPoint(x: shoulder + 1, y: tab - 5))
        path.addQuadCurve(to: CGPoint(x: shoulder + 10, y: tab), control: CGPoint(x: shoulder + 5, y: tab))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: tab))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: tab + radius), control: CGPoint(x: rect.maxX, y: tab))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - radius), control: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return path
    }
}

/// Keep the paper surface at the row's owning modifier so List cannot replace it.
private struct ProjectEditorialRowStyle: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let enabled: Bool
    let compact: Bool
    let selected: Bool
    let starts: Bool
    let ends: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .listRowBackground(rowBackground)
                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                .listRowSeparator(.hidden)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                        .padding(.leading, compact ? 24 : 0)
                        .allowsHitTesting(false)
                }
        } else {
            content.listRowBackground(selected ? palette.surface : nil)
        }
    }
    @ViewBuilder private var rowBackground: some View {
        if compact { ProjectPaperBackground(starts: starts, ends: ends, selected: selected) }
        else if selected { palette.surface }
        else { Color.clear }
    }
}

private struct ProjectPaperBackground: View {
    @Environment(\.workspacePalette) private var palette
    let starts: Bool
    let ends: Bool
    let selected: Bool
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: starts ? 18 : 0,
            bottomLeadingRadius: ends ? 18 : 0, bottomTrailingRadius: ends ? 18 : 0,
            topTrailingRadius: starts ? 18 : 0, style: .continuous)
            .fill(selected ? palette.surface : Color(uiColor: .secondarySystemGroupedBackground))
    }
}

/// A folder remains recognisable beside ordinary members, including when starred.
private struct ProjectNestedGroupRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    let record: WorkspaceRecord
    let memberCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : palette.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(record.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if record.pinned {
                    Image(systemName: "star.fill").font(.caption2)
                        .foregroundStyle(.orange).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(memberCount, format: .number.grouping(.never))
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(.secondary).fixedSize()
                .accessibilityHidden(true)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.accent.opacity(0.7))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(palette.accent.opacity(colorScheme == .dark ? 0.12 : 0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.accent.opacity(0.14), lineWidth: 0.5)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkspaceLocalization.format("子项目组，%@", String(describing: record.title)))
        .accessibilityValue(WorkspaceLocalization.format("%@ 项内容，%@%@", String(describing: memberCount), String(describing: record.isFinished ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未完成")), String(describing: record.pinned ? WorkspaceLocalization.string("，星标") : "")))
        .accessibilityIdentifier("project-nested-group-\(record.id.uuidString)")
    }
}

/// Compact folder previews and a date-led workbook layout share the same row model.
private struct ProjectBrowserItemRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var compactDateWidth = 72
    @ScaledMetric(relativeTo: .title3) private var ledgerDateWidth = 62
    @ScaledMetric(relativeTo: .largeTitle) private var daySize = 30
    let record: WorkspaceRecord
    var compact = false
    var recurrenceLabel: String?

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 7) {
                    titleLine
                    if moment != nil || isRepeating {
                        accessibleDateLine.padding(.leading, compact ? 24 : 28)
                    }
                }
            } else if compact {
                HStack(alignment: .center, spacing: 8) {
                    titleLine
                    if moment != nil || isRepeating {
                        compactDateColumn.frame(width: compactDateWidth, alignment: .trailing)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    titleLine
                    if moment != nil || isRepeating {
                        ledgerDateColumn.frame(width: ledgerDateWidth, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, compact ? 3 : 10)
        .frame(minHeight: compact ? 46 : 82)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in compact ? 24 : 28 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.title)
        .accessibilityValue(accessibilitySummary)
    }

    private var titleLine: some View {
        HStack(alignment: .center, spacing: compact ? 10 : 12) {
            Image(systemName: record.pinned ? "star.fill" : "circle.fill")
                .font(.system(size: record.pinned ? (compact ? 12 : 15) : (compact ? 5 : 6)))
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : record.pinned ? Color.orange : palette.accent)
                .frame(width: compact ? 14 : 16)
                .accessibilityHidden(true)
            Text(record.title)
                .font(compact ? .body.weight(.medium) : .title3.weight(.bold))
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                .lineSpacing(compact ? 1 : 2)
                .lineLimit(typeSize.isAccessibilitySize ? nil : compact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactDateColumn: some View {
        HStack(spacing: 4) {
            if isRepeating { recurrenceIcon.font(.system(size: 10, weight: .medium)) }
            if let moment {
                Text(moment, format: compactDayStyle)
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .foregroundStyle(record.isOverdue ? Color.red : Color.secondary)
    }

    private var ledgerDateColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let moment {
                HStack(spacing: 4) {
                    if isRepeating { recurrenceIcon.font(.system(size: 9, weight: .semibold)) }
                    Text(moment, format: monthStyle).font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                Text(record.calendar.component(.day, from: moment), format: .number.precision(.integerLength(2...)))
                    .font(.system(size: daySize, weight: .heavy, design: .default))
                    .tracking(-1).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(dateInk)
                if !dayOnly {
                    Text(moment, format: timeStyle)
                        .font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                }
            } else if isRepeating {
                recurrenceIcon.font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private var accessibleDateLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isRepeating { recurrenceIcon }
            if let moment { Text(moment, format: accessibleDateStyle) }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(record.isOverdue ? Color.red : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recurrenceIcon: some View {
        Image(systemName: "repeat").accessibilityHidden(true)
    }
    private var isRepeating: Bool { recurrenceLabel != nil || record.recurrenceSeriesID != nil }
    private var dayOnly: Bool { record.dateOnly && record.dueDate != nil }
    private var dateInk: Color {
        record.isFinished ? Color.workspaceCompleted : record.isOverdue ? .red : palette.accent
    }
    private var moment: Date? {
        if compact { return record.dueDate.map(record.effectiveDueDate) ?? record.scheduledAt ?? record.remindAt }
        return record.dueDate ?? record.remindAt ?? record.scheduledAt
    }
    private var compactDayStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits)
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
    private var monthStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.abbreviated)
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
    private var timeStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
    private var accessibleDateStyle: Date.FormatStyle {
        var style: Date.FormatStyle = dayOnly ? .dateTime.year().month().day() : .dateTime.year().month().day().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
    private var accessibilitySummary: String {
        [record.isFinished ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未完成"), record.pinned ? WorkspaceLocalization.string("星标") : "",
         record.isOverdue ? WorkspaceLocalization.string("已逾期") : "", moment?.formatted(accessibleDateStyle) ?? "",
         isRepeating ? recurrenceLabel ?? WorkspaceLocalization.string("重复事项") : ""]
            .filter { !$0.isEmpty }.joined(separator: "，")
    }
}

/// A continuous deadline ledger: time in theme ink, content across a single fine rule.
private struct ProjectBrowserDeadlineRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var timerWidth = 116
    let record: WorkspaceRecord
    var recurrenceLabel: String?

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    countdown
                    content
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    countdown.frame(width: timerWidth, alignment: .leading)
                    Rectangle()
                        .fill(record.isFinished ? Color.primary.opacity(0.1) : record.isOverdue ? Color.red.opacity(0.24) : palette.accent.opacity(0.24))
                        .frame(width: 1, height: 44)
                        .accessibilityHidden(true)
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(minHeight: 86)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(record.isFinished ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未完成"))
    }

    @ViewBuilder private var countdown: some View {
        if record.isFinished {
            Label(WorkspaceLocalization.string("已完成"), systemImage: "checkmark")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.workspaceCompleted)
        } else if let due = record.dueDate {
            DeadlineCountdownView(target: record.effectiveDueDate(due), isInline: true,
                                  numberFont: .system(.title2, design: .default, weight: .heavy))
                .lineLimit(1).minimumScaleFactor(0.55)
        } else {
            Text("—").font(.title2.weight(.bold)).foregroundStyle(.secondary)
                .accessibilityLabel(WorkspaceLocalization.string("未设截止时间"))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if record.pinned {
                    Image(systemName: "star.fill").font(.caption)
                        .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.orange)
                        .accessibilityLabel(WorkspaceLocalization.string("星标"))
                }
                Text(record.title).font(.body.weight(.bold))
                    .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                    .lineSpacing(2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if recurrenceLabel != nil || record.recurrenceSeriesID != nil {
                    Image(systemName: "repeat").font(.system(size: 10, weight: .medium))
                        .accessibilityLabel(recurrenceLabel ?? WorkspaceLocalization.string("重复事项"))
                }
                if let due = record.dueDate {
                    Text(due, format: dateStyle)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private var dateStyle: Date.FormatStyle {
        var style: Date.FormatStyle = record.dateOnly ? .dateTime.month().day() : .dateTime.month().day().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
}
#endif

enum RecurringRecordPresentation {
    /// A repeat rule takes one row. Prefer today's or the next occurrence;
    /// an old unfinished occurrence must not hide every upcoming one.
    static func representatives(in records: [WorkspaceRecord]) -> [WorkspaceRecord] {
        let now = Date()
        var todayByTimezone: [String: Date] = [:]
        var chosen: [UUID: WorkspaceRecord] = [:]
        func rank(_ record: WorkspaceRecord) -> (Int, Date) {
            let today: Date
            if let cached = todayByTimezone[record.timezone] { today = cached }
            else { today = record.calendar.startOfDay(for: now); todayByTimezone[record.timezone] = today }
            let moment = record.recurrenceAnchor ?? .distantFuture
            return (record.isFinished ? 2 : moment >= today ? 0 : 1, moment)
        }
        for record in records {
            guard let seriesID = record.recurrenceSeriesID else { continue }
            guard let existing = chosen[seriesID] else { chosen[seriesID] = record; continue }
            let left = rank(record), right = rank(existing)
            if left.0 < right.0 || (left.0 == right.0 && (left.0 == 0 ? left.1 < right.1 : left.1 > right.1)) {
                chosen[seriesID] = record
            }
        }
        return records.filter { record in record.recurrenceSeriesID.map { chosen[$0]?.id == record.id } ?? true }
    }
}

/// Compact preview with stars taking precedence over completion dots.
private struct CompactProjectMemberRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    let record: WorkspaceRecord
    var recurrenceLabel: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: record.pinned ? "star.fill" : "circle.fill")
                .font(.system(size: record.pinned ? 12 : 5))
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : record.pinned ? Color.orange : palette.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title
                    Spacer(minLength: 4)
                    date
                }
                VStack(alignment: .leading, spacing: 3) { title; date }
            }
        }
        .padding(.vertical, 3)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
        .accessibilityValue(record.isFinished ? WorkspaceLocalization.string("已完成") : record.pinned ? WorkspaceLocalization.string("星标") : "")
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.title).font(.body.weight(.medium))
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let recurrenceLabel {
                Label(recurrenceLabel, systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var date: some View {
        if let moment = record.dueDate.map(record.effectiveDueDate) ?? record.scheduledAt ?? record.remindAt {
            HStack(spacing: 3) {
                if record.isOverdue { Text(WorkspaceLocalization.string("逾期")) }
                Text(moment, format: dateStyle)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(record.isOverdue ? Color.red : Color.secondary)
            .fixedSize()
        }
    }
    private var dateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month().day()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
}
private struct ProjectGroupCardHeader: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    let record: WorkspaceRecord
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.isFinished ? "checkmark.circle.fill" : record.pinned ? "star.fill" : "folder.fill").font(.title2)
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : record.pinned ? Color.orange : folderTint)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.title3.weight(.semibold))
                    .foregroundStyle(record.isFinished ? Color.workspaceCompleted : colorScheme == .dark ? Color(white: 0.95) : Color.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityValue(record.kind.completedStatus == nil ? "" : record.isFinished ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未完成"))
    }
    private var folderTint: Color {
        palette.accent
    }
}
struct ActionsView: View {
    var selection: Binding<UUID?>? = nil
    var body: some View {
        RecordListView(kind: .task, selection: selection, includedKinds: [.task, .reminder, .milestone])
    }
}
struct ProjectGroupsView: View {
    var selection: Binding<UUID?>? = nil
    var body: some View { RecordListView(kind: .project, selection: selection, includedKinds: [.project, .area]) }
}
struct ArchivesView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        List {
            ForEach(store.state.records.filter { $0.archivedAt != nil && $0.deletedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }) { record in
                HStack {
                    NavigationLink { RecordDetailView(id: record.id) } label: { RecordRow(record: record) }
                    Button(WorkspaceLocalization.string("恢复"), systemImage: "arrow.counterclockwise") { store.perform { try store.archive(record.id, restore: true) } }
                        .disabled(store.isReadOnlyWorkspace)
                }
            }
        }.navigationTitle(WorkspaceLocalization.string("归档"))
    }
}
struct TrashView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        List {
            Section {
                Text(WorkspaceLocalization.string("项目组等记录可在删除后 30 天内恢复。知识笔记不设恢复期限。恢复会保留关联关系。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.state.trash.sorted { $0.deletedAt > $1.deletedAt }) { batch in
                VStack(alignment: .leading, spacing: 8) {
                    Text(batch.title).font(.headline)
                    Text(WorkspaceLocalization.format("%@ 项 · %@", String(describing: batch.itemIDs.count), String(describing: batch.deletedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: WorkspaceLocalization.locale)))))
                        .font(.caption).foregroundStyle(.secondary)
                    if let expires = batch.expiresAt { Text(WorkspaceLocalization.format("恢复期限：%@", String(describing: expires.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: WorkspaceLocalization.locale))))).font(.caption) }
                    Button(WorkspaceLocalization.string("恢复此批次"), systemImage: "arrow.counterclockwise") { store.perform { try store.restore(batch) } }
                        .disabled(store.isReadOnlyWorkspace || (batch.expiresAt.map { $0 < Date() } ?? false))
                }.padding(.vertical, 4)
            }
        }.navigationTitle(WorkspaceLocalization.string("回收站"))
    }
}

#Preview("记录行") {
    let store = try! WorkspaceStore(repository: SwiftDataRepository(inMemory: true), isDemoMode: true)
    RecordRow(record: WorkspaceRecord(kind: .task, title: "整理待办事项与项目组安排", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)).padding().environment(store)
}

struct DeadlineCountdownView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: Date
    private var group: DeadlineCountdownGroup?
    private var isInline = false
    private var numberFont: Font?
    init(target: Date, isInline: Bool = false, numberFont: Font? = nil) {
        self.target = target; self.isInline = isInline; self.numberFont = numberFont
    }
    init(group: DeadlineCountdownGroup) { self.target = group.dueDates[0]; self.group = group }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let target = group?.countdownDate(at: context.date) ?? self.target
            let overdue = target <= context.date
            let title = overdue ? WorkspaceLocalization.string("已逾期") : (group?.records.count ?? 1) > 1 ? WorkspaceLocalization.string("距离下一项截止") : WorkspaceLocalization.string("距离截止")
            let duration = durationDescription(to: target, from: context.date)
            VStack(alignment: .leading, spacing: 4) {
                if !isInline {
                    Label(title, systemImage: overdue ? "exclamationmark.circle.fill" : "timer")
                        .font(.caption.weight(.semibold))
                }
                Group {
                    if reduceMotion { Text(target, style: .timer) }
                    else { Text(target, style: .timer).contentTransition(.numericText()) }
                }
                .font((numberFont ?? .system(.largeTitle, design: isInline ? .default : .rounded, weight: .semibold)).monospacedDigit())
            }
            .foregroundStyle(overdue ? Color.red : isInline ? inlineTint : Color.primary)
            .padding(isInline ? 0 : 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(isInline ? Color.clear : overdue ? Color.red.opacity(0.08) : palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(duration)
        }
    }
    private var inlineTint: Color {
        palette.accent
    }
    private func durationDescription(to target: Date, from now: Date) -> String {
        var seconds = Int(abs(target.timeIntervalSince(now)))
        let days = seconds / 86_400; seconds %= 86_400
        let hours = seconds / 3_600; seconds %= 3_600
        let minutes = seconds / 60; seconds %= 60
        return (days > 0 ? WorkspaceLocalization.format("%@天 ", String(describing: days)) : "") + WorkspaceLocalization.format("%@小时 %@分 %@秒", String(describing: hours), String(describing: minutes), String(describing: seconds))
    }
}


// Only an opaque reference is dragged; record contents and account
// credentials never enter the pasteboard. The root owns this transient UI state.
struct WorkspaceRecordDragPayload: Transferable {
    let token: UUID
    static let contentType = UTType(exportedAs: "org.example.workspace.record-reference", conformingTo: .data)
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: contentType) { payload in
            #if DEBUG
            print("WORKSPACE_RECORD_DRAG_EXPORT")
            #endif
            return Data(payload.token.uuidString.utf8)
        } importing: { data in
            #if DEBUG
            print("WORKSPACE_RECORD_DRAG_IMPORT bytes=\(data.count)")
            #endif
            guard data.count <= 64, let text = String(data: data, encoding: .utf8), let token = UUID(uuidString: text) else {
                throw CocoaError(.coderInvalidValue)
            }
            return Self(token: token)
        }
        // The advertised representation contains only a random token. Receivers
        // require the originating window's live drag session and unchanged
        // account/workspace scope.
        .visibility(.all)
    }
}

private enum WorkspaceDragMotion {
    static func lift(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.9)
    }
    static func feedback(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.24)
    }
    static func reorder(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.94)
    }
}

@MainActor @Observable final class WorkspaceRecordDragSession {
    private(set) var recordID: UUID?
    private(set) var token: UUID?
    private weak var owner: WorkspaceStore?
    private var accountScope: String?
    private var expiry: Task<Void, Never>?
    private var ending: Task<Void, Never>?
    private(set) var dropPending = false
    private(set) var settling = false
    private var destinationID: UUID?

    func begin(_ record: WorkspaceRecord, in store: WorkspaceStore) -> WorkspaceRecordDragPayload {
        if !settling, recordID == record.id, matches(store), let token { return WorkspaceRecordDragPayload(token: token) }
        finish()
        let token = UUID()
        self.token = token; recordID = record.id
        owner = store; accountScope = store.backend.accountScope
        Self.feedback(in: store)
        #if DEBUG
        print("WORKSPACE_RECORD_DRAG_BEGIN id=\(record.id)")
        #endif
        // Older systems don't expose drag-end callbacks. Expire abandoned UI
        // without ever persisting an optimistic move.
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard self?.token == token else { return }
            self?.finish()
        }
        return WorkspaceRecordDragPayload(token: token)
    }
    func finish() {
        expiry?.cancel(); expiry = nil
        ending?.cancel(); ending = nil
        dropPending = false; settling = false; destinationID = nil
        recordID = nil; token = nil; owner = nil; accountScope = nil
    }
    func isDragging(_ id: UUID) -> Bool { recordID == id && !settling }
    func isSettling(to groupID: UUID?, in store: WorkspaceStore) -> Bool {
        settling && matches(store) && destinationID == groupID
    }
    // Protect a slow provider callback from the native drag-end notification.
    // The bounded timeout also restores the UI if a provider never calls back.
    func prepareDrop(token: UUID) {
        guard self.token == token else { return }
        dropPending = true
        ending?.cancel(); ending = nil
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if self?.token == token { self?.finish() }
        }
    }
    func completeDrop(token: UUID, to groupID: UUID?, reduceMotion: Bool) {
        guard self.token == token else { return }
        expiry?.cancel(); ending?.cancel(); ending = nil
        dropPending = false; destinationID = groupID; settling = true
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 420)) } catch { return }
            if self?.token == token { self?.finish() }
        }
    }
    func dragEnded(token: UUID) {
        guard self.token == token, !dropPending, !settling else { return }
        ending?.cancel()
        ending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, self.token == token, !self.dropPending, !self.settling else { return }
            self.finish()
        }
    }
    func matches(_ store: WorkspaceStore) -> Bool {
        owner === store && accountScope == store.backend.accountScope && !store.isReadOnlyWorkspace
    }
    func canMove(in store: WorkspaceStore, to groupID: UUID?) -> Bool {
        guard !dropPending, !settling, matches(store), let recordID, let record = store.record(recordID),
              record.kind.isItem || record.kind == .deadline,
              store.isVisibleRecord(record.id) else { return false }
        guard let groupID else { return record.projectID != nil || record.areaID != nil }
        guard let group = store.record(groupID), group.kind.isProjectGroup,
              store.isVisibleRecord(group.id) else { return false }
        if group.kind == .project { return record.projectID != groupID || record.areaID != nil }
        return record.areaID != groupID || record.projectID != nil
    }
    static let contentType = WorkspaceRecordDragPayload.contentType
    static func feedback(in store: WorkspaceStore) {
        guard store.hapticsEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #else
        WorkspaceHaptics.play(.selection, enabled: true)
        #endif
    }
}

extension EnvironmentValues {
    @Entry var workspaceRecordDragSession: WorkspaceRecordDragSession? = nil
}

struct WorkspaceRecordDragOverlay: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = WorkspaceRecordDragSession()
    func body(content: Content) -> some View {
        content
            .environment(\.workspaceRecordDragSession, session)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if session.recordID != nil, session.matches(store) {
                        WorkspaceRecordDropTray(session: session)
                            .padding(12)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .offset(y: 12).combined(with: .opacity),
                                removal: .offset(y: 6).combined(with: .opacity)))
                    }
                }
                .animation(WorkspaceDragMotion.lift(reduceMotion: reduceMotion), value: session.recordID != nil)
            }
            .onChange(of: ObjectIdentifier(store)) { _, _ in session.finish() }
            .onChange(of: store.backend.accountScope) { _, _ in session.finish() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { session.finish() } }
            .onDisappear { session.finish() }
    }
}

private struct WorkspaceRecordDropTray: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var phoneTargetHeight: CGFloat = 76
    @State private var destinationPage = 0
    #endif
    let session: WorkspaceRecordDragSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(WorkspaceLocalization.string("移到项目组")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(WorkspaceLocalization.string("取消"), systemImage: "xmark") { session.finish() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    #if os(iOS)
                    .frame(width: 44, height: 44)
                    #else
                    .padding(6)
                    #endif
            }
            #if os(iOS)
            phoneDestinations
            #else
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    destination(nil, title: WorkspaceLocalization.string("未归组事项"), symbol: "tray")
                    ForEach(store.projectGroupRecords) { group in
                        destination(group.id, title: group.title, symbol: "folder")
                    }
                }.padding(3)
            }
            .scrollIndicators(.hidden)
            #endif
        }
        .padding(12)
        .frame(maxWidth: 720)
        .background {
            WorkspaceDragSurface(reduceTransparency: reduceTransparency, cornerRadius: 22)
        }
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(palette.accent.opacity(0.2)).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
        .environment(\.workspaceRecordDragSession, session)
        .accessibilityIdentifier("record-group-drop-tray")
    }
    #if os(iOS)
    private struct Destination: Identifiable {
        let group: WorkspaceRecord?
        var id: String { group?.id.uuidString ?? "ungrouped" }
    }
    private var phoneDestinations: some View {
        let destinations = [Destination(group: nil)] + store.projectGroupRecords.map { Destination(group: $0) }
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        let rows = typeSize.isAccessibilitySize ? (verticalSizeClass == .compact ? 1 : 2) : (verticalSizeClass == .compact ? 2 : 3)
        let pageSize = columns * rows
        let pageCount = max(1, (destinations.count + pageSize - 1) / pageSize)
        let page = min(destinationPage, pageCount - 1)
        let visible = Array(destinations.dropFirst(page * pageSize).prefix(pageSize))
        return VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(visible) { destination in
                    phoneDestination(destination.group)
                        .transition(.opacity)
                }
                if pageCount > 1 {
                    ForEach(visible.count..<pageSize, id: \.self) { _ in
                        Color.clear.frame(height: phoneTargetHeight).accessibilityHidden(true)
                    }
                }
            }
            .animation(WorkspaceDragMotion.feedback(reduceMotion: reduceMotion), value: page)
            if pageCount > 1 {
                HStack(spacing: 12) {
                    WorkspaceDropPageButton(session: session, forward: false, enabled: page > 0) {
                        destinationPage = max(0, min(pageCount - 1, destinationPage) - 1)
                    }
                    VStack(spacing: 2) {
                        Text("\(page + 1) / \(pageCount)").monospacedDigit()
                        Text(WorkspaceLocalization.string("拖至箭头停留翻页"))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    WorkspaceDropPageButton(session: session, forward: true, enabled: page + 1 < pageCount) {
                        destinationPage = min(pageCount - 1, destinationPage + 1)
                    }
                }
            }
        }
        .onChange(of: session.token) { _, token in
            if token != nil { destinationPage = 0 }
        }
    }
    private func phoneDestination(_ group: WorkspaceRecord?) -> some View {
        let groupID = group?.id
        let title = group?.title ?? WorkspaceLocalization.string("未归组事项")
        let active = session.canMove(in: store, to: groupID) || session.isSettling(to: groupID, in: store)
        let parentID = group?.projectID ?? group?.areaID
        let parent = parentID.flatMap { store.record($0)?.title }
        return HStack(spacing: 8) {
            Image(systemName: group == nil ? "tray" : "folder")
                .font(.body.weight(.medium)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let parent {
                    Text(parent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: phoneTargetHeight)
        .foregroundStyle(active ? palette.accent : Color.secondary)
        .background(palette.accent.opacity(active ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .workspaceRecordGroupDropTarget(groupID)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record-drop-" + (groupID?.uuidString ?? "ungrouped"))
    }
    #endif
    private func destination(_ id: UUID?, title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 14).frame(minHeight: 46)
            .foregroundStyle(session.canMove(in: store, to: id) || session.isSettling(to: id, in: store) ? palette.accent : Color.secondary)
            .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .workspaceRecordGroupDropTarget(id)
            .accessibilityIdentifier("record-drop-" + (id?.uuidString ?? "ungrouped"))
    }
}

#if os(iOS)
/// A held item can turn a page without needing a second finger to scroll.
/// Releasing on this navigation control never changes a record's group.
private struct WorkspaceDropPageButton: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    let session: WorkspaceRecordDragSession
    let forward: Bool
    let enabled: Bool
    let advance: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: advance) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.subheadline.weight(.semibold))
                .frame(width: 52, height: 44)
                .background(palette.accent.opacity(hovered ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(WorkspaceLocalization.string(forward ? "下一页项目组" : "上一页项目组"))
        .accessibilityIdentifier(forward ? "record-drop-page-next" : "record-drop-page-previous")
        .onDrop(of: [WorkspaceRecordDragSession.contentType], delegate:
            WorkspaceDropPageDelegate(session: session, enabled: enabled, hovered: $hovered))
        .task(id: hovered ? session.token : nil) {
            guard hovered, enabled, let token = session.token else { return }
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            while !Task.isCancelled, hovered, session.token == token, session.matches(store),
                  !session.dropPending, !session.settling {
                advance()
                WorkspaceRecordDragSession.feedback(in: store)
                // A steady edge hold may cross several pages; pause long enough
                // to read each page, and cancel immediately when the drag leaves.
                do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
            }
        }
        .onChange(of: session.token) { _, _ in hovered = false }
        .onChange(of: enabled) { _, value in if !value { hovered = false } }
    }
}
private struct WorkspaceDropPageDelegate: DropDelegate {
    let session: WorkspaceRecordDragSession
    let enabled: Bool
    @Binding var hovered: Bool
    func validateDrop(info: DropInfo) -> Bool {
        enabled && session.recordID != nil && !session.dropPending && !session.settling &&
            info.hasItemsConforming(to: [WorkspaceRecordDragSession.contentType])
    }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { hovered = true } }
    func dropExited(info: DropInfo) { hovered = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .forbidden) }
    func performDrop(info: DropInfo) -> Bool { hovered = false; return false }
}
#endif

private struct WorkspaceRecordDragSource: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspaceRecordDragSession) private var session
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let record: WorkspaceRecord?
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, let record, let session, !store.isReadOnlyWorkspace,
           record.kind.isItem || record.kind == .deadline,
           store.record(record.id) != nil, store.isVisibleRecord(record.id) {
            let source = content
                .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14))
                .draggable(session.begin(record, in: store)) {
                    Label(record.title, systemImage: record.kind.symbol)
                        .font(.headline).lineLimit(2).padding(14)
                        .frame(maxWidth: 260, alignment: .leading)
                        .background { WorkspaceDragSurface(reduceTransparency: reduceTransparency, cornerRadius: 14) }
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(palette.accent.opacity(0.12)) }
                }
                .opacity(session.isDragging(record.id) ? 0.8 : 1)
                .scaleEffect(session.isDragging(record.id) && !reduceMotion ? 0.985 : 1)
                .animation(WorkspaceDragMotion.lift(reduceMotion: reduceMotion), value: session.isDragging(record.id))
                .accessibilityHint(WorkspaceLocalization.string("长按并拖到项目组以移动"))
            source.modifier(WorkspaceRecordDragCompletion())
        } else { content }
    }
}


private struct WorkspaceRecordDragCompletion: ViewModifier {
    @Environment(\.workspaceRecordDragSession) private var session
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.0, macOS 26.0, *) {
            content
                .dragConfiguration(.init(allowMove: true))
                .dropConfiguration { _ in DropConfiguration(operation: .move) }
                .onDragSessionUpdated { update in
                    #if DEBUG
                    print("WORKSPACE_RECORD_DRAG_PHASE \(String(describing: update.phase))")
                    #endif
                    switch update.phase {
                    case .ended, .dataTransferCompleted:
                        if let token = session?.token { session?.dragEnded(token: token) }
                    default: break
                    }
                }
        } else { content }
    }
}

private struct WorkspaceRecordGroupDropTarget: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspaceRecordDragSession) private var session
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    let groupID: UUID?
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, let session, !store.isReadOnlyWorkspace {
            content
                .modifier(WorkspaceDropHighlight(targeted: targeted, settled: session.isSettling(to: groupID, in: store),
                    accent: palette.accent, reduceMotion: reduceMotion))
                .onDrop(of: [WorkspaceRecordDragSession.contentType], delegate:
                    WorkspaceRecordGroupDropDelegate(store: store, session: session, groupID: groupID,
                        targeted: $targeted, reduceMotion: reduceMotion))
                .onChange(of: session.recordID) { _, _ in targeted = false }
        } else { content }
    }
}

private struct WorkspaceRecordGroupDropDelegate: DropDelegate {
    let store: WorkspaceStore
    let session: WorkspaceRecordDragSession
    let groupID: UUID?
    @Binding var targeted: Bool
    let reduceMotion: Bool
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [WorkspaceRecordDragSession.contentType]) && session.canMove(in: store, to: groupID)
    }
    func dropEntered(info: DropInfo) {
        guard !targeted, validateDrop(info: info) else { return }
        targeted = true
        WorkspaceRecordDragSession.feedback(in: store)
    }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info), let token = session.token, let id = session.recordID,
              let provider = info.itemProviders(for: [WorkspaceRecordDragSession.contentType]).first else { return false }
        let scope = store.backend.accountScope
        session.prepareDrop(token: token)
        provider.loadDataRepresentation(forTypeIdentifier: WorkspaceRecordDragSession.contentType.identifier) { data, _ in
            Task { @MainActor in
                guard session.token == token else { return }
                guard let data, data.count <= 64, String(data: data, encoding: .utf8) == token.uuidString,
                      store.backend.accountScope == scope, session.matches(store) else {
                    session.finish(); return
                }
                store.perform {
                    let changed = try withAnimation(WorkspaceDragMotion.reorder(reduceMotion: reduceMotion)) {
                        try store.moveRecords([id], to: groupID)
                    }
                    if changed { session.completeDrop(token: token, to: groupID, reduceMotion: reduceMotion) }
                    else { session.finish() }
                }
                // perform reports a save error through the existing app UI.
                if session.token == token, !session.settling { session.finish() }
            }
        }
        return true
    }
}

private struct WorkspaceDragSurface: View {
    let reduceTransparency: Bool
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
    }
}

// Decoration only: it never resizes the folder or interferes with its controls.
private struct WorkspaceDropHighlight: ViewModifier {
    let targeted: Bool
    let settled: Bool
    let accent: Color
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(accent.opacity(settled ? 0.18 : targeted ? 0.09 : 0))
                    .animation(WorkspaceDragMotion.feedback(reduceMotion: reduceMotion), value: targeted)
                    .animation(WorkspaceDragMotion.feedback(reduceMotion: reduceMotion), value: settled)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(settled ? 0.6 : targeted ? 0.4 : 0), lineWidth: 1)
                    .animation(WorkspaceDragMotion.feedback(reduceMotion: reduceMotion), value: targeted)
                    .animation(WorkspaceDragMotion.feedback(reduceMotion: reduceMotion), value: settled)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func workspaceRecordDragSource(_ record: WorkspaceRecord?, enabled: Bool = true) -> some View {
        modifier(WorkspaceRecordDragSource(record: record, enabled: enabled))
    }
    func workspaceRecordGroupDropTarget(_ groupID: UUID?, enabled: Bool = true) -> some View {
        modifier(WorkspaceRecordGroupDropTarget(groupID: groupID, enabled: enabled))
    }
}
