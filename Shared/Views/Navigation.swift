import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppDestination: String, CaseIterable, Identifiable {
    case overview, projects, actions, deadlines, courses, more, knowledge, calendar, timeline, archives, areas, settings, trash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: WorkspaceLocalization.string("首页")
        case .projects: WorkspaceLocalization.string("项目组")
        case .actions: WorkspaceLocalization.string("事项")
        case .deadlines: WorkspaceLocalization.string("截止事项")
        case .courses: WorkspaceLocalization.string("课程")
        case .more: WorkspaceLocalization.string("更多")
        case .knowledge: WorkspaceLocalization.string("知识库")
        case .calendar: WorkspaceLocalization.string("日历")
        case .timeline: WorkspaceLocalization.string("时间线")
        case .archives: WorkspaceLocalization.string("归档")
        case .areas: WorkspaceLocalization.string("项目组")
        case .settings: WorkspaceLocalization.string("设置")
        case .trash: WorkspaceLocalization.string("回收站")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .projects: "folder"
        case .actions: "checklist"
        case .deadlines: "hourglass"
        case .courses: "graduationcap"
        case .more: "ellipsis.circle"
        case .knowledge: "book.closed"
        case .calendar: "calendar"
        case .timeline: "chart.bar.xaxis"
        case .archives: "archivebox"
        case .areas: "square.stack.3d.up"
        case .settings: "gearshape"
        case .trash: "trash"
        }
    }
    var creationKind: ItemKind {
        switch self { case .projects, .areas: .project; case .deadlines: .deadline; case .knowledge: .knowledge; default: .task }
    }
}
struct RecordRoute: Identifiable { var id: UUID }

