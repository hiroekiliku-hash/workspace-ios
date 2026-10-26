import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private enum SettingsRoute: Hashable {
    case account, appearance, preferences, reminders, library, api, backup, contentUpdates, about
}

struct SettingsView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showGettingStarted = false
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        settingsContent
            .navigationTitle(WorkspaceLocalization.string("设置"))
            .workspaceResponsiveTitle()
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .account: BackendSettingsView()
                case .api: APIConfigurationView()
                case .appearance: AppearancePreferencesView()
                case .preferences: PersonalPreferencesView()
                case .reminders: ReminderPreferencesView()
                case .backup: BackupPreferencesView()
                case .about: AboutWorkspaceView()
                case .contentUpdates: ContentUpdatesView()
                case .library:
                    #if os(iOS)
                    WorkspaceLibraryView()
                    #else
                    EmptyView()
                    #endif
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .tabBar)
            #endif

            .environment(\.timeZone, WorkspaceDates.calendar(store.state.profile.timezone).timeZone)
            .preferredColorScheme((store.isDemoMode ? store.demoAppearance : appearance) == "light" ? .light : (store.isDemoMode ? store.demoAppearance : appearance) == "dark" ? .dark : nil)
            .gettingStarted(isPresented: $showGettingStarted, isReplay: true)
            .task { await store.prepareForInteraction() }
    }
    @ViewBuilder private var settingsContent: some View {
        #if os(iOS)
        GeometryReader { geometry in
            if geometry.size.width >= 680 && !typeSize.isAccessibilitySize {
                HStack(spacing: 0) {
                    Form { accountSection; demoSection }
                        .formStyle(.grouped)
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .contentMargins(.top, 8, for: .scrollContent)
                        .frame(width: geometry.size.width * 0.46)
                    Form { preferenceSections; supportSection }
                        .formStyle(.grouped)
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .contentMargins(.top, 8, for: .scrollContent)
                }
                .accessibilityIdentifier("settings-columns")
            } else { compactSettings }
        }
        #else
        compactSettings
        #endif
    }
    private var compactSettings: some View {
        Form { accountSection; preferenceSections; demoSection; supportSection }
            .formStyle(.grouped)
    }
    @ViewBuilder private var accountSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.account) {
                HStack(spacing: 14) {
                    AvatarView(data: store.state.profile.avatar).frame(width: 56, height: 56).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.state.profile.name).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Text(store.isDemoMode ? WorkspaceLocalization.string("演示资料") : store.backend.signedIn ? store.backend.accountName : WorkspaceLocalization.string("登录工作坊，同步你的内容"))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 6)
            }
        }
    }
    @ViewBuilder private var preferenceSections: some View {
        Section {
            NavigationLink(value: SettingsRoute.appearance) {
                SettingsEntry(title: AppearancePreferencesView.title, symbol: "paintpalette", color: palette.action)
            }
            NavigationLink(value: SettingsRoute.preferences) {
                SettingsEntry(title: WorkspaceLocalization.string("个人偏好"), symbol: "slider.horizontal.3", color: .teal)
            }
            NavigationLink(value: SettingsRoute.reminders) {
                SettingsEntry(title: ReminderPreferencesView.title, symbol: "bell", color: .orange)
            }
        }
        Section {
            #if os(iOS)
            NavigationLink {
                WidgetPreferencesView()
            } label: {
                SettingsEntry(title: WorkspaceLocalization.string("桌面小组件"), symbol: "rectangle.on.rectangle", color: palette.action)
            }
            .accessibilityIdentifier("settings-widgets")
            NavigationLink(value: SettingsRoute.library) {
                SettingsEntry(title: WorkspaceLocalization.string("工作空间"), symbol: "square.grid.2x2", color: palette.action)
            }
            #endif
            NavigationLink(value: SettingsRoute.api) {
                SettingsEntry(title: WorkspaceLocalization.string("API 接口"), symbol: "curlybraces", color: palette.action)
            }
            .accessibilityIdentifier("settings-api")
            NavigationLink(value: SettingsRoute.backup) {
                SettingsEntry(title: WorkspaceLocalization.string("数据与备份"), symbol: "externaldrive", color: .teal)
            }
        }
    }
    @ViewBuilder private var demoSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.isDemoMode }, set: { enabled in
                if enabled { store.perform { try store.beginDemo() } }
                else { store.endDemo() }
            })) {
                SettingsEntry(title: WorkspaceLocalization.string("演示模式"), symbol: "flask", color: .purple)
            }.accessibilityIdentifier("demo-mode-toggle")
            if store.isDemoMode {
                Button(WorkspaceLocalization.string("重置演示数据"), systemImage: "arrow.counterclockwise") {
                    store.perform { try store.resetDemo() }
                }
            }
        } footer: {
            Text(store.isDemoMode ? WorkspaceLocalization.string("自由试用，退出后丢弃演示中的更改。") : WorkspaceLocalization.string("用模拟日常自由试用，不影响你的内容。"))
        }
    }
    @ViewBuilder private var supportSection: some View {
        Section {
            Button { showGettingStarted = true } label: {
                SettingsEntry(title: WorkspaceLocalization.string("欢迎与使用指南"), symbol: "play", color: palette.action)
            }
            NavigationLink(value: SettingsRoute.contentUpdates) {
                SettingsEntry(title: WorkspaceLocalization.string("内容更新"), symbol: "arrow.down.circle", color: palette.action)
            }
            .accessibilityIdentifier("settings-content-updates")
            NavigationLink(value: SettingsRoute.about) {
                SettingsEntry(title: WorkspaceLocalization.string("关于工作坊"), symbol: "info", color: .gray)
            }
        }
    }

}

