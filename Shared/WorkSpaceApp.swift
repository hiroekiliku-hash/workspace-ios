import SwiftUI
#if os(macOS)
import AppKit
#else
import WidgetKit
#endif

@main @MainActor struct WorkSpaceApp: App {
    @State private var store: WorkspaceStore?
    // App-owned state survives demo switches and window recreation during this launch.
    @State private var hasFinishedLaunch = !WorkspaceLaunchPreferences.shouldPlay
    @State private var isReadyForInteraction = false
    #if os(macOS)
    @AppStorage("showMenuBarCountdown") private var showMenuBarCountdown = true
    @StateObject private var appUpdater = MacAppUpdater()
    #endif
    @State private var startupError: String?
    @State private var startupTask: Task<Void, Never>?
    @State private var pendingStartupURL: URL?
    @AppStorage(WorkspaceColorTheme.preferenceKey) private var savedColorTheme = WorkspaceColorTheme.blue.rawValue
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NativePlatformDelegate.self) private var delegate
    #else
    @UIApplicationDelegateAdaptor(NativePlatformDelegate.self) private var delegate
    #endif
    private func initializeWorkspace() async {
        guard store == nil, startupError == nil else { return }
        if let startupTask { await startupTask.value; return }
        let task = Task { @MainActor in await loadWorkspace() }
        startupTask = task
        await task.value
    }
    private func loadWorkspace() async {
        defer { startupTask = nil }
        do {
            #if DEBUG
            let smokeTest = ProcessInfo.processInfo.arguments.contains("--ui-smoke") || ProcessInfo.processInfo.arguments.contains("--ui-smoke-demo")
            #else
            let smokeTest = false
            #endif
            #if DEBUG
            let clock = ContinuousClock()
            let started = clock.now
            #endif
            let isolatedDemo = smokeTest && ProcessInfo.processInfo.arguments.contains("--ui-smoke-recurrence")
            async let storage = SwiftDataRepository.prepareStartup(inMemory: smokeTest)
            async let session = BackendService.prepareSession(isDemoMode: smokeTest)
            let loaded = try await storage
            let queries = try await WorkspaceStore.prepareRecordQueries(loaded.state.records)
            let savedSession = await session
            try Task.checkCancellation()
            let store = try WorkspaceStore(repository: SwiftDataRepository(preparedStartup: loaded),
                isDemoMode: isolatedDemo,
                preparedSession: savedSession, preparedQueries: queries)
            #if DEBUG
            print("WORKSPACE_STARTUP_PREPARED duration=\(started.duration(to: clock.now))")
            #endif
            #if DEBUG
            if smokeTest {
                var project = WorkspaceRecord(kind: .project, title: "原生界面验收项目", id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
                project.status = "ACTIVE"
                try store.save(project, expectedVersion: nil)
                var action = WorkspaceRecord(kind: .task, title: "整理课程资料并完成下一步行动", id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)
                action.projectID = project.id
                try store.save(action, expectedVersion: nil)
                var deadline = WorkspaceRecord(kind: .deadline, title: "提交本周课程报告：完整标题和重要截止内容，附研究摘要与课程实验记录", id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!)
                deadline.dateOnly = false; deadline.dueDate = Date().addingTimeInterval(7200)
                try store.save(deadline, expectedVersion: nil)
                var overdue = WorkspaceRecord(kind: .deadline, title: "已逾期事项，优先处理", id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!)
                overdue.dateOnly = false; overdue.dueDate = Date().addingTimeInterval(-600)
                try store.save(overdue, expectedVersion: nil)
                if ProcessInfo.processInfo.arguments.contains("--ui-smoke-deadlines") { store.navigation = .deadlines }
                if ProcessInfo.processInfo.arguments.contains("--ui-smoke-recurrence") {
                    var repeating = WorkspaceRecord(kind: .task, title: "每天复习课程笔记")
                    repeating.scheduledAt = Date().addingTimeInterval(3600)
                    try store.save(repeating, expectedVersion: nil, recurrenceRule: RecurrenceRule(frequency: .daily))
                    store.navigation = .actions
                    do { try store.verifyProjectedOccurrenceActions(); print("RECURRENCE_MANAGEMENT_PASS") }
                    catch { store.errorMessage = error.localizedDescription; print("RECURRENCE_MANAGEMENT_FAILED: \(error)") }
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-smoke-notification") {
                    Task {
                        do {
                            try await store.notifications.requestAuthorization()
                            try await store.notifications.sendTest()
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-smoke-demo") {
                try store.beginDemo()
                if ProcessInfo.processInfo.arguments.contains("--verify-demo-isolation") {
                    Task { do { try await store.verifyDemoIsolation(); print("DEMO_ISOLATION_PASS") }
                        catch { store.errorMessage = error.localizedDescription; print("DEMO_ISOLATION_FAILED: \(error)") } }
                }
            }
            #endif
            self.store = store
            RemotePushBridge.shared.store = store
            #if DEBUG
            if smokeTest && ProcessInfo.processInfo.arguments.contains("--verify-startup-preparation") {
                try await WorkspaceStore.verifyStartupHomePreparation()
                print("WORKSPACE_HOME_PREPARATION_PASS")
            }
            #endif
            #if DEBUG && os(iOS)
            if ProcessInfo.processInfo.arguments.contains("--verify-course-number-keyboard") {
                do {
                    try CourseNumberKeyboardRegression.run()
                    print("COURSE_NUMBER_KEYBOARD_PASS")
                } catch {
                    print("COURSE_NUMBER_KEYBOARD_FAILED: \(error)")
                    throw error
                }
            }
            #endif
        } catch {
            startupError = error.localizedDescription
        }
    }
    var body: some Scene {
        #if os(macOS)
        mainWindow.commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                MacCheckForUpdatesButton(updater: appUpdater)
            }
            if let store { WorkspaceCommands(store: store.activeStore) }
        }
        Settings {
            if let store { NavigationStack { SettingsView() }.modifier(MacWorkspacePresentations()).modifier(WorkspaceThemeModifier())
                .environment(store.activeStore).id(ObjectIdentifier(store.activeStore))
                .frame(minWidth: 520, idealWidth: 660, minHeight: 480, idealHeight: 700)
                .environment(\.locale, selectedLocale)
                .environment(\.timeZone, WorkspaceDates.calendar(store.state.profile.timezone).timeZone)
                .preferredColorScheme(settingsAppearance) }
            else if startupError != nil { startupFailure }
            else { startupPlaceholder.task { await initializeWorkspace() } }
        }
        MenuBarExtra(isInserted: $showMenuBarCountdown) {
            if let store { MacDeadlineMenu().modifier(WorkspaceThemeModifier()).environment(store.activeStore).environment(\.locale, selectedLocale) }
        } label: {
            Image(systemName: "hourglass")
                .accessibilityLabel("工作坊倒计时")
        }.menuBarExtraStyle(.window)
        #else
        mainWindow
        #endif
    }
    @AppStorage(WorkspaceLanguage.preferenceKey) private var languageRaw = WorkspaceLanguage.system.rawValue
    private var selectedLocale: Locale {
        let language = WorkspaceLanguage(rawValue: languageRaw) ?? .system
        return Locale(identifier: language.resolvedIdentifier(preferredLanguages: Locale.preferredLanguages))
    }
    @AppStorage("appearance") private var appearanceRaw = "system"
    private var settingsAppearance: ColorScheme? { appearanceRaw == "light" ? .light : appearanceRaw == "dark" ? .dark : nil }
    private var mainWindow: some Scene {
        #if os(iOS)
        WindowGroup { rootContent }
            .defaultSize(width: 1180, height: 780)
            .backgroundTask(.appRefresh(WorkspaceBackgroundSync.taskIdentifier)) {
                await initializeWorkspace()
                await WorkspaceBackgroundSync.perform(store)
            }
        #else
        WindowGroup(id: "workspace") { rootContent }
            .defaultSize(width: 1380, height: 860)
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
        #endif
    }
    private var rootContent: some View {
        WorkspaceLaunchHost(isFinished: $hasFinishedLaunch, isReady: isReadyForInteraction || startupError != nil) {
            if let realStore = store {
                let store = realStore.activeStore
                Group {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-smoke-backend") {
                        NavigationStack { BackendSettingsView() }
                            .task { await store.prepareForInteraction(); isReadyForInteraction = true }
                    } else if store.isDemoMode, ProcessInfo.processInfo.arguments.contains("--ui-smoke-course-player") {
                        CourseServerPlayerSmokeView()
                            .task { await store.prepareForInteraction(); isReadyForInteraction = true }
                    } else if store.isDemoMode, ProcessInfo.processInfo.arguments.contains("--ui-smoke-course-layout") {
                        CourseLayoutSmokeView(code: ProcessInfo.processInfo.arguments.contains("--ui-smoke-code-layout"))
                            .task { await store.prepareForInteraction(); isReadyForInteraction = true }
                    } else if ProcessInfo.processInfo.arguments.contains("--ui-smoke-settings") {
                        NavigationStack { SettingsView() }
                            .task { await store.prepareForInteraction(); isReadyForInteraction = true }
                    } else {
                        workspaceRoot(store)
                    }
                    #else
                    workspaceRoot(store)
                    #endif
                }
                .modifier(WorkspaceThemeModifier()).environment(store)
            } else if startupError != nil {
                startupFailure
            } else {
                startupPlaceholder
            }
        }
        .environment(\.locale, selectedLocale)
        .onChange(of: languageRaw, initial: true) { _, value in
            #if os(iOS)
            let defaults = UserDefaults(suiteName: WorkspaceLanguage.sharedDefaults)
            if defaults?.string(forKey: WorkspaceLanguage.preferenceKey) != value {
                defaults?.set(value, forKey: WorkspaceLanguage.preferenceKey)
                WidgetCenter.shared.reloadAllTimelines()
            }
            #endif
        }
        .environment(\.workspacePalette, startupTheme.palette)
        .tint(startupTheme.palette.accent)
        .preferredColorScheme(appAppearance)
        .nativeWindowSize()
        .task { await initializeWorkspace() }
        #if os(macOS)
        .task(id: isReadyForInteraction && hasFinishedLaunch) {
            if isReadyForInteraction && hasFinishedLaunch { await appUpdater.startAfterLaunch() }
        }
        #endif
        .onOpenURL { url in if store == nil { pendingStartupURL = url } }
    }
    private func workspaceRoot(_ store: WorkspaceStore) -> some View {
        WorkspaceRootView(pendingStartupURL: $pendingStartupURL, startupReady: $isReadyForInteraction,
            prewarmsCourseRuntime: !hasFinishedLaunch)
            .id(ObjectIdentifier(store))
    }
    private var startupPlaceholder: some View {
        ProgressView("正在打开工作坊…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .accessibilityIdentifier("workspace-startup-loading")
    }
    private var startupTheme: WorkspaceColorTheme {
        if let active = store?.activeStore, active.isDemoMode {
            return WorkspaceColorTheme(rawValue: active.demoColorTheme) ?? .blue
        }
        return WorkspaceColorTheme(rawValue: savedColorTheme) ?? .blue
    }
    private var appAppearance: ColorScheme? {
        let raw = store?.activeStore.isDemoMode == true ? store?.activeStore.demoAppearance ?? appearanceRaw : appearanceRaw
        return raw == "light" ? .light : raw == "dark" ? .dark : nil
    }
    private var startupFailure: some View {
        ContentUnavailableView(WorkspaceLocalization.string("无法打开本机资料库"), systemImage: "externaldrive.badge.exclamationmark",
            description: Text((startupError ?? WorkspaceLocalization.string("未知存储错误")) + "\n" + WorkspaceLocalization.string("原有数据没有被删除。请保留资料库并联系维护者。")))
            .padding().frame(minWidth: 320, minHeight: 300)
    }
}
extension View {
    @ViewBuilder func nativeWindowSize() -> some View {
        #if os(macOS)
        self.frame(minWidth: 820, minHeight: 540)
        #else
        self
        #endif
    }
}
#if os(macOS)
@MainActor struct WorkspaceCommands: Commands {
    let store: WorkspaceStore
    @FocusedValue(\.workspaceCreation) private var creation
    @AppStorage("showMenuBarCountdown") private var showMenuBarCountdown = true
    @AppStorage("macShowRecordDetails") private var showsRecordDetails = true
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(creation?.title ?? WorkspaceLocalization.format("新建%@", (creation?.kind ?? store.navigation.creationKind).title)) {
                if let creation { creation.create() } else { store.createKind = store.navigation.creationKind }
            }.keyboardShortcut("n").disabled(store.isReadOnlyWorkspace || creation?.isEnabled == false)
            Button(WorkspaceLocalization.string("新建截止事项")) { store.createKind = .deadline }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(store.isReadOnlyWorkspace)
            Button(WorkspaceLocalization.string("新建项目组")) { store.createKind = .project }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(store.isReadOnlyWorkspace)
        }
        CommandGroup(after: .sidebar) {
            Toggle(WorkspaceLocalization.string("显示记录详情"), isOn: $showsRecordDetails)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(![AppDestination.projects, .areas, .actions, .deadlines, .knowledge, .timeline, .calendar].contains(store.navigation))
        }
        CommandMenu(WorkspaceLocalization.string("工作空间")) {
            Button(WorkspaceLocalization.string("首页")) { store.navigation = .overview }.keyboardShortcut("0")
            Button(WorkspaceLocalization.string("事项")) { store.navigation = .actions }.keyboardShortcut("1")
            Button(WorkspaceLocalization.string("截止事项")) { store.navigation = .deadlines }.keyboardShortcut("2")
            Button(WorkspaceLocalization.string("项目组")) { store.navigation = .projects }.keyboardShortcut("3")
            Button(WorkspaceLocalization.string("课程")) { store.navigation = .courses }.keyboardShortcut("4")
            Button(WorkspaceLocalization.string("知识库")) { store.navigation = .knowledge }.keyboardShortcut("5")
            Divider()
            Button(WorkspaceLocalization.string("日历")) { store.navigation = .calendar }.keyboardShortcut("6")
            Button(WorkspaceLocalization.string("时间线")) { store.navigation = .timeline }.keyboardShortcut("7")
            Divider()
            Button(WorkspaceLocalization.string("回收站")) { store.navigation = .trash }
            Toggle(WorkspaceLocalization.string("菜单栏倒计时"), isOn: $showMenuBarCountdown)
            Button(WorkspaceLocalization.string("刷新")) {
                if store.navigation == .courses { Task { await store.courses.refresh() } }
                else { store.refresh() }
            }.keyboardShortcut("r")
        }
    }
}
#endif