struct WorkspaceRootView: View {
    @Binding var pendingStartupURL: URL?
    @Binding var startupReady: Bool
    var prewarmsCourseRuntime = false
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceLaunchInProgress) private var launchInProgress
    // Prepare the welcome page behind the launch cover, so the fade reveals its final destination.
    @State private var showGettingStarted = UserDefaults.standard.integer(forKey: "gettingStartedVersion") < GettingStartedVersion.current
    @State private var projectSection = AppDestination.projects
    @AppStorage("scheduleViewMode") private var savedScheduleSectionRaw = AppDestination.timeline.rawValue
    @AppStorage("demoScheduleViewMode") private var demoScheduleSectionRaw = AppDestination.timeline.rawValue
    init(pendingStartupURL: Binding<URL?> = .constant(nil), startupReady: Binding<Bool> = .constant(true),
         prewarmsCourseRuntime: Bool = false) {
        _pendingStartupURL = pendingStartupURL
        _startupReady = startupReady
        self.prewarmsCourseRuntime = prewarmsCourseRuntime
    }
    var body: some View {
        @Bindable var store = store
        platformNavigation
            .tint(palette.accent)
            .environment(\.timeZone, WorkspaceDates.calendar(store.state.profile.timezone).timeZone)
            .preferredColorScheme(appearance)
            .sheet(item: $store.createKind) { kind in NavigationStack { RecordEditorView(kind: kind) }.nativeEditorPresentation() }
            .sheet(item: route) { route in
                NavigationStack {
                    RecordDetailView(id: route.id)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("关闭")) { store.openedRecordID = nil } } }
                }
                .nativeSheetSize()
            }
            #if os(macOS)
            .modifier(MacWorkspacePresentations())
            #else
            .sheet(isPresented: Binding(get: { store.pendingImport != nil }, set: { if !$0 { store.cancelSyncReview() } })) {
                NavigationStack { ImportReviewView() }.nativeSheetSize()
            }
            .alert(WorkspaceLocalization.string("操作未完成"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(WorkspaceLocalization.string("好")) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .alert(WorkspaceLocalization.string("工作坊"), isPresented: Binding(get: { store.information != nil }, set: { if !$0 { store.information = nil } })) {
                Button(WorkspaceLocalization.string("好")) { store.information = nil }
            } message: { Text(store.information ?? "") }
            #endif
            .modifier(WorkspaceRecordDragOverlay())
            .modifier(WorkspaceFeedbackModifier())
            .gettingStarted(isPresented: Binding(get: { showGettingStarted && !store.isDemoMode },
                                               set: { showGettingStarted = $0 }), embedded: true)
            .task(id: canPrepareVisibleWindow, priority: .utility) {
                guard canPrepareVisibleWindow else { return }
                let firstPreparation = !startupReady
                #if DEBUG
                let clock = ContinuousClock(), started = clock.now
                #endif
                // Work while the real navigation is mounted under the launch/welcome cover.
                // Returning from the background takes the same path without replaying launch.
                await store.refreshForInteraction()
                guard !Task.isCancelled else { return }
                await store.prepareForInteraction()
                guard !Task.isCancelled else { return }
                await store.courses.prepareForInteraction(preloadFirstCourse: firstPreparation && prewarmsCourseRuntime)
                guard !Task.isCancelled else { return }
                if firstPreparation {
                    // Even with the animation disabled, use the initial loading
                    // cover to prepare the actual server-player WebKit instance.
                    await Task.yield()
                    await prepareCoveredCourseRuntime()
                    guard !Task.isCancelled else { return }
                }
                // Allow navigation its first layout before the cover begins to leave.
                await Task.yield()
                startupReady = true
                #if DEBUG
                if firstPreparation { print("WORKSPACE_INTERACTION_READY duration=\(started.duration(to: clock.now))") }
                #endif
                store.scheduleSync()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    if scenePhase == .active {
                        store.scheduleSync()
                        #if os(iOS)
                        store.liveActivity.synchronize(store.state)
                        #endif
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                if phase == .background { WorkspaceBackgroundSync.updateSchedule(for: store) }
                #endif
                #if os(macOS)
                if phase == .background { store.cancelInteractionPreparation() }
                #else
                if phase != .active { store.cancelInteractionPreparation() }
                #endif
            }
            .task(id: scenePhase == .active && !launchInProgress, priority: .utility) {
                guard scenePhase == .active, !launchInProgress else { return }
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                guard !arguments.contains("--ui-smoke"), !arguments.contains("--ui-smoke-demo") else { return }
                #endif
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                await AppContentService.shared.refresh()
            }
            .onDisappear { store.cancelInteractionPreparation() }
            .onOpenURL(perform: handleOpenURL)
            .onChange(of: pendingStartupURL, initial: true) { _, url in
                guard let url else { return }
                pendingStartupURL = nil
                handleOpenURL(url)
            }
    }
    private var canPrepareVisibleWindow: Bool {
        #if os(macOS)
        scenePhase != .background
        #else
        scenePhase == .active
        #endif
    }
    private func prepareCoveredCourseRuntime() async {
        let gate = WorkspaceCourseWarmupGate()
        await withTaskCancellationHandler {
            await gate.prepare()
        } onCancel: { Task { @MainActor in gate.finish() } }
    }
    private func handleOpenURL(_ url: URL) {
        #if os(iOS)
        if url.scheme == "guangyi-workspace", url.host == "widget" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let context = query.first(where: { $0.name == "context" })?.value, context != store.widgetContextID { return }
            if let demo = query.first(where: { $0.name == "demo" })?.value, demo != store.liveActivity.demoSessionID?.uuidString { return }
            store.navigation = .overview
            return
        }
        #endif
        if url.scheme == "guangyi-workspace", let id = UUID(uuidString: url.lastPathComponent), store.record(id) != nil {
            #if os(iOS)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let context = query.first(where: { $0.name == "context" })?.value, context != store.widgetContextID { return }
            let linkedSession = query.first { $0.name == "demo" }?.value
            guard linkedSession == store.liveActivity.demoSessionID?.uuidString else { return }
            #endif
            store.openedRecordID = id
        } else if url.isFileURL {
            Task {
                do {
                    let imported = try await Task.detached(priority: .userInitiated) {
                        try ArchiveService.read(url: url, password: nil)
                    }.value
                    try Task.checkCancellation()
                    store.importDescription = WorkspaceLocalization.format("文件：%@", String(describing: url.lastPathComponent))
                    store.pendingImport = imported
                } catch { store.errorMessage = error.localizedDescription }
            }
        }
    }
    @AppStorage("appearance") private var appearanceRaw = "system"
    private var appearance: ColorScheme? {
        let value = store.isDemoMode ? store.demoAppearance : appearanceRaw
        return value == "light" ? .light : value == "dark" ? .dark : nil
    }
    private var scheduleSection: AppDestination {
        get {
            let raw = store.isDemoMode ? demoScheduleSectionRaw : savedScheduleSectionRaw
            return raw == AppDestination.calendar.rawValue ? .calendar : .timeline
        }
        nonmutating set {
            let raw = newValue == .calendar ? AppDestination.calendar.rawValue : AppDestination.timeline.rawValue
            if store.isDemoMode { demoScheduleSectionRaw = raw }
            else { savedScheduleSectionRaw = raw }
        }
    }
    private var route: Binding<RecordRoute?> {
        Binding(get: { store.openedRecordID.map { RecordRoute(id: $0) } }, set: { store.openedRecordID = $0?.id })
    }
    @ViewBuilder private var platformNavigation: some View {
        #if os(macOS)
        MacWorkspaceNavigation()
        #else
        TabView(selection: Binding<AppDestination>(get: {
            switch store.navigation {
            case .overview, .courses: store.navigation
            case .timeline, .calendar: .timeline
            case .projects, .areas, .actions, .deadlines: .projects
            default: .overview
            }
        }, set: {
            switch $0 {
            case .projects: store.navigation = projectSection
            case .timeline: store.navigation = scheduleSection
            default: store.navigation = $0
            }
        })) {
            ForEach([AppDestination.overview, .timeline, .projects, .courses]) { destination in
                NavigationStack {
                    Group {
                        if destination == .projects {
                            ProjectBrowserView(section: Binding(get: { projectSection }, set: {
                                projectSection = $0
                                store.navigation = $0
                            }))
                        } else if destination == .timeline {
                            ScheduleBrowserView(section: Binding(get: { scheduleSection }, set: {
                                scheduleSection = $0
                                store.navigation = $0
                            }))
                        } else {
                            DestinationView(destination: destination)
                        }
                    }
                    .toolbar {
                        if destination == .overview {
                            ToolbarItem { NavigationLink(value: AppDestination.settings) { Label(WorkspaceLocalization.string("设置"), systemImage: "gearshape") } }
                        }
                    }
                    .navigationDestination(for: AppDestination.self) { DestinationView(destination: $0) }
                }
                .tabItem {
                    let label = destination == .timeline ? scheduleSection : destination
                    Label(destination == .projects ? WorkspaceLocalization.string("项目") : label.title, systemImage: label.symbol)
                }
                .tag(destination)
            }
        }
        .onChange(of: store.navigation, initial: true) { _, destination in
            switch destination {
            case .projects, .actions, .deadlines: projectSection = destination
            case .areas: projectSection = .projects
            case .timeline, .calendar: scheduleSection = destination
            default: break
            }
        }
        #endif
    }
}