private struct ContentUpdatesView: View {
    @State private var content = AppContentService.shared

    var body: some View {
        Form {
            Section {
                LabeledContent(WorkspaceLocalization.string("状态"), value: content.isRefreshing ? WorkspaceLocalization.string("正在检查…") : content.message ?? WorkspaceLocalization.string("已准备就绪"))
                LabeledContent(WorkspaceLocalization.string("最近检查")) {
                    if let date = content.lastChecked {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text(WorkspaceLocalization.string("尚未检查")).foregroundStyle(.secondary)
                    }
                }
                if let date = content.lastUpdated {
                    LabeledContent(WorkspaceLocalization.string("最近更新")) {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
                LabeledContent(WorkspaceLocalization.string("可用内容"), value: WorkspaceLocalization.format("%@ 项", String(describing: content.availableEntries.count)))
            }
            Section {
                Button {
                    Task { await content.refresh(force: true) }
                } label: {
                    HStack {
                        Spacer()
                        if content.isRefreshing { ProgressView().controlSize(.small) }
                        Text(content.isRefreshing ? WorkspaceLocalization.string("正在检查…") : WorkspaceLocalization.string("检查更新"))
                        Spacer()
                    }.frame(minHeight: 36)
                }
                .disabled(content.isRefreshing)
                .accessibilityIdentifier("content-check-for-updates")
            } footer: {
                Text(WorkspaceLocalization.string("演示课程和使用指南会随内容更新。"))
            }
            if !content.announcements.isEmpty {
                Section(WorkspaceLocalization.string("公告")) {
                    ForEach(content.announcements, id: \.id) { announcement in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(announcement.title).font(.headline)
                            Text(announcement.message).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(WorkspaceLocalization.string("内容更新"))
        .workspaceInlineTitle()
        .task { await content.prepare() }
    }
}

private struct SettingsEntry: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
        }.padding(.vertical, 3)
    }
}

private struct AppearancePreferencesView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(WorkspaceColorTheme.preferenceKey) private var savedTheme = WorkspaceColorTheme.blue.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    static var title: String {
        #if os(iOS)
        WorkspaceLocalization.string("外观与触感")
        #else
        WorkspaceLocalization.string("外观")
        #endif
    }
    var body: some View {
        Form {
            Section(WorkspaceLocalization.string("显示模式")) {
                Picker(WorkspaceLocalization.string("显示模式"), selection: Binding(get: { store.isDemoMode ? store.demoAppearance : appearance }, set: { value in
                    if store.isDemoMode { store.demoAppearance = value } else { appearance = value }
                })) {
                    Text(WorkspaceLocalization.string("跟随系统")).tag("system")
                    Text(WorkspaceLocalization.string("浅色")).tag("light")
                    Text(WorkspaceLocalization.string("深色")).tag("dark")
                }.pickerStyle(.segmented)
            }
            Section(WorkspaceLocalization.string("鲜明配色")) { themeChoices(WorkspaceColorTheme.vividThemes) }
            Section(WorkspaceLocalization.string("柔和与中性")) { themeChoices(WorkspaceColorTheme.quietThemes) }
            #if os(iOS)
            Section { Toggle(WorkspaceLocalization.string("操作触感反馈"), isOn: Binding(get: { store.isDemoMode ? store.demoHapticsEnabled : hapticsEnabled }, set: { value in
                if store.isDemoMode { store.demoHapticsEnabled = value } else { hapticsEnabled = value }
            })) }
            #endif

        }.formStyle(.grouped).navigationTitle(Self.title).workspaceInlineTitle()
            .workspaceSelectionFeedback(trigger: appearance)
            .workspaceSelectionFeedback(trigger: selectedTheme)
            #if os(iOS)
            .onChange(of: selectedTheme) { _, _ in store.publishWidgetSnapshot() }
            #endif
    }
    private func themeChoices(_ themes: [WorkspaceColorTheme]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 100), spacing: 10)], spacing: 10) {
            ForEach(themes) { theme in
                WorkspaceThemeOption(theme: theme, selected: selectedTheme == theme) {
                    if store.isDemoMode { store.demoColorTheme = theme.rawValue }
                    else { savedTheme = theme.rawValue }
                }
            }
        }.padding(.vertical, 4)
    }

    private var selectedTheme: WorkspaceColorTheme {
        WorkspaceColorTheme(rawValue: store.isDemoMode ? store.demoColorTheme : savedTheme) ?? .blue
    }
}

