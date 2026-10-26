import Foundation
import SwiftUI
import WebKit

struct CourseCodeRunResult: Codable, Equatable {
    var status: String
    var stdout: String
    var stderr: String
    var exitCode: Int?
    var durationMs: Int
    var passed: Bool?
}

/// JavaScript runs in a disposable worker, without the lesson's DOM, storage,
/// native bridge or network. Native compilers use the authenticated server runner.
@MainActor final class CourseJavaScriptRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var view: WKWebView?
    private var continuation: CheckedContinuation<CourseCodeRunResult, Never>?
    private var timeout: Task<Void, Never>?
    private var token = UUID().uuidString
    private var expectedOutput: String?
    #if os(iOS)
    private weak var host: UIView?
    func attach(to host: UIView) { self.host = host }
    #elseif os(macOS)
    private weak var host: NSView?
    func attach(to host: NSView) { self.host = host }
    #endif

    func run(answer: String, configuration: CourseExecutionConfiguration, stdin: String) async -> CourseCodeRunResult {
        guard continuation == nil else {
            return CourseCodeRunResult(status: "runtimeError", stdout: "", stderr: WorkspaceLocalization.string("已有代码正在运行。"), durationMs: 0)
        }
        token = UUID().uuidString
        let source = configuration.template?.replacingOccurrences(of: "{{ANSWER}}", with: answer) ?? answer
        guard source.utf16.count <= 40_000, stdin.utf16.count <= 4_000 else {
            return CourseCodeRunResult(status: "runtimeError", stdout: "", stderr: WorkspaceLocalization.string("代码或输入过长。"), durationMs: 0)
        }
        expectedOutput = configuration.expectedOutput
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else { stop(); return }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.userContentController.add(self, name: "courseRun")
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.navigationDelegate = self
                self.view = view
                // iOS may suspend script work in detached zero-sized pages.
                // Keep this disposable page in its reader's tiny native host;
                // the source still executes exclusively inside the worker.
                if let host {
                    view.frame = host.bounds
                    host.addSubview(view)
                }
                // Includes cold WebKit startup; the worker itself has a 2 s limit.
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    self?.finish(CourseCodeRunResult(status: "timeout", stdout: "", stderr: WorkspaceLocalization.string("运行超时，已停止。"), durationMs: 12_000))
                }
                view.loadHTMLString(Self.document(source: source, stdin: stdin, token: token), baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        finish(CourseCodeRunResult(status: "cancelled", stdout: "", stderr: WorkspaceLocalization.string("已停止运行。"), durationMs: 0))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === view, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], body["token"] as? String == token,
              let status = body["status"] as? String,
              ["completed", "runtimeError", "timeout", "outputLimit"].contains(status),
              let stdout = body["stdout"] as? String, let stderr = body["stderr"] as? String,
              stdout.utf8.count <= 32_768, stderr.utf8.count <= 32_768,
              let duration = body["durationMs"] as? Int, (0...12_000).contains(duration) else { return }
        var result = CourseCodeRunResult(status: status, stdout: stdout, stderr: stderr,
            exitCode: status == "completed" ? 0 : nil, durationMs: duration)
        if status == "completed", let expectedOutput {
            result.passed = Self.normalizedOutput(stdout) == Self.normalizedOutput(expectedOutput)
        }
        finish(result)
    }

    private static func normalizedOutput(_ source: String) -> String {
        var result = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }

    private func finish(_ result: CourseCodeRunResult) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        view?.evaluateJavaScript("window.stopCourseRun?.()", completionHandler: nil)
        view?.configuration.userContentController.removeScriptMessageHandler(forName: "courseRun")
        view?.navigationDelegate = nil
        view?.stopLoading()
        view?.loadHTMLString("", baseURL: nil)
        view?.removeFromSuperview()
        view = nil
        continuation.resume(returning: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.navigationType == .other ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(CourseCodeRunResult(status: "runtimeError", stdout: "", stderr: WorkspaceLocalization.string("运行环境已停止，请缩小程序后重试。"), durationMs: 0))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(CourseCodeRunResult(status: "runtimeError", stdout: "", stderr: WorkspaceLocalization.string("暂时无法准备运行环境。"), durationMs: 0))
    }

    // Only the trusted outer page can talk to native code. The student's source
    // is data in a worker; none of it is interpolated into executable HTML.
    static func document(source: String, stdin: String, token: String) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: ["source": source, "stdin": stdin]))?.base64EncodedString() ?? ""
        let timeoutMessage = (try? JSONEncoder().encode(WorkspaceLocalization.string("运行超过 2 秒，已停止。")))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"Execution timed out.\""
        return #"""
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\#(token)' 'unsafe-eval'; worker-src blob:; connect-src 'none'; img-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <script nonce="\#(token)">
        (() => {
          const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\#(payload)'), c => c.charCodeAt(0))));
          const workerSource = `
            (() => {
              const send = self.postMessage.bind(self), start = performance.now();
              const output = {stdout:'',stderr:''}; let stopped = false;
              const limit = 16384;
              function finish(status) {
                if (stopped) return; stopped = true;
                send({status, ...output, durationMs:Math.min(12000,Math.round(performance.now()-start))});
                self.close();
              }
              function format(value) {
                if (typeof value === 'string') return value;
                try { return JSON.stringify(value) ?? String(value); } catch (_) { return String(value); }
              }
              function write(stream,args) {
                if (stopped) return;
                const text = args.map(format).join(' ')+'\\n';
                output[stream] += text.slice(0,Math.max(0,limit-output[stream].length));
                if (output[stream].length >= limit) finish('outputLimit');
              }
              const console = Object.freeze({log:(...v)=>write('stdout',v),info:(...v)=>write('stdout',v),
                warn:(...v)=>write('stderr',v),error:(...v)=>write('stderr',v),debug:(...v)=>write('stdout',v)});
              for (const key of ['fetch','XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker',
                'RTCPeerConnection','webkitRTCPeerConnection','indexedDB','caches','importScripts']) {
                try { Object.defineProperty(self,key,{value:undefined,writable:false,configurable:false}); } catch (_) {}
              }
              Object.defineProperty(self,'console',{value:console,writable:false,configurable:false});
              self.onmessage = async event => {
                const input = String(event.data.stdin), lines = input.replace(/\\r\\n?/g,'\\n').split('\\n'); let index=0;
                const readLine = () => index < lines.length ? lines[index++] : null;
                try {
                  const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
                  await new AsyncFunction('stdin','readLine','print',event.data.source)(input,readLine,(...v)=>write('stdout',v));
                  finish('completed');
                } catch (error) {
                  const message = String(error), stack = String(error?.stack || '');
                  write('stderr',[stack.includes(message) ? stack : message+'\\n'+stack]); finish('runtimeError');
                }
              };
            })();`;
          const url = URL.createObjectURL(new Blob([workerSource],{type:'text/javascript'}));
          let worker = new Worker(url), timer;
          URL.revokeObjectURL(url);
          function finish(result) {
            if (!worker) return;
            worker.terminate(); worker=null; clearTimeout(timer);
            window.webkit.messageHandlers.courseRun.postMessage({...result,token:'\#(token)'});
          }
          window.stopCourseRun = () => { worker?.terminate(); worker=null; clearTimeout(timer); };
          worker.onmessage = event => {
            const v=event.data;
            if (!['completed','runtimeError','timeout','outputLimit'].includes(v?.status)) return;
            const clip = value => new TextDecoder().decode(new TextEncoder().encode(String(value??'')).subarray(0,16384),{stream:true});
            finish({status:v.status,stdout:clip(v.stdout),stderr:clip(v.stderr),
              durationMs:Math.max(0,Math.min(12000,Math.round(Number(v.durationMs)||0)))});
          };
          worker.onerror = event => finish({status:'runtimeError',stdout:'',stderr:String(event.message).slice(0,16384),durationMs:0});
          timer=setTimeout(()=>finish({status:'timeout',stdout:'',stderr:\#(timeoutMessage),durationMs:2000}),2000);
          worker.postMessage(payload);
        })();
        </script>
        """#
    }
}

#if os(iOS)
struct CourseJavaScriptRunHost: UIViewRepresentable {
    let runner: CourseJavaScriptRunner
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        runner.attach(to: host)
        return host
    }
    func updateUIView(_ view: UIView, context: Context) { runner.attach(to: view) }
}
#elseif os(macOS)
struct CourseJavaScriptRunHost: NSViewRepresentable {
    let runner: CourseJavaScriptRunner
    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        runner.attach(to: host)
        return host
    }
    func updateNSView(_ view: NSView, context: Context) { runner.attach(to: view) }
}
#endif
