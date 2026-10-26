import SwiftUI
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum GettingStartedVersion { static let current = 4 }

enum WorkspaceLaunchPreferences {
    static let completedKey = "hasPlayedLaunchAnimation"
    static let repeatsKey = "playsLaunchAnimation"
    static var shouldPlay: Bool {
        !UserDefaults.standard.bool(forKey: completedKey) || UserDefaults.standard.bool(forKey: repeatsKey)
    }
}

private struct WorkspaceLaunchInProgressKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workspaceLaunchInProgress: Bool {
        get { self[WorkspaceLaunchInProgressKey.self] }
        set { self[WorkspaceLaunchInProgressKey.self] = newValue }
    }
}

/// Keep the destination mounted and ready behind the reveal.
/// Fixed launch labels use SwiftUI localization and the inherited locale, avoiding
/// synchronous preference reads while the animation hierarchy is being updated.
struct WorkspaceLaunchHost<Content: View>: View {
    @Binding var isFinished: Bool
    var isReady = true
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            content
                .environment(\.workspaceLaunchInProgress, !isFinished || !isReady)
                .allowsHitTesting(isFinished && isReady)
                .accessibilityHidden(!isFinished || !isReady)
            if !isFinished {
                WorkspaceLaunchAnimation(isReady: isReady) {
                    guard !isFinished else { return }
                    UserDefaults.standard.set(true, forKey: WorkspaceLaunchPreferences.completedKey)
                    // The splash finishes its own fade before navigation and sheets can change.
                    isFinished = true
                }
                .transition(.identity)
                .zIndex(1)
            } else if !isReady {
                // Disabling the animation does not expose a half-prepared home.
                // Its real hierarchy is already mounted underneath this short cover.
                ProgressView("正在打开工作坊…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TutorialAppearance.background.ignoresSafeArea())
                    .zIndex(1)
            }
        }
    }
}

private struct WorkspaceLaunchAnimation: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var showsInstalledIcon = false
    @State private var wantsToFinish = false
    @State private var isExiting = false
    private let fadeDuration = 0.42
    let isReady: Bool
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    WorkspaceLaunchGlyph(revealed: revealed)
                    TutorialAppearance.applicationIcon.resizable().scaledToFit()
                        .opacity(showsInstalledIcon || reduceMotion ? 1 : 0)
                }
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .scaleEffect(revealed || reduceMotion ? 1 : 0.9)
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.84), value: revealed)
                .accessibilityHidden(true)
                Text("工作坊").font(.title2.weight(.semibold)).tracking(3)
                    .opacity(revealed || reduceMotion ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.22), value: revealed)
            }
            Spacer()
            Group {
                if wantsToFinish && !isReady {
                    ProgressView("正在打开工作坊…").font(.subheadline)
                } else {
                    Button("跳过动画") { wantsToFinish = true }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .buttonStyle(.plain).accessibilityIdentifier("launch-skip")
                }
            }.frame(minWidth: 88, minHeight: 44).padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            TutorialAppearance.background.ignoresSafeArea()
            WorkspaceLaunchHalo(revealed: revealed)
        }
        .opacity(isExiting ? 0 : 1)
        .allowsHitTesting(!wantsToFinish)
        .accessibilityIdentifier("workspace-launch-animation")
        .task(id: scenePhase) {
            guard scenePhase == .active, !wantsToFinish else { return }
            revealed = true
            do {
                if reduceMotion {
                    try await Task.sleep(for: .milliseconds(350))
                } else {
                    try await Task.sleep(for: .milliseconds(520))
                    withAnimation(.easeInOut(duration: 0.38)) { showsInstalledIcon = true }
                    try await Task.sleep(for: .milliseconds(530))
                }
                try Task.checkCancellation()
                wantsToFinish = true
            } catch { /* Resume the short reveal when the app becomes active again. */ }
        }
        .task(id: wantsToFinish && isReady) {
            guard wantsToFinish, isReady else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: fadeDuration)) { isExiting = true }
            do {
                if !reduceMotion { try await Task.sleep(for: .seconds(fadeDuration)) }
                try Task.checkCancellation()
                finish()
            } catch { /* A discarded launch host must not complete a different launch. */ }
        }
    }
}

