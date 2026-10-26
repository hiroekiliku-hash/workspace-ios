import SwiftUI
import Charts
import ImageIO
import UniformTypeIdentifiers
import WebKit


#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct CourseRefreshIdentity: Hashable {
    let scope: String?
    let active: Bool
}

private struct CourseStudyViewportKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    /// Space left after navigation, lesson controls and the system keyboard.
    /// Editors and interactive panels size themselves from this, not the screen.
    var courseStudyViewport: CGSize {
        get { self[CourseStudyViewportKey.self] }
        set { self[CourseStudyViewportKey.self] = newValue }
    }
}

struct CoursesView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showUpload = false
    @State private var showNewCourse = false
    @State private var onlyStarred = false
    #if os(macOS)
    @State private var courseSearch = ""
    #endif
    @State private var deletionRequest: CourseDeletionRequest?
    @AppStorage("courseGettingStartedVersion") private var completedCourseTutorialVersion = 0
    @AppStorage("demoCourseGettingStartedVersion") private var completedDemoCourseTutorialVersion = 0
    @State private var showCourseTutorial = false
    @State private var isVisible = false
    private let courseTutorialVersion = 2

    var body: some View {
        let library = store.courses
        let cache = library.visibleCache
        let starredIDs = Set(cache.catalog.starredCourseIDs ?? [])
        let displayedCourses = cache.catalog.courses.enumerated().filter {
                let matchesStar = !onlyStarred || starredIDs.contains($0.element.id)
                #if os(macOS)
                let query = courseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                return matchesStar && (query.isEmpty || $0.element.title.localizedCaseInsensitiveContains(query)
                    || $0.element.summary.localizedCaseInsensitiveContains(query))
                #else
                return matchesStar
                #endif
            }
            .sorted { left, right in
                let leftStar = starredIDs.contains(left.element.id), rightStar = starredIDs.contains(right.element.id)
                return leftStar != rightStar ? leftStar : left.offset < right.offset
            }.map(\.element)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !cache.catalog.courses.isEmpty { referenceLabLink }
                if let error = library.error {
                    CourseConnectionNotice(message: error) { Task { await library.refresh() } }
                }
                if !cache.catalog.courses.isEmpty {
                    #if os(macOS)
                    HStack(alignment: .center, spacing: 28) {
                        quickStartLink.frame(maxWidth: 530)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("课程资料库").font(.title2.weight(.bold))
                            Text("\(cache.catalog.courses.count) 门课程 · \(starredIDs.count) 门星标")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Picker("课程范围", selection: $onlyStarred) {
                                Text("全部课程").tag(false)
                                Text("星标课程").tag(true)
                            }.pickerStyle(.segmented).frame(maxWidth: 260)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #else
                    quickStartLink
                    Picker("课程范围", selection: $onlyStarred) {
                        Text("全部课程").tag(false)
                        Text("星标课程").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 420)
                    #endif
                    if onlyStarred && displayedCourses.isEmpty {
                        ContentUnavailableView("还没有星标课程", systemImage: "star", description: Text("轻点课程卡片上的星星，收藏常学的课程。"))
                    }
                    #if os(macOS)
                    if displayedCourses.isEmpty && !onlyStarred && !courseSearch.isEmpty {
                        ContentUnavailableView.search(text: courseSearch)
                    }
                    #endif
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280), spacing: 18)], spacing: 18) {
                        ForEach(Array(displayedCourses.enumerated()), id: \.element.id) { index, course in
                            ZStack(alignment: .topTrailing) {
                                NavigationLink {
                                    CourseDetailView(id: course.id).id(store.backend.accountScope)
                                } label: {
                                    CourseCoverTile(course: course, index: index + 1, completed: library.completedCount(for: course))
                                }.buttonStyle(CourseTilePressStyle())
                                HStack(spacing: 0) {
                                    CourseStarButton(id: course.id)
                                    if store.isDemoMode || (store.backend.signedIn && !store.isReadOnlyWorkspace) {
                                        Button(role: .destructive) { requestDeletion(course) } label: {
                                            Image(systemName: "trash").foregroundStyle(.secondary)
                                                .frame(width: 44, height: 44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("删除课程")
                                    }
                                }.padding(14)
                            }
                            .contextMenu {
                                Button(library.isStarred(course.id) ? WorkspaceLocalization.string("取消星标") : WorkspaceLocalization.string("标星"), systemImage: library.isStarred(course.id) ? "star.slash" : "star") {
                                    do { try library.setStarred(course.id, starred: !library.isStarred(course.id)); store.feedbackSequence += 1 }
                                    catch { store.errorMessage = error.localizedDescription }
                                }
                                if store.isDemoMode || (store.backend.signedIn && !store.isReadOnlyWorkspace) {
                                    Button("删除课程", systemImage: "trash", role: .destructive) { requestDeletion(course) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: courseLibraryWidth).padding(20).frame(maxWidth: .infinity)
        }
        .background(Color.primary.opacity(0.035).ignoresSafeArea())
        .overlay {
            if cache.catalog.courses.isEmpty, library.preparing || library.refreshing {
                ProgressView("正在载入课程…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cache.catalog.courses.isEmpty, let error = library.error {
                ContentUnavailableView {
                    Label("暂时无法读取课程", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await library.refresh() } }
                        .buttonStyle(WorkspacePrimaryButtonStyle())
                }
            } else if cache.catalog.courses.isEmpty {
                ContentUnavailableView {
                    Label(store.backend.signedIn || store.isDemoMode ? WorkspaceLocalization.string("还没有课程") : WorkspaceLocalization.string("你的课程，从这里开始"), systemImage: "book.closed")
                } description: {
                    Text(store.backend.signedIn ? WorkspaceLocalization.string("发布课程后，会自动显示在这里。") : WorkspaceLocalization.string("登录后即可接收课程，并在设备间继续学习。"))
                } actions: {
                    VStack(spacing: 12) {
                        if !store.isDemoMode, !store.backend.signedIn {
                            NavigationLink("登录工作坊") { BackendSettingsView() }
                                .buttonStyle(WorkspacePrimaryButtonStyle())
                        } else if store.isDemoMode || !store.isReadOnlyWorkspace {
                            Button("新建课程", systemImage: "plus") { showNewCourse = true }
                                .buttonStyle(WorkspacePrimaryButtonStyle())
                            Button("粘贴课程并上传") { showUpload = true }
                                .buttonStyle(WorkspacePrimaryButtonStyle(prominent: false))
                        }
                    }.frame(maxWidth: 360)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if cache.catalog.courses.isEmpty {
                referenceLabLink.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            }
        }
        .navigationTitle("课程").workspaceResponsiveTitle()
        #if os(macOS)
        .searchable(text: $courseSearch, prompt: WorkspaceLocalization.string("搜索课程"))
        .focusedSceneValue(\.workspaceCreation, WorkspaceCreationContext(kind: .task,
            title: WorkspaceLocalization.string("新建课程"),
            isEnabled: store.isDemoMode || (store.backend.signedIn && !store.isReadOnlyWorkspace),
            create: { showNewCourse = true }))
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button("刷新课程", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    .labelStyle(.iconOnly)
                    .help("刷新课程（⌘R）")
            }
            #endif
            ToolbarItem {
                Menu {
                    Button("课程使用指南", systemImage: "book.pages") { showCourseTutorial = true }
                    if !store.isDemoMode, store.backend.signedIn, !store.isReadOnlyWorkspace,
                       store.backend.currentWorkspaceID == nil {
                        NavigationLink { CoursePublishingSettingsView() } label: {
                            Label("课程 API", systemImage: "curlybraces")
                        }
                    }
                } label: { Label("课程帮助", systemImage: "questionmark.circle") }
            }
            if store.isDemoMode || (store.backend.signedIn && !store.isReadOnlyWorkspace) {
                ToolbarItem {
                    Menu {
                        Button("新建课程", systemImage: "square.and.pencil") { showNewCourse = true }
                        Button("粘贴课程并上传", systemImage: "doc.on.clipboard") { showUpload = true }
                    } label: { Label("添加课程", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $showUpload) { NavigationStack { CoursePasteUploadView(onUploaded: { onlyStarred = false }) }.nativeEditorPresentation() }
        .sheet(isPresented: $showNewCourse) { NavigationStack { CourseNewView(onCreated: { onlyStarred = false }) }.nativeEditorPresentation() }
        .modifier(CourseDeletionConfirmation(request: $deletionRequest))
        .sheet(isPresented: $showCourseTutorial, onDismiss: completeCourseTutorial) {
            NavigationStack {
                CourseGettingStartedView {
                    completeCourseTutorial()
                    showCourseTutorial = false
                }
            }.nativeSheetSize()
        }
        .onAppear {
            isVisible = true
            presentCourseTutorialIfNeeded()
        }
        .onDisappear { isVisible = false }
        .onChange(of: store.navigation) { _, _ in presentCourseTutorialIfNeeded() }
        .onChange(of: scenePhase) { _, _ in presentCourseTutorialIfNeeded() }
        .refreshable { await library.refresh() }
        .task(id: CourseRefreshIdentity(scope: library.scope, active: shouldLoadCourses)) {
            guard shouldLoadCourses else { return }
            await library.prepareForInteraction(preloadFirstCourse: false)
            guard !Task.isCancelled else { return }
            #if DEBUG
            // A disposable, in-memory fixture keeps UI checks independent of accounts and input methods.
            if store.isDemoMode, ProcessInfo.processInfo.arguments.contains("--ui-smoke-course-rich") {
                do {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("course-rich-smoke.json")
                    let course = try CourseImport.parse(String(contentsOf: url, encoding: .utf8))
                    if library.visibleCache.editions[course.id] == nil {
                        _ = try await library.upload(course, expectedRevision: nil, mutationID: UUID())
                    }
                } catch { store.errorMessage = WorkspaceLocalization.string("课程界面验证样例无法载入。") }
            }
            #endif
            await library.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if scenePhase == .active { await library.refresh() }
            }
        }
    }

    private var shouldLoadCourses: Bool {
        guard isVisible, store.navigation == .courses else { return false }
        #if os(macOS)
        // A visible Mac window may be inactive (for example beside another app).
        // Its initial catalog load must not depend on keyboard/window focus.
        return true
        #else
        return scenePhase == .active
        #endif
    }

    private var referenceLabLink: some View {
        CourseReferenceLabEntry {
            CourseReferenceLabPreview { courseID, lessonID in
                CourseLessonView(courseID: courseID, lessonID: lessonID)
            }
        }
    }

    private var courseLibraryWidth: CGFloat {
        #if os(macOS)
        1_440
        #else
        1_080
        #endif
    }

    private var quickStartLink: some View {
        NavigationLink {
            CourseQuickStartView().id(store.courses.scope)
        } label: {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("快速开始").font(quickStartTitleFont).foregroundStyle(.primary)
                    Text("从当前进度，接着学").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.title3.weight(.bold))
                    .foregroundStyle(.white).frame(width: quickStartIconSize, height: quickStartIconSize)
                    .background(palette.action, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(quickStartPadding).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.gradient, in: RoundedRectangle(cornerRadius: 26))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    Capsule().frame(width: 28, height: 3)
                    Capsule().frame(width: 12, height: 3)
                    Circle().frame(width: 3, height: 3)
                }.foregroundStyle(palette.accent.opacity(0.45)).padding(.leading, 24).padding(.bottom, 10)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(CourseTilePressStyle())
        .accessibilityIdentifier("courses.quickStart")
        #if os(macOS)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .help("从当前学习进度继续（⇧⌘L）")
        #endif
    }

    private var quickStartTitleFont: Font {
        #if os(macOS)
        .title2.weight(.bold)
        #else
        .title.weight(.bold)
        #endif
    }
    private var quickStartIconSize: CGFloat {
        #if os(macOS)
        42
        #else
        54
        #endif
    }
    private var quickStartPadding: CGFloat {
        #if os(macOS)
        20
        #else
        24
        #endif
    }

    private func requestDeletion(_ course: CourseSummary) {
        guard let scope = store.courses.scope else { return }
        deletionRequest = CourseDeletionRequest(course: course, scope: scope)
    }

    private func presentCourseTutorialIfNeeded() {
        // Tab containers may instantiate or preload this view before the user enters it.
        guard isVisible, store.navigation == .courses, scenePhase == .active,
              !showUpload, !showNewCourse, !showCourseTutorial, deletionRequest == nil else { return }
        let completedVersion = store.isDemoMode ? completedDemoCourseTutorialVersion : completedCourseTutorialVersion
        if completedVersion < courseTutorialVersion { showCourseTutorial = true }
    }

    private func completeCourseTutorial() {
        if store.isDemoMode { completedDemoCourseTutorialVersion = courseTutorialVersion }
        else { completedCourseTutorialVersion = courseTutorialVersion }
    }
}

private struct CourseGettingStartedView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var publishedTutorial: PublishedTutorial?
    @State private var hasPreparedTutorialContent = false
    @State private var automaticUpload = false
    @State private var traceStep = 0
    @State private var selectedAnswer: Int?
    @State private var answerChecked = false
    @State private var lessonCompleted = false
    @State private var starred = false
    let finish: () -> Void
    private let pageCount = 4
    private let program = ["score = 2", "score = score + 3", "print(score)"]

    var body: some View {
        VStack(spacing: 0) {
            TutorialPager(selection: $page, count: pageCount) { index in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: index))
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(palette.accent)
                                .frame(width: 54, height: 54)
                                .background(palette.surface, in: RoundedRectangle(cornerRadius: 17))
                            Text("\(index + 1) / \(pageCount)")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(title(for: index)).font(.largeTitle.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text(subtitle(for: index)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        pageContent(index)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }.scrollIndicators(.hidden)
            }
            .disabled(!hasPreparedTutorialContent)
            .accessibilityIdentifier("course-tutorial-pager")
            VStack(spacing: 8) {
                TutorialPageIndicators(selection: $page, count: pageCount)
                    .disabled(!hasPreparedTutorialContent)
                Button(action: advance) {
                    Label(page == pageCount - 1 ? WorkspaceLocalization.string("开始学习") : WorkspaceLocalization.string("继续"), systemImage: "arrow.right")
                }
                    .modifier(CourseLearningActionStyle())
                    .disabled(!hasPreparedTutorialContent)
                    .accessibilityIdentifier("course-tutorial-continue")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: 520).padding(.horizontal, 24).padding(.bottom, 20)
        }
        .background(Color.primary.opacity(0.035).ignoresSafeArea())
        .navigationTitle("课程指南").workspaceInlineTitle()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("跳过", action: finish) } }
        .tint(palette.accent)
        .workspaceSelectionFeedback(trigger: page)
        .workspaceSelectionFeedback(trigger: traceStep)
        .workspaceSelectionFeedback(trigger: selectedAnswer)
        .workspaceSelectionFeedback(trigger: starred)
        .task {
            guard !hasPreparedTutorialContent else { return }
            await AppContentService.shared.prepare()
            guard !Task.isCancelled else { return }
            // Keep the text and artwork stable for the lifetime of this guide.
            publishedTutorial = AppContentService.shared.tutorial("course-tutorial")
            hasPreparedTutorialContent = true
        }
    }

    private func publishedPage(for index: Int) -> PublishedTutorialPage? {
        let ids = ["import", "code", "practice", "progress"]
        guard ids.indices.contains(index) else { return nil }
        return publishedTutorial?.pages.first { $0.id == ids[index] }
    }

    private func symbol(for index: Int) -> String {
        if let symbol = publishedPage(for: index)?.symbol { return symbol }
        return switch index {
        case 0: "sparkles"
        case 1: "curlybraces"
        case 2: "play.rectangle"
        default: "bookmark"
        }
    }

    private func title(for index: Int) -> String {
        if let title = publishedPage(for: index)?.title { return title }
        return switch index {
        case 0: WorkspaceLocalization.string("把想学的，变成课程。")
        case 1: WorkspaceLocalization.string("看着代码，一步步理解。")
        case 2: WorkspaceLocalization.string("动手作答，运行验证。")
        default: WorkspaceLocalization.string("随时回来，接着学。")
        }
    }

    private func subtitle(for index: Int) -> String {
        if let subtitle = publishedPage(for: index)?.subtitle { return subtitle }
        return switch index {
        case 0: WorkspaceLocalization.string("资料、问题或学习目标，都可以成为有图解、演示和练习的一节节课。")
        case 1: WorkspaceLocalization.string("完整程序会留在上方；讲到哪里，就标记对应的行、变量或字符。")
        case 2: WorkspaceLocalization.string("支持运行的 Python、C++ 练习，可以编写答案并核对实际输出。")
        default: WorkspaceLocalization.string("学习进度会自动保存，星标收藏常学的课程。")
        }
    }

    @ViewBuilder private func pageContent(_ index: Int) -> some View {
        switch index {
        case 0: importPractice
        case 1: codePractice
        case 2: answerPractice
        default: progressPractice
        }
    }

    private var importPractice: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("课程制作方式", selection: $automaticUpload) {
                Text("手动带入").tag(false)
                Text("AI 自动上传").tag(true)
            }.pickerStyle(.segmented)
            guideRow(WorkspaceLocalization.string("先复制提示词"), detail: (automaticUpload ? WorkspaceLocalization.string("课程页右上角“?” →“课程 API”，复制自动发布提示词。") : WorkspaceLocalization.string("课程页右上角“?” →“课程 API”，复制制作提示词。")), symbol: "doc.on.doc")
            guideRow(WorkspaceLocalization.string("告诉 AI 你想学什么"), detail: WorkspaceLocalization.string("连同提示词发给 AI，让它安排讲解、互动演示与练习。"), symbol: "sparkles")
            guideRow(automaticUpload ? WorkspaceLocalization.string("打开课程，开始学习") : WorkspaceLocalization.string("把生成的课程粘贴回来"),
                detail: automaticUpload ? WorkspaceLocalization.string("使用自动发布提示词后，让 AI 上传；课程会出现在这里。") : WorkspaceLocalization.string("课程页右上角“+” →“粘贴课程并上传”。也可以选择“新建课程”。"),
                symbol: automaticUpload ? "book.closed" : "doc.on.clipboard")
            if store.isReadOnlyWorkspace || store.backend.currentWorkspaceID != nil {
                Text("切换到自己的空间，即可配置课程 API；只读空间仍可学习已有课程。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if !store.backend.signedIn && !store.isDemoMode {
                Text("登录后，即可接收课程并同步学习进度。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.modifier(CoursePaperPanel())
    }

    private var codePractice: some View {
        VStack(alignment: .leading, spacing: 20) {
            programPanel(focus: traceSpans)
            HStack(alignment: .firstTextBaseline) {
                Text(traceStep == 2 ? WorkspaceLocalization.string("输出") : "score").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(traceStep == 0 ? "2" : "5")
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .foregroundStyle(palette.accent).contentTransition(.numericText())
            }
            Text(traceNote).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(traceStep == 2 ? WorkspaceLocalization.string("重新观察") : WorkspaceLocalization.string("执行下一步"), systemImage: traceStep == 2 ? "arrow.counterclockwise" : "arrow.right") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { traceStep = (traceStep + 1) % 3 }
            }.buttonStyle(WorkspacePrimaryButtonStyle(prominent: false))
                .accessibilityIdentifier("course-tutorial-trace-next")
        }.modifier(CoursePaperPanel())
    }

    private func programPanel(focus: [CourseCodeSpan]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("完整程序", systemImage: "chevron.left.forwardslash.chevron.right").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("Python").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(program.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                            CourseMarkedCodeText(source: program[index], lineNumber: index + 1,
                                spans: focus.filter { $0.line == index + 1 })
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }.padding(14)
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            .accessibilityLabel("完整 Python 程序")
        }
    }

    private var traceSpans: [CourseCodeSpan] {
        switch traceStep {
        case 0: [CourseCodeSpan(line: 1, text: "2")]
        case 1: [CourseCodeSpan(line: 2, text: "score", occurrence: 2), CourseCodeSpan(line: 2, text: "+")]
        default: [CourseCodeSpan(line: 3, text: "score")]
        }
    }

    private var traceNote: String {
        switch traceStep {
        case 0: WorkspaceLocalization.string("先把 2 存入 score。点下一步，看看变量怎样变化。")
        case 1: WorkspaceLocalization.string("读取右侧的 score，加上 3，再把结果 5 存回去。")
        default: WorkspaceLocalization.string("最后输出 5。推演时，标记会跟着当前步骤移动。")
        }
    }

    private var answerPractice: some View {
        VStack(alignment: .leading, spacing: 20) {
            programPanel(focus: [CourseCodeSpan(line: 3, text: "score")])
            Label("试一道小题", systemImage: "pencil.and.outline").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
            Text("这段程序，最后输出多少？").font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ForEach([2, 5, 8], id: \.self) { value in
                    Button {
                        selectedAnswer = value
                        answerChecked = false
                    } label: {
                        Text("\(value)").font(.title3.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(selectedAnswer == value ? palette.accent.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selectedAnswer == value ? palette.accent : .clear, lineWidth: 1.5) }
                    }.buttonStyle(.plain)
                        .accessibilityLabel("答案 \(value)")
                        .accessibilityAddTraits(selectedAnswer == value ? .isSelected : [])
                }
            }
            if answerChecked, let selectedAnswer {
                Label(selectedAnswer == 5 ? WorkspaceLocalization.string("答对了：2 + 3 = 5。") : WorkspaceLocalization.string("想一想：score 从 2 开始，再加上 3。"), systemImage: selectedAnswer == 5 ? "checkmark.circle.fill" : "lightbulb")
                    .font(.subheadline).foregroundStyle(selectedAnswer == 5 ? palette.accent : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("course-tutorial-answer-feedback")
            } else {
                Text("选一个答案，再点右下角的箭头，试试提交答案。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Divider()
            guideRow(WorkspaceLocalization.string("一个箭头，顺手往下学"), detail: WorkspaceLocalization.string("有尚未检查的答案时，先提交当前答案；再次点击，才前往下一页。"), symbol: "arrow.right.circle")
            Text("填空、选择、代码题，都可以这样操作。")
                .font(.caption).foregroundStyle(.secondary)
        }.modifier(CoursePaperPanel())
    }

    private var progressPractice: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Python，从第一步开始").font(.headline)
                    Text("已完成 \(lessonCompleted ? 2 : 1) / 3 课时").font(.subheadline)
                        .foregroundStyle(lessonCompleted ? Color.workspaceCompleted : .secondary)
                }
                Spacer(minLength: 0)
                Button { starred.toggle() } label: {
                    Image(systemName: starred ? "star.fill" : "star")
                        .font(.title3).foregroundStyle(starred ? palette.accent : .secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(starred ? WorkspaceLocalization.string("取消演示星标") : WorkspaceLocalization.string("添加演示星标"))
                    .accessibilityIdentifier("course-tutorial-star")
            }
            ProgressView(value: lessonCompleted ? 2 : 1, total: 3).tint(palette.accent)
            Button(lessonCompleted ? WorkspaceLocalization.string("已完成这一课") : WorkspaceLocalization.string("试试标记本节完成"), systemImage: lessonCompleted ? "checkmark.circle.fill" : "checkmark.circle") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { lessonCompleted.toggle() }
            }.buttonStyle(WorkspacePrimaryButtonStyle(tint: lessonCompleted ? Color.workspaceCompleted : nil, prominent: false))
            guideRow(WorkspaceLocalization.string("快速开始"), detail: WorkspaceLocalization.string("下次从课程页的“快速开始”，接着当前进度学习。"), symbol: "play.fill")
            Text("指南里的操作只用于体验。以后可从课程页右上角“?”重看。")
                .font(.caption).foregroundStyle(.secondary)
            if !store.backend.signedIn && !store.isDemoMode {
                Text("登录后，课程和学习进度会在设备间同步。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.modifier(CoursePaperPanel())
    }

    private func advance() {
        if page == 2, selectedAnswer != nil, !answerChecked {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { answerChecked = true }
        } else if page == pageCount - 1 {
            finish()
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { page += 1 }
        }
    }

    private func guideRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(palette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CourseCoverTile: View {
    @Environment(\.workspacePalette) private var palette
    let course: CourseSummary
    let index: Int
    let completed: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d", index)).font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 12)
                Color.clear.frame(width: 88, height: 44).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(course.title).font(.title2.weight(.bold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !course.summary.isEmpty {
                    Text(course.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: Double(completed), total: Double(max(course.lessonCount, 1))).tint(palette.accent)
                HStack {
                    Text(completed == course.lessonCount ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.format("%lld / %lld 课时", completed, course.lessonCount))
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                }
            }
        }
        .padding(24).padding(.leading, 5).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .leading) { Capsule().fill(palette.accent.opacity(0.55)).frame(width: 5).padding(.vertical, 26) }
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.065), lineWidth: 1) }
    }
}

private struct CourseTilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WorkspaceStore.self) private var store
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: configuration.isPressed) { _, pressed in store.hapticsEnabled && pressed }
    }
}