private struct WorkspaceThemeOption: View {
    let theme: WorkspaceColorTheme
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        let colors = theme.palette
        Button(action: choose) {
            VStack(spacing: 9) {
                Circle().fill(colors.action.gradient).frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(theme.title).font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 82)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(colors.accent.opacity(selected ? 1 : 0.16), lineWidth: selected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.caption)
                        .foregroundStyle(colors.accent).padding(7)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityValue(selected ? WorkspaceLocalization.string("当前主题") : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("color-theme-" + theme.rawValue)
    }
}

private struct PersonalPreferencesView: View {
    @Environment(WorkspaceStore.self) private var store
    @AppStorage(WorkspaceLanguage.preferenceKey) private var language = WorkspaceLanguage.system.rawValue
    @AppStorage(CourseLearningControlSide.preferenceKey) private var courseControlSide = CourseLearningControlSide.right.rawValue
    @AppStorage(WorkspaceLaunchPreferences.repeatsKey) private var playsLaunchAnimation = false
    var body: some View {
        Form {
            Section {
                Picker(selection: $language) {
                    ForEach(WorkspaceLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language.rawValue)
                    }
                } label: {
                    Label(WorkspaceLocalization.string("语言"), systemImage: "globe")
                }
                .accessibilityIdentifier("settings-language")
            }

            #if os(iOS)
            Section {
                Picker(selection: $courseControlSide) {
                    ForEach(CourseLearningControlSide.allCases) { side in
                        Text(verbatim: side.title).tag(side.rawValue)
                    }
                } label: {
                    Label(WorkspaceLocalization.string("学习按钮位置"), systemImage: "hand.point.up.left")
                }
                .accessibilityIdentifier("settings-course-control-side")
            }
            #endif

            Section {
                Toggle(WorkspaceLocalization.string("启动时播放开屏动画"), isOn: Binding(get: {
                    store.isDemoMode ? store.demoPlaysLaunchAnimation : playsLaunchAnimation
                }, set: { value in
                    if store.isDemoMode { store.demoPlaysLaunchAnimation = value }
                    else { playsLaunchAnimation = value }
                }))
                .accessibilityIdentifier("settings-launch-animation")
            } footer: {
                Text(WorkspaceLocalization.string("重新启动 App 时播放。"))
            }
            Section {
                Toggle(WorkspaceLocalization.string("事项默认提醒"), isOn: preference(\.taskRemindersEnabled))
                Toggle(WorkspaceLocalization.string("截止事项默认提醒"), isOn: preference(\.deadlineRemindersEnabled))
                Picker(WorkspaceLocalization.string("默认提醒时间"), selection: preference(\.notificationLeadMinutes)) {
                    Text(WorkspaceLocalization.string("准时")).tag(0)
                    Text(WorkspaceLocalization.string("提前 5 分钟")).tag(5)
                    Text(WorkspaceLocalization.string("提前 15 分钟")).tag(15)
                    Text(WorkspaceLocalization.string("提前 30 分钟")).tag(30)
                    Text(WorkspaceLocalization.string("提前 1 小时")).tag(60)
                    Text(WorkspaceLocalization.string("提前 1 天")).tag(1440)
                    if ![0, 5, 15, 30, 60, 1440].contains(store.preferences.notificationLeadMinutes) {
                        Text(WorkspaceLocalization.format("提前 %@ 分钟", String(describing: store.preferences.notificationLeadMinutes))).tag(store.preferences.notificationLeadMinutes)
                    }
                }
                Toggle(WorkspaceLocalization.string("截止日期默认全天"), isOn: preference(\.dateOnlyDeadlines))
            } header: { Text(WorkspaceLocalization.string("新建事项")) }
            footer: { Text(WorkspaceLocalization.string("新建时自动使用这些选项，也可以为每个事项单独调整。")) }
            Section {
                NavigationLink { ProjectCategoryPreferencesView() } label: {
                    Label(WorkspaceLocalization.string("项目组分类"), systemImage: "tag")
                }
            }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("个人偏好")).workspaceInlineTitle()
    }
    private func preference<Value>(_ path: WritableKeyPath<WorkspacePreferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: path] }, set: { store.preferences[keyPath: path] = $0 })
    }
}