/// A timeout releases the cover even if WebKit has a shared waiter or is still
/// compiling content rules. Cancelling a Task and awaiting its value would not.
@MainActor private final class WorkspaceCourseWarmupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var finished = false

    func prepare() async {
        guard !finished, !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            work = Task { [self] in
                await CourseInteractionPrewarmer.prepare()
                finish()
            }
            timeout = Task { [self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                finish()
            }
        }
    }
    func finish() {
        guard !finished else { return }
        finished = true
        work?.cancel(); work = nil
        timeout?.cancel(); timeout = nil
        continuation?.resume(); continuation = nil
    }
}

#if os(iOS)
/// One stable tab keeps navigation selected while its schedule presentation changes.
private struct ScheduleBrowserView: View {
    @Binding var section: AppDestination
    private var alternate: AppDestination { section == .calendar ? .timeline : .calendar }

    var body: some View {
        Group {
            if section == .calendar { WorkspaceCalendarView() }
            else { WorkspaceTimelineView() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    section = alternate
                } label: {
                    Label(WorkspaceLocalization.format("切换到%@视图", String(describing: alternate.title)), systemImage: alternate.symbol)
                }
                .labelStyle(.iconOnly)
                .accessibilityValue(WorkspaceLocalization.format("当前为%@视图", String(describing: section.title)))
                .accessibilityIdentifier("schedule-view-toggle")
            }
        }
        .workspaceSelectionFeedback(trigger: section)
    }
}
#endif