private struct CoursePaperPanel: ViewModifier {
    var contentPadding: CGFloat = 22
    func body(content: Content) -> some View {
        content.padding(contentPadding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.065), lineWidth: 1) }
    }
}

private struct CourseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deletionRequest: CourseDeletionRequest?
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    let id: UUID
    var body: some View {
        let library = store.courses
        let edition = library.visibleCache.editions[id]
        Group {
            if let edition {
                let progress = library.visibleCache.progress[id]
                #if os(macOS)
                desktopOverview(edition: edition, progress: progress)
                #else
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 18) {
                            Label("课程", systemImage: "book.closed").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                            Text(edition.course.title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            if !edition.course.summary.isEmpty { Text(edition.course.summary).font(.body).foregroundStyle(.secondary).lineSpacing(4) }
                            let count = progress?.completedLessonIDs.count ?? 0
                            ProgressView(value: Double(count), total: Double(max(edition.course.lessons.count, 1))).tint(palette.accent)
                            Text("已完成 \(count) / \(edition.course.lessons.count) 课时").font(.subheadline).foregroundStyle(.secondary)
                            if let next = CourseLearningContinuation.nextLesson(in: edition, progress: progress) {
                                NavigationLink {
                                    CourseLessonView(courseID: id, lessonID: next.id).id("\(id)-\(next.id)-\(edition.revision)")
                                } label: { Label(count == 0 ? WorkspaceLocalization.string("开始学习") : WorkspaceLocalization.string("继续学习"), systemImage: "play.fill") }
                                    .buttonStyle(WorkspacePrimaryButtonStyle())
                            }
                        }.modifier(CoursePaperPanel()).padding(.bottom, 24)
                        if library.hasEarlierDrafts(id) {
                            Text("课程已更新，有尚未提交的旧版作答。请按新版内容重新练习。")
                                .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 24)
                        }
                        if let error = library.error { CourseConnectionNotice(message: error) { Task { await library.open(id) } }.padding(.bottom, 24) }
                        Text("学习路径").font(.title3.weight(.bold)).padding(.horizontal, 4).padding(.bottom, 24)
                        Group {
                            ForEach(Array(edition.course.lessons.enumerated()), id: \.element.id) { index, lesson in
                                let completed = progress?.completedLessonIDs.contains(lesson.id) == true
                                NavigationLink {
                                    CourseLessonView(courseID: id, lessonID: lesson.id).id("\(id)-\(lesson.id)-\(edition.revision)")
                                } label: {
                                    HStack(alignment: .center, spacing: 16) {
                                        Group {
                                            if completed { Image(systemName: "checkmark").font(.title3.weight(.bold)) }
                                            else { Text(String(format: "%02d", index + 1)).font(.title2.weight(.bold).monospacedDigit()) }
                                        }
                                        .foregroundStyle(completed ? Color.workspaceCompleted : palette.accent)
                                        .frame(width: 46, height: 52).background(palette.surface, in: RoundedRectangle(cornerRadius: 15))
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(lesson.title).font(.headline).foregroundStyle(.primary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let objective = lesson.objectives?.first {
                                                Text(objective).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            HStack(spacing: 10) {
                                                Text("\(lesson.blocks.filter { $0.type == .question }.count) 道练习")
                                                if let minutes = lesson.estimatedMinutes { Text("约 \(minutes) 分钟") }
                                            }.font(.subheadline).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                                    }.modifier(CoursePaperPanel())
                                }.buttonStyle(CourseTilePressStyle())
                                if lesson.id != edition.course.lessons.last?.id {
                                    HStack { Capsule().fill(palette.accent.opacity(0.25)).frame(width: 2, height: 18).padding(.leading, 44); Spacer() }
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }.frame(maxWidth: 800).padding(20).frame(maxWidth: .infinity)
                }
                #endif
            } else if let error = library.error {
                ContentUnavailableView { Label("暂时无法打开课程", systemImage: "wifi.exclamationmark") }
                description: { Text(error) }
                actions: { Button("重试") { Task { await library.open(id) } } }
            } else { ProgressView("正在打开课程…") }
        }
        .background(Color.primary.opacity(0.035).ignoresSafeArea())
        .navigationTitle("课程").workspaceInlineTitle()
        .toolbar {
            if let edition {
                ToolbarItem { CourseStarButton(id: id) }
                if store.isDemoMode || (store.backend.signedIn && !store.isReadOnlyWorkspace) {
                    ToolbarItem {
                        Button("删除课程", systemImage: "trash", role: .destructive) {
                            guard let scope = library.scope else { return }
                            let course = CourseSummary(id: id, title: edition.course.title, summary: edition.course.summary,
                                revision: edition.revision, updatedAt: edition.updatedAt, lessonCount: edition.course.lessons.count)
                            deletionRequest = CourseDeletionRequest(course: course, scope: scope)
                        }.labelStyle(.iconOnly)
                    }
                }
            }
        }
        .modifier(CourseDeletionConfirmation(request: $deletionRequest, onDeleted: { dismiss() }))
        // The overview itself does not start author content or add web views.
        // An optional app-level warm-up owns the single empty WebKit shell.
        .task(id: id) { await library.open(id) }
        .refreshable { await library.open(id) }
    }
    #if os(macOS)
    private func desktopOverview(edition: CourseEdition, progress: CourseProgress?) -> some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("课程", systemImage: "book.closed").font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                    Text(edition.course.title).font(.system(size: 28, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    if !edition.course.summary.isEmpty {
                        Text(edition.course.summary).font(.body).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    let count = progress?.completedLessonIDs.count ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(count), total: Double(max(edition.course.lessons.count, 1))).tint(palette.accent)
                        Text("已完成 \(count) / \(edition.course.lessons.count) 课时").font(.caption).foregroundStyle(.secondary)
                    }
                    if let next = CourseLearningContinuation.nextLesson(in: edition, progress: progress) {
                        NavigationLink {
                            CourseLessonView(courseID: id, lessonID: next.id).id("\(id)-\(next.id)-\(edition.revision)")
                        } label: { Label(count == 0 ? WorkspaceLocalization.string("开始学习") : WorkspaceLocalization.string("继续学习"), systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                            .help("继续学习（⇧⌘L）")
                    }
                    if libraryHasEarlierDrafts {
                        Label("课程已更新，请按新版内容重新练习。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.courses.error {
                        CourseConnectionNotice(message: error) { Task { await store.courses.open(id) } }
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
                .background(.background.opacity(0.7))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("学习路径").font(.title2.weight(.bold))
                        Spacer()
                        Text("\(edition.course.lessons.count) 课时").font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(Array(edition.course.lessons.enumerated()), id: \.element.id) { index, lesson in
                            let completed = progress?.completedLessonIDs.contains(lesson.id) == true
                            NavigationLink {
                                CourseLessonView(courseID: id, lessonID: lesson.id).id("\(id)-\(lesson.id)-\(edition.revision)")
                            } label: {
                                HStack(spacing: 16) {
                                    Group {
                                        if completed { Image(systemName: "checkmark").font(.headline) }
                                        else { Text(String(format: "%02d", index + 1)).font(.title3.weight(.bold).monospacedDigit()) }
                                    }.foregroundStyle(completed ? Color.workspaceCompleted : palette.accent)
                                        .frame(width: 38, height: 42)
                                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(lesson.title).font(.headline).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let objective = lesson.objectives?.first {
                                            Text(objective).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        HStack(spacing: 12) {
                                            Text("\(lesson.blocks.filter { $0.type == .question }.count) 道练习")
                                            if let minutes = lesson.estimatedMinutes { Text("约 \(minutes) 分钟") }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }.padding(16)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
                            }.buttonStyle(CourseTilePressStyle()).help(lesson.title)
                        }
                    }
                }.frame(maxWidth: 840).padding(28).frame(maxWidth: .infinity)
            }.frame(minWidth: 360, maxWidth: .infinity)
        }
    }
    private var libraryHasEarlierDrafts: Bool { store.courses.hasEarlierDrafts(id) }
    #endif

}

private struct CourseLearningUnit: Identifiable {
    let id: UUID
    var blocks: [CourseBlock]
    var title: String {
        guard let block = blocks.first else { return WorkspaceLocalization.string("学习") }
        if let title = block.title, !title.isEmpty { return title }
        if let kind = block.presentation?.kind {
            switch kind {
            case .code: return WorkspaceLocalization.string("代码示例")
            case .table: return WorkspaceLocalization.string("梳理结构")
            case .steps: return WorkspaceLocalization.string("分步推演")
            case .trace: return WorkspaceLocalization.string("程序推演")
            case .comparison: return WorkspaceLocalization.string("对照阅读")
            case .flashcards: return WorkspaceLocalization.string("记忆卡片")
            case .markdown: return WorkspaceLocalization.string("图文阅读")
            case .html: return WorkspaceLocalization.string("互动演示")
            case .svg: return WorkspaceLocalization.string("矢量图解")
            }
        }
        switch block.type {
        case .text: return WorkspaceLocalization.string("读一读")
        case .callout: return WorkspaceLocalization.string("要点")
        case .image: return WorkspaceLocalization.string("图解")
        case .chart: return WorkspaceLocalization.string("观察图表")
        case .question: return block.answerFormat == .code ? WorkspaceLocalization.string("代码练习") : block.answerFormat == .output ? WorkspaceLocalization.string("预测输出") : WorkspaceLocalization.string("动手练习")
        }
    }
    var symbol: String {
        guard let block = blocks.first else { return "book" }
        if let kind = block.presentation?.kind {
            switch kind {
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .table: return "tablecells"
            case .steps: return "point.3.connected.trianglepath.dotted"
            case .trace: return "play.rectangle"
            case .comparison: return "rectangle.split.2x1"
            case .flashcards: return "rectangle.on.rectangle.angled"
            case .markdown: return "text.document"
            case .html: return "play.rectangle"
            case .svg: return "scribble.variable"
            }
        }
        switch block.type {
        case .text: return "text.alignleft"
        case .callout: return "lightbulb"
        case .image: return "photo"
        case .chart: return "chart.bar.xaxis"
        case .question: return "pencil.tip"
        }
    }
    static func make(from lesson: CourseLesson) -> [Self] {
        var units: [Self] = []
        for block in lesson.blocks {
            if block.type == .callout, block.presentation == nil, block.title == nil, block.focusLines == nil, block.focusSpans == nil,
               let last = units.last, last.blocks.first?.type == .text, last.blocks.first?.presentation == nil {
                units[units.count - 1].blocks.append(block)
            } else { units.append(Self(id: block.id, blocks: [block])) }
        }
        return units
    }
}

private struct CourseLessonView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var readingTicket: UUID?
    @State private var readingLibrary: CourseLibraryService?
    @State private var useNativeReader = false
    @State private var activeServerLessonID: UUID?
    let courseID: UUID
    let lessonID: UUID

    var body: some View {
        let cache = store.courses.visibleCache
        Group {
            if let edition = cache.editions[courseID],
               let lesson = edition.course.lessons.first(where: { $0.id == (activeServerLessonID ?? lessonID) }) {
                if useNativeReader {
                    CoursePreparedLessonView(edition: edition, lesson: lesson,
                        progress: cache.progress[courseID] ?? CourseProgress(courseID: courseID), scope: store.courses.scope)
                } else {
                    CourseServerPlayerView(edition: edition, lesson: lesson,
                        progress: cache.progress[courseID] ?? CourseProgress(courseID: courseID),
                        onUseNative: { useNativeReader = true },
                        onNavigateLesson: { activeServerLessonID = $0 })
                        .id("web-player-\(store.courses.scope ?? "local")-\(edition.revision)-\(lesson.id)")
                }
            } else { ContentUnavailableView("请重新打开课程", systemImage: "book.closed") }
        }
        .onAppear {
            guard readingTicket == nil else { return }
            readingLibrary = store.courses
            readingTicket = store.courses.beginReading(courseID)
        }
        .onDisappear {
            if let readingTicket { readingLibrary?.endReading(readingTicket) }
            readingTicket = nil; readingLibrary = nil
        }
    }
}

/// Only the first nearby web documents are prepared; publishers' scripts do not
/// run until the learner starts their activity. Preparation never opens a network.
private struct CoursePreparedLessonView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edition: CourseEdition
    let lesson: CourseLesson
    let progress: CourseProgress
    let scope: String?
    @State private var prepared: PreparationKey?
    @State private var failure: String?
    @State private var retry = 0
    @State private var phase = WorkspaceLocalization.string("准备阅读内容")
    private struct PreparationKey: Hashable {
        let scope: String?
        let courseID: UUID
        let lessonID: UUID
        let revision: Int
    }
    private struct Attempt: Hashable { let key: PreparationKey; let retry: Int }
    private var key: PreparationKey {
        PreparationKey(scope: scope, courseID: edition.course.id, lessonID: lesson.id, revision: edition.revision)
    }
    private var webBlocks: [CourseBlock] {
        lesson.blocks.filter { $0.presentation?.kind == .html || $0.presentation?.kind == .svg }
    }
    var body: some View {
        Group {
            if prepared == key || webBlocks.isEmpty {
                CourseLessonReader(edition: edition, lesson: lesson, progress: progress)
            } else if let failure {
                ContentUnavailableView {
                    Label("暂时无法准备互动", systemImage: "arrow.clockwise")
                } description: { Text(failure) } actions: {
                    Button("重试") { retry += 1 }
                    Button("先阅读文字") { prepared = key }
                }
            } else {
                CourseLoadingIndicator(title: WorkspaceLocalization.string("正在准备课时"), detail: phase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("准备课时").workspaceInlineTitle()
            }
        }
        .task(id: Attempt(key: key, retry: retry)) {
            guard prepared != key, !webBlocks.isEmpty else { return }
            failure = nil; phase = WorkspaceLocalization.string("准备阅读内容")
            await Task.yield()
            do {
                // At most two nearby documents, with a bounded shared cache.
                for block in webBlocks.prefix(2) {
                    let svg = block.presentation?.kind == .svg
                    if let content = svg ? block.presentation?.svg : block.presentation?.html {
                        _ = await CourseWebDocuments.shared.document(source: content.source, isSVG: svg, reduceMotion: reduceMotion)
                    }
                    try Task.checkCancellation()
                }
                phase = WorkspaceLocalization.string("准备互动环境")
                try await CourseWebPreloader.shared.prepare()
                try Task.checkCancellation()
                prepared = key
            } catch {
                guard !Task.isCancelled else { return }
                failure = WorkspaceLocalization.string("可以重试，或先阅读课程中的文字说明。")
            }
        }
    }
}

private struct CourseLoadingIndicator: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(palette.accent)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center).padding(24)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Isolated sample path used to inspect the real native shell and remote page.
struct CourseServerPlayerSmokeView: View {
    var body: some View {
        NavigationStack {
            CourseReferenceLabPreview { courseID, lessonID in
                CourseLessonView(courseID: courseID, lessonID: lessonID)
            }
        }
    }
}
#endif

#if DEBUG
/// Local-only layout fixture: use the same reader/editor as production without
/// tapping through navigation or loading any account's courses.
struct CourseLayoutSmokeView: View {
    private let edition: CourseEdition
    private let lesson: CourseLesson?

    init(code: Bool) {
        var fixture = CourseDemo.edition()
        let kind: CourseQuestionInputKind = code ? .code : .integer
        var selection: CourseLesson?
        for original in fixture.course.lessons {
            guard let question = original.blocks.first(where: {
                $0.type == .question && $0.questionType == .shortAnswer && $0.resolvedInput.kind == kind
            }) else { continue }
            var isolated = original
            isolated.referenceCode = original.codeContext(for: question.id, courseReference: fixture.course.referenceCode)
            isolated.blocks = [question]
            selection = isolated
            fixture.course.lessons = [isolated]
            break
        }
        edition = fixture
        lesson = selection
    }

    var body: some View {
        NavigationStack {
            if let lesson {
                CourseLessonReader(edition: edition, lesson: lesson,
                    progress: CourseProgress(courseID: edition.course.id, courseRevision: edition.revision))
            } else {
                ContentUnavailableView("没有匹配的演示练习", systemImage: "exclamationmark.triangle")
            }
        }
    }
}
#endif

/// Immutable lesson structure is prepared outside the state that changes while
/// typing an answer, so every keystroke does not rebuild units or scan all answers.
private struct CourseLessonReader: View {
    @AppStorage(CourseLearningControlSide.preferenceKey) private var controlSide = CourseLearningControlSide.right.rawValue
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let edition: CourseEdition
    let lesson: CourseLesson
    let progress: CourseProgress
    private let units: [CourseLearningUnit]
    private let questions: [CourseBlock]
    private let answersByBlock: [UUID: CourseAnswer]
    private let codeContexts: [UUID: CourseCodeSample]
    private var courseID: UUID { edition.course.id }
    private var lessonID: UUID { lesson.id }
    @State private var focusedQuestionID: UUID?
    private var isAnswerEditing: Bool {
        #if os(iOS)
        focusedQuestionID != nil
        #else
        false
        #endif
    }
    private var readingPadding: CGFloat {
        #if os(iOS)
        isAnswerEditing ? 12 : 16
        #else
        20
        #endif
    }
    private var panelPadding: CGFloat {
        #if os(iOS)
        18
        #else
        22
        #endif
    }
    @State private var notice: String?
    @State private var activeUnitID: UUID?
    @State private var continuous = false
    @State private var drafts: [UUID: CourseQuestionDraft] = [:]
    @State private var traceSources: [UUID: CourseCodeSample] = [:]
    @State private var unitBodyHeight: CGFloat = 200
    @State private var nextLessonID: UUID?
    #if os(macOS)
    @State private var showsDesktopDirectory = true
    @State private var showsCompactDirectory = false
    @State private var desktopViewportWidth: CGFloat = 0
    @State private var referenceColumnFraction: CGFloat = 0.43
    @State private var referenceResizeOrigin: CGFloat?
    #endif

    init(edition: CourseEdition, lesson: CourseLesson, progress: CourseProgress) {
        self.edition = edition; self.lesson = lesson; self.progress = progress
        units = CourseLearningUnit.make(from: lesson)
        questions = lesson.blocks.filter { $0.type == .question }
        answersByBlock = Dictionary(progress.answers.filter { $0.lessonID == lesson.id }.map { ($0.blockID, $0) },
            uniquingKeysWith: { first, _ in first })
        codeContexts = Dictionary(uniqueKeysWithValues: lesson.blocks.compactMap { block in
            lesson.codeContext(for: block.id, courseReference: edition.course.referenceCode).map { (block.id, $0) }
        })
    }

    var body: some View {
        let currentID = activeUnitID ?? units.first?.id
        Group {
            #if os(macOS)
            GeometryReader { geometry in
                HSplitView {
                    if showsDesktopDirectory && geometry.size.width >= 760 {
                        desktopDirectory(currentID: currentID)
                            .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
                    }
                    VStack(spacing: 0) {
                        desktopReadingHeader(currentID: currentID)
                        if continuous || dynamicTypeSize.isAccessibilitySize {
                            continuousContent(edition: edition, lesson: lesson, progress: progress, units: units, sideBySide: true)
                        } else {
                            unitStage(units.first { $0.id == currentID }, progress: progress, revision: edition.revision, sideBySide: true)
                        }
                        if !traceOwnsControls(currentID) {
                            lessonControls(edition: edition, lesson: lesson, progress: progress, units: units, currentID: currentID)
                        }
                    }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { desktopViewportWidth = $0 }
            }
            #else
            GeometryReader { geometry in
                let landscape = verticalSizeClass == .compact && geometry.size.width >= 600
                mobileLessonContent(currentID: currentID, size: geometry.size, landscape: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: CourseLearningControlSide(rawValue: controlSide)?.alignment ?? .bottomTrailing) {
                if !traceOwnsControls(currentID) {
                    lessonControls(edition: edition, lesson: lesson, progress: progress, units: units,
                        currentID: currentID, vertical: true, compact: true)
                        .frame(width: 64)
                        .padding(.horizontal, 14)
                }
            }
            #endif
        }
        .onChange(of: edition.revision) { _, _ in drafts.removeAll(); traceSources.removeAll(); activeUnitID = nil }
        .background(Color.primary.opacity(0.035).ignoresSafeArea())
        .navigationTitle(isAnswerEditing ? WorkspaceLocalization.string("答题") : WorkspaceLocalization.string("学习")).workspaceInlineTitle()
        .navigationDestination(item: $nextLessonID) { id in
            CourseLessonView(courseID: courseID, lessonID: id).id("\(courseID)-\(id)-\(edition.revision)")
        }
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button {
                    if desktopViewportWidth >= 760 { showsDesktopDirectory.toggle() }
                    else { showsCompactDirectory.toggle() }
                } label: { Label("学习目录", systemImage: "sidebar.left") }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .help(WorkspaceLocalization.string("显示或隐藏学习目录（⌃⌘L）"))
                    .popover(isPresented: $showsCompactDirectory) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(verbatim: lesson.title).font(.headline)
                                unitDirectory(units, currentID: currentID, vertical: true)
                            }.padding(16)
                        }.frame(width: 300, height: 400)
                    }
            }
            #endif
            if !isAnswerEditing {
                ToolbarItem {
                    #if os(iOS)
                    Menu {
                        ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                            Button("\(index + 1). \(unit.title)") { continuous = false; select(unit.id) }
                        }
                        Divider()
                        Button(continuous ? WorkspaceLocalization.string("逐步学习") : WorkspaceLocalization.string("连续阅读")) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { continuous.toggle() }
                        }
                    } label: { Label("学习目录", systemImage: "list.bullet") }
                    #else
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { continuous.toggle() }
                    } label: {
                        Label(continuous ? WorkspaceLocalization.string("切换为卡片阅读") : WorkspaceLocalization.string("切换为连续阅读"), systemImage: continuous ? "square.stack" : "doc.text")
                    }.labelStyle(.iconOnly)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help(continuous ? WorkspaceLocalization.string("卡片阅读（⇧⌘R）") : WorkspaceLocalization.string("连续阅读（⇧⌘R）"))
                    #endif
                }
            }
        }
        .workspaceSelectionFeedback(trigger: activeUnitID)
        .workspaceSelectionFeedback(trigger: continuous)
        #if os(macOS)
        .background {
            // Trace arrows belong to individual statements. Unit navigation
            // retains its distinct modified shortcut even with the shared footer.
            if traceOwnsControls(currentID), let index = units.firstIndex(where: { $0.id == currentID }) {
                Button(WorkspaceLocalization.string("上一学习单元")) {
                    if index > 0 { select(units[index - 1].id) }
                }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(index == 0).hidden().accessibilityHidden(true)
                if index + 1 < units.count {
                    Button(WorkspaceLocalization.string("继续")) { select(units[index + 1].id) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        .hidden().accessibilityHidden(true)
                }
            }
        }
        #endif
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-smoke-demo"), arguments.contains("--ui-smoke-course-layout") {
                focusedQuestionID = questions.first { $0.questionType == .shortAnswer }?.id
            }
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder private func mobileLessonContent(currentID: UUID?, size: CGSize, landscape: Bool) -> some View {
        if continuous || dynamicTypeSize.isAccessibilitySize {
            continuousContent(edition: edition, lesson: lesson, progress: progress, units: units, sideBySide: landscape)
        } else {
            let showDirectory = !landscape && size.width >= 740 && size.height >= 540 && !isAnswerEditing
            HStack(alignment: .top, spacing: 0) {
                if showDirectory {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            lessonHeading(edition: edition, lesson: lesson)
                            unitDirectory(units, currentID: currentID, vertical: true)
                        }.padding(20)
                    }.frame(width: 250)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !isAnswerEditing && !showDirectory && !landscape {
                        compactLearningHeading(currentID: currentID)
                    }
                    unitStage(units.first { $0.id == currentID }, progress: progress, revision: edition.revision, sideBySide: landscape)
                }
            }
        }
    }
    #endif

    private func traceOwnsControls(_ currentID: UUID?) -> Bool {
        guard !continuous, !dynamicTypeSize.isAccessibilitySize,
              let index = units.firstIndex(where: { $0.id == currentID }) else { return false }
        #if os(iOS)
        guard index + 1 < units.count else { return false }
        #endif
        return units[index].blocks.first?.presentation?.kind == .trace
    }

    private func compactLearningHeading(currentID: UUID?) -> some View {
        let index = units.firstIndex { $0.id == currentID } ?? 0
        return HStack(spacing: 12) {
            Text(units.indices.contains(index) ? units[index].title : lesson.title)
                .font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(index + 1) / \(units.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    private func desktopDirectory(currentID: UUID?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("课程目录", systemImage: "books.vertical").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(edition.course.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: Double(progress.completedLessonIDs.count),
                        total: Double(max(edition.course.lessons.count, 1))).tint(palette.accent)
                    Text("已完成 \(progress.completedLessonIDs.count) / \(edition.course.lessons.count) 课时")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(edition.course.lessons.enumerated()), id: \.element.id) { index, entry in
                        if entry.id == lessonID {
                            desktopLessonLabel(entry, index: index, selected: true)
                            VStack(spacing: 4) {
                                ForEach(Array(units.enumerated()), id: \.element.id) { unitIndex, unit in
                                    directoryButton(unit, index: unitIndex, selected: !continuous && unit.id == currentID)
                                }
                            }.padding(.leading, 8).padding(.bottom, 8)
                        } else {
                            NavigationLink {
                                CourseLessonView(courseID: courseID, lessonID: entry.id)
                                    .id("\(courseID)-\(entry.id)-\(edition.revision)")
                            } label: { desktopLessonLabel(entry, index: index, selected: false) }
                                .buttonStyle(.plain).help(entry.title)
                        }
                    }
                }
            }.padding(16)
        }
        .background(.background.opacity(0.65))
        .accessibilityIdentifier("course-desktop-directory")
    }

    private func desktopLessonLabel(_ entry: CourseLesson, index: Int, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: progress.completedLessonIDs.contains(entry.id) ? "checkmark.circle.fill" : "book.closed")
                .foregroundStyle(selected ? palette.accent : Color.secondary).frame(width: 16)
            Text("\(index + 1). \(entry.title)").font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 10).padding(.horizontal, 9)
            .background(selected ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }

    private func desktopReadingHeader(currentID: UUID?) -> some View {
        let index = units.firstIndex { $0.id == currentID } ?? 0
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(continuous ? WorkspaceLocalization.string("连续阅读") : WorkspaceLocalization.format("单元 %lld / %lld", index + 1, units.count))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let minutes = lesson.estimatedMinutes {
                Label("约 \(minutes) 分钟", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }.padding(.horizontal, 28).padding(.vertical, 16)
            .background(.background.opacity(0.8))
            .overlay(alignment: .bottom) { Divider() }
    }
    #endif

    private func lessonHeading(edition: CourseEdition, lesson: CourseLesson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(edition.course.title).lineLimit(1)
                Spacer(minLength: 0)
                let index = (edition.course.lessons.firstIndex { $0.id == lesson.id } ?? 0) + 1
                Text("\(index) / \(edition.course.lessons.count) 课时").fixedSize()
            }.font(.subheadline.weight(.medium)).foregroundStyle(palette.accent)
            Text(lesson.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func unitDirectory(_ units: [CourseLearningUnit], currentID: UUID?, vertical: Bool) -> some View {
        if vertical {
            VStack(spacing: 8) {
                ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                    directoryButton(unit, index: index, selected: unit.id == currentID)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                            directoryButton(unit, index: index, selected: unit.id == currentID).id(unit.id)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 2)
                }
                .onChange(of: currentID) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }
    private func directoryButton(_ unit: CourseLearningUnit, index: Int, selected: Bool) -> some View {
        Button {
            #if os(macOS)
            continuous = false
            #endif
            select(unit.id)
        } label: {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1)).font(.subheadline.weight(.bold).monospacedDigit())
                Text(unit.title).font(.subheadline.weight(.semibold)).lineLimit(directoryTitleLineLimit)
                #if os(macOS)
                Spacer(minLength: 0)
                #endif
            }
            .padding(.horizontal, 13).frame(minHeight: directoryRowHeight)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
            .background(selected ? palette.action : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
            .accessibilityLabel("第 \(index + 1) 个单元，\(unit.title)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var directoryTitleLineLimit: Int {
        #if os(macOS)
        2
        #else
        1
        #endif
    }
    private var directoryRowHeight: CGFloat {
        #if os(macOS)
        36
        #else
        44
        #endif
    }

    private func unitStage(_ unit: CourseLearningUnit?, progress: CourseProgress, revision: Int, sideBySide: Bool = false) -> some View {
        GeometryReader { geometry in
            Group {
                if let unit, unit.blocks.first?.presentation?.kind == .trace {
                    VStack(spacing: 0) {
                        notices.padding(.horizontal, 20)
                        unitContent(unit, progress: progress, revision: revision, fitsViewport: true)
                    }
                } else {
                    scrollingUnitStage(unit, progress: progress, revision: revision, availableHeight: geometry.size.height,
                        availableWidth: geometry.size.width, sideBySide: sideBySide)
                }
            }
            .environment(\.courseStudyViewport, geometry.size)
        }
    }

    private func scrollingUnitStage(_ unit: CourseLearningUnit?, progress: CourseProgress,
                                    revision: Int, availableHeight: CGFloat, availableWidth: CGFloat = 0,
                                    sideBySide: Bool = false) -> some View {
        let columns = sideBySide && !dynamicTypeSize.isAccessibilitySize && availableWidth >= 620
        let layout = columns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            if let unit, let code = source(for: unit) {
                sourceHeader(code, availableHeight: availableHeight, sideBySide: columns)
                    .frame(width: columns ? referenceColumnWidth(availableWidth) : nil)
                    .modifier(CourseReferenceResizeHandle(enabled: columns, resize: { change in
                        #if os(macOS)
                        if let translation = change {
                            let origin = referenceResizeOrigin ?? referenceColumnFraction
                            referenceResizeOrigin = origin
                            referenceColumnFraction = min(0.62, max(0.3, origin + translation / max(1, availableWidth)))
                        } else { referenceResizeOrigin = nil }
                        #endif
                    }))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let unit { unitContent(unit, progress: progress, revision: revision).id(unit.id) }
                        notices
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(unitBodyHeight - height) > 0.5 { unitBodyHeight = height }
                    }
                    .frame(maxWidth: columns ? .infinity : 900)
                    .padding(readingPadding).frame(maxWidth: .infinity, alignment: .top)
                }
                #if os(iOS)
                .contentMargins(.bottom, 136, for: .scrollContent)
                #endif
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedQuestionID) { _, focused in
                    if let focused { proxy.scrollTo("answer-\(focused)", anchor: .center) }
                }
                .onChange(of: availableHeight) { _, _ in
                    if let focusedQuestionID { proxy.scrollTo("answer-\(focusedQuestionID)", anchor: .center) }
                }
                .id(unit?.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func referenceColumnWidth(_ availableWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        min(max(260, availableWidth * referenceColumnFraction), availableWidth - 320)
        #else
        min(420, availableWidth * 0.43)
        #endif
    }

    private func continuousContent(edition: CourseEdition, lesson: CourseLesson, progress: CourseProgress,
                                   units: [CourseLearningUnit], sideBySide: Bool = false) -> some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - readingPadding * 2)
            let columns = sideBySide && !dynamicTypeSize.isAccessibilitySize && contentWidth >= 620
            let layout = columns
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                : AnyLayout(VStackLayout(spacing: 0))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                        #if !os(macOS)
                        if !isAnswerEditing { lessonHeading(edition: edition, lesson: lesson) }
                        #endif
                        ForEach(units) { unit in
                            Section {
                                layout {
                                    if columns, let code = source(for: unit) {
                                        CourseProgramReferenceView(code: code, maximumHeight: max(80, geometry.size.height - 60))
                                            .frame(width: referenceColumnWidth(contentWidth - 16))
                                    }
                                    unitContent(unit, progress: progress, revision: edition.revision)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } header: {
                                if !columns, let code = source(for: unit) {
                                    CourseProgramReferenceView(code: code, maximumHeight: sourceHeight(geometry.size.height))
                                        .id(code.source)
                                }
                            }
                        }
                        notices
                    }.frame(maxWidth: columns ? .infinity : 900).padding(readingPadding).frame(maxWidth: .infinity)
                }
                #if os(iOS)
                .contentMargins(.bottom, 136, for: .scrollContent)
                #endif
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedQuestionID) { _, focused in
                    if let focused { proxy.scrollTo("answer-\(focused)", anchor: .center) }
                }
                .onChange(of: geometry.size.height) { _, _ in
                    if let focusedQuestionID { proxy.scrollTo("answer-\(focusedQuestionID)", anchor: .center) }
                }
            }
            .environment(\.courseStudyViewport, geometry.size)
        }
    }

    private func source(for unit: CourseLearningUnit) -> CourseCodeSample? {
        guard let block = unit.blocks.first else { return nil }
        return traceSources[block.id] ?? codeContexts[block.id]
    }

    private func sourceHeight(_ availableHeight: CGFloat) -> CGFloat {
        #if os(iOS)
        // The budget includes the 44-point source toolbar. Keep at least one
        // source line visible without letting a short viewport crowd the answer.
        if isAnswerEditing {
            min(96, max(40, availableHeight * 0.30 - 44))
        } else {
            max(40, availableHeight - min(unitBodyHeight + readingPadding * 2, availableHeight * 0.55) - 56)
        }
        #else
        // This is the code viewport only; its toolbar consumes another 44 pt.
        // Keep a useful answer area when a narrow or short window stacks panes.
        min(220, max(36, availableHeight * 0.32 - 44))
        #endif
    }

    private func sourceHeader(_ code: CourseCodeSample, availableHeight: CGFloat, sideBySide: Bool = false) -> some View {
        CourseProgramReferenceView(code: code, maximumHeight: sideBySide ? max(40, availableHeight - 60) : sourceHeight(availableHeight))
            .id(code.source)
            .frame(maxWidth: 800)
            .padding(.horizontal, readingPadding)
            .padding(.top, sideBySide ? 6 : isAnswerEditing ? 4 : 12)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func unitContent(_ unit: CourseLearningUnit, progress: CourseProgress, revision: Int, fitsViewport: Bool = false) -> some View {
        if let trace = unit.blocks.first?.presentation?.trace {
            if !continuous, !dynamicTypeSize.isAccessibilitySize,
               let index = units.firstIndex(where: { $0.id == unit.id }), index + 1 < units.count {
                CourseTracePresentationView(trace: trace, sourceIsPinned: !fitsViewport, fitsViewport: fitsViewport,
                    onSourceChange: { traceSources[unit.id] = $0 }) { select(units[index + 1].id) }
                    .id("trace-\(revision)-\(unit.id)")
            } else {
                #if os(macOS)
                if !continuous, !dynamicTypeSize.isAccessibilitySize, unit.id == units.last?.id {
                    CourseTracePresentationView(trace: trace, sourceIsPinned: !fitsViewport, fitsViewport: fitsViewport,
                        onSourceChange: { traceSources[unit.id] = $0 }, finalActions: {
                            lessonControls(edition: edition, lesson: lesson, progress: progress, units: units,
                                currentID: unit.id, includesBackControl: false)
                        })
                        .id("trace-\(revision)-\(unit.id)")
                } else {
                    CourseTracePresentationView(trace: trace, sourceIsPinned: !fitsViewport, fitsViewport: fitsViewport,
                        onSourceChange: { traceSources[unit.id] = $0 }).id("trace-\(revision)-\(unit.id)")
                }
                #else
                CourseTracePresentationView(trace: trace, sourceIsPinned: !fitsViewport, fitsViewport: fitsViewport,
                    onSourceChange: { traceSources[unit.id] = $0 }).id("trace-\(revision)-\(unit.id)")
                #endif
            }
        } else if let block = unit.blocks.first, block.type == .question {
            let answer = answersByBlock[block.id]
            CourseQuestionView(courseID: courseID, lessonID: lessonID, revision: revision, block: block, answer: answer, focusedQuestion: $focusedQuestionID,
                sourceIsPinned: source(for: unit) != nil,
                draft: Binding(get: { drafts[block.id] ?? CourseQuestionDraft(answer: answer, block: block) }, set: { drafts[block.id] = $0 }))
                .id("\(revision)-\(block.id)")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if unit.blocks.first?.presentation == nil {
                    Label(unit.title, systemImage: unit.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                }
                ForEach(unit.blocks) { block in
                    CourseContentBlockView(block: block, sourceIsPinned: source(for: unit) != nil).id("\(revision)-\(block.id)")
                }
            }.modifier(CoursePaperPanel(contentPadding: panelPadding))
        }
    }

    @ViewBuilder private var notices: some View {
        if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        if let error = store.courses.error {
            CourseConnectionNotice(message: error) { Task { await store.courses.open(courseID) } }
        }
    }

    private func lessonControls(edition: CourseEdition, lesson: CourseLesson, progress: CourseProgress, units: [CourseLearningUnit],
                                currentID: UUID?, vertical: Bool = false, compact: Bool = false,
                                includesBackControl: Bool = true) -> some View {
        let index = units.firstIndex { $0.id == currentID } ?? 0
        let isContinuous = continuous || dynamicTypeSize.isAccessibilitySize
        let showCompletion = isContinuous || index == units.count - 1
        let finished = progress.completedLessonIDs.contains(lessonID)
        let unanswered = questions.filter { !questionDraft(for: $0, progress: progress).submitted }
        let toSubmit = pendingQuestions(currentID: currentID, progress: progress)
        let canSubmit = toSubmit.allSatisfy { questionDraft(for: $0, progress: progress).hasResponse(for: $0) }
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 9) {
            if !vertical && !compact && !isAnswerEditing && showCompletion && !unanswered.isEmpty {
                Button("还有 \(unanswered.count) 道练习待提交") {
                    if let first = unanswered.first { continuous = false; select(first.id) }
                }.font(.footnote.weight(.medium)).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            layout {
                #if os(macOS)
                if !isContinuous {
                    Text("\(index + 1) / \(units.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                #endif
                #if os(iOS)
                if compact && !vertical && controlSide != CourseLearningControlSide.left.rawValue { Spacer(minLength: 0) }
                #endif
                if (vertical || compact) && !isAnswerEditing && showCompletion && !unanswered.isEmpty {
                    Button {
                        if let first = unanswered.first { continuous = false; select(first.id) }
                    } label: { Label("还有 \(unanswered.count) 道练习待提交", systemImage: "list.bullet") }
                        .modifier(CourseLearningActionStyle(prominent: false))
                }
                if !vertical && includesBackControl { lessonBackControl(index: index, isContinuous: isContinuous) }
                #if os(iOS)
                if !vertical && !compact { Spacer(minLength: 12) }
                #endif
                if !toSubmit.isEmpty {
                    Button {
                        // Checking an answer and turning the page are separate taps:
                        // keep the result visible, including when the keyboard was open.
                        _ = submitAnswers(toSubmit, progress: progress, revision: edition.revision)
                    } label: { Label("继续", systemImage: "arrow.right") }
                    .modifier(CourseLearningActionStyle()).disabled(!canSubmit && !canCommitFocusedAnswer)
                    #if os(macOS)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("提交回答（⌘↩）")
                    #endif
                    .accessibilityLabel("提交当前回答")
                    .accessibilityIdentifier("course-continue-submit")
                    .accessibilityHint("提交当前回答并查看结果，再次点击继续翻页")
                } else if !showCompletion {
                    Button {
                        if continueAfterEditing(currentID: currentID, progress: progress, revision: edition.revision), index + 1 < units.count {
                            select(units[index + 1].id)
                        }
                    }
                    label: { Label("继续", systemImage: "arrow.right") }.modifier(CourseLearningActionStyle())
                        .accessibilityIdentifier("course-continue-next")
                        #if os(macOS)
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        .help("下一学习单元（⌥⌘→）")
                        .background {
                            Button {
                                if continueAfterEditing(currentID: currentID, progress: progress, revision: edition.revision), index + 1 < units.count {
                                    select(units[index + 1].id)
                                }
                            } label: { EmptyView() }
                                .keyboardShortcut(.return, modifiers: .command)
                                .hidden().accessibilityHidden(true)
                        }
                        #endif
                } else if finished {
                    Menu {
                        Button("标为未完成") { markCompleted(false, edition: edition) }
                    } label: { Label("课时完成选项", systemImage: "ellipsis") }
                        .modifier(CourseLearningActionStyle(prominent: false))
                        .accessibilityLabel("课时完成选项")
                    if let nextIndex = edition.course.lessons.firstIndex(where: { $0.id == lessonID }), nextIndex + 1 < edition.course.lessons.count {
                        let next = edition.course.lessons[nextIndex + 1]
                        Button {
                            if continueAfterEditing(currentID: currentID, progress: progress, revision: edition.revision) { nextLessonID = next.id }
                        } label: { Label("下一课", systemImage: "arrow.right") }.modifier(CourseLearningActionStyle())
                        #if os(macOS)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help(WorkspaceLocalization.string("下一课") + "（⌘↩）")
                        #endif
                    } else {
                        Button {
                            if continueAfterEditing(currentID: currentID, progress: progress, revision: edition.revision) { dismiss() }
                        } label: { Label("本课已完成", systemImage: "checkmark") }
                            .modifier(CourseLearningActionStyle())
                            #if os(macOS)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help(WorkspaceLocalization.string("本课已完成") + "（⌘↩）")
                            #endif
                    }
                } else {
                    Button {
                        if continueAfterEditing(currentID: currentID, progress: progress, revision: edition.revision) { markCompleted(true, edition: edition) }
                    } label: { Label("完成本课", systemImage: "checkmark") }
                        .modifier(CourseLearningActionStyle()).disabled(!unanswered.isEmpty)
                        #if os(macOS)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(WorkspaceLocalization.string("完成本课") + "（⌘↩）")
                        #endif
                }
                if vertical && includesBackControl { lessonBackControl(index: index, isContinuous: isContinuous) }
                #if os(iOS)
                if compact && !vertical && controlSide == CourseLearningControlSide.left.rawValue { Spacer(minLength: 0) }
                #endif
            }
            .modifier(CourseLearningGlassGroup())
        }
        .frame(maxWidth: 1_080).padding(.horizontal, vertical ? 6 : isAnswerEditing ? 12 : 20)
        .padding(.vertical, 6).frame(maxWidth: .infinity)
    }

    @ViewBuilder private func lessonBackControl(index: Int, isContinuous: Bool) -> some View {
        if isAnswerEditing {
            Button { focusedQuestionID = nil } label: {
                Label("收起键盘", systemImage: "keyboard.chevron.compact.down")
            }.modifier(CourseLearningActionStyle(prominent: false))
                .accessibilityLabel("收起键盘")
                .accessibilityIdentifier("course-dismiss-keyboard")
        } else if !isContinuous {
            Button {
                if index > 0 { select(units[index - 1].id) }
            } label: { Label("上一学习单元", systemImage: "arrow.left") }
                .modifier(CourseLearningActionStyle(prominent: false))
                .disabled(index == 0)
                .accessibilityLabel("上一学习单元")
                #if os(macOS)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .help("上一学习单元（⌥⌘←）")
                #endif
    }
    }

    private func questionDraft(for block: CourseBlock, progress: CourseProgress) -> CourseQuestionDraft {
        drafts[block.id] ?? CourseQuestionDraft(answer: answersByBlock[block.id], block: block)
    }

    private var canCommitFocusedAnswer: Bool {
        #if os(macOS)
        focusedQuestionID != nil
        #else
        false
        #endif
    }

    private func pendingQuestions(currentID: UUID?, progress: CourseProgress) -> [CourseBlock] {
        let isContinuous = continuous || dynamicTypeSize.isAccessibilitySize
        let currentBlock = units.first { $0.id == currentID }?.blocks.first
        let currentQuestionID = currentBlock?.type == .question ? currentBlock?.id : nil
        let showCompletion = isContinuous || currentID == units.last?.id
        return questions.filter { question in
            let value = questionDraft(for: question, progress: progress)
            guard !value.submitted else { return false }
            if !isContinuous, currentQuestionID == question.id { return true }
            if isContinuous, let focusedQuestionID { return question.id == focusedQuestionID }
            return showCompletion && drafts[question.id] != nil && value.hasResponse(for: question)
        }
    }

    /// An IME can still own uncommitted characters when the button or shortcut
    /// fires. Commit synchronously, then decide from the latest answer binding.
    private func continueAfterEditing(currentID: UUID?, progress: CourseProgress, revision: Int) -> Bool {
        #if os(macOS)
        CourseAnswerEditor.commitCurrentEditing()
        #endif
        let pending = pendingQuestions(currentID: currentID, progress: progress)
        guard !pending.isEmpty else { return true }
        _ = submitAnswers(pending, progress: progress, revision: revision)
        return false
    }

    private func submitAnswers(_ questions: [CourseBlock], progress: CourseProgress, revision: Int) -> Bool {
        #if os(macOS)
        CourseAnswerEditor.commitCurrentEditing()
        #endif
        do {
            // Validate all visible edits before writing any of them. Save through
            // the local-first service before allowing navigation to continue.
            let prepared = try questions.map { question in
                (question.id, try questionDraft(for: question, progress: progress).submission(for: question, revision: revision, lessonID: lessonID))
            }
            for (id, update) in prepared {
                try store.courses.submit(courseID: courseID, update: update)
                if let question = questions.first(where: { $0.id == id }) {
                    var value = questionDraft(for: question, progress: progress)
                    value.submitted = true; value.notice = nil
                    drafts[id] = value
                }
            }
            focusedQuestionID = nil
            notice = nil; store.feedbackSequence += 1
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
    private func select(_ id: UUID) {
        #if os(macOS)
        CourseAnswerEditor.commitCurrentEditing()
        #endif
        focusedQuestionID = nil
        #if os(macOS)
        showsCompactDirectory = false
        #endif
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            traceSources.removeValue(forKey: id)
            activeUnitID = id
        }
    }
    private func markCompleted(_ completed: Bool, edition: CourseEdition) {
        do {
            try store.courses.submit(courseID: courseID, update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lessonID, completed: completed))
            notice = nil; store.feedbackSequence += 1
        } catch { notice = error.localizedDescription }
    }
}

enum CourseLearningControlSide: String, CaseIterable, Identifiable {
    case left, right
    static let preferenceKey = "courseLearningControlSide"
    var id: String { rawValue }
    var alignment: Alignment { self == .left ? .bottomLeading : .bottomTrailing }
    var title: String { WorkspaceLocalization.string(self == .left ? "左下角" : "右下角") }
}

/// Keeps the editor/source identities stable while the reader changes between
/// stacked and side-by-side layouts. Dragging changes only their width budget.
private struct CourseReferenceResizeHandle: ViewModifier {
    var enabled: Bool
    let resize: (CGFloat?) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay(alignment: .trailing) {
            if enabled {
                Rectangle().fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                    .padding(.horizontal, 5)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { resize($0.translation.width) }
                        .onEnded { _ in resize(nil) })
                    .onHover { hovering in (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                    .accessibilityLabel(WorkspaceLocalization.string("调整程序与内容的宽度"))
                    .accessibilityAdjustableAction { direction in
                        resize(direction == .increment ? 24 : -24)
                        resize(nil)
                    }
                    .help(WorkspaceLocalization.string("拖动以调整程序与内容的宽度"))
            }
        }
        #else
        content
        #endif
    }
}

/// One compact action surface is shared by reading, questions and trace controls.
struct CourseLearningActionStyle: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var prominent = true

    private var diameter: CGFloat {
        #if os(iOS)
        52
        #else
        prominent ? 52 : 44
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let control = content
            .labelStyle(.iconOnly)
            .font(.system(size: diameter == 52 ? 22 : 18, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .foregroundStyle(prominent ? Color.white : palette.accent)
            .contentShape(Circle())
            .buttonStyle(.plain)
        if #available(iOS 26, macOS 26, *) {
            control
                .glassEffect(prominent ? .regular.tint(palette.action).interactive() : .regular.interactive(), in: .circle)
                .opacity(isEnabled ? 1 : 0.4)
        } else {
            control
                .background(prominent ? palette.action : palette.surface, in: Circle())
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

struct CourseLearningGlassGroup: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

private struct CourseQuickStartView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var state = LoadingState.loading
    @State private var retry = 0

    private enum LoadingState {
        case loading, lesson(CourseLearningTarget), completed, failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("正在接续学习…")
            case .lesson(let target):
                CourseLessonView(courseID: target.courseID, lessonID: target.lessonID)
                    .id("\(target.courseID)-\(target.lessonID)-\(target.revision)")
            case .completed:
                ContentUnavailableView("课程已全部完成", systemImage: "checkmark.circle",
                    description: Text("可以返回课程列表，选择课时复习。"))
            case .failed(let message):
                ContentUnavailableView {
                    Label("暂时无法继续学习", systemImage: "book.closed")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { retry += 1 }
                }
            }
        }
        .navigationTitle("学习").workspaceInlineTitle()
        .task(id: retry) {
            state = .loading
            do {
                let target = try await store.courses.quickStart()
                try Task.checkCancellation()
                state = target.map { .lesson($0) } ?? .completed
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct CourseConnectionNotice: View {
    let message: String
    var retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
            Button("重试", action: retry).font(.footnote.weight(.semibold))
        }.padding(.vertical, 6)
    }
}


private struct CourseContentBlockView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.courseStudyViewport) private var studyViewport
    @State private var selectedLabel: String?
    let block: CourseBlock
    var sourceIsPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let presentation = block.presentation {
                if sourceIsPinned && presentation.kind == .code {
                    if let title = block.title { Text(title).font(.headline) }
                    CourseMarkdownView(source: block.text ?? "")
                } else {
                    CourseStructuredContentView(presentation: presentation, title: block.title)
                }
                if presentation.kind == .html || presentation.kind == .svg {
                    DisclosureGroup("文字说明") {
                        CourseMarkdownView(source: block.text ?? "")
                    }.font(.subheadline)
                }
            } else {
                switch block.type {
                case .text:
                    Text(.init(block.text ?? "")).font(.title3).lineSpacing(8)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .callout:
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lightbulb.fill").font(.body).foregroundStyle(palette.accent).padding(.top, 3)
                        Text(.init(block.text ?? "")).font(.body.weight(.medium)).lineSpacing(5)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
                case .image:
                    CourseRemoteImage(url: block.url ?? "", alternativeText: block.caption ?? WorkspaceLocalization.string("课程图片"))
                case .chart:
                    if let points = block.points { chart(points) }
                case .question: EmptyView()
                }
                if let caption = block.caption, !caption.isEmpty {
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ points: [CourseChartPoint]) -> some View {
        let entries = CoursePresentationEntry.make(points) { "\($0.label):\($0.value)" }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedLabel ?? WorkspaceLocalization.string("选择一项，看看数值")).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let point = points.first(where: { $0.label == selectedLabel }) {
                    Text(point.value, format: .number.precision(.fractionLength(0...3)))
                        .font(.title.weight(.bold).monospacedDigit()).foregroundStyle(palette.accent)
                }
            }.frame(minHeight: 36)
            Chart(entries) { entry in
                let point = entry.value
                if block.chartType == .line {
                    LineMark(x: .value(WorkspaceLocalization.string("项目"), point.label), y: .value(WorkspaceLocalization.string("数值"), point.value))
                        .foregroundStyle(palette.accent).lineStyle(StrokeStyle(lineWidth: 3))
                    PointMark(x: .value(WorkspaceLocalization.string("项目"), point.label), y: .value(WorkspaceLocalization.string("数值"), point.value))
                        .foregroundStyle(palette.accent).symbolSize(selectedLabel == point.label ? 90 : 35)
                } else {
                    BarMark(x: .value(WorkspaceLocalization.string("项目"), point.label), y: .value(WorkspaceLocalization.string("数值"), point.value))
                        .foregroundStyle(palette.accent.opacity(selectedLabel == nil || selectedLabel == point.label ? 0.9 : 0.3))
                        .cornerRadius(5)
                }
            }
            .chartScrollableAxes(points.count > 8 ? .horizontal : [])
            .chartXVisibleDomain(length: max(1, min(points.count, 8)))
            .chartXSelection(value: $selectedLabel)
            .frame(height: studyViewport.height > 0 ? min(340, max(160, studyViewport.height * 0.44)) : 220)
            .accessibilityLabel(block.caption ?? WorkspaceLocalization.string("课程图表"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        Button { selectedLabel = entry.value.label } label: {
                            Text(entry.value.label).font(.subheadline.weight(.medium)).padding(.horizontal, 13).frame(minHeight: 44)
                                .foregroundStyle(selectedLabel == entry.value.label ? Color.white : palette.accent)
                                .background(selectedLabel == entry.value.label ? palette.action : palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityAddTraits(selectedLabel == entry.value.label ? .isSelected : [])
                    }
                }
            }
        }.workspaceSelectionFeedback(trigger: selectedLabel)
    }
}

private struct CourseQuestionDraft: Equatable {
    var selected: Set<String>
    var response: String
    var submitted: Bool
    var notice: String?
    var explanationExpanded = false
    var revealedHintCount = 0
    var runResult: CourseCodeRunResult?

    init(answer: CourseAnswer?, block: CourseBlock? = nil) {
        selected = Set(answer?.selectedOptionIDs ?? [])
        response = answer?.text ?? block?.resolvedInput.starterCode ?? ""
        submitted = answer != nil
    }
    func hasResponse(for block: CourseBlock) -> Bool {
        block.questionType == .shortAnswer ? !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !selected.isEmpty
    }
    func submission(for block: CourseBlock, revision: Int, lessonID: UUID) throws -> CourseProgressUpdate {
        let choices = block.questionType == .shortAnswer ? [] : selected.sorted()
        let text = block.questionType == .shortAnswer ? response : ""
        try CourseValidation.validateAnswer(block: block, selected: choices, text: text)
        return CourseProgressUpdate(courseRevision: revision, lessonID: lessonID, blockID: block.id,
            selectedOptionIDs: block.questionType == .shortAnswer ? nil : choices,
            text: block.questionType == .shortAnswer ? text : nil)
    }
}

private struct CourseQuestionView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.courseStudyViewport) private var studyViewport
    let focusedQuestion: Binding<UUID?>
    private var responseFocused: Bool { focusedQuestion.wrappedValue == block.id }
    private var compactInput: Bool {
        #if os(iOS)
        responseFocused
        #else
        false
        #endif
    }
    private var contentPadding: CGFloat {
        #if os(iOS)
        compactInput ? 16 : 18
        #else
        22
        #endif
    }
    private var contentSpacing: CGFloat {
        #if os(iOS)
        compactInput ? 12 : 16
        #else
        20
        #endif
    }
    let courseID: UUID
    let lessonID: UUID
    let revision: Int
    let block: CourseBlock
    private let sourceIsPinned: Bool
    private let externalDraft: Binding<CourseQuestionDraft>?
    @State private var localDraft: CourseQuestionDraft
    @State private var runTask: Task<Void, Never>?
    @State private var running = false
    @State private var standardInput = ""
    @State private var initializedInput = false
    @State private var localRunner = CourseJavaScriptRunner()

    init(courseID: UUID, lessonID: UUID, revision: Int, block: CourseBlock,
         answer: CourseAnswer?, focusedQuestion: Binding<UUID?>,
         sourceIsPinned: Bool = false,
         draft: Binding<CourseQuestionDraft>? = nil) {
        self.courseID = courseID
        self.lessonID = lessonID
        self.revision = revision
        self.block = block
        self.sourceIsPinned = sourceIsPinned
        self.focusedQuestion = focusedQuestion
        externalDraft = draft
        _localDraft = State(initialValue: CourseQuestionDraft(answer: answer, block: block))
    }

    private var draft: Binding<CourseQuestionDraft> { externalDraft ?? $localDraft }
    private var value: CourseQuestionDraft { draft.wrappedValue }
    private var isShortAnswer: Bool { block.questionType == .shortAnswer }
    private var isLiteralAnswer: Bool { block.resolvedInput.kind == .code || block.answerFormat == .output }
    private var hints: [String] {
        (block.hints ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var answerPlaceholder: String {
        block.answerFormat == .code ? WorkspaceLocalization.string("在这里写下代码…") : block.answerFormat == .output ? WorkspaceLocalization.string("写下程序的输出…") : WorkspaceLocalization.string("写下你的想法…")
    }
    private var hasResponse: Bool {
        value.hasResponse(for: block)
    }
    private var canRunAnswer: Bool {
        #if os(macOS)
        hasResponse || responseFocused
        #else
        hasResponse
        #endif
    }
    private var kindTitle: String {
        if isShortAnswer {
            return block.resolvedInput.kind == .code ? WorkspaceLocalization.string("代码练习") : block.answerFormat == .output ? WorkspaceLocalization.string("预测输出") : WorkspaceLocalization.string("想一想")
        }
        return block.questionType == .multipleChoice ? WorkspaceLocalization.string("多选") : WorkspaceLocalization.string("单选")
    }
    private var answerText: Binding<String> {
        Binding(get: { value.response }, set: { text in
            // Ending text entry can write the identical value again. It must not
            // turn the answer just submitted by Continue back into a dirty draft.
            guard text != value.response else { return }
            runTask?.cancel(); runTask = nil; running = false
            updateDraft {
                $0.runResult = nil
                $0.response = text
                $0.submitted = false
                $0.notice = nil
                $0.explanationExpanded = false
            }
        })
    }
    private var explanationExpanded: Binding<Bool> {
        Binding(get: { value.explanationExpanded }, set: { expanded in
            updateDraft { $0.explanationExpanded = expanded }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            if !compactInput {
                HStack(spacing: 8) {
                    Image(systemName: isShortAnswer ? "pencil.tip" : "checklist")
                        .font(.subheadline.weight(.semibold))
                    Text(kindTitle).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if value.submitted {
                        Text("已作答").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(palette.accent)
            }

            Text(block.text ?? "")
                .font(.title3.weight(.semibold))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if !sourceIsPinned, let code = block.code { CourseCodeSampleView(code: code) }

            if isShortAnswer {
                CourseAnswerEditor(text: answerText, input: block.resolvedInput, limit: block.answerTextLimit,
                    isFocused: Binding(get: { responseFocused }, set: { focused in
                        if focused { focusedQuestion.wrappedValue = block.id }
                        else if responseFocused { focusedQuestion.wrappedValue = nil }
                    }), hapticsEnabled: store.hapticsEnabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("answer-\(block.id)")
            } else {
                VStack(spacing: 10) {
                    ForEach(Array((block.options ?? []).enumerated()), id: \.element.id) { index, option in
                        optionButton(option, index: index)
                    }
                }
            }

            if block.execution != nil { executionPanel }
            if !hints.isEmpty { hintsPanel }
            if value.submitted { resultPanel }

            if let notice = value.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .background(alignment: .bottomTrailing) {
            CourseJavaScriptRunHost(runner: localRunner).frame(width: 2, height: 2)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .workspaceSelectionFeedback(trigger: value.selected)
        .workspaceSelectionFeedback(trigger: value.submitted)
        .onAppear {
            if !initializedInput { standardInput = block.execution?.stdin ?? ""; initializedInput = true }
        }
        .onDisappear { runTask?.cancel(); runTask = nil; running = false }
        .onChange(of: value.submitted) { _, submitted in
            if submitted && responseFocused { focusedQuestion.wrappedValue = nil }
            if submitted, block.execution != nil { runAnswer() }
        }
    }

    private var executionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("程序输入") {
                TextEditor(text: $standardInput)
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(height: standardInputHeight).scrollContentBackground(.hidden)
                    .onChange(of: standardInput) { _, text in
                        if text.utf16.count > 4_000 { standardInput = String(text.prefix(4_000)) }
                    }
            }.font(.subheadline)
            HStack(spacing: 12) {
                Button {
                    if running { runTask?.cancel(); runTask = nil; running = false }
                    else { runAnswer() }
                } label: {
                    Label(running ? WorkspaceLocalization.string("停止运行") : WorkspaceLocalization.string("运行代码"), systemImage: running ? "stop.fill" : "play.fill")
                }.buttonStyle(.bordered).disabled(!running && !canRunAnswer)
                    .accessibilityIdentifier("course-run-answer")
                if running { ProgressView().controlSize(.small); Text("正在运行…").font(.footnote).foregroundStyle(.secondary) }
            }
            if let result = value.runResult {
                VStack(alignment: .leading, spacing: 8) {
                    Label(runTitle(result), systemImage: result.status == "completed" ? (result.passed == false ? "xmark.circle" : "checkmark.circle") : "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(result.passed == true ? palette.confirmation : palette.accent)
                    if !result.stdout.isEmpty {
                        Text(result.stdout).font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !result.stderr.isEmpty {
                        Text(result.stderr).font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if result.status == "completed" { Text("\(result.durationMs) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("course-run-result")
            }
        }
    }
    private var standardInputHeight: CGFloat {
        let lines = standardInput.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let limit = studyViewport.height > 0 ? min(180, max(56, studyViewport.height * 0.3)) : 180
        return min(limit, max(56, CGFloat(lines) * 21 + 20))
    }
    private func runTitle(_ result: CourseCodeRunResult) -> String {
        switch result.status {
        case "completed": result.passed == true ? WorkspaceLocalization.string("测试通过") : result.passed == false ? WorkspaceLocalization.string("输出与预期不同") : WorkspaceLocalization.string("运行完成")
        case "timeout": WorkspaceLocalization.string("运行超时")
        case "compileError": WorkspaceLocalization.string("编译未通过")
        case "outputLimit": WorkspaceLocalization.string("输出过多，已停止")
        case "unavailable": WorkspaceLocalization.string("运行环境暂不可用")
        case "cancelled": WorkspaceLocalization.string("已停止")
        default: WorkspaceLocalization.string("运行出错")
        }
    }
    private func runAnswer() {
        guard let configuration = block.execution, !running else { return }
        #if os(macOS)
        CourseAnswerEditor.commitCurrentEditing()
        #endif
        do { try CourseValidation.validateAnswer(block: block, selected: [], text: value.response) }
        catch { updateDraft { $0.notice = error.localizedDescription }; return }
        focusedQuestion.wrappedValue = nil
        let text = value.response, input = standardInput, scope = store.courses.scope
        running = true
        updateDraft { $0.runResult = nil; $0.notice = nil }
        runTask = Task { @MainActor in
            defer { if !Task.isCancelled { running = false; runTask = nil } }
            do {
                let result: CourseCodeRunResult
                if configuration.language == "javascript" {
                    var local = configuration
                    if input != (configuration.stdin ?? "") { local.expectedOutput = nil }
                    result = await localRunner.run(answer: text, configuration: local, stdin: input)
                } else if store.isDemoMode {
                    result = CourseCodeRunResult(status: "unavailable", stdout: "", stderr: WorkspaceLocalization.string("演示模式可在本机运行 JavaScript；Python 和 C++ 请登录后使用。"), durationMs: 0)
                } else {
                    result = try await store.backend.runCourseAnswer(courseID, revision: revision,
                        lessonID: lessonID, blockID: block.id, text: text,
                        stdin: input == (configuration.stdin ?? "") ? nil : input)
                }
                guard !Task.isCancelled, scope == store.courses.scope, text == value.response else { return }
                updateDraft { $0.runResult = result }
            } catch {
                guard !Task.isCancelled, scope == store.courses.scope else { return }
                updateDraft { $0.runResult = CourseCodeRunResult(status: "runtimeError", stdout: "", stderr: error.localizedDescription, durationMs: 0) }
            }
        }
    }

    private func optionButton(_ option: CourseOption, index: Int) -> some View {
        let selected = value.selected.contains(option.id)
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let letter = index < letters.count ? String(letters[index]) : String(index + 1)
        return Button { choose(option.id) } label: {
            HStack(alignment: .top, spacing: 13) {
                Text(letter)
                    .font(.subheadline.weight(.bold).monospaced())
                    .foregroundStyle(selected ? Color.white : palette.accent)
                    .frame(minWidth: 32, minHeight: 32)
                    .background(selected ? palette.action : palette.surface,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(option.text)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(selected ? palette.accent : Color.primary.opacity(0.18))
                    .padding(.top, 7)
                    .accessibilityHidden(true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.surface.opacity(0.65) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(selected ? palette.accent.opacity(0.6) : Color.primary.opacity(0.075), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选项 \(letter)，\(option.text)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
    }

    private var hintsPanel: some View {
        let revealed = min(value.revealedHintCount, hints.count)
        return VStack(alignment: .leading, spacing: 12) {
            if revealed > 0 {
                ForEach(0..<revealed, id: \.self) { index in
                    HStack(alignment: .top, spacing: 11) {
                        Text(String(index + 1))
                            .font(.caption.weight(.bold).monospaced())
                            .foregroundStyle(palette.accent)
                            .frame(minWidth: 23, minHeight: 23)
                            .background(palette.surface, in: Circle())
                            .accessibilityHidden(true)
                        Text(hints[index])
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("提示 \(index + 1)，\(hints[index])")
                    }
                }
            }
            if revealed < hints.count {
                Button {
                    updateDraft { $0.revealedHintCount = min(hints.count, $0.revealedHintCount + 1) }
                } label: {
                    Label(revealed == 0 ? WorkspaceLocalization.string("给点提示") : WorkspaceLocalization.string("下一条提示"), systemImage: "lightbulb")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("逐条展开提示，保持当前回答")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: revealed)
        .workspaceSelectionFeedback(trigger: value.revealedHintCount)
    }

    private var resultPanel: some View {
        let result = block.execution == nil ? block.evaluate(selectedOptionIDs: value.selected, text: value.response) : value.runResult?.passed
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: result == true ? "checkmark.circle.fill" : result == false ? "arrow.clockwise" : "checkmark.circle")
                    .font(.title3.weight(.medium))
                VStack(alignment: .leading, spacing: 4) {
                    Text(result == true ? WorkspaceLocalization.string("回答正确") : result == false ? WorkspaceLocalization.string("再想一想") : WorkspaceLocalization.string("回答已保存"))
                        .font(.subheadline.weight(.semibold))
                    if result == false {
                        Text(isShortAnswer ? WorkspaceLocalization.string("回答已保存，可以修改后再试。") : WorkspaceLocalization.string("回答已保存，可以调整选项后再试。"))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(result == true ? palette.confirmation : palette.accent)

            if let explanation = block.explanation,
               !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup(isExpanded: explanationExpanded) {
                    Text(explanation)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } label: {
                    Text("查看解析").font(.subheadline.weight(.medium))
                }
                .tint(palette.accent)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateDraft(_ change: (inout CourseQuestionDraft) -> Void) {
        var next = draft.wrappedValue
        change(&next)
        draft.wrappedValue = next
    }
    private func choose(_ id: String) {
        updateDraft {
            if block.questionType == .singleChoice { $0.selected = [id] }
            else if $0.selected.contains(id) { $0.selected.remove(id) }
            else { $0.selected.insert(id) }
            $0.submitted = false
            $0.notice = nil
            $0.explanationExpanded = false
        }
    }
}

private struct CourseStructuredContentView: View {
    @Environment(\.workspacePalette) private var palette
    let presentation: CoursePresentation
    var title: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch presentation.kind {
            case .code:
                VStack(alignment: .leading, spacing: 20) {
                    Label(title ?? WorkspaceLocalization.string("代码示例"), systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.subheadline.weight(.bold)).foregroundStyle(palette.accent)
                    if let code = presentation.code { CourseCodeSampleView(code: code) }
                }
            case .table:
                if let table = presentation.table { CourseTablePresentationView(table: table, title: title) }
            case .trace:
                if let trace = presentation.trace { CourseTracePresentationView(trace: trace) }
            case .steps:
                if let steps = presentation.steps { CourseStepsPresentationView(steps: steps, title: title) }
            case .comparison:
                if let items = presentation.items { CourseComparisonPresentationView(items: items, title: title) }
            case .flashcards:
                if let cards = presentation.cards { CourseFlashcardsPresentationView(cards: cards, title: title) }
            case .markdown:
                if let markdown = presentation.markdown {
                    VStack(alignment: .leading, spacing: 16) {
                        if let title { Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader) }
                        CourseMarkdownView(source: markdown.source)
                    }
                }
            case .html:
                if let html = presentation.html { CourseWebPresentationView(content: html, isSVG: false, title: title) }
            case .svg:
                if let svg = presentation.svg { CourseWebPresentationView(content: svg, isSVG: true, title: title) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// These entries belong to one immutable published block. Content-derived identities
/// plus a duplicate ordinal stay deterministic across local presentation changes.
/// The enclosing lesson already changes identity when the course revision changes.
private struct CoursePresentationEntry<Value>: Identifiable {
    let id: String
    let ordinal: Int
    let value: Value

    static func make(_ values: [Value], key: (Value) -> String) -> [Self] {
        var occurrences: [String: Int] = [:]
        return values.enumerated().map { ordinal, value in
            let content = key(value)
            let occurrence = occurrences[content, default: 0]
            occurrences[content] = occurrence + 1
            return Self(id: "\(content.utf16.count):\(content):\(occurrence)", ordinal: ordinal, value: value)
        }
    }
}

private struct CoursePresentationLabel: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.accent)
            Spacer(minLength: 6)
            Text(detail).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

private struct CourseCodeSampleView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let code: CourseCodeSample
    private let lines: [CourseSourceLine]
    @State private var selectedAnnotationLine: Int?
    @State private var showsReference = false
    @State private var copySequence = 0
    @State private var sourcePage = 0
    private let linesPerPage = 24

    init(code: CourseCodeSample) {
        self.code = code
        let highlights = Set(code.highlightLines ?? [])
        let spans = Dictionary(grouping: code.highlightSpans ?? [], by: \.line)
        let annotations = Dictionary((code.annotations ?? []).map { ($0.line, $0.text) }, uniquingKeysWith: { first, _ in first })
        let normalized = code.source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, source in
            CourseSourceLine(number: offset + 1, source: String(source), highlighted: highlights.contains(offset + 1),
                annotation: annotations[offset + 1], spans: spans[offset + 1] ?? [])
        }
        let firstFocus = code.highlightSpans?.first?.line ?? code.highlightLines?.first ?? 1
        _sourcePage = State(initialValue: min(max(0, (firstFocus - 1) / 24), max(0, (lines.count - 1) / 24)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    sourceTitle
                    Spacer(minLength: 8)
                    copyButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    sourceTitle
                    copyButton
                }
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.dropFirst(sourcePage * linesPerPage).prefix(linesPerPage))) { line in
                        CourseSourceLineView(line: line, isSelected: selectedAnnotationLine == line.number,
                            joinsPrevious: line.number > sourcePage * linesPerPage + 1 && isEmphasized(line.number - 1),
                            joinsNext: line.number < min(lines.count, (sourcePage + 1) * linesPerPage) && isEmphasized(line.number + 1)) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                selectedAnnotationLine = selectedAnnotationLine == line.number ? nil : line.number
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6).padding(.vertical, 10)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 15))
            .accessibilityLabel("\(code.language) 源码")
            if lines.count > linesPerPage {
                HStack(spacing: 12) {
                    Button("上一段", systemImage: "arrow.left") { sourcePage -= 1; selectedAnnotationLine = nil }
                        .disabled(sourcePage == 0)
                    Spacer(minLength: 0)
                    Text("\(sourcePage * linesPerPage + 1)–\(min(lines.count, (sourcePage + 1) * linesPerPage)) / \(lines.count) 行")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("下一段", systemImage: "arrow.right") { sourcePage += 1; selectedAnnotationLine = nil }
                        .disabled((sourcePage + 1) * linesPerPage >= lines.count)
                }.font(.subheadline).buttonStyle(.borderless).frame(minHeight: 44).tint(palette.accent)
            }
            if let number = selectedAnnotationLine,
               let line = lines.first(where: { $0.number == number }), let annotation = line.annotation {
                HStack(alignment: .top, spacing: 10) {
                    Text("L\(number)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Text(verbatim: annotation)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
            } else if !(code.annotations ?? []).isEmpty {
                Label("点行号，查看注解", systemImage: "text.bubble")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if code.stdin != nil || code.expectedOutput != nil {
                DisclosureGroup(isExpanded: $showsReference) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let input = code.stdin { CourseLiteralReferenceView(title: WorkspaceLocalization.string("输入"), text: input) }
                        if let output = code.expectedOutput { CourseLiteralReferenceView(title: WorkspaceLocalization.string("预期输出"), text: output) }
                        Text("作者提供的教学参考")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } label: {
                    Label("输入与输出", systemImage: "terminal")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(palette.accent)
            }
        }
        .workspaceSelectionFeedback(trigger: selectedAnnotationLine)
        .workspaceSelectionFeedback(trigger: showsReference)
        .workspaceSelectionFeedback(trigger: copySequence)
        .workspaceSelectionFeedback(trigger: sourcePage)
    }

    private func isEmphasized(_ number: Int) -> Bool {
        guard lines.indices.contains(number - 1) else { return false }
        return lines[number - 1].highlighted || selectedAnnotationLine == number
    }

    private var sourceTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: code.filename ?? code.language.uppercased())
                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if code.filename != nil {
                Text(verbatim: code.language.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private var copyButton: some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.setItems([["public.utf8-plain-text": code.source]], options: [.localOnly: true])
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.source, forType: .string)
            #endif
            copySequence += 1
        } label: {
            Label(copySequence == 0 ? WorkspaceLocalization.string("复制") : WorkspaceLocalization.string("已复制"), systemImage: copySequence == 0 ? "doc.on.doc" : "checkmark")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .foregroundStyle(palette.accent)
                .background(palette.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制完整源码")
    }
}

private struct CourseSourceLine: Identifiable {
    var id: Int { number }
    let number: Int
    let source: String
    let highlighted: Bool
    let annotation: String?
    let spans: [CourseCodeSpan]
}

private struct CourseSourceLineView: View {
    @Environment(\.workspacePalette) private var palette
    @ScaledMetric(relativeTo: .body) private var gutterWidth = 46.0
    let line: CourseSourceLine
    let isSelected: Bool
    let joinsPrevious: Bool
    let joinsNext: Bool
    let select: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if line.annotation != nil {
                    Button(action: select) {
                        HStack(spacing: 3) {
                            Circle().fill(palette.accent).frame(width: 4, height: 4)
                            Text(line.number, format: .number.grouping(.never))
                        }
                        .frame(width: gutterWidth, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                    .accessibilityLabel("第 \(line.number) 行注解")
                    .accessibilityValue(isSelected ? WorkspaceLocalization.string("已展开") : WorkspaceLocalization.string("已收起"))
                } else {
                    Text(line.number, format: .number.grouping(.never))
                        .frame(width: gutterWidth, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(.caption, design: .monospaced, weight: .medium))
            CourseMarkedCodeText(source: line.source, lineNumber: line.number, spans: line.spans)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel("第 \(line.number) 行，\(line.source)")
        }
        .padding(.vertical, 4)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CourseCodeLineHighlight(isHighlighted: line.highlighted || isSelected,
                joinsPrevious: joinsPrevious, joinsNext: joinsNext)
        }
    }
}

private struct CourseLiteralReferenceView: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(verbatim: text.isEmpty ? WorkspaceLocalization.string("（空文本）") : text)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct CourseTablePresentationView: View {
    @Environment(\.workspacePalette) private var palette
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth = 96.0
    @State private var viewportWidth: CGFloat = 0
    private let columns: [CoursePresentationEntry<String>]
    private let rows: [CoursePresentationEntry<[String]>]

    private let title: String

    init(table: CourseTableContent, title: String? = nil) {
        self.title = title ?? WorkspaceLocalization.string("表格")
        columns = CoursePresentationEntry.make(table.columns) { $0 }
        rows = CoursePresentationEntry.make(table.rows) { row in
            row.map { "\($0.utf16.count):\($0)" }.joined()
        }
    }

    var body: some View {
        let count = max(columns.count, 1)
        let cellWidth = max(minimumColumnWidth, viewportWidth / CGFloat(count))
        let tableWidth = cellWidth * CGFloat(count)
        VStack(alignment: .leading, spacing: 12) {
            CoursePresentationLabel(title: title, symbol: "tablecells", detail: WorkspaceLocalization.format("%lld 行 · %lld 列", rows.count, columns.count))
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(columns) { column in
                            tableCell(column.value, header: true, width: cellWidth)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    .background(Rectangle().fill(palette.surface))
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(columns) { column in
                                let value = row.value.count > column.ordinal ? row.value[column.ordinal] : ""
                                tableCell(value, header: false, width: cellWidth)
                                    .accessibilityLabel("\(column.value)：\(value)")
                            }
                        }
                        .background(Rectangle().fill(row.ordinal.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear))
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                        }
                    }
                }
                .frame(width: tableWidth, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .defaultScrollAnchor(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            if viewportWidth > 0 && tableWidth > viewportWidth + 1 {
                Label("左右滑动查看完整表格", systemImage: "arrow.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tableCell(_ text: String, header: Bool, width: CGFloat) -> some View {
        Text(verbatim: text)
            .font(header ? .body.weight(.semibold) : .body)
            .foregroundStyle(header ? palette.accent : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(width: width, alignment: .topLeading)
            .textSelection(.enabled)
    }

}

#Preview("课程表格 · 三列") {
    ScrollView {
        CourseTablePresentationView(table: CourseTableContent(columns: ["类型", "例子", "用途"], rows: [
            ["整数", "18、-3", "人数、次数"],
            ["浮点数", "3.5、0.1", "带小数的值；并非所有小数都能精确表示。"],
            ["字符串", "\"18\"、\"你好\"", "文本；注意引号与数字类型的区别。"],
            ["布尔值", "True、False", "表达条件是否成立"]
        ]), title: "四种常见值")
        .modifier(CoursePaperPanel()).padding(20)
    }
}

#Preview("课程表格 · 宽表与长文本") {
    ScrollView {
        CourseTablePresentationView(table: CourseTableContent(columns: ["阶段", "输入", "操作", "输出", "说明"], rows: [
            ["初始化", "count = 0", "建立变量", "0", "保留原始大小写与代码符号"],
            ["更新", "count", "count += 1", "1", "这一行有较长的文字，用于检查换行和同一行各列的对齐。"]
        ]))
        .modifier(CoursePaperPanel()).padding(20)
    }
}

private struct CourseStepsPresentationView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let entries: [CoursePresentationEntry<CourseTeachingItem>]
    @State private var selectedID: String?

    private let title: String

    init(steps: [CourseTeachingItem], title: String? = nil) {
        self.title = title ?? WorkspaceLocalization.string("分步理解")
        entries = CoursePresentationEntry.make(steps) { "\($0.title.utf16.count):\($0.title)\($0.text)\($0.code?.source ?? "")" }
    }

    private var current: CoursePresentationEntry<CourseTeachingItem>? {
        entries.first(where: { $0.id == selectedID }) ?? entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CoursePresentationLabel(title: title, symbol: "point.3.connected.trianglepath.dotted", detail: "\((current?.ordinal ?? 0) + 1) / \(entries.count)")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        Button { select(entry) } label: {
                            Text(entry.ordinal + 1, format: .number.grouping(.never))
                                .font(.subheadline.weight(.bold))
                                .frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(current?.id == entry.id ? Color.white : palette.accent)
                                .background(current?.id == entry.id ? palette.action : palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(entry.ordinal + 1) 步，\(entry.value.title)")
                        .accessibilityAddTraits(current?.id == entry.id ? .isSelected : [])
                    }
                }
            }
            if let current {
                CourseTeachingItemView(item: current.value)
                    .id(current.id)
                    .transition(.opacity)
                CoursePresentationNavigation(
                    previousTitle: WorkspaceLocalization.string("上一步"), nextTitle: WorkspaceLocalization.string("下一步"),
                    previousEnabled: current.ordinal > 0,
                    nextEnabled: current.ordinal < entries.count - 1,
                    previous: { move(-1) }, next: { move(1) })
            }
        }
        .workspaceSelectionFeedback(trigger: selectedID)
    }

    private func select(_ entry: CoursePresentationEntry<CourseTeachingItem>) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selectedID = entry.id }
    }

    private func move(_ direction: Int) {
        guard let current, let entry = entries.first(where: { $0.ordinal == current.ordinal + direction }) else { return }
        select(entry)
    }
}

private struct CourseTeachingItemView: View {
    let item: CourseTeachingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: item.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: item.text).font(.body).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let code = item.code { CourseCodeSampleView(code: code) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CourseComparisonPresentationView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let entries: [CoursePresentationEntry<CourseTeachingItem>]
    @State private var selectedID: String?

    private let title: String

    init(items: [CourseTeachingItem], title: String? = nil) {
        self.title = title ?? WorkspaceLocalization.string("对照")
        entries = CoursePresentationEntry.make(items) { "\($0.title.utf16.count):\($0.title)\($0.text)\($0.code?.source ?? "")" }
    }

    private var current: CoursePresentationEntry<CourseTeachingItem>? {
        entries.first(where: { $0.id == selectedID }) ?? entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CoursePresentationLabel(title: title, symbol: "rectangle.split.2x1", detail: WorkspaceLocalization.format("%lld 种思路", entries.count))
            if dynamicTypeSize.isAccessibilitySize { compactComparison }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(entries) { entry in
                            CourseTeachingItemView(item: entry.value)
                                .frame(minWidth: 220, maxWidth: .infinity, alignment: .topLeading)
                                .padding(14)
                                .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    compactComparison
                }
            }
        }
        .workspaceSelectionFeedback(trigger: selectedID)
    }

    private var compactComparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        Button { selectedID = entry.id } label: {
                            Text(verbatim: entry.value.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .frame(minHeight: 44)
                                .foregroundStyle(current?.id == entry.id ? Color.white : palette.accent)
                                .background(current?.id == entry.id ? palette.action : palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(current?.id == entry.id ? .isSelected : [])
                    }
                }
            }
            if let current { CourseTeachingItemView(item: current.value).id(current.id) }
        }
    }
}

private struct CourseFlashcardsPresentationView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let entries: [CoursePresentationEntry<CourseFlashcardContent>]
    @State private var selectedID: String?
    @State private var showsBack = false
    @State private var interactionSequence = 0

    private let title: String

    init(cards: [CourseFlashcardContent], title: String? = nil) {
        self.title = title ?? WorkspaceLocalization.string("回忆卡")
        entries = CoursePresentationEntry.make(cards) { "\($0.front.utf16.count):\($0.front)\($0.back)" }
    }

    private var current: CoursePresentationEntry<CourseFlashcardContent>? {
        entries.first(where: { $0.id == selectedID }) ?? entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CoursePresentationLabel(title: title, symbol: "rectangle.on.rectangle.angled", detail: "\((current?.ordinal ?? 0) + 1) / \(entries.count)")
            if let current {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(showsBack ? WorkspaceLocalization.string("背面") : WorkspaceLocalization.string("先想一想")).font(.caption.weight(.bold)).foregroundStyle(palette.accent)
                        Spacer()
                        Image(systemName: showsBack ? "text.alignleft" : "questionmark")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent.opacity(0.7))
                    }
                    Text(verbatim: showsBack ? current.value.back : current.value.front)
                        .font(.title3.weight(showsBack ? .regular : .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .textSelection(.enabled)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { showsBack.toggle() }
                        interactionSequence += 1
                    } label: {
                        Label(showsBack ? WorkspaceLocalization.string("回到正面") : WorkspaceLocalization.string("查看背面"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 18))
                CoursePresentationNavigation(
                    previousTitle: WorkspaceLocalization.string("上一张"), nextTitle: WorkspaceLocalization.string("下一张"),
                    previousEnabled: current.ordinal > 0,
                    nextEnabled: current.ordinal < entries.count - 1,
                    previous: { move(-1) }, next: { move(1) })
            }
        }
        .workspaceSelectionFeedback(trigger: interactionSequence)
    }

    private func move(_ direction: Int) {
        guard let current, let entry = entries.first(where: { $0.ordinal == current.ordinal + direction }) else { return }
        // Revealing an answer belongs to the current card only.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsBack = false; selectedID = entry.id }
        interactionSequence += 1
    }
}

private struct CoursePresentationNavigation: View {
    @Environment(\.workspacePalette) private var palette
    var previousTitle = WorkspaceLocalization.string("上一项")
    var nextTitle = WorkspaceLocalization.string("下一项")
    let previousEnabled: Bool
    let nextEnabled: Bool
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: previous) { Label(previousTitle, systemImage: "arrow.left").frame(minHeight: 44) }
                .disabled(!previousEnabled)
            Spacer(minLength: 0)
            Button(action: next) { Label(nextTitle, systemImage: "arrow.right").frame(minHeight: 44) }
                .disabled(!nextEnabled)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderless)
        .tint(palette.accent)
        .frame(minHeight: 44)
    }
}

private struct CourseRemoteImage: View {
    let url: String
    let alternativeText: String
    @State private var bitmap: CGImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let bitmap { Image(decorative: bitmap, scale: 1).resizable().scaledToFit().accessibilityLabel(alternativeText) }
            else if failed { Label("图片暂时无法加载", systemImage: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: url) {
            bitmap = nil; failed = false
            do {
                let result = try await CourseImageLoader.load(url)
                try Task.checkCancellation(); bitmap = result
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private enum CourseImageLoader {
    /// Decode a bounded thumbnail off the main actor, with no account credential
    /// or website cookies attached to a publisher's external image URL.
    nonisolated static func load(_ address: String) async throws -> CGImage {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { throw NativeBackendError.malformed }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: SecureCourseImageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= 8 * 1024 * 1024 else { throw NativeBackendError.malformed }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NativeBackendError.malformed }
        return image
    }
}
private final class SecureCourseImageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

struct CoursePasteUploadView: View {
    var onUploaded: () -> Void = {}
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var draft: Draft?
    @State private var notice: String?
    @State private var uploaded = false
    @State private var busy = false
    @State private var importingFile = false
    @State private var editingJSON = false
    private struct Draft {
        var course: CourseDocument
        var expectedRevision: Int?
        var mutationID = UUID()
        var scope: String
    }
    var body: some View {
        Form {
            if !uploaded {
                Section {
                    Text("把 AI 生成的课程粘贴到这里，预览后上传。").foregroundStyle(.secondary)
                    HStack {
                        PasteButton(payloadType: String.self) { values in
                            if let text = values.first { source = text }
                        }
                        Button("选择文件", systemImage: "doc") { importingFile = true }
                    }.buttonStyle(.borderless).disabled(busy)
                    CourseAnswerEditor(text: $source,
                        input: CourseQuestionInput(kind: .code, language: "json", placeholder: WorkspaceLocalization.string("在这里粘贴课程 JSON"), minLines: 6, maxLines: 12),
                        limit: 1_048_576, isFocused: $editingJSON)
                        .disabled(busy)
                    Button(busy ? WorkspaceLocalization.string("正在处理…") : WorkspaceLocalization.string("预览课程"), systemImage: "doc.text.magnifyingglass") { preview() }
                        .disabled(busy || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let draft {
                    Section("课程预览") {
                        Text(draft.course.title).font(.headline)
                        if !draft.course.summary.isEmpty { Text(draft.course.summary).foregroundStyle(.secondary) }
                        LabeledContent("课时", value: "\(draft.course.lessons.count)")
                        LabeledContent("练习", value: WorkspaceLocalization.format("%lld 道", draft.course.lessons.flatMap(\.blocks).filter { $0.type == .question }.count))
                        let exercises = draft.course.lessons.flatMap(\.blocks).filter { $0.type == .question }
                        LabeledContent("数字输入", value: WorkspaceLocalization.format("%lld 道", exercises.filter { $0.resolvedInput.kind == .integer || $0.resolvedInput.kind == .decimal }.count))
                        LabeledContent("代码编辑", value: WorkspaceLocalization.format("%lld 道", exercises.filter { $0.resolvedInput.kind == .code }.count))
                        LabeledContent("可运行练习", value: WorkspaceLocalization.format("%lld 道", exercises.filter { $0.execution != nil }.count))
                        ForEach(Array(draft.course.lessons.enumerated()), id: \.element.id) { index, lesson in
                            Text("\(index + 1). \(lesson.title)").font(.subheadline)
                        }
                        if !store.isDemoMode {
                            LabeledContent("上传至", value: store.backend.currentWorkspaceID == nil ? store.backend.accountName : WorkspaceLocalization.string("当前共享空间"))
                        }
                        if draft.expectedRevision != nil {
                            Text("将更新已有课程，并开始新版学习进度。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button(busy ? WorkspaceLocalization.string("正在上传…") : store.isDemoMode ? WorkspaceLocalization.string("加入演示课程") : draft.expectedRevision == nil ? WorkspaceLocalization.string("上传课程") : WorkspaceLocalization.string("更新课程"), systemImage: "arrow.up.doc") { upload(draft) }
                            .buttonStyle(WorkspacePrimaryButtonStyle())
                            .disabled(busy || (!store.isDemoMode && (!store.backend.signedIn || store.isReadOnlyWorkspace)))
                            .workspaceActionRow()
                    }
                }
            } else {
                Section {
                    Label(store.isDemoMode ? WorkspaceLocalization.string("已加入演示课程") : WorkspaceLocalization.string("课程已上传"), systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(Color.workspaceCompleted)
                    Text("在课程页打开，即可开始学习。").foregroundStyle(.secondary)
                }
                Section {
                    Button("完成") { dismiss() }.buttonStyle(WorkspacePrimaryButtonStyle())
                        .workspaceActionRow()
                }
            }
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped).navigationTitle("上传课程").workspaceInlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(uploaded ? WorkspaceLocalization.string("完成") : WorkspaceLocalization.string("关闭")) { dismiss() }.disabled(busy) }
        }
        .interactiveDismissDisabled(busy)
        .onChange(of: source) { _, _ in draft = nil; notice = nil; uploaded = false }
        .onChange(of: store.backend.accountScope) { _, _ in draft = nil; uploaded = false; notice = WorkspaceLocalization.string("账号或空间已切换，请重新预览。") }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json, .plainText]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 + 100 else { throw WorkspaceFailure.tooLarge }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请选择 UTF-8 格式的课程文件。")) }
                source = text
            } catch { notice = error.localizedDescription }
        }
        .task {
            await store.courses.refresh()
        }
    }
    private func preview() {
        let input = source
        busy = true; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let course = try await Task.detached(priority: .userInitiated) { try CourseImport.parse(input) }.value
                guard source == input, let scope = store.courses.scope else { throw NativeBackendError.configuration }
                draft = Draft(course: course, expectedRevision: store.courses.visibleCache.catalog.courses.first { $0.id == course.id }?.revision, scope: scope)
            } catch { notice = error.localizedDescription }
        }
    }
    private func upload(_ draft: Draft) {
        guard draft.scope == store.courses.scope else { notice = WorkspaceLocalization.string("账号或空间已切换，请重新预览。"); return }
        busy = true; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await store.courses.upload(draft.course, expectedRevision: draft.expectedRevision, mutationID: draft.mutationID)
                guard draft.scope == store.courses.scope else { return }
                uploaded = true; store.feedbackSequence += 1; onUploaded()
            } catch { notice = error.localizedDescription }
        }
    }
}

// MARK: - Rich curriculum (local, isolated, no native bridge)

private struct CourseMarkdownView: View {
    private enum Fragment {
        case prose(String), code(String, String), table(CourseTableContent)
    }
    private let fragments: [Fragment]

    init(source: String) {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Fragment] = [], buffer: [String] = []
        var fence: Character?, fenceLength = 0, language = "text"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let first = trimmed.first
            let run = (first == "`" || first == "~") ? trimmed.prefix(while: { $0 == first }).count : 0
            if fence == nil, run >= 3, let marker = first {
                if !buffer.isEmpty { result.append(.prose(buffer.joined(separator: "\n"))); buffer = [] }
                fence = marker; fenceLength = run
                language = String(trimmed.dropFirst(run)).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "text"
            } else if fence != nil, first == fence, run >= fenceLength,
                      trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(.code(language, buffer.joined(separator: "\n"))); buffer = []; fence = nil
            } else { buffer.append(line) }
        }
        if !buffer.isEmpty {
            result.append(fence == nil ? .prose(buffer.joined(separator: "\n")) : .code(language, buffer.joined(separator: "\n")))
        }
        fragments = result.flatMap { fragment in
            if case .prose(let source) = fragment { return Self.tables(in: source) }
            return [fragment]
        }
    }

    private static func tables(in source: String) -> [Fragment] {
        let lines = source.components(separatedBy: "\n")
        var result: [Fragment] = [], prose: [String] = [], index = 0
        func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }
            if value.hasSuffix("|"), !value.hasSuffix("\\|") { value.removeLast() }
            return value.replacingOccurrences(of: "\\|", with: "\u{E000}")
                .components(separatedBy: "|").map {
                    $0.replacingOccurrences(of: "\u{E000}", with: "|").trimmingCharacters(in: .whitespaces)
                }
        }
        while index < lines.count {
            let columns = cells(lines[index])
            if index + 2 < lines.count, lines[index].contains("|"), (1...8).contains(columns.count) {
                let separators = cells(lines[index + 1])
                if separators.count == columns.count,
                   separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                    var rows: [[String]] = [], next = index + 2
                    while next < lines.count, rows.count < 60, lines[next].contains("|") {
                        let row = cells(lines[next])
                        guard row.count == columns.count else { break }
                        rows.append(row); next += 1
                    }
                    if !rows.isEmpty {
                        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                        result.append(.table(CourseTableContent(columns: columns, rows: rows)))
                        index = next; continue
                    }
                }
            }
            prose.append(lines[index]); index += 1
        }
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(fragments.indices, id: \.self) { index in
                switch fragments[index] {
                case .code(let language, let source):
                    CourseCodeSampleView(code: CourseCodeSample(language: language, source: source))
                case .prose(let source): CourseMarkdownProse(source: source)
                case .table(let table): CourseTablePresentationView(table: table, title: nil)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CourseMarkdownProse: View {
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(source.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(level), trimmed.dropFirst(level).first == " " {
                    inline(String(trimmed.dropFirst(level + 1)))
                        .font(level <= 2 ? .title2.bold() : .headline).accessibilityAddTraits(.isHeader)
                } else if trimmed.hasPrefix("> ") {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3)
                        inline(String(trimmed.dropFirst(2))).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 10) { Text("•"); inline(String(trimmed.dropFirst(2))) }
                } else if trimmed == "---" || trimmed == "***" { Divider().padding(.vertical, 6) }
                else if !trimmed.isEmpty { inline(line) }
                else { Color.clear.frame(height: 3).accessibilityHidden(true) }
            }
        }.font(.body).lineSpacing(5).textSelection(.enabled)
    }
    private func inline(_ source: String) -> Text {
        // Markdown images remain alternate text; this renderer never downloads media.
        let inert = source.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        let value = (try? AttributedString(markdown: inert, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(inert)
        return Text(value)
    }
}

/// onAppear includes prefetched LazyVStack content; use the actual scroll viewport.
private struct CourseViewportActivity: ViewModifier {
    @Binding var active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { active = $0 }
        } else {
            content.onAppear { active = true }.onDisappear { active = false }
        }
    }
}