struct ProjectCategoryPreferencesView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var newCategory = ""
    @State private var notice: String?
    private var trimmed: String { newCategory.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Form {
            Section {
                TextField(WorkspaceLocalization.string("分类名称"), text: $newCategory)
                Button(WorkspaceLocalization.string("添加分类"), systemImage: "plus") { addCategory() }
                    .disabled(trimmed.isEmpty || trimmed.utf16.count > 240 || store.preferences.customProjectCategories.count >= 50)
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Picker(WorkspaceLocalization.string("新建项目组默认分类"), selection: Binding(
                    get: { store.preferences.defaultProjectCategory },
                    set: { store.preferences.defaultProjectCategory = $0 })) {
                    Text(WorkspaceLocalization.string("无分类")).tag("")
                    ForEach(store.projectCategoryKeys, id: \.self) { key in
                        Text(projectKindLabel(key)).tag(key)
                    }
                }
            }
            Section {
                ForEach(store.projectCategoryKeys, id: \.self) { key in
                    NavigationLink { ProjectCategoryEditorView(categoryKey: key) } label: {
                        Text(projectKindLabel(key))
                    }
                }
            } header: { Text(WorkspaceLocalization.string("可用分类")) }
            footer: { Text(WorkspaceLocalization.string("所有分类均可改名或删除。删除后项目组保留，并设为无分类。")) }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("项目组分类")).workspaceInlineTitle()
    }
    private func addCategory() {
        let key = store.projectCategoryKeys.first { $0 == trimmed || projectKindLabel($0) == trimmed }
        guard key == nil else { notice = WorkspaceLocalization.string("已有这个分类"); return }
        guard !trimmed.isEmpty, trimmed.utf16.count <= 240,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              store.preferences.customProjectCategories.count < 50 else { notice = WorkspaceLocalization.string("请使用有效的分类名称"); return }
        store.preferences.customProjectCategories.append(trimmed)
        newCategory = ""; notice = WorkspaceLocalization.string("分类已添加")
    }
}