/// Keep project browsing and both item lists within one stable tab.
private struct ProjectBrowserView: View {
    @Binding var section: AppDestination
    var body: some View {
        Group {
            switch section {
            case .actions:
                RecordListView(kind: .task, includedKinds: [.task, .reminder, .milestone],
                    projectSection: $section)
            case .deadlines:
                RecordListView(kind: .deadline, projectSection: $section)
            default:
                RecordListView(kind: .project, includedKinds: [.project, .area], projectSection: $section)
            }
        }
        .workspaceSelectionFeedback(trigger: section)
    }
}

struct DestinationView: View {
    let destination: AppDestination
    @ViewBuilder var body: some View {
        switch destination {
        case .overview: OverviewView()
        case .projects: ProjectGroupsView()
        case .actions: ActionsView()
        case .deadlines: RecordListView(kind: .deadline)
        case .knowledge: RecordListView(kind: .knowledge)
        case .calendar: WorkspaceCalendarView()
        case .timeline:
            #if os(iOS)
            WorkspaceTimelineView()
            #else
            MacWorkspaceTimelineView()
            #endif
        case .courses: CoursesView()
        case .areas: ProjectGroupsView()
        case .archives: ArchivesView()
        case .settings, .more: SettingsView()
        case .trash: TrashView()
        }
    }
}
extension View {
    @ViewBuilder func workspaceInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func workspaceResponsiveTitle() -> some View {
        #if os(iOS)
        modifier(WorkspaceResponsiveTitleModifier())
        #else
        self
        #endif
    }
    func workspaceSelectionFeedback<T: Equatable>(trigger: T, feedback: SensoryFeedback = .impact(weight: .medium, intensity: 0.85)) -> some View {
        modifier(WorkspaceSelectionFeedback(trigger: trigger, feedback: feedback))
    }
    /// Give standalone form actions room outside the button's own rounded background.
    func workspaceActionRow() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
    @ViewBuilder func nativeSheetSize() -> some View {
        #if os(macOS)
        self.frame(minWidth: 580, idealWidth: 640, minHeight: 520, idealHeight: 680)
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct WorkspaceResponsiveTitleModifier: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(verticalSizeClass == .compact ? .inline : .large)
    }
}
#endif

/// Shared by app windows and settings; changing color never recreates navigation.
struct WorkspaceThemeModifier: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @AppStorage(WorkspaceColorTheme.preferenceKey) private var savedTheme = WorkspaceColorTheme.blue.rawValue
    func body(content: Content) -> some View {
        let raw = store.isDemoMode ? store.demoColorTheme : savedTheme
        let theme = WorkspaceColorTheme(rawValue: raw) ?? .blue
        return content
            .environment(\.workspacePalette, theme.palette)
            .tint(theme.palette.accent)
    }
}

/// All iPhone touch feedback shares one lazy, foreground-only output path.
/// Result feedback has its own cooldown, so a tap never suppresses its outcome.
@MainActor enum WorkspaceHaptics {
    enum Event: Hashable {
        case key, selection, tap, confirmation, success, warning, error, boundary
    }

    #if os(iOS)
    private static let generators = Generators()
    private static var lastLightFeedback: TimeInterval = -.infinity
    private static var lastResultFeedback: [Event: TimeInterval] = [:]

    @MainActor private final class Generators {
        lazy var selection = UISelectionFeedbackGenerator()
        lazy var key = UIImpactFeedbackGenerator(style: .light)
        lazy var tap = UIImpactFeedbackGenerator(style: .soft)
        lazy var boundary = UIImpactFeedbackGenerator(style: .rigid)
        lazy var notification = UINotificationFeedbackGenerator()
    }
    #endif