private struct CourseWebPresentationView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.courseStudyViewport) private var studyViewport
    let content: CourseWebContent
    let isSVG: Bool
    var title: String?
    @State private var running = false
    @State private var generation = 0
    @State private var failure: String?
    @State private var visible = false
    @State private var loading = true
    @State private var inViewport = false
    @State private var renderedWidth: CGFloat = 0

    private var presentationHeight: CGFloat {
        // The author's height is a preference, not a fixed device-sized canvas.
        // The iframe keeps its own scroll area when a short viewport constrains it.
        let proposed = content.height.map(CGFloat.init)
            ?? max(180, renderedWidth * (isSVG ? 0.66 : 0.78))
        let available = studyViewport.height > 0 ? max(120, studyViewport.height - 100) : 640
        return min(720, available, max(120, proposed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title ?? (isSVG ? WorkspaceLocalization.string("矢量图解") : WorkspaceLocalization.string("互动演示")), systemImage: isSVG ? "scribble.variable" : "play.rectangle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                Spacer(minLength: 4)
                if running {
                    Button("停止", systemImage: "stop.fill") { running = false }.labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                    Button("重新开始", systemImage: "arrow.counterclockwise") { failure = nil; loading = true; generation += 1 }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }
            if visible, scenePhase == .active, running, failure == nil {
                ZStack {
                    CourseIsolatedWebView(source: content.source, isSVG: isSVG, reduceMotion: reduceMotion,
                        isActive: inViewport && scenePhase == .active,
                        onReady: { loading = false }, onFailure: { failure = $0; loading = false })
                        .id(generation)
                        .allowsHitTesting(!loading)
                        .accessibilityHidden(loading)
                    if loading {
                        CourseLoadingIndicator(title: isSVG ? WorkspaceLocalization.string("正在加载图解") : WorkspaceLocalization.string("正在加载演示"), detail: WorkspaceLocalization.string("准备好后即可互动"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(palette.surface)
                    }
                }
                .frame(height: presentationHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.15)))
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                Button("重新加载") { self.failure = nil; loading = true; running = true; generation += 1 }
            } else {
                Button { failure = nil; loading = true; running = true } label: {
                    Label(isSVG ? WorkspaceLocalization.string("显示图解") : WorkspaceLocalization.string("开始互动演示"), systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(WorkspacePrimaryButtonStyle())
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(renderedWidth - width) > 1 { renderedWidth = width }
        }
        .modifier(CourseViewportActivity(active: $inViewport))
        .onAppear { visible = true; loading = true; if isSVG && inViewport { running = true } }
        .onChange(of: inViewport) { _, entered in
            if entered && isSVG && !running { running = true }
        }
        .onDisappear { visible = false; running = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { running = false } }
    }
}

/// A new, ephemeral WebKit instance per visible activity. No account state, cookies,
/// file URLs, message handlers, external resources, or native execution are exposed.
@MainActor private enum CourseWebSandbox {
    static let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    private static var rulesTask: Task<WKContentRuleList, Error>?
    private static var rulesGeneration = UUID()

    /// The same immutable blocker is shared; ephemeral web views remain isolated.
    static func networkBlocker() async throws -> WKContentRuleList {
        if let rulesTask { return try await rulesTask.value }
        let generation = UUID()
        rulesGeneration = generation
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "workshop-course-offline-v1", encodedContentRuleList: rules) { result, error in
                    if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "WorkshopCourseSandbox", code: 1)) }
                }
            }
        }
        rulesTask = task
        do { return try await task.value }
        catch {
            if rulesGeneration == generation { rulesTask = nil }
            throw error
        }
    }
    nonisolated static func escape(_ source: String) -> String {
        source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    nonisolated static func document(source: String, isSVG: Bool, reduceMotion: Bool) -> String {
        let policy = "default-src 'none'; script-src \(isSVG ? "'none'" : "'unsafe-inline'"); style-src 'unsafe-inline'; img-src 'none'; media-src 'none'; connect-src 'none'; font-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
        let motion = reduceMotion ? "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}" : ""
        let inner = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        :root{color-scheme:light dark;font-family:system-ui,-apple-system,sans-serif}*{box-sizing:border-box}body{margin:0;padding:14px;overflow-wrap:anywhere}svg,canvas{max-width:100%;height:auto}pre{overflow:auto}button,input,select{font:inherit;max-width:100%}button{min-height:44px}a{color:inherit}img,video,audio,iframe,object,embed{display:none!important}\(motion)
        </style></head><body>\(source)</body></html>
        """
        // srcdoc is an opaque sandbox origin: even script-bearing lessons cannot
        // reach the outer document or a different course's web storage.
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src about:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;color-scheme:light dark}iframe{display:block;border:0;width:100%;height:100%}</style></head><body><iframe title="课程演示" sandbox="\(isSVG ? "" : "allow-scripts")" allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'" srcdoc="\(escape(inner))"></iframe></body></html>
        """
    }
    /// Local scheduling only: no message handlers, storage or network bridge.
    /// A hidden iframe freezes pending work instead of catching up on return.
    nonisolated static let runtimeScript = #"""
    (() => {
        if (window === window.top) {
            let active = false;
            const publish = () => {
                for (const frame of document.querySelectorAll('iframe')) {
                    frame.contentWindow?.postMessage({type:'workshop-activity',active}, '*');
                }
            };
            Object.defineProperty(window, '__workshopSetActive', {value: value => {
                active = Boolean(value); publish();
            }});
            window.addEventListener('load', publish);
            return;
        }
        const native = {
            timeout: window.setTimeout.bind(window), clear: window.clearTimeout.bind(window),
            raf: window.requestAnimationFrame.bind(window), caf: window.cancelAnimationFrame.bind(window)
        };
        const timers = new Map(), fastTimers = new Map(), frames = new Map(), renders = new Map();
        let active = false, nextID = 1, frameID = null;
        const now = () => performance.now();
        const report = error => native.timeout(() => { throw error; }, 0);
        const invoke = (callback, args) => {
            try { Reflect.apply(callback, window, args); } catch (error) { report(error); }
        };
        const hasFrameWork = () => frames.size || renders.size || fastTimers.size;
        function requestFrame() {
            if (active && frameID === null && hasFrameWork()) frameID = native.raf(tick);
        }
        function tick(timestamp) {
            frameID = null;
            if (!active) return;
            // Snapshot IDs, but keep entries cancellable by an earlier callback.
            const callbacks = Array.from(frames.keys());
            const updates = Array.from(renders.keys());
            for (const id of callbacks) {
                const callback = frames.get(id);
                if (callback) { frames.delete(id); invoke(callback, [timestamp]); }
            }
            for (const key of updates) {
                const callback = renders.get(key);
                if (callback) { renders.delete(key); invoke(callback, [timestamp]); }
            }
            // Share a small budget between legacy sub-frame intervals. Rotate
            // serviced IDs so a busy model cannot starve the others or input.
            const started = now();
            for (const id of Array.from(fastTimers.keys())) {
                const timer = fastTimers.get(id);
                if (!timer || timestamp < timer.due) continue;
                fastTimers.delete(id); fastTimers.set(id, timer);
                timer.due = timestamp + 16;
                invoke(timer.callback, timer.args);
                if (!active || now() - started >= 4) break;
            }
            requestFrame();
        }
        function arm(id, timer) {
            if (!active) return;
            timer.due = now() + timer.remaining;
            if (timer.fast) { requestFrame(); return; }
            timer.nativeID = native.timeout(() => {
                timer.nativeID = null;
                if (!active || !timers.has(id)) return;
                if (!timer.repeat) timers.delete(id);
                invoke(timer.callback, timer.args);
                if (timer.repeat && timers.has(id)) {
                    timer.remaining = timer.delay;
                    arm(id, timer);
                }
            }, timer.remaining);
        }
        function createTimer(callback, delay, args, repeat) {
            // Keep WebKit's existing CSP/error behavior for string callbacks.
            if (typeof callback !== 'function') {
                const script = String(callback);
                callback = () => native.timeout(script, 0); // CSP still rejects unsafe-eval.
            }
            const numeric = Number(delay);
            const duration = Number.isFinite(numeric) ? Math.min(2147483647, Math.max(0, numeric)) : 0;
            const id = nextID++;
            const timer = {callback, args, repeat, delay:duration, remaining:duration,
                fast:repeat && duration < 16, due:now() + duration, nativeID:null};
            timers.set(id, timer);
            if (timer.fast) fastTimers.set(id, timer);
            arm(id, timer);
            return id;
        }
        function clearTimer(id) {
            const timer = timers.get(id);
            if (timer && timer.nativeID !== null) native.clear(timer.nativeID);
            timers.delete(id); fastTimers.delete(id);
        }
        window.setTimeout = (callback, delay = 0, ...args) => createTimer(callback, delay, args, false);
        window.setInterval = (callback, delay = 0, ...args) => createTimer(callback, delay, args, true);
        window.clearTimeout = window.clearInterval = clearTimer;
        window.requestAnimationFrame = callback => {
            if (typeof callback !== 'function') throw new TypeError('Expected an animation callback');
            const id = nextID++; frames.set(id, callback); requestFrame(); return id;
        };
        window.cancelAnimationFrame = id => frames.delete(id);
        const pausedAnimations = new Set();
        let pauseStyle;
        function updateAnimations() {
            if (!document.documentElement) return;
            if (!pauseStyle) {
                pauseStyle = document.createElement('style');
                pauseStyle.textContent = '*,*::before,*::after{animation-play-state:paused!important}';
            }
            if (!active) {
                document.documentElement.append(pauseStyle);
                for (const animation of document.getAnimations()) {
                    if (animation.playState === 'running') { pausedAnimations.add(animation); animation.pause(); }
                }
            } else {
                pauseStyle.remove();
                for (const animation of pausedAnimations) {
                    if (animation.playState === 'paused' && animation.effect?.target?.isConnected) animation.play();
                }
                pausedAnimations.clear();
            }
            for (const svg of document.querySelectorAll('svg')) {
                if (active) svg.unpauseAnimations?.(); else svg.pauseAnimations?.();
            }
        }
        function setActive(value) {
            const next = Boolean(value) && !document.hidden;
            if (active === next) return;
            active = next;
            const timestamp = now();
            if (!active) {
                if (frameID !== null) { native.caf(frameID); frameID = null; }
                for (const timer of timers.values()) {
                    timer.remaining = Math.max(0, timer.due - timestamp);
                    if (timer.nativeID !== null) { native.clear(timer.nativeID); timer.nativeID = null; }
                }
            } else {
                for (const [id, timer] of timers) arm(id, timer);
                requestFrame();
            }
            updateAnimations();
            window.dispatchEvent(new CustomEvent('workshopvisibilitychange', {detail:{active}}));
        }
        let hostActive = false;
        window.addEventListener('message', event => {
            if (event.source !== window.parent || event.data?.type !== 'workshop-activity') return;
            hostActive = event.data.active === true;
            setActive(hostActive);
        });
        document.addEventListener('visibilitychange', () => setActive(hostActive));
        document.addEventListener('DOMContentLoaded', updateAnimations, {once:true});
        Object.defineProperty(window, 'WorkshopRuntime', {value:Object.freeze({
            get active() { return active; },
            // Latest render for a key wins; model state is updated synchronously by the author.
            invalidate(key, callback) {
                if (typeof callback !== 'function') throw new TypeError('Expected a render callback');
                renders.set(key, callback); requestFrame();
            },
            cancelInvalidation(key) { renders.delete(key); },
            yield() { return new Promise(resolve => window.requestAnimationFrame(resolve)); }
        })});
    })();
    """#

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: runtimeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // WebRTC transports do not consistently pass through ordinary resource
        // rules/CSP. Disable their constructors before any lesson script runs.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        for (const key of ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel']) {
            try { Object.defineProperty(globalThis,key,{value:undefined,writable:false,configurable:false}); } catch (_) {}
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false // The bounded srcdoc owns its scroll area.
        #endif
        return view
    }
}

/// A small actor-owned cache keeps HTML escaping off the UI actor. It contains
/// inert strings only; it never evaluates a publisher's JavaScript.
private actor CourseWebDocuments {
    static let shared = CourseWebDocuments()
    private struct Key: Hashable { let source: String; let isSVG: Bool; let reduceMotion: Bool }
    private var entries: [Key: String] = [:]
    private var order: [Key] = []
    private var bytes = 0
    func document(source: String, isSVG: Bool, reduceMotion: Bool) -> String {
        let key = Key(source: source, isSVG: isSVG, reduceMotion: reduceMotion)
        if let result = entries[key] {
            order.removeAll { $0 == key }; order.append(key)
            return result
        }
        let result = CourseWebSandbox.document(source: source, isSVG: isSVG, reduceMotion: reduceMotion)
        let size = result.utf8.count + source.utf8.count
        let limit = 2 * 1024 * 1024
        guard size <= limit else { return result }
        while order.count >= 4 || bytes + size > limit {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { bytes -= removed.utf8.count + oldest.source.utf8.count }
        }
        entries[key] = result; order.append(key); bytes += size
        return result
    }
}

/// Deferred, optional app-level warm-up. This loads only an empty isolated page;
/// no course HTML, author script, login state or network request is involved.
@MainActor enum CourseInteractionPrewarmer {
    static func prepare() async {
        guard !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        // Warm the server player first; its configuration intentionally does not
        // include the legacy publisher runtime that suspends embedded scripts.
        try? await CourseWebPreloader.player.prepare()
        // The fallback reader prepares its embedded runtime on demand. Starting
        // a second unused WebKit view here would delay revealing the home screen.
    }
}

/// Keep one *empty*, isolated web view ready. Used views are destroyed, never
/// returned to the pool with another lesson's state, storage, timers or scripts.
@MainActor final class CourseWebPreloader: NSObject, WKNavigationDelegate {
    static let shared = CourseWebPreloader(publisherRuntime: true)
    static let player = CourseWebPreloader(publisherRuntime: false)
    private let publisherRuntime: Bool
    private init(publisherRuntime: Bool) { self.publisherRuntime = publisherRuntime; super.init() }
    private func makeWebView() -> WKWebView {
        if publisherRuntime { return CourseWebSandbox.makeWebView() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
    private var idle: WKWebView?
    private var candidate: WKWebView?
    private var warming: Task<Void, Error>?
    private var warmingID: UUID?
    private var completion: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var waiters: Set<UUID> = []

    func prepare() async throws {
        try Task.checkCancellation()
        if idle != nil { return }
        let waiter = UUID()
        waiters.insert(waiter)
        defer { waiters.remove(waiter) }
        let task: Task<Void, Error>
        if let warming { task = warming }
        else {
            let warmingID = UUID()
            self.warmingID = warmingID
            task = Task { @MainActor [self] in
                defer {
                    if self.warmingID == warmingID { self.warming = nil; self.warmingID = nil }
                }
                let rules = try await CourseWebSandbox.networkBlocker()
                try Task.checkCancellation()
                let view = self.makeWebView()
                view.configuration.userContentController.add(rules)
                self.candidate = view
                view.navigationDelegate = self
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.completion = continuation
                    self.timeout = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(12))
                        guard !Task.isCancelled else { return }
                        self?.finish(error: NSError(domain: "WorkshopCoursePreload", code: 1))
                    }
                    view.loadHTMLString("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\"><title>Ready</title>", baseURL: nil)
                }
            }
            warming = task
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(waiter: waiter) }
        }
    }
    private func cancel(waiter: UUID) {
        waiters.remove(waiter)
        // An interactive reader may join a background warm-up. Only cancel the
        // shared candidate when no live caller still needs it.
        guard waiters.isEmpty else { return }
        warming?.cancel()
        finish(error: CancellationError())
        warming = nil; warmingID = nil
    }
    func take() -> WKWebView {
        guard let view = idle else {
            #if DEBUG
            print("COURSE_WEB_SHELL_COLD publisher=\(publisherRuntime)")
            #endif
            return makeWebView()
        }
        idle = nil
        #if DEBUG
        print("COURSE_WEB_SHELL_PREWARMED publisher=\(publisherRuntime)")
        #endif
        return view
    }
    private func finish(error: Error? = nil) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        candidate?.navigationDelegate = nil
        if let error { candidate?.stopLoading(); candidate = nil; completion.resume(throwing: error) }
        else { idle = candidate; candidate = nil; completion.resume(returning: ()) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if webView === candidate { finish() } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === candidate { finish(error: error) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === candidate { finish(error: error) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === candidate { finish(error: NSError(domain: "WorkshopCoursePreload", code: 2)) }
    }
}

@MainActor private final class CourseWebCoordinator: NSObject, WKNavigationDelegate {
    private struct LoadKey: Equatable { let source: String; let isSVG: Bool; let reduceMotion: Bool }
    private var key: LoadKey?
    var generation = 0
    var onReady: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }
    private var timeout: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var activeNavigation: WKNavigation?
    private var isActive = false
    private var appliedActivity: Bool?
    private var navigationFinished = false
    private var ready = false
    private var preparingFrame = false
    private var paintGeneration = 0

    func setActive(_ active: Bool, in webView: WKWebView) {
        isActive = active
        guard activeNavigation != nil else { return }
        if appliedActivity != active {
            appliedActivity = active
            // Only the trusted outer frame can signal its opaque lesson iframe.
            webView.evaluateJavaScript("window.__workshopSetActive?.(\(active ? "true" : "false"))", completionHandler: nil)
            if !active && navigationFinished {
                paintGeneration += 1; preparingFrame = false
                timeout?.cancel(); timeout = nil
            }
        }
        if active && navigationFinished && !ready { prepareFirstFrame(in: webView) }
    }
    func load(_ webView: WKWebView, source: String, isSVG: Bool, reduceMotion: Bool) {
        let next = LoadKey(source: source, isSVG: isSVG, reduceMotion: reduceMotion)
        guard key != next else { return }
        key = next; generation += 1
        activeNavigation = nil
        appliedActivity = nil
        navigationFinished = false; ready = false; preparingFrame = false; paintGeneration += 1
        webView.stopLoading()
        let current = generation
        webView.navigationDelegate = self
        loading?.cancel(); timeout?.cancel(); timeout = nil
        // Fail closed: attach the cached blanket blocker before loading any lesson.
        loading = Task { @MainActor [weak self, weak webView] in
            do {
                let rules = try await CourseWebSandbox.networkBlocker()
                let document = await CourseWebDocuments.shared.document(source: source, isSVG: isSVG, reduceMotion: reduceMotion)
                guard !Task.isCancelled, let self, let webView, self.generation == current else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(rules)
                self.activeNavigation = webView.loadHTMLString(document, baseURL: nil)
                self.timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    self?.onFailure(WorkspaceLocalization.string("演示加载超时，请重新加载或阅读文字说明。"))
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.onFailure(WorkspaceLocalization.string("演示暂时无法打开，可以先阅读文字说明。"))
            }
        }
    }
    func stop(_ webView: WKWebView) {
        navigationFinished = false; ready = false; preparingFrame = false; paintGeneration += 1
        activeNavigation = nil
        generation += 1; loading?.cancel(); loading = nil; timeout?.cancel(); timeout = nil
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        let local = url == "about:blank" || url == "about:srcdoc" || url.hasPrefix("about:srcdoc#")
        decisionHandler(local && navigationAction.navigationType == .other ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === activeNavigation else { return }
        navigationFinished = true
        timeout?.cancel(); timeout = nil
        appliedActivity = nil
        setActive(isActive, in: webView)
    }
    private func prepareFirstFrame(in webView: WKWebView) {
        guard !preparingFrame, let navigation = activeNavigation else { return }
        preparingFrame = true
        let current = generation, paint = paintGeneration
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.onFailure(WorkspaceLocalization.string("演示准备超时，请重新加载或阅读文字说明。"))
        }
        // Navigation completion precedes layout/paint. Keep the loading cover
        // through a full rendered frame, including the first startup timer batch.
        webView.callAsyncJavaScript("""
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return true;
            """, arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self, self.generation == current, self.paintGeneration == paint,
                      self.isActive, navigation === self.activeNavigation else { return }
                self.preparingFrame = false
                self.timeout?.cancel(); self.timeout = nil
                switch result {
                case .success: self.ready = true; self.onReady()
                case .failure: self.onFailure(WorkspaceLocalization.string("演示暂时无法显示，可以先阅读文字说明。"))
                }
            }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        timeout?.cancel(); onFailure(WorkspaceLocalization.string("演示已停止，请重新加载。"))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(navigation, error: error)
    }
    private func fail(_ navigation: WKNavigation?, error: Error) {
        guard let navigation, navigation === activeNavigation,
              (error as NSError).code != NSURLErrorCancelled else { return }
        timeout?.cancel(); onFailure(WorkspaceLocalization.string("演示暂时无法显示，可以先阅读文字说明。"))
    }
}

#if os(iOS)
private struct CourseIsolatedWebView: UIViewRepresentable {
    let source: String
    let isSVG: Bool
    let reduceMotion: Bool
    var isActive = true
    var onReady: () -> Void = {}
    var onFailure: (String) -> Void
    func makeCoordinator() -> CourseWebCoordinator { CourseWebCoordinator() }
    func makeUIView(context: Context) -> WKWebView { CourseWebPreloader.shared.take() }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onFailure = onFailure
        context.coordinator.load(view, source: source, isSVG: isSVG, reduceMotion: reduceMotion)
        context.coordinator.setActive(isActive, in: view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: CourseWebCoordinator) { coordinator.stop(view) }
}
#elseif os(macOS)
private struct CourseIsolatedWebView: NSViewRepresentable {
    let source: String
    let isSVG: Bool
    let reduceMotion: Bool
    var isActive = true
    var onReady: () -> Void = {}
    var onFailure: (String) -> Void
    func makeCoordinator() -> CourseWebCoordinator { CourseWebCoordinator() }
    func makeNSView(context: Context) -> WKWebView { CourseWebPreloader.shared.take() }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onFailure = onFailure
        context.coordinator.load(view, source: source, isSVG: isSVG, reduceMotion: reduceMotion)
        context.coordinator.setActive(isActive, in: view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: CourseWebCoordinator) { coordinator.stop(view) }
}
#endif

private struct CourseDeletionRequest: Identifiable {
    var id: UUID { course.id }
    let course: CourseSummary
    let scope: String
}

private struct CourseDeletionConfirmation: ViewModifier {
    @Environment(WorkspaceStore.self) private var store
    @Binding var request: CourseDeletionRequest?
    var onDeleted: () -> Void = {}
    @State private var deleting = false
    @State private var notice: String?
    func body(content: Content) -> some View {
        content
            .confirmationDialog("删除课程？", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }), titleVisibility: .visible, presenting: request) { request in
                Button("删除课程", role: .destructive) { remove(request) }
                Button("取消", role: .cancel) {}
            } message: { request in
                Text("“\(request.course.title)”将从当前空间移除，共享成员也将无法查看。")
            }
            .overlay(alignment: .top) {
                if deleting {
                    ProgressView("正在删除课程…").padding(14).background(.regularMaterial, in: Capsule()).padding(.top, 10)
                }
            }
            .alert("暂时无法删除", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
    }
    private func remove(_ request: CourseDeletionRequest) {
        guard !deleting else { return }
        guard store.courses.scope == request.scope else { notice = WorkspaceLocalization.string("账号或空间已切换，请重新选择课程。"); return }
        deleting = true
        Task { @MainActor in
            defer { deleting = false }
            do {
                try await store.courses.delete(request.course.id, expectedRevision: request.course.revision)
                guard store.courses.scope == request.scope else { return }
                store.feedbackSequence += 1
                onDeleted()
            } catch {
                guard store.courses.scope == request.scope else { return }
                notice = error.localizedDescription
            }
        }
    }
}

/// A star is personal, including in shared read-only spaces.
private struct CourseStarButton: View {
    @Environment(WorkspaceStore.self) private var store
    let id: UUID
    var body: some View {
        let starred = store.courses.isStarred(id)
        Button {
            do {
                try store.courses.setStarred(id, starred: !starred)
                store.feedbackSequence += 1
            } catch { store.errorMessage = error.localizedDescription }
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.body.weight(.semibold)).foregroundStyle(starred ? Color.orange : Color.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? WorkspaceLocalization.string("取消课程星标") : WorkspaceLocalization.string("标星课程"))
        .accessibilityValue(starred ? WorkspaceLocalization.string("已标星") : WorkspaceLocalization.string("未标星"))
        .accessibilityIdentifier("course-star-\(id)")
    }
}

private struct CourseNewView: View {
    var onCreated: () -> Void = {}
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var summary = ""
    @State private var lessonTitle = WorkspaceLocalization.string("第一课")
    @State private var source = ""
    @State private var destinationScope: String?
    @State private var draft: Draft?
    @State private var busy = false
    @State private var notice: String?
    private struct Draft {
        let course: CourseDocument
        let mutationID = UUID()
        let scope: String
    }
    private var canSave: Bool {
        !busy && destinationScope != nil && destinationScope == store.courses.scope &&
        (store.isDemoMode || (store.backend.signedIn && !store.isReadOnlyWorkspace)) &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lessonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Form {
            Section("课程") {
                TextField("课程名称", text: $title)
                TextField("简介（选填）", text: $summary, axis: .vertical).lineLimit(2...4)
            }.disabled(busy || draft != nil)
            Section {
                TextField("课时名称", text: $lessonTitle)
                TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if source.isEmpty { Text("写下内容，可使用 Markdown 和代码围栏。")
                                .font(.body).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    }
            } header: { Text("第一课") } footer: {
                Text("适合先写一节课。丰富的多课时内容，也可以由 AI 制作后粘贴或导入。")
            }.disabled(busy || draft != nil)
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
            Section {
                Button(busy ? WorkspaceLocalization.string("正在保存…") : draft == nil ? WorkspaceLocalization.string("创建课程") : WorkspaceLocalization.string("重试保存"), systemImage: "plus") { save() }
                    .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(!canSave).workspaceActionRow()
            }
        }
        .formStyle(.grouped).navigationTitle("新建课程").workspaceInlineTitle()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .task {
            await store.courses.prepareForInteraction(preloadFirstCourse: false)
            guard !Task.isCancelled else { return }
            if destinationScope == nil { destinationScope = store.courses.scope }
        }
        .onChange(of: store.courses.scope) { _, _ in notice = WorkspaceLocalization.string("账号或空间已切换，请重新打开新建课程。") }
    }
    private func save() {
        guard canSave, let scope = destinationScope else { return }
        do {
            if draft == nil {
                let body = source.trimmingCharacters(in: .whitespacesAndNewlines)
                let block = CourseBlock(type: .text, text: body, presentation: CoursePresentation(kind: .markdown, markdown: CourseMarkdownContent(source: body)))
                let course = CourseDocument(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    lessons: [CourseLesson(title: lessonTitle.trimmingCharacters(in: .whitespacesAndNewlines), blocks: [block])])
                try CourseValidation.validate(course)
                draft = Draft(course: course, scope: scope)
            }
            guard let draft, draft.scope == store.courses.scope else { throw NativeBackendError.configuration }
            busy = true; notice = nil
            Task { @MainActor in
                defer { busy = false }
                do {
                    _ = try await store.courses.upload(draft.course, expectedRevision: nil, mutationID: draft.mutationID)
                    guard store.courses.scope == draft.scope else { return }
                    store.feedbackSequence += 1; onCreated(); dismiss()
                } catch {
                    guard store.courses.scope == draft.scope else { return }
                    notice = error.localizedDescription
                }
            }
        } catch { notice = error.localizedDescription }
    }
}