#if os(macOS)
/// Latch presentations to the window where the operation was started. The
/// Settings scene has its own host, so errors and conflict review stay there.
struct MacWorkspacePresentations: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.controlActiveState) private var activeState
    @State private var showError = false
    @State private var showInformation = false
    @State private var showImport = false
    func body(content: Content) -> some View {
        content
            .onAppear { presentPending() }
            .onChange(of: activeState) { _, _ in presentPending() }
            .onChange(of: store.errorMessage) { _, _ in presentPending() }
            .onChange(of: store.information) { _, _ in presentPending() }
            .onChange(of: store.pendingImport != nil) { _, _ in presentPending() }
            .alert("操作未完成", isPresented: $showError) {
                Button(WorkspaceLocalization.string("好")) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .alert("工作坊", isPresented: $showInformation) {
                Button(WorkspaceLocalization.string("好")) { store.information = nil }
            } message: { Text(store.information ?? "") }
            .sheet(isPresented: $showImport, onDismiss: { store.cancelSyncReview() }) {
                NavigationStack { ImportReviewView() }.environment(store).nativeSheetSize()
            }
    }
    private func presentPending() {
        guard activeState == .key else { return }
        if store.errorMessage != nil { showError = true }
        else if store.pendingImport != nil { showImport = true }
        else if store.information != nil { showInformation = true }
    }
}