    static func play(_ event: Event, enabled: Bool) {
        #if os(iOS)
        guard enabled, UIApplication.shared.applicationState == .active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .key, .selection, .tap, .boundary:
            guard now - lastLightFeedback >= 0.065 else { return }
            lastLightFeedback = now
        case .confirmation, .success, .warning, .error:
            guard now - (lastResultFeedback[event] ?? -.infinity) >= 0.35 else { return }
            lastResultFeedback[event] = now
        }
        switch event {
        case .key: generators.key.impactOccurred(intensity: 0.35)
        case .selection: generators.selection.selectionChanged()
        case .tap: generators.tap.impactOccurred(intensity: 0.55)
        case .confirmation: generators.tap.impactOccurred(intensity: 0.75)
        case .success: generators.notification.notificationOccurred(.success)
        case .warning: generators.notification.notificationOccurred(.warning)
        case .error: generators.notification.notificationOccurred(.error)
        case .boundary: generators.boundary.impactOccurred(intensity: 0.4)
        }
        #endif
    }
}

private struct WorkspaceFeedbackModifier: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @AppStorage("hapticsEnabled") private var savedEnabled = true
    private var enabled: Bool { store.isDemoMode ? store.demoHapticsEnabled : savedEnabled }
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onChange(of: store.navigation) { _, _ in WorkspaceHaptics.play(.selection, enabled: enabled) }
            .onChange(of: store.feedbackSequence) { _, _ in WorkspaceHaptics.play(.confirmation, enabled: enabled) }
            .onChange(of: store.errorMessage) { _, value in
                if value != nil { WorkspaceHaptics.play(.error, enabled: enabled) }
            }
            .onChange(of: store.createKind) { _, value in
                if value != nil { WorkspaceHaptics.play(.tap, enabled: enabled) }
            }
            .onChange(of: store.openedRecordID) { _, value in
                if value != nil { WorkspaceHaptics.play(.selection, enabled: enabled) }
            }
            .onChange(of: store.information) { _, value in
                if value != nil { WorkspaceHaptics.play(.confirmation, enabled: enabled) }
            }
        #else
        content
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.95), trigger: store.navigation) { _, _ in enabled }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: store.feedbackSequence) { _, _ in enabled }
            .sensoryFeedback(.error, trigger: store.errorMessage) { _, value in enabled && value != nil }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: store.createKind) { _, value in enabled && value != nil }
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.85), trigger: store.openedRecordID) { _, value in enabled && value != nil }
            .sensoryFeedback(.success, trigger: store.information) { _, value in enabled && value != nil }
        #endif
    }
}

private struct WorkspaceSelectionFeedback<T: Equatable>: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    private var enabled: Bool { store.hapticsEnabled }
    let trigger: T
    let feedback: SensoryFeedback
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content.onChange(of: trigger) { _, _ in WorkspaceHaptics.play(.selection, enabled: enabled) }
        #else
        content.sensoryFeedback(feedback, trigger: trigger) { _, _ in enabled }
        #endif
    }
}

/// Full-width in-content actions keep a readable label even inside a List or Form.
struct WorkspacePrimaryButtonStyle: ButtonStyle {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WorkspaceStore.self) private var store
    private var hapticsEnabled: Bool { store.hapticsEnabled }
    var tint: Color? = nil
    var prominent = true
    var hapticOnPress = true
    func makeBody(configuration: Configuration) -> some View {
        let accent = tint ?? palette.accent
        let fillTint = tint == nil ? palette.action : accent
        #if os(macOS)
        let maximumWidth: CGFloat? = nil
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 7
        let radius: CGFloat = 8
        #else
        let maximumWidth: CGFloat? = .infinity
        let horizontalPadding: CGFloat = 18
        let verticalPadding: CGFloat = 13
        let radius: CGFloat = 16
        #endif
        return configuration.label
            .labelStyle(.titleAndIcon)
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: maximumWidth, minHeight: 24)
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .foregroundStyle(prominent ? Color.white : accent)
            .background(prominent ? AnyShapeStyle(fillTint.gradient) : AnyShapeStyle(accent.opacity(0.08)), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(accent.opacity(prominent ? 0 : 0.14), lineWidth: 1) }
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
            #if os(iOS)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { WorkspaceHaptics.play(.tap, enabled: hapticOnPress && hapticsEnabled && enabled) }
            }
            #else
            .sensoryFeedback(.impact(weight: prominent ? .heavy : .medium, intensity: prominent ? 1 : 0.85), trigger: configuration.isPressed) { _, pressed in
                hapticOnPress && hapticsEnabled && enabled && pressed
            }
            #endif
    }
}