/// Render one gradient, then animate its layer opacity and scale instead of rebuilding its colors.
private struct WorkspaceLaunchHalo: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let revealed: Bool

    var body: some View {
        RadialGradient(stops: [
            .init(color: palette.surface.opacity(0.8), location: 0),
            .init(color: palette.surface.opacity(0.6), location: 0.3),
            .init(color: palette.surface.opacity(0.25), location: 0.65),
            .init(color: palette.surface.opacity(0), location: 1)
        ], center: .center, startRadius: 0, endRadius: 280)
        .scaleEffect(revealed || reduceMotion ? 1.04 : 0.92)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.05), value: revealed)
        .opacity(revealed || reduceMotion ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: revealed)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The three paths match WorkspaceMark.svg; animate them without starting a web renderer.
private struct WorkspaceLaunchGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let revealed: Bool
    private let heights: [CGFloat] = [0.445, 0.6, 0.355]

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(colors: [Color(red: 0, green: 0.99144, blue: 1),
                                        Color(red: 0, green: 0.5898, blue: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(.white)
                        .frame(width: side * 0.17, height: side * heights[index])
                        .scaleEffect(x: 1, y: revealed || reduceMotion ? 1 : 0.06, anchor: .bottom)
                        .animation(reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.8)
                            .delay(Double(index) * 0.09), value: revealed)
                        .position(x: side * (0.2588 + CGFloat(index) * 0.25),
                                  y: side * (0.8 - heights[index] / 2))
                }
            }
        }
    }
}

/// A shared pager gives both tutorials a real horizontal paging interaction.
struct TutorialPager<Content: View>: View {
    @Binding var selection: Int
    let count: Int
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(0..<count, id: \.self) { index in
                content(index).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        content(index)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(index)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding<Int?>(get: { selection }, set: {
                if let index = $0, (0..<count).contains(index) { selection = index }
            }), anchor: .leading)
        }
        #endif
    }
}

struct TutorialPageIndicators: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Int
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { selection = index }
                } label: {
                    Capsule().fill(index == selection ? palette.accent : Color.secondary.opacity(0.22))
                        .frame(width: index == selection ? 22 : 6, height: 6)
                        .frame(width: 38, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WorkspaceLocalization.format("第 %@ 页，共 %@ 页", String(describing: index + 1), String(describing: count)))
                .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
    }
}