private struct MacDeadlineMenu: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        // Reuse the same grouping as the DDL list. Only the displayed timer
        // updates each second; workspace projection runs at most twice a minute.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let records = store.records(.deadline) + store.actionRecords.filter { $0.dueDate != nil }.map { record in
                var deadline = record; deadline.kind = .deadline; return deadline
            }
            let groups = WorkspaceLogic.deadlineCountdownGroups(records, now: context.date, timezone: store.state.profile.timezone)
                .filter { $0.dueDates.contains { $0 > context.date } }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(WorkspaceLocalization.string(store.isDemoMode ? "演示倒计时" : "工作坊")).font(.headline)
                    Spacer()
                    Button(WorkspaceLocalization.string("打开"), systemImage: "arrow.up.forward.app") { open(nil) }.labelStyle(.iconOnly)
                }
                if let group = groups.first {
                    Text(timerInterval: context.date...group.countdownDate(at: context.date), countsDown: true)
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(WorkspaceLocalization.string("距离最近截止")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(groups.prefix(5))) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(group.countdownDate(at: context.date).formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(group.records) { record in
                                        Button { open(record.id) } label: {
                                            HStack { Text(record.title).lineLimit(2); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: 290)
                } else {
                    ContentUnavailableView(WorkspaceLocalization.string("暂无待截止事项"), systemImage: "hourglass", description: Text(WorkspaceLocalization.string("设置截止时间后，会在这里显示倒计时。")))
                }
                Button(WorkspaceLocalization.string("查看全部截止事项")) { store.navigation = .deadlines; open(nil) }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }.padding(20).frame(width: 360)
        }
        .environment(\.locale, WorkspaceLocalization.locale)
        .environment(\.timeZone, WorkspaceDates.calendar(store.state.profile.timezone).timeZone)
    }
    private func open(_ id: UUID?) {
        openWindow(id: "workspace")
        if let id { store.openedRecordID = id }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif
