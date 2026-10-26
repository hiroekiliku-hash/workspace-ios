import SwiftUI
import WebKit
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The native shell owns identity, persistence and navigation. The server owns
/// the complete learning canvas, but never receives an App token in its HTML.
struct CourseServerPlayerView: View {
    @AppStorage(CourseLearningControlSide.preferenceKey) private var savedControlSide = CourseLearningControlSide.right.rawValue
    @AppStorage("hapticsEnabled") private var savedHapticsEnabled = true
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let edition: CourseEdition
    let lesson: CourseLesson
    let progress: CourseProgress
    var onUseNative: () -> Void = {}
    var onNavigateLesson: (UUID) -> Void = { _ in }
    @State private var bridge = CoursePlayerBridge()
    @State private var loadedScope: String?
    @State private var loaded = false
    @State private var failure: String?
    @State private var retry = 0
    @State private var runTask: Task<Void, Never>?
    @State private var running = false
    @State private var readyTimeout: Task<Void, Never>?

    private struct LoadKey: Hashable {
        var scope: String?
        var course: UUID
        var lesson: UUID
        var revision: Int
        var retry: Int
    }
    private var loadKey: LoadKey {
        LoadKey(scope: store.courses.scope, course: edition.course.id,
                lesson: lesson.id, revision: edition.revision, retry: retry)
    }
    private var controlSide: CourseLearningControlSide {
        CourseLearningControlSide(rawValue: savedControlSide) ?? .right
    }
    private var pageTitle: String {
        #if os(macOS)
        lesson.title
        #else
        lesson.blocks.indices.contains(bridge.index) && lesson.blocks[bridge.index].type == .question ? "答题" : "学习"
        #endif
    }
    private var showsNavigationControls: Bool {
        bridge.ready && loadedScope == store.courses.scope && failure == nil
    }
    private var canvasBackground: Color {
        colorScheme == .dark ? .black : Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
    }
    var body: some View {
        ZStack {
            if loaded && loadedScope == store.courses.scope {
                CoursePlayerWebSurface(bridge: bridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Extend the document beneath the home indicator without
                    // moving the floating controls or ignoring the keyboard.
                    .ignoresSafeArea(.container, edges: .bottom)
                    .opacity(bridge.ready ? 1 : 0)
                    .overlay(alignment: .bottomLeading) {
                        CourseJavaScriptRunHost(runner: bridge.javaScriptRunner)
                            .frame(width: 2, height: 2)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            }
            if let failure {
                ContentUnavailableView {
                    Label("暂时无法打开课时", systemImage: "book.closed")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { retry += 1 }
                    Button("使用基础阅读器", action: onUseNative)
                }
            } else if !bridge.ready {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在准备课时").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvasBackground.ignoresSafeArea())
        .navigationTitle(pageTitle)
        .workspaceInlineTitle()
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .overlay(alignment: controlSide.alignment) {
            if showsNavigationControls {
                navigationControls
            }
        }
        #elseif os(macOS)
        .toolbar { macNavigationControls }
        #endif
        .task(id: loadKey) { await load() }
        .onChange(of: colorScheme) { _, _ in sendEnvironment() }
        .onChange(of: palette) { _, _ in sendEnvironment() }
        .onChange(of: reduceMotion) { _, _ in sendEnvironment() }
        .onChange(of: savedControlSide) { _, _ in sendEnvironment() }
        .onChange(of: savedHapticsEnabled) { _, _ in sendEnvironment() }
        .onDisappear { tearDown() }
    }
    private var navigationControls: some View {
        VStack(spacing: 12) {
            Button {
                bridge.feedback("impact", enabled: store.hapticsEnabled)
                bridge.send(["type": "next"])
            } label: { Label("继续", systemImage: "arrow.right") }
            .modifier(CourseLearningActionStyle())
            .disabled(!bridge.canNext)
            .accessibilityLabel("继续")
            Button {
                bridge.feedback("impact", enabled: store.hapticsEnabled)
                bridge.send(["type": "previous"])
            } label: { Label("上一步", systemImage: "arrow.left") }
            .modifier(CourseLearningActionStyle(prominent: false))
            .disabled(!bridge.canPrevious)
            .accessibilityLabel("上一步")
        }
        .modifier(CourseLearningGlassGroup())
        .frame(width: 64)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
    #if os(macOS)
    /// Desktop actions live in window chrome so a code editor or a short window
    /// never has to share its bottom corner with the phone's floating controls.
    @ToolbarContentBuilder
    private var macNavigationControls: some ToolbarContent {
        if showsNavigationControls {
            ToolbarItem(placement: .status) {
                Text("\(bridge.index + 1) / \(bridge.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("第 \(bridge.index + 1) 步，共 \(bridge.count) 步")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    bridge.feedback("impact", enabled: store.hapticsEnabled)
                    bridge.send(["type": "previous"])
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .disabled(!bridge.canPrevious)
                .accessibilityLabel("上一步")
                .help("上一步（正文未编辑时按 ←）")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    bridge.feedback("impact", enabled: store.hapticsEnabled)
                    bridge.send(["type": "next"])
                } label: {
                    Label("继续", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                        .frame(minWidth: 54, minHeight: 22)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.action)
                .foregroundStyle(.white)
                .disabled(!bridge.canNext)
                .accessibilityLabel("继续")
                .help("继续、提交回答或执行下一步（正文未编辑时按 → 或 ⌘↩）")
            }
        }
    }
    #endif
    @MainActor private func load() async {
        tearDown()
        let scope = store.courses.scope
        guard scope != nil else { onUseNative(); return }
        failure = nil
        loadedScope = scope
        do {
            let package = try await store.courses.playerPackage(edition: edition, lesson: lesson)
            try Task.checkCancellation()
            guard store.courses.scope == scope else { return }
            guard package.courseID == edition.course.id, package.lessonID == lesson.id,
                  package.courseRevision == edition.revision,
                  package.protocolVersion == "WORKSHOP-PLAYER/1",
                  package.html.utf8.count <= 4 * 1024 * 1024 else {
                throw WorkspaceFailure.invalid("课程已更新或播放器不兼容，请返回课程列表刷新。")
            }
            bridge.load(html: package.html)
            bridge.onMessage = { message in handle(message) }
            bridge.onFailure = { message in
                guard loadedScope == store.courses.scope else { return }
                failure = message
                bridge.ready = false
            }
            loaded = true
            readyTimeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard !Task.isCancelled, !bridge.ready, loadedScope == scope else { return }
                failure = "课时准备时间较长，请重试或使用基础阅读器。"
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, store.courses.scope == scope else { return }
            failure = error.localizedDescription
        }
    }
    /// Resolve the same adaptive assets used by native controls. Only CSS changes;
    /// the server package, course data and answers keep their existing formats.
    private var canvasColors: [String: String] {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        func css(_ color: Color) -> String {
            let resolved = color.resolve(in: environment).cgColor
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let components = resolved.converted(to: space, intent: .defaultIntent, options: nil)?.components,
                  components.count >= 3 else { return "inherit" }
            let rgb = components.prefix(3).map { Int((min(1, max(0, $0)) * 255).rounded()) }
            let alpha = components.count > 3 ? min(1, max(0, components[3])) : 1
            return "rgba(\(rgb[0]), \(rgb[1]), \(rgb[2]), \(alpha))"
        }
        return ["--accent": css(palette.accent), "--soft": css(palette.surface),
                "--mark": css(palette.accent.opacity(0.22))]
    }

    @MainActor private func sendEnvironment() {
        guard bridge.ready, loadedScope == store.courses.scope else { return }
        bridge.applyCanvasColors(canvasColors)
        let current = store.courses.visibleCache.progress[edition.course.id] ?? progress
        guard let data = try? WorkspaceCoding.encoder().encode(current),
              let value = try? JSONSerialization.jsonObject(with: data) else { return }
        bridge.send(["type": "init", "progress": value,
                     "theme": colorScheme == .dark ? "dark" : "light", "reduceMotion": reduceMotion,
                     "controlSide": controlSide.rawValue, "hapticsEnabled": store.hapticsEnabled])
    }
    @MainActor private func handle(_ message: [String: Any]) {
        guard loaded, loadedScope == store.courses.scope,
              let type = message["type"] as? String else { return }
        if type == "rendererError" {
            readyTimeout?.cancel(); readyTimeout = nil
            failure = "课程显示遇到问题，请重试。"
            #if DEBUG
            NSLog("COURSE_PLAYER_SCRIPT_ERROR %@", String(describing: message["message"]))
            #endif
            return
        }
        if type == "ready" {
            guard !bridge.ready else { return }
            bridge.ready = true
            readyTimeout?.cancel(); readyTimeout = nil
            sendEnvironment()
            return
        }
        guard bridge.ready else { return }
        if type == "haptic" {
            guard let style = message["style"] as? String else { return }
            bridge.feedback(style, enabled: store.hapticsEnabled)
            return
        }
        if type == "state" {
            guard let index = message["index"] as? Int, let count = message["count"] as? Int,
                  (1...10_000).contains(count), (0..<count).contains(index),
                  let previous = message["canPrevious"] as? Bool,
                  let next = message["canNext"] as? Bool else { return }
            bridge.index = index; bridge.count = count
            bridge.canPrevious = previous; bridge.canNext = next
            return
        }
        if type == "navigation" {
            guard let direction = message["direction"] as? String,
                  let current = edition.course.lessons.firstIndex(where: { $0.id == lesson.id }) else { return }
            let target: Int
            switch direction {
            case "nextLesson": target = current + 1
            case "previousLesson": target = current - 1
            default: return
            }
            // Completion is persisted independently, before the renderer requests navigation.
            if target > current {
                let currentProgress = store.courses.visibleCache.progress[edition.course.id]
                guard currentProgress?.completedLessonIDs.contains(lesson.id) == true else { return }
            }
            if target == edition.course.lessons.count { dismiss(); return }
            guard edition.course.lessons.indices.contains(target) else { return }
            onNavigateLesson(edition.course.lessons[target].id)
            return
        }
        guard let requestID = message["requestID"] as? String,
              !requestID.isEmpty, requestID.utf8.count <= 128 else { return }
        do {
            switch type {
            case "submit":
                let block = try question(message)
                guard let selected = message["selectedOptionIDs"] as? [String],
                      selected.count <= 20, let text = message["text"] as? String else {
                    throw WorkspaceFailure.invalid("回答格式无效。")
                }
                try CourseValidation.validateAnswer(block: block, selected: selected, text: text)
                try store.courses.submit(courseID: edition.course.id,
                    update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                        blockID: block.id, selectedOptionIDs: selected, text: text))
                bridge.send(["type": "saved", "requestID": requestID, "ok": true])
            case "complete":
                guard message["completed"] as? Bool == true else { return }
                try store.courses.submit(courseID: edition.course.id,
                    update: CourseProgressUpdate(courseRevision: edition.revision,
                        lessonID: lesson.id, completed: true))
                bridge.send(["type": "saved", "requestID": requestID, "ok": true])
            case "run":
                let block = try question(message)
                guard block.execution != nil, let answer = message["answer"] as? String,
                      let stdin = message["stdin"] as? String, stdin.utf16.count <= 4_000 else {
                    throw WorkspaceFailure.invalid("运行参数无效。")
                }
                try CourseValidation.validateAnswer(block: block, selected: [], text: answer)
                guard !running else { throw WorkspaceFailure.invalid("已有代码正在运行。") }
                run(block: block, answer: answer, stdin: stdin, requestID: requestID)
            default: return
            }
        } catch {
            bridge.send(["type": type == "run" ? "runResult" : "saved", "requestID": requestID,
                         "ok": false, "error": error.localizedDescription])
        }
    }
    private func question(_ message: [String: Any]) throws -> CourseBlock {
        guard let raw = message["blockID"] as? String, let id = UUID(uuidString: raw),
              let block = lesson.blocks.first(where: { $0.id == id && $0.type == .question }) else {
            throw WorkspaceFailure.invalid("题目不存在。")
        }
        return block
    }
    @MainActor private func run(block: CourseBlock, answer: String, stdin: String, requestID: String) {
        running = true
        let scope = loadedScope
        runTask = Task { @MainActor in
            defer { running = false; runTask = nil }
            do {
                let result: CourseCodeRunResult
                if var configuration = block.execution, configuration.language == "javascript" {
                    if stdin != (configuration.stdin ?? "") { configuration.expectedOutput = nil }
                    result = await bridge.javaScriptRunner.run(answer: answer, configuration: configuration, stdin: stdin)
                } else if store.isDemoMode {
                    result = CourseCodeRunResult(status: "unavailable", stdout: "",
                        stderr: "演示模式可在本机运行 JavaScript；Python 和 C++ 请登录后使用。", durationMs: 0)
                } else {
                    result = try await store.backend.runCourseAnswer(edition.course.id,
                        revision: edition.revision, lessonID: lesson.id, blockID: block.id,
                        text: answer, stdin: stdin == (block.execution?.stdin ?? "") ? nil : stdin)
                }
                try Task.checkCancellation()
                guard loadedScope == scope, store.courses.scope == scope else { return }
                let data = try WorkspaceCoding.encoder().encode(result)
                let value = try JSONSerialization.jsonObject(with: data)
                bridge.send(["type": "runResult", "requestID": requestID, "result": value])
            } catch {
                guard !Task.isCancelled, loadedScope == scope, store.courses.scope == scope else { return }
                bridge.send(["type": "runResult", "requestID": requestID, "error": error.localizedDescription])
            }
        }
    }
    @MainActor private func tearDown() {
        runTask?.cancel(); runTask = nil; running = false
        readyTimeout?.cancel(); readyTimeout = nil
        loaded = false; loadedScope = nil
        bridge.destroy()
    }
}

@MainActor @Observable private final class CoursePlayerBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var ready = false
    var index = 0
    var count = 1
    var canPrevious = false
    var canNext = true
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored var onMessage: (([String: Any]) -> Void)?
    @ObservationIgnored var onFailure: ((String) -> Void)?
    @ObservationIgnored let javaScriptRunner = CourseJavaScriptRunner()
    #if os(macOS)
    @ObservationIgnored private var lastMacFeedback: TimeInterval = 0
    #endif

    func feedback(_ style: String, enabled: Bool) {
        guard enabled, ["selection", "impact", "success", "warning", "error"].contains(style) else { return }
        #if os(iOS)
        let event: WorkspaceHaptics.Event
        switch style {
        case "selection": event = .selection
        case "success": event = .success
        case "warning": event = .warning
        case "error": event = .error
        default: event = .tap
        }
        WorkspaceHaptics.play(event, enabled: enabled)
        #elseif os(macOS)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMacFeedback >= 0.12 else { return }
        lastMacFeedback = now
        NSHapticFeedbackManager.defaultPerformer.perform(style == "selection" ? .alignment : .levelChange, performanceTime: .now)
        #endif
    }

    func load(html: String) {
        destroy()
        // This pool contains only unused blank player surfaces. Preparing
        // WebKit while the course list is visible avoids its first-use cost
        // landing on the transition into a lesson.
        #if DEBUG
        let shellStarted = ProcessInfo.processInfo.systemUptime
        #endif
        let view = CourseWebPreloader.player.take()
        #if DEBUG
        print("COURSE_PLAYER_SHELL_ACQUIRED ms=\((ProcessInfo.processInfo.systemUptime - shellStarted) * 1000)")
        #endif
        let configuration = view.configuration
        configuration.userContentController.add(self, name: "workshopPlayer")
        let errors = """
        (function(){
          function report(value){window.webkit?.messageHandlers?.workshopPlayer?.postMessage({type:'rendererError',message:String(value).slice(0,300)});}
          window.addEventListener('error',function(e){report(e.message);});
          window.addEventListener('unhandledrejection',function(e){report(e.reason && e.reason.message || e.reason);});
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: errors, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if os(macOS)
        // Keyboard commands leave typing, selection and IME composition alone.
        let shortcuts = """
        // The desktop controls live in window chrome, not over the canvas.
        // Keep the renderer's last content clear without its phone-only reserve.
        var desktopInsets=document.createElement('style');
        desktopInsets.textContent='body{--control-space:16px !important}header.heading>.eyebrow{display:none}';
        document.head.appendChild(desktopInsets);
        document.addEventListener('keydown', function(e) {
          var t=e.target;
          if(e.defaultPrevented || e.isComposing || t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
          var type=(e.key==='ArrowRight' && !e.metaKey && !e.ctrlKey && !e.altKey) || (e.key==='Enter' && e.metaKey) ? 'next' : e.key==='ArrowLeft' && !e.metaKey && !e.ctrlKey && !e.altKey ? 'previous' : null;
          if(type && window.WorkshopPlayer && typeof window.WorkshopPlayer.receive==='function') { e.preventDefault(); window.WorkshopPlayer.receive({type:type}); }
        });
        """
        configuration.userContentController.addUserScript(WKUserScript(source: shortcuts, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        #endif
        view.navigationDelegate = self
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .systemGroupedBackground
        view.underPageBackgroundColor = .systemGroupedBackground
        view.scrollView.backgroundColor = .systemGroupedBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.keyboardDismissMode = .interactive
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        view.allowsBackForwardNavigationGestures = false
        webView = view
        view.loadHTMLString(html, baseURL: nil)
    }
    func applyCanvasColors(_ colors: [String: String]) {
        // Set existing renderer CSS variables directly, including cached packages.
        // Updating styles leaves the current step, answer draft and focus intact.
        webView?.callAsyncJavaScript("""
        for (const [name, value] of Object.entries(colors)) {
            document.body.style.setProperty(name, value);
        }
        """, arguments: ["colors": colors], in: nil, in: .page, completionHandler: nil)
    }

    func send(_ message: [String: Any]) {
        guard let webView, JSONSerialization.isValidJSONObject(message) else { return }
        // Pass values through WebKit's argument serializer; answer text can never
        // become executable JavaScript, even when it contains quotes or </script>.
        webView.callAsyncJavaScript("if (window.WorkshopPlayer) window.WorkshopPlayer.receive(message);",
            arguments: ["message": message], in: nil, in: .page, completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "workshopPlayer", message.frameInfo.isMainFrame,
              message.webView === webView,
              let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 192 * 1024 else { return }
        onMessage?(body)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.targetFrame,
              let url = navigationAction.request.url,
              navigationAction.navigationType == .other else {
            decisionHandler(.cancel); return
        }
        if !target.isMainFrame {
            // Author content lives in sandboxed srcdoc frames. Those frames may
            // render locally, but never invoke the native handler above.
            decisionHandler(["about:blank", "about:srcdoc"].contains(url.absoluteString)
                || url.scheme == "data" ? .allow : .cancel)
            return
        }
        // The initial HTML is the only native document; following links cannot
        // replace the trusted renderer with another data document.
        decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        onFailure?("课时显示已暂停，请重新打开。")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        onFailure?(error.localizedDescription)
    }
    func destroy() {
        javaScriptRunner.stop()
        onMessage = nil; onFailure = nil
        ready = false; index = 0; count = 1; canPrevious = false; canNext = true
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "workshopPlayer")
        webView?.navigationDelegate = nil
        webView = nil
    }
}

#if os(iOS)
private struct CoursePlayerWebSurface: UIViewRepresentable {
    let bridge: CoursePlayerBridge
    func makeUIView(context: Context) -> WKWebView { bridge.webView ?? WKWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "workshopPlayer")
        view.navigationDelegate = nil
    }
}
#elseif os(macOS)
private struct CoursePlayerWebSurface: NSViewRepresentable {
    let bridge: CoursePlayerBridge
    func makeNSView(context: Context) -> WKWebView { bridge.webView ?? WKWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "workshopPlayer")
        view.navigationDelegate = nil
    }
}
#endif