private struct ProjectCategoryEditorView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let categoryKey: String
    @State private var name: String
    @State private var error: String?
    @State private var confirmingRemoval = false
    init(categoryKey: String) {
        self.categoryKey = categoryKey
        _name = State(initialValue: projectKindLabel(categoryKey))
    }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUsed: Bool {
        store.state.records.contains { $0.kind.isProjectGroup && $0.deletedAt == nil && $0.projectKind == categoryKey }
    }
    var body: some View {
        Form {
            Section {
                TextField(WorkspaceLocalization.string("分类名称"), text: $name)
            } footer: { Text(WorkspaceLocalization.string("重命名会一起更新当前空间中使用此分类的项目组，包括已归档的项目组。")) }
            Section {
                Button(WorkspaceLocalization.string("删除分类"), systemImage: "trash", role: .destructive) {
                    confirmingRemoval = true
                }
                .disabled(isUsed && store.isReadOnlyWorkspace)
            } footer: { Text(WorkspaceLocalization.string("仅删除分类，使用此分类的项目组将设为无分类，内容不受影响。")) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("编辑分类")).workspaceInlineTitle()
        .confirmationDialog(WorkspaceLocalization.format("删除“%@”分类？", String(describing: projectKindLabel(categoryKey))), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(WorkspaceLocalization.string("删除分类"), role: .destructive) { remove() }
        } message: {
            Text(WorkspaceLocalization.string("项目组及其内容会保留，分类改为无分类。"))
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(WorkspaceLocalization.string("保存")) { save() }
                    .disabled(trimmed.isEmpty || trimmed.utf16.count > 240 || (isUsed && store.isReadOnlyWorkspace))
            }
        }
    }
    private func remove() {
        do { try store.removeProjectCategory(categoryKey); dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard trimmed != projectKindLabel(categoryKey) else { dismiss(); return }
        guard !store.projectCategoryKeys.contains(where: { $0 != categoryKey && ($0 == trimmed || projectKindLabel($0) == trimmed) }) else {
            error = WorkspaceLocalization.string("已有这个分类，请使用其他名称。"); return
        }
        do { try store.renameProjectCategory(categoryKey, to: trimmed); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ReminderPreferencesView: View {
    static var title: String {
        #if os(iOS)
        WorkspaceLocalization.string("提醒与灵动岛")
        #else
        WorkspaceLocalization.string("提醒")
        #endif
    }
    var body: some View {
        Form {
            NotificationSettingsSection()
            #if os(iOS)
            LiveActivityPreferencesSection()
            #endif
        }
        .formStyle(.grouped).navigationTitle(Self.title).workspaceInlineTitle()
    }
}

private struct BackupPreferencesView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var showExport = false
    @State private var showImport = false
    var body: some View {
        Form {
            Section {
                Button(WorkspaceLocalization.string("导出备份"), systemImage: "square.and.arrow.up") {
                    if store.isDemoMode { store.information = WorkspaceLocalization.string("演示模式不会导出文件。") } else { showExport = true }
                }
                Button(WorkspaceLocalization.string("导入备份"), systemImage: "square.and.arrow.down") { showImport = true }
            }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("数据与备份")).workspaceInlineTitle()
            .workspaceSelectionFeedback(trigger: showExport)
            .workspaceSelectionFeedback(trigger: showImport)
            .sheet(isPresented: $showExport) { NavigationStack { ExportArchiveView() }.nativeSheetSize() }
            .sheet(isPresented: $showImport) { NavigationStack { ImportArchiveView() }.nativeSheetSize() }
    }
}

#if os(iOS)
private struct WorkspaceLibraryView: View {
    var body: some View {
        Form {
            Section {
                ForEach([AppDestination.knowledge, .calendar, .timeline, .archives, .trash]) { destination in
                    NavigationLink { DestinationView(destination: destination) } label: {
                        Label(destination.title, systemImage: destination.symbol)
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("工作空间")).workspaceInlineTitle()
    }
}
#endif

private struct AboutWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(WorkspaceLocalization.string("工作坊")).font(.title2.bold())
                    Text("WorkSpace · \(version)").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section { Link(WorkspaceLocalization.string("打开网页版"), destination: BackendService.serviceURL).disabled(store.isDemoMode) }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("关于工作坊")).workspaceInlineTitle()
    }
}

struct ProfileSettingsSection: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @State private var name = ""
    @State private var zone = "Asia/Shanghai"
    @State private var photo: PhotosPickerItem?
    @State private var updatingPhoto = false
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { trimmedName != store.state.profile.name || zone != store.state.profile.timezone }
    var body: some View {
        let avatar = store.state.profile.avatar
        Section(WorkspaceLocalization.string("个人资料")) {
            HStack(spacing: 16) {
                PhotosPicker(selection: $photo, matching: .images) {
                    HStack(spacing: 16) {
                        AvatarView(data: avatar)
                            .frame(width: 64, height: 64).clipShape(Circle())
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill").font(.title3)
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, palette.action)
                            }
                        Text(updatingPhoto ? WorkspaceLocalization.string("正在更新…") : WorkspaceLocalization.string("更换头像")).font(.subheadline)
                    }
                }.buttonStyle(.plain).accessibilityLabel(WorkspaceLocalization.string("更换头像")).disabled(updatingPhoto)
                Spacer()
                if store.state.profile.avatar != nil {
                    Button(WorkspaceLocalization.string("移除头像"), role: .destructive) { store.perform { try store.commit { $0.profile.avatar = nil } } }
                        .buttonStyle(.borderless).font(.caption).disabled(updatingPhoto)
                }
            }.padding(.vertical, 4)
            LabeledContent(WorkspaceLocalization.string("姓名")) { TextField(WorkspaceLocalization.string("姓名"), text: $name).multilineTextAlignment(.trailing).onSubmit(save) }
            Picker(WorkspaceLocalization.string("时区"), selection: $zone) {
                ForEach(Array(Set([zone, "Asia/Shanghai", "Asia/Tokyo", "Europe/London", "America/New_York", TimeZone.current.identifier])).sorted(), id: \.self) { value in
                    Text(zoneName(value)).tag(value)
                }
            }
            if hasChanges {
                Button(WorkspaceLocalization.string("保存修改"), systemImage: "checkmark", action: save).disabled(trimmedName.isEmpty)
            }
        }
        .onAppear { name = store.state.profile.name; zone = store.state.profile.timezone }
        .onChange(of: store.state.profile.name) { previous, current in if name == previous { name = current } }
        .onChange(of: store.state.profile.timezone) { previous, current in if zone == previous { zone = current } }
        .task(id: photo) {
            guard let selectedPhoto = photo else { return }
            updatingPhoto = true
            defer {
                if photo == selectedPhoto { updatingPhoto = false; photo = nil }
            }
            do {
                if let data = try await selectedPhoto.loadTransferable(type: Data.self) {
                    try Task.checkCancellation()
                    guard data.count <= 5 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
                    let avatar = try await Task.detached(priority: .userInitiated) {
                        try AvatarService.normalized(data)
                    }.value
                    try Task.checkCancellation()
                    try store.commit { $0.profile.avatar = avatar }
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { store.errorMessage = error.localizedDescription }
            }
        }
    }
    private func save() {
        guard hasChanges else { return }
        store.perform {
            guard !trimmedName.isEmpty else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请填写姓名。")) }
            try store.commit { $0.profile.name = trimmedName; $0.profile.timezone = zone }
            store.information = WorkspaceLocalization.string("个人资料已保存。")
        }
    }
    private func zoneName(_ value: String) -> String {
        switch value {
        case "Asia/Shanghai": WorkspaceLocalization.string("北京时间")
        case "Asia/Tokyo": WorkspaceLocalization.string("东京时间")
        case "Europe/London": WorkspaceLocalization.string("伦敦时间")
        case "America/New_York": WorkspaceLocalization.string("纽约时间")
        default: TimeZone(identifier: value)?.localizedName(for: .standard, locale: WorkspaceLocalization.locale) ?? value
        }
    }
}
struct AvatarView: View {
    @Environment(\.workspacePalette) private var palette
    var data: Data?
    @State private var decodedImage: CGImage?
    var body: some View {
        Group {
            if let decodedImage {
                Image(decorative: decodedImage, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(palette.accent)
            }
        }
        .task(id: data) {
            let image = await AvatarImageCache.shared.image(for: data)
            guard !Task.isCancelled else { return }
            decodedImage = image
        }
    }
}
struct NotificationSettingsSection: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        Section {
            Toggle(WorkspaceLocalization.string("到期提醒"), isOn: Binding(get: { store.notifications.enabled }, set: { enabled in
                if enabled {
                    Task { do { try await store.notifications.requestAuthorization() } catch { store.errorMessage = error.localizedDescription } }
                } else { store.notifications.enabled = false; store.notifications.reschedule(store.state) }
            }))
            Button(action: openNotificationSettings) {
                HStack {
                    Text(WorkspaceLocalization.string("系统通知"))
                    Spacer()
                    Text(authorizationLabel).foregroundStyle(.secondary)
                }
            }.foregroundStyle(.primary)
        }
        Section {
            DisclosureGroup(WorkspaceLocalization.string("检查提醒")) {
                LabeledContent(WorkspaceLocalization.string("已安排"), value: WorkspaceLocalization.format("%@ 条", String(describing: store.notifications.pendingCount)))
                if store.notifications.unscheduledCount > 0 {
                    Text(WorkspaceLocalization.format("还有 %@ 条后续提醒，打开应用后会继续安排。", String(describing: store.notifications.unscheduledCount)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(WorkspaceLocalization.string("测试提醒"), systemImage: "bell.badge") {
                    Task {
                        do { try await store.notifications.requestAuthorization(); try await store.notifications.sendTest(); store.information = store.isDemoMode ? WorkspaceLocalization.string("演示提醒已触发，不会发送系统通知。") : WorkspaceLocalization.string("三秒后发送测试通知，请查看通知中心。") }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
        }.task { await store.notifications.refreshAuthorization() }
    }
    private var authorizationLabel: String {
        switch store.notifications.authorization {
        case .authorized: WorkspaceLocalization.string("已允许")
        case .denied: WorkspaceLocalization.string("已拒绝")
        case .notDetermined: WorkspaceLocalization.string("尚未授权")
        case .provisional: WorkspaceLocalization.string("暂时允许")
        #if os(iOS)
        case .ephemeral: WorkspaceLocalization.string("临时允许")
        #endif
        @unknown default: WorkspaceLocalization.string("由系统管理")
        }
    }
    private func openNotificationSettings() {
        guard !store.isDemoMode else { store.information = WorkspaceLocalization.string("演示模式不更改系统通知设置。"); return }
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}
struct ExportArchiveView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var encrypted = true
    @State private var password = ""
    @State private var confirmation = ""
    @State private var document: ArchiveDocument?
    @State private var exporting = false
    @State private var preparing = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var error: String?
    var body: some View {
        Form {
            Section(WorkspaceLocalization.string("导出格式")) {
                Toggle(WorkspaceLocalization.string("使用密码加密"), isOn: $encrypted)
                if encrypted { SecureField(WorkspaceLocalization.string("至少 8 个字符"), text: $password); SecureField(WorkspaceLocalization.string("再次输入密码"), text: $confirmation) }
                Text(encrypted ? WorkspaceLocalization.string("密码不会保存。请妥善保管，遗失后无法解密。") : WorkspaceLocalization.string("JSON 包含明文记录和附件，请存放在安全位置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(WorkspaceLocalization.string("包含项目组、事项、截止事项、循环规则、提醒设置、知识笔记、历史记录、PDF 和个人资料。登录凭据与通知授权不导出。"))
                Button(preparing ? WorkspaceLocalization.string("正在准备…") : WorkspaceLocalization.string("选择保存位置"), systemImage: "square.and.arrow.up") {
                    guard !store.isDemoMode else { store.information = WorkspaceLocalization.string("演示模式不会导出文件。"); return }
                    preparing = true
                    let snapshot = store.state, pass = encrypted ? password : nil
                    preparationTask = Task {
                        defer { preparing = false }
                        do {
                            let data = try await Task.detached(priority: .userInitiated) {
                                try ArchiveService.encode(snapshot, password: pass)
                            }.value
                            try Task.checkCancellation()
                            document = ArchiveDocument(data: data); exporting = true
                        } catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(preparing || (encrypted && (password.count < 8 || password != confirmation)))
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("导出归档")).workspaceInlineTitle()
            .onDisappear { preparationTask?.cancel() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("关闭")) { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: document, contentType: encrypted ? .workspaceArchive : .json,
                defaultFilename: WorkspaceLocalization.format("工作坊-%@", String(describing: WorkspaceDates.dayKey(Date(), timezone: store.state.profile.timezone)))) { result in
                switch result {
                case .success: password = ""; confirmation = ""; document = nil; dismiss()
                case .failure(let failure): error = failure.localizedDescription
                }
            }
    }
}
struct ImportArchiveView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var picking = false
    @State private var reading = false
    @State private var readTask: Task<Void, Never>?
    @State private var error: String?
    var body: some View {
        Form {
            Section(WorkspaceLocalization.string("本机归档")) {
                SecureField(WorkspaceLocalization.string("归档密码（明文 JSON 可留空）"), text: $password)
                Text(WorkspaceLocalization.string("导入工作坊归档后，先预览内容，再确认合并。")).font(.caption).foregroundStyle(.secondary)
                Button(reading ? WorkspaceLocalization.string("正在读取…") : WorkspaceLocalization.string("选择归档"), systemImage: "doc.badge.plus") { picking = true }
                    .disabled(reading)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("导入归档")).workspaceInlineTitle()
            .interactiveDismissDisabled(reading)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("关闭")) { readTask?.cancel(); dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.workspaceArchive, .json, .data]) { result in
                guard !reading else { return }
                reading = true
                let pass = password
                readTask = Task {
                    defer { reading = false }
                    do {
                        let url = try result.get()
                        let state = try await Task.detached(priority: .userInitiated) {
                            try ArchiveService.read(url: url, password: pass)
                        }.value
                        try Task.checkCancellation()
                        password = ""
                        dismiss()
                        // Let the importer close before presenting its review.
                        try await Task.sleep(for: .milliseconds(350))
                        store.importDescription = WorkspaceLocalization.format("文件：%@", String(describing: url.lastPathComponent)); store.pendingImport = state
                    } catch is CancellationError { }
                    catch { self.error = error.localizedDescription }
                }
            }
    }
}
struct ImportReviewView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var preferIncoming = false
    @ViewBuilder var body: some View {
        if store.pendingSyncReview != nil { SyncConflictReviewView() }
        else { importForm }
    }
    private var importForm: some View {
        Form {
            if let incoming = store.pendingImport {
                let conflicts = incoming.records.filter { item in store.record(item.id).map { !WorkspaceCoding.equivalent($0, item) } ?? false }.count
                Section(WorkspaceLocalization.string("已校验")) {
                    Text(store.importDescription)
                    LabeledContent(WorkspaceLocalization.string("记录"), value: WorkspaceLocalization.format("%@ 项", String(describing: incoming.records.count)))
                    LabeledContent("PDF", value: WorkspaceLocalization.format("%@ 个", String(describing: incoming.assets.count)))
                    LabeledContent(WorkspaceLocalization.string("同标识内容差异"), value: WorkspaceLocalization.format("%@ 项", String(describing: conflicts)))
                }
                Section(WorkspaceLocalization.string("合并策略")) {
                    Picker(WorkspaceLocalization.string("重复内容"), selection: $preferIncoming) { Text(WorkspaceLocalization.string("保留本机版本")).tag(false); Text(WorkspaceLocalization.string("使用导入版本")).tag(true) }
                    Text(WorkspaceLocalization.string("新增记录会导入；重复标识按此选择处理。导入不会删除本机独有的记录。选择导入版本也会使用其个人资料。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(WorkspaceLocalization.string("确认合并"), systemImage: "arrow.triangle.merge") {
                    do { try store.importState(incoming, preferIncoming: preferIncoming); store.pendingImport = nil; dismiss(); store.information = WorkspaceLocalization.string("归档已合并。") }
                    catch { store.errorMessage = error.localizedDescription }
                }.buttonStyle(WorkspacePrimaryButtonStyle())
                .workspaceActionRow()
            }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("确认导入")).workspaceInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("取消")) { store.cancelSyncReview(); dismiss() } } }
    }
}


struct SyncConflictReviewView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var resolution = WorkspaceSyncResolution.local
    private var differences: [UUID] {
        guard let remote = store.pendingSyncReview?.remote.snapshot else { return [] }
        let local = store.syncReviewLocal ?? store.state
        let left = Dictionary(uniqueKeysWithValues: local.records.map { ($0.id, $0) })
        let right = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.id, $0) })
        return Set(left.keys).union(right.keys).filter { id in
            if let a = left[id], let b = right[id] { return !WorkspaceCoding.equivalent(a, b) }
            return true
        }.sorted { $0.uuidString < $1.uuidString }
    }
    var body: some View {
        List {
            Section(WorkspaceLocalization.string("冲突选择")) {
                Picker(WorkspaceLocalization.string("同时修改的内容"), selection: $resolution) {
                    ForEach(WorkspaceSyncResolution.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(WorkspaceLocalization.string("选择同时修改的内容要保留哪个版本，其他更改会自动合并。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let checkpoint = store.pendingSyncReview {
                Section(WorkspaceLocalization.string("个人资料")) {
                    LabeledContent(WorkspaceLocalization.string("本机"), value: (store.syncReviewLocal ?? store.state).profile.name + " · " + (store.syncReviewLocal ?? store.state).profile.timezone)
                    LabeledContent(WorkspaceLocalization.string("云端"), value: checkpoint.remote.snapshot.profile.name + " · " + checkpoint.remote.snapshot.profile.timezone)
                }
                Section(WorkspaceLocalization.string("内容比较")) {
                    if differences.isEmpty { Text(WorkspaceLocalization.string("记录内容一致；请核对循环、附件或个人资料的变更。")) }
                    ForEach(differences, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(isConflict(id) ? WorkspaceLocalization.string("双方同时修改：将按您的选择处理") : WorkspaceLocalization.string("单端改动：将自动合并"), systemImage: isConflict(id) ? "exclamationmark.triangle" : "arrow.triangle.merge")
                                .font(.caption.weight(.semibold)).foregroundStyle(isConflict(id) ? Color.orange : Color.secondary)
                            version(WorkspaceLocalization.string("本机"), record: (store.syncReviewLocal ?? store.state).records.first { $0.id == id })
                            Divider()
                            version(WorkspaceLocalization.string("云端"), record: checkpoint.remote.snapshot.records.first { $0.id == id })
                        }.padding(.vertical, 6)
                    }
                }
                Section(WorkspaceLocalization.string("其他资料")) {
                    LabeledContent(WorkspaceLocalization.string("本机循环 / 附件"), value: "\((store.syncReviewLocal ?? store.state).series.count) / \((store.syncReviewLocal ?? store.state).assets.count)")
                    LabeledContent(WorkspaceLocalization.string("云端循环 / 附件"), value: "\(checkpoint.remote.snapshot.series.count) / \(checkpoint.remote.snapshot.assets.count)")
                }
            }
        }.navigationTitle(WorkspaceLocalization.string("比较同步内容"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("取消")) { store.cancelSyncReview(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkspaceLocalization.string("应用选择")) {
                        do { try store.resolveSyncReview(resolution); dismiss(); store.information = WorkspaceLocalization.string("冲突选择已保存，可立即同步到其他设备。") }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
    }
    @ViewBuilder private func version(_ source: String, record: WorkspaceRecord?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(source).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let record {
                Text(record.title).font(.headline).foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary).textSelection(.enabled)
                if record.deletedAt != nil { Text(WorkspaceLocalization.string("已删除")).font(.subheadline) }
                else if record.archivedAt != nil { Text(WorkspaceLocalization.string("已归档")).font(.subheadline) }
                else if record.isFinished { Label(WorkspaceLocalization.string("已完成"), systemImage: "checkmark").font(.subheadline).foregroundStyle(Color.workspaceCompleted) }
                if let due = record.dueDate { Text(dateLabel(due, record: record)).font(.caption) }
                if !record.summary.isEmpty { Text(record.summary).textSelection(.enabled) }
                if !record.body.isEmpty {
                    Text(record.body).lineLimit(6).textSelection(.enabled)
                    DisclosureGroup(WorkspaceLocalization.string("查看完整正文")) { Text(record.body).font(.body).textSelection(.enabled) }
                }
            } else { Text(WorkspaceLocalization.string("此端没有这条记录")).foregroundStyle(.secondary) }
        }
    }
    private func isConflict(_ id: UUID) -> Bool {
        let old = store.syncReviewBase?.records.first { $0.id == id }
        let local = (store.syncReviewLocal ?? store.state).records.first { $0.id == id }
        let remote = store.pendingSyncReview?.remote.snapshot.records.first { $0.id == id }
        func equivalent(_ a: WorkspaceRecord?, _ b: WorkspaceRecord?) -> Bool {
            if let a, let b { return WorkspaceCoding.equivalent(a, b) }
            return a == nil && b == nil
        }
        return !equivalent(local, remote) && !equivalent(local, old) && !equivalent(remote, old)
    }
    private func dateLabel(_ date: Date, record: WorkspaceRecord) -> String {
        var format: Date.FormatStyle = record.dateOnly ? .dateTime.year().month().day() : .dateTime.year().month().day().hour().minute()
        format.locale = WorkspaceLocalization.locale; format.timeZone = record.calendar.timeZone
        return format.format(date) + " · " + record.timezone
    }

}