/// The same choices appear wherever the user adds content; only the destination changes.
struct RecordCreationActions: View {
    var withinGroup = false
    var create: (ItemKind) -> Void
    var body: some View {
        Button(WorkspaceLocalization.string("事项"), systemImage: ItemKind.task.symbol) { create(.task) }
        Button(WorkspaceLocalization.string("截止事项"), systemImage: ItemKind.deadline.symbol) { create(.deadline) }
        Button(withinGroup ? WorkspaceLocalization.string("子项目组") : WorkspaceLocalization.string("项目组"), systemImage: ItemKind.project.symbol) { create(.project) }
    }
}

struct WorkspaceCreationContext {
    var kind: ItemKind
    var title: String? = nil
    var isEnabled = true
    var create: () -> Void
}
private struct WorkspaceCreationKey: FocusedValueKey {
    typealias Value = WorkspaceCreationContext
}
extension FocusedValues {
    var workspaceCreation: WorkspaceCreationContext? {
        get { self[WorkspaceCreationKey.self] }
        set { self[WorkspaceCreationKey.self] = newValue }
    }
}
#if os(macOS)
struct MacWorkspaceNavigation: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    @State private var selection: UUID?
    @State private var hasRoomForDetails = false
    @State private var detailPresentationActive = false
    @AppStorage("macShowRecordDetails") private var showsDetails = true
    @AppStorage("scheduleViewMode") private var scheduleMode = AppDestination.timeline.rawValue
    @AppStorage("demoScheduleViewMode") private var demoScheduleMode = AppDestination.timeline.rawValue
    private var listKind: ItemKind? {
        switch store.navigation {
        case .projects, .areas: .project
        case .actions: .task
        case .deadlines: .deadline
        case .knowledge: .knowledge
        default: nil
        }
    }
    private var isSchedule: Bool { store.navigation == .calendar || store.navigation == .timeline }
    private var scheduleDestination: AppDestination {
        (store.isDemoMode ? demoScheduleMode : scheduleMode) == AppDestination.calendar.rawValue ? .calendar : .timeline
    }
    private var sidebarSelection: Binding<AppDestination?> {
        Binding(get: {
            isSchedule ? .timeline : store.navigation == .areas ? .projects : store.navigation
        }, set: { destination in
            guard let destination else { return }
            store.navigation = destination == .timeline ? scheduleDestination : destination
        })
    }
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                Group {
                    if let kind = listKind { recordBrowser(kind) }
                    else if isSchedule { scheduleBrowser }
                    else { DestinationView(destination: store.navigation) }
                }
            }
            .id(store.navigation)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.navigation, initial: true) { _, destination in
            selection = nil
            if destination == .calendar || destination == .timeline {
                if store.isDemoMode { demoScheduleMode = destination.rawValue }
                else { scheduleMode = destination.rawValue }
            }
        }
        .onChange(of: store.state.records) { _, _ in
            if let id = selection, !store.state.records.contains(where: { $0.id == id && WorkspaceLogic.visible($0, in: store.state) }) {
                selection = nil
            }
        }
        .focusedSceneValue(\.workspaceCreation, WorkspaceCreationContext(kind: listKind ?? .task, create: { store.createKind = listKind ?? .task }))
    }
    private func recordBrowser(_ kind: ItemKind) -> some View {
        GeometryReader { geometry in
            let inlineDetails = (showsDetails && hasRoomForDetails) || detailPresentationActive
            HSplitView {
                Group {
                    if store.navigation == .actions { ActionsView(selection: $selection) }
                    else if kind.isProjectGroup { ProjectGroupsView(selection: $selection) }
                    else { RecordListView(kind: kind, selection: $selection) }
                }
                .frame(minWidth: inlineDetails ? min(440, max(300, geometry.size.width * 0.45)) : min(300, geometry.size.width),
                       idealWidth: inlineDetails ? 480 : 620,
                       maxWidth: inlineDetails ? 680 : .infinity, maxHeight: .infinity)
                if inlineDetails {
                    NavigationStack {
                        if let selection {
                            RecordDetailView(id: selection, embedded: true,
                                presentationChanged: { detailPresentationActive = $0 })
                        } else {
                            ContentUnavailableView(WorkspaceLocalization.string("选择一条记录"), systemImage: "sidebar.right",
                                description: Text(WorkspaceLocalization.string("单击列表或使用方向键选择，在这里直接查看和处理。")))
                        }
                    }
                    .id(selection)
                    .frame(minWidth: 320, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 740 } action: { hasRoomForDetails = $0 }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showsDetails) { Label(WorkspaceLocalization.string("详情"), systemImage: "sidebar.right") }
                    .toggleStyle(.button)
                    .help(hasRoomForDetails ? WorkspaceLocalization.string("显示或隐藏详情（⌥⌘I）") : WorkspaceLocalization.string("加宽窗口可并排查看；双击或 ⌘↩ 打开所选记录"))
                    .disabled(!hasRoomForDetails)
            }
            ToolbarItem(placement: .automatic) {
                Button(WorkspaceLocalization.string("查看详情"), systemImage: "arrow.up.right.square") {
                    store.openedRecordID = selection
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selection == nil)
                .help(WorkspaceLocalization.string("打开所选记录（⌘↩）；列表中也可双击打开"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                if let id = selection, let record = store.record(id) {
                    Image(systemName: record.kind.symbol).foregroundStyle(palette.accent)
                    Text(record.title).lineLimit(1)
                } else {
                    Text(WorkspaceLocalization.string("选择记录以预览"))
                }
                Spacer(minLength: 12)
                Text(WorkspaceLocalization.string("双击打开 · ⇧/⌘ 多选"))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .accessibilityIdentifier("mac-record-workspace")
    }
    private var scheduleBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(WorkspaceLocalization.string("日程视图"), selection: Binding(get: { store.navigation }, set: { store.navigation = $0 })) {
                    Label(WorkspaceLocalization.string("时间线"), systemImage: "chart.bar.xaxis").tag(AppDestination.timeline)
                    Label(WorkspaceLocalization.string("日历"), systemImage: "calendar").tag(AppDestination.calendar)
                }
                .pickerStyle(.segmented).frame(width: 230)
                Spacer()
                Menu { RecordCreationActions { store.createKind = $0 } }
                    label: { Label(WorkspaceLocalization.string("新建"), systemImage: "plus") }
                    .disabled(store.isReadOnlyWorkspace)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if store.navigation == .calendar { WorkspaceCalendarView() }
            else { MacWorkspaceTimelineView() }
        }
    }
    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section(WorkspaceLocalization.string("工作台")) {
                sidebarRow(.overview, title: WorkspaceLocalization.string("首页"))
                sidebarRow(.timeline, title: scheduleDestination.title, symbol: scheduleDestination.symbol)
                sidebarRow(.courses)
            }
            Section(WorkspaceLocalization.string("项目")) {
                sidebarRow(.projects)
                sidebarRow(.actions)
                sidebarRow(.deadlines)
            }
            Section(WorkspaceLocalization.string("资料")) {
                sidebarRow(.knowledge)
                sidebarRow(.archives)
                sidebarRow(.trash)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(WorkspaceLocalization.string("工作坊"))
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SettingsLink {
                    HStack(spacing: 10) {
                        AvatarView(data: store.state.profile.avatar).frame(width: 30, height: 30).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.state.profile.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(store.isDemoMode ? WorkspaceLocalization.string("演示模式") : WorkspaceLocalization.string("设置与个人资料")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                    }
                    .padding(12).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(WorkspaceLocalization.string("设置（⌘,）"))
            }
        }
    }
    private func sidebarRow(_ destination: AppDestination, title: String? = nil, symbol: String? = nil) -> some View {
        Label {
            Text(title ?? destination.title)
        } icon: {
            Image(systemName: symbol ?? destination.symbol)
        }
        .padding(.vertical, 3)
        .tag(destination)
    }
}
#endif
extension View {
    @ViewBuilder func nativeEditorPresentation() -> some View {
        #if os(iOS)
        self.presentationDetents([.large]).presentationDragIndicator(.visible)
        #else
        self.nativeSheetSize()
        #endif
    }
}