struct GettingStartedView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedPage: Int?
    @State private var step = 0
    @State private var publishedTutorial: PublishedTutorial?
    @State private var hasPreparedTutorialContent = false
    @State private var practice = TutorialPractice()
    @State private var busy = false
    @State private var loginError: String?
    @State private var authorization = WebLoginAuthorization()
    @State private var loginTask: Task<Void, Never>?
    var isReplay = false
    let finish: (_ signedIn: Bool) -> Void
    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            TutorialPager(selection: $step, count: pageCount) { index in page(index) }
                .disabled(busy || !hasPreparedTutorialContent)
                .accessibilityIdentifier("tutorial-pager")
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TutorialAppearance.background)
        .tint(palette.accent)
        .workspaceSelectionFeedback(trigger: step)
        .onChange(of: step) { _, page in focusedPage = page }
        .alert(WorkspaceLocalization.string("暂时无法登录"), isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button(WorkspaceLocalization.string("好")) { loginError = nil }
        } message: { Text(loginError ?? "") }
        .task {
            if !hasPreparedTutorialContent {
                await AppContentService.shared.prepare()
                guard !Task.isCancelled else { return }
                // Freeze this presentation; a later content refresh must not change a page while swiping.
                publishedTutorial = AppContentService.shared.tutorial("welcome-tutorial")
                hasPreparedTutorialContent = true
            }
            await store.prepareForInteraction()
        }
        .onDisappear { loginTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            if step > 0 {
                Button { move(to: step - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel(WorkspaceLocalization.string("上一页"))
            } else { Text(isReplay ? WorkspaceLocalization.string("使用指南") : WorkspaceLocalization.string("欢迎来到工作坊")).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Button(isReplay ? WorkspaceLocalization.string("关闭") : WorkspaceLocalization.string("跳过")) { finish(false) }
                .foregroundStyle(.secondary).frame(minHeight: 44)
        }
        .font(.subheadline.weight(.medium)).buttonStyle(.plain)
        .padding(.horizontal, 24).disabled(busy || !hasPreparedTutorialContent)
    }

    private func page(_ index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if index == 0 {
                    welcomeBrand
                } else {
                    Label(sectionTitle(for: index), systemImage: sectionSymbol(for: index))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(title(for: index)).font(.largeTitle.bold()).tracking(-0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedPage, equals: index)
                    Text(subtitle(for: index)).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch index {
                case 0: TutorialHomeExercise(practice: $practice)
                case 1: TutorialTimelineExercise(practice: $practice)
                case 2: TutorialProjectsExercise(practice: $practice)
                default:
                    accountArtwork
                    if store.backend.signedIn && !store.isDemoMode {
                        Label(store.backend.accountName, systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(palette.accent)
                    }
                    Text(WorkspaceLocalization.string("想先试一试？设置中的演示模式，为你准备了一份独立的日常。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("tutorial-page-\(index)")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            TutorialPageIndicators(selection: $step, count: pageCount)
            Button(action: primaryAction) {
                HStack(spacing: 9) {
                    if busy { ProgressView().tint(.white) }
                    Text(primaryTitle)
                }
            }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(busy)
            if step == pageCount - 1 && !store.backend.signedIn && !store.isDemoMode {
                Button(WorkspaceLocalization.string("先直接使用")) { finish(false) }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
            } else if step < pageCount - 1 {
                Text(WorkspaceLocalization.string("左右滑动，也可以切换页面"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
        }
        .frame(maxWidth: 480).padding(.horizontal, 24)
        .padding(.bottom, 20).disabled(busy || !hasPreparedTutorialContent)
    }

    private func publishedPage(for page: Int) -> PublishedTutorialPage? {
        let ids = ["home", "timeline", "projects", "account"]
        guard ids.indices.contains(page) else { return nil }
        return publishedTutorial?.pages.first { $0.id == ids[page] }
    }
    private func title(for page: Int) -> String {
        if let title = publishedPage(for: page)?.title { return title }
        return switch page {
        case 0: WorkspaceLocalization.string("把要做的事，\n放在一起。")
        case 1: WorkspaceLocalization.string("顺着时间，\n看清每一天。")
        case 2: WorkspaceLocalization.string("从一件事，\n到整个项目。")
        default: WorkspaceLocalization.string("在你的设备间，\n接着使用。")
        }
    }
    private func subtitle(for page: Int) -> String {
        if let subtitle = publishedPage(for: page)?.subtitle { return subtitle }
        return switch page {
        case 0: WorkspaceLocalization.string("首页把临近截止和接下来的安排放在眼前。点右上角 +，记下新的事项。")
        case 1: WorkspaceLocalization.string("上下浏览时间段，也能切换成日历。计划与截止，沿时间自然展开。")
        case 2: WorkspaceLocalization.string("项目组收纳相关内容；切换到事项或截止事项，就能按时间集中管理。")
        default: WorkspaceLocalization.string("登录或注册，合并本机与云端内容。在 iPhone 或 Mac 上，都可以继续。")
        }
    }
    private var welcomeBrand: some View {
        HStack(spacing: 18) {
            TutorialAppearance.applicationIcon.resizable().scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(WorkspaceLocalization.string("工作坊")).font(.title2.weight(.semibold))
                Text(WorkspaceLocalization.string("日常 · 计划 · 学习")).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
    private func sectionTitle(for page: Int) -> String {
        if let title = publishedPage(for: page)?.sectionTitle { return title }
        return switch page { case 1: WorkspaceLocalization.string("时间线与日历"); case 2: WorkspaceLocalization.string("项目"); default: WorkspaceLocalization.string("账户与同步") }
    }
    private func sectionSymbol(for page: Int) -> String {
        if let symbol = publishedPage(for: page)?.symbol { return symbol }
        return switch page { case 1: "chart.bar.xaxis"; case 2: "folder"; default: "icloud" }
    }
    private var primaryTitle: String {
        guard step == pageCount - 1 else { return WorkspaceLocalization.string("继续") }
        if busy { return WorkspaceLocalization.string("正在登录…") }
        if store.isDemoMode || store.backend.signedIn { return isReplay ? WorkspaceLocalization.string("完成") : WorkspaceLocalization.string("开始使用") }
        return WorkspaceLocalization.string("登录或注册")
    }
    private var accountArtwork: some View {
        TutorialCard {
            HStack(spacing: 22) {
                Image(systemName: "icloud.fill").font(.system(size: 40)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 7) {
                    Text(WorkspaceLocalization.string("你的内容，随身而行")).font(.headline)
                    Text(WorkspaceLocalization.string("也可以先在本机开始使用。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 12)
        }
    }
    private func move(to page: Int) {
        guard (0..<pageCount).contains(page), !busy else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { step = page }
    }
    private func primaryAction() {
        guard !busy else { return }
        guard step == pageCount - 1 else { move(to: step + 1); return }
        guard !store.isDemoMode, !store.backend.signedIn else { finish(false); return }
        busy = true
        loginTask = Task { @MainActor in
            defer { busy = false }
            do {
                try await store.backend.signInWithWeb(using: authorization)
                try Task.checkCancellation()
                finish(true)
            } catch {
                let failure = error as NSError
                let canceled = failure.domain == ASWebAuthenticationSessionError.errorDomain && failure.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                if !(error is CancellationError) && !canceled { loginError = error.localizedDescription }
            }
        }
    }
}

/// All exercises are local values; no workspace, notification or network writes.
private struct TutorialPractice {
    var title = WorkspaceLocalization.string("整理课程笔记")
    var project = WorkspaceLocalization.string("本周学习")
    var completed = false
    var hasCompletedOnce = false
    var important = false
    var selectedDay = 0
    var scheduleView = "时间线"
    var projectView = "项目组"
    var addedSubgroup = false
    var activityStartedAt = Date()
    var activityEndsAt = Date().addingTimeInterval(25 * 60)
    mutating func toggleCompletion() {
        completed.toggle()
        if completed { hasCompletedOnce = true }
    }
}

private struct TutorialHomeExercise: View {
    @Environment(\.workspacePalette) private var palette
    @Binding var practice: TutorialPractice
    var body: some View {
        TutorialCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(WorkspaceLocalization.string("今天")).font(.title2.bold())
                    Spacer()
                    Image(systemName: "plus").font(.title3).foregroundStyle(palette.accent).accessibilityHidden(true)
                }
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "hourglass").font(.title2).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WorkspaceLocalization.string("课程报告")).font(.headline)
                        Text(WorkspaceLocalization.string("明天截止")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(WorkspaceLocalization.string("1 天")).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(palette.accent)
                }
                Divider()
                Button { practice.important.toggle() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: practice.important ? "star.fill" : "star")
                            .foregroundStyle(practice.important ? .orange : palette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(practice.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(practice.important ? WorkspaceLocalization.string("重要 · 今天 18:00") : WorkspaceLocalization.string("今天 18:00 · 点星星标记重要"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                        .frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                    .accessibilityLabel(practice.important ? WorkspaceLocalization.string("取消整理课程笔记的重要标记") : WorkspaceLocalization.string("把整理课程笔记标为重要"))
            }.font(.subheadline)
        }
        .workspaceSelectionFeedback(trigger: practice.important)
    }
}

private struct TutorialTimelineExercise: View {
    @Environment(\.workspacePalette) private var palette
    @Binding var practice: TutorialPractice
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TutorialCard {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text(LocalizedStringKey(practice.scheduleView)).font(.headline)
                        Spacer()
                        Button {
                            practice.scheduleView = practice.scheduleView == "时间线" ? "日历" : "时间线"
                        } label: {
                            Image(systemName: practice.scheduleView == "时间线" ? "calendar" : "chart.bar.xaxis")
                                .frame(width: 44, height: 44)
                                .background(palette.surface, in: Circle())
                        }.buttonStyle(.plain).foregroundStyle(palette.accent)
                            .accessibilityLabel(practice.scheduleView == "时间线" ? WorkspaceLocalization.string("试着切换为日历") : WorkspaceLocalization.string("试着切换为时间线"))
                    }
                    if practice.scheduleView == "日历" { calendarPreview }
                    else {
                        Picker(WorkspaceLocalization.string("查看日期"), selection: $practice.selectedDay) {
                            Text(WorkspaceLocalization.string("今天")).tag(0); Text(WorkspaceLocalization.string("明天")).tag(1)
                        }.pickerStyle(.segmented)
                        timelineRow(time: practice.selectedDay == 0 ? "18:00" : "09:00",
                                    title: practice.selectedDay == 0 ? practice.title : WorkspaceLocalization.string("小组讨论"), symbol: "circle")
                        timelineRow(time: "21:00", title: practice.selectedDay == 0 ? WorkspaceLocalization.string("提交实验记录") : WorkspaceLocalization.string("提交课程报告"), symbol: "hourglass")
                    }
                }
            }
            Text(WorkspaceLocalization.string("点卡片右上角，试着切换视图。计划时间是打算开始的时间；截止时间是最晚完成的时间。"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .workspaceSelectionFeedback(trigger: practice.selectedDay)
        .workspaceSelectionFeedback(trigger: practice.scheduleView)
    }
    private var calendarPreview: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<2, id: \.self) { day in
                Button { practice.selectedDay = day } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(day == 0 ? WorkspaceLocalization.string("今天") : WorkspaceLocalization.string("明天")).font(.subheadline.weight(.semibold))
                        RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 24, height: 3)
                        Text(day == 0 ? WorkspaceLocalization.string("18:00\n整理笔记") : WorkspaceLocalization.string("09:00\n小组讨论"))
                            .font(.subheadline).lineSpacing(5)
                        Text(WorkspaceLocalization.string("21:00\n提交报告")).font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(practice.selectedDay == day ? palette.surface : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(practice.selectedDay == day ? palette.accent.opacity(0.3) : .clear) }
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(practice.selectedDay == day ? .isSelected : [])
            }
        }
    }
    private func timelineRow(time: String, title: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(palette.accent).frame(width: 52, alignment: .leading)
            Image(systemName: symbol).foregroundStyle(palette.accent)
            Text(title).font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
}

private struct TutorialProjectsExercise: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var practice: TutorialPractice
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let choices = ["项目组", "事项", "截止事项"]
            if typeSize.isAccessibilitySize {
                Picker(WorkspaceLocalization.string("项目内容"), selection: $practice.projectView) {
                    ForEach(choices, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                }.pickerStyle(.menu)
            } else {
                Picker(WorkspaceLocalization.string("项目内容"), selection: $practice.projectView) {
                    ForEach(choices, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                }.pickerStyle(.segmented)
            }
            switch practice.projectView {
            case "事项":
                TutorialTaskExercise(practice: $practice, allowsRenaming: false)
                Text(WorkspaceLocalization.string("只区分完成与未完成。打开事项后可编辑；列表里的批量管理适合一次处理多项。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            case "截止事项":
                TutorialCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(WorkspaceLocalization.string("课程报告"), systemImage: "hourglass").font(.headline)
                        Text(timerInterval: practice.activityStartedAt...practice.activityEndsAt, countsDown: true, showsHours: false)
                            .font(.largeTitle.monospacedDigit().bold()).foregroundStyle(palette.accent)
                            .multilineTextAlignment(.leading).frame(maxWidth: 170, alignment: .leading)
                        Text(WorkspaceLocalization.string("提交报告 · 上传实验记录")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(WorkspaceLocalization.string("相近的截止会合并倒计时。锁屏与灵动岛的自动追踪，在设置中统一管理。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            default:
                TutorialCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(WorkspaceLocalization.string("本周学习"), systemImage: "folder.fill").font(.headline).foregroundStyle(palette.accent)
                        Label(WorkspaceLocalization.string("C++ 练习"), systemImage: "folder").padding(.leading, 24)
                        if practice.addedSubgroup { Label(WorkspaceLocalization.string("复习资料"), systemImage: "folder").padding(.leading, 24) }
                        Divider()
                        Button { practice.addedSubgroup = true } label: {
                            Label(practice.addedSubgroup ? WorkspaceLocalization.string("已添加子项目组") : WorkspaceLocalization.string("试着添加子项目组"), systemImage: practice.addedSubgroup ? "checkmark" : "folder.badge.plus")
                                .frame(minHeight: 44)
                        }.buttonStyle(.plain).disabled(practice.addedSubgroup)
                    }
                }
                Text(WorkspaceLocalization.string("打开项目组，用“添加内容”建立子项目组、事项或截止事项；分类也可以自定义。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .workspaceSelectionFeedback(trigger: practice.projectView)
        .workspaceSelectionFeedback(trigger: practice.addedSubgroup)
    }
}

private struct TutorialTaskExercise: View {
    @Environment(\.workspacePalette) private var palette
    @Binding var practice: TutorialPractice
    var allowsRenaming: Bool
    @State private var completionArmed = false

    var body: some View {
        TutorialCard {
            VStack(alignment: .leading, spacing: 18) {
                Picker(selection: $practice.project) {
                    Text(WorkspaceLocalization.string("本周学习")).tag(WorkspaceLocalization.string("本周学习"))
                    Text(WorkspaceLocalization.string("生活计划")).tag(WorkspaceLocalization.string("生活计划"))
                } label: {
                    Label("项目组", systemImage: "folder")
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                Divider()
                if allowsRenaming {
                    TextField(WorkspaceLocalization.string("事项名称"), text: $practice.title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(WorkspaceLocalization.string("练习事项名称"))
                }
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: practice.completed ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(practice.completed ? Color.workspaceCompleted : palette.accent)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    Text(practice.title.isEmpty ? WorkspaceLocalization.string("整理课程笔记") : practice.title)
                        .font(.body.weight(.medium))
                        .strikethrough(practice.completed)
                        .foregroundStyle(practice.completed ? Color.workspaceCompleted : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { practice.important.toggle() } label: {
                        Image(systemName: practice.important ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(practice.completed ? Color.workspaceCompleted : practice.important ? Color.orange : Color.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(practice.important ? WorkspaceLocalization.string("取消重要标记") : WorkspaceLocalization.string("标记为重要"))
                    .accessibilityValue(practice.important ? WorkspaceLocalization.string("重要") : WorkspaceLocalization.string("普通"))
                }
                Button {
                    if practice.completed || completionArmed {
                        practice.toggleCompletion()
                        completionArmed = false
                    } else {
                        completionArmed = true
                    }
                } label: {
                    Label(practice.completed ? WorkspaceLocalization.string("标为未完成") : completionArmed ? WorkspaceLocalization.string("再点一次，确认完成") : WorkspaceLocalization.string("标记完成"),
                          systemImage: practice.completed ? "arrow.counterclockwise" : "checkmark")
                }
                .buttonStyle(WorkspacePrimaryButtonStyle(tint: practice.completed ? .secondary : completionArmed ? palette.confirmation : palette.action,
                                                         prominent: !practice.completed))
                .accessibilityHint(practice.completed ? WorkspaceLocalization.string("恢复这个练习事项") : WorkspaceLocalization.string("连续轻点两次确认完成"))
                .accessibilityIdentifier("tutorial-complete-example")
                if practice.hasCompletedOnce {
                    Label(WorkspaceLocalization.string("完成后会变成灰色，也可以恢复为未完成。"), systemImage: "checkmark")
                        .font(.subheadline).foregroundStyle(Color.workspaceCompleted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .workspaceSelectionFeedback(trigger: practice.completed)
        .workspaceSelectionFeedback(trigger: practice.important)
        .workspaceSelectionFeedback(trigger: practice.project)
        .task(id: completionArmed) {
            guard completionArmed else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            completionArmed = false
        }
        .onDisappear { completionArmed = false }
    }
}

private struct TutorialCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(TutorialAppearance.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

@MainActor
private enum TutorialAppearance {
    static var background: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var card: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
    /// Cache the installed Icon Composer artwork once, instead of decoding it on every interaction.
    static let applicationIcon: Image = {
        #if os(iOS)
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        for name in files.reversed() {
            if let image = UIImage(named: name) { return Image(uiImage: image) }
        }
        return Image("AppIcon")
        #else
        return Image(nsImage: NSApplication.shared.applicationIconImage)
        #endif
    }()
}

/// Finish dismissing the tutorial before a merge can present a conflict review.
private struct GettingStartedPresentation: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @AppStorage("hasCompletedGettingStarted") private var completed = false
    @AppStorage("gettingStartedVersion") private var completedVersion = 0
    @Binding var isPresented: Bool
    var isReplay: Bool
    var embedded: Bool
    @State private var mergeAfterDismissal = false

    @ViewBuilder func body(content: Content) -> some View {
        if embedded {
            ZStack {
                content.allowsHitTesting(!isPresented).accessibilityHidden(isPresented)
                if isPresented { tutorial.onDisappear(perform: didDismiss).zIndex(1) }
            }
        } else {
            #if os(iOS)
            content.fullScreenCover(isPresented: $isPresented, onDismiss: didDismiss) { tutorial }
            #else
            content.sheet(isPresented: $isPresented, onDismiss: didDismiss) { tutorial }
            #endif
        }
    }
    private var tutorial: some View {
        GettingStartedView(isReplay: isReplay) { signedIn in
            mergeAfterDismissal = signedIn
            if !store.isDemoMode {
                completed = true
                completedVersion = GettingStartedVersion.current
            }
            isPresented = false
        }
        .environment(store)
        .nativeSheetSize()
        .interactiveDismissDisabled()
    }
    private func didDismiss() {
        guard mergeAfterDismissal else { return }
        mergeAfterDismissal = false
        Task { @MainActor in
            do { try await store.completeAccountSignIn() }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

extension View {
    func gettingStarted(isPresented: Binding<Bool>, isReplay: Bool = false, embedded: Bool = false) -> some View {
        modifier(GettingStartedPresentation(isPresented: isPresented, isReplay: isReplay, embedded: embedded))
    }
}
