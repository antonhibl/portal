// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit

@MainActor
private final class EditorView: WKWebView, NativeSurface {
    let toolbarModel: ToolbarModel? = ToolbarModel(.editor)
    weak var session: WebEditorSession?
    var nativeView: NSView { self }
    var input: NativeInput? { session?.input }
    func handleKeyEvent(_ event: NSEvent) -> Bool { input?.handleKeyEvent(event) ?? false }
}

/// One trusted local editor per document. Hiding a pane preserves its JS heap,
/// selection and undo history. Arbitrary browser previews never get this bridge.
@MainActor
private final class WebEditorSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
    WKUIDelegate {
    let id: Int
    let web: EditorView
    var host: NativeHost
    let url: URL
    private var messages: [[String: Any]] = []
    private var notified = false
    private var retry: Task<Void, Never>?
    lazy var input = NativeInput(target: "editor:\(id)", view: web, host: host) { [weak self] in
        self?.focus() ?? false
    }
    private var closed = false

    init(id: Int, host: NativeHost, url: URL) {
        self.id = id
        self.host = host
        self.url = url
        let configuration = WKWebViewConfiguration()
        // The document and its images belong to Emacs, never browser storage.
        configuration.websiteDataStore = .nonPersistent()
        web = EditorView(frame: .zero, configuration: configuration)
        super.init()
        web.session = self
        web.navigationDelegate = self
        web.uiDelegate = self
        configuration.userContentController.add(self, name: "portal")
        web.load(URLRequest(url: url))
    }

    func emit(_ message: [String: Any]) {
        guard !closed else { return }
        // Large scenes stay outside the pipe. A newer change supersedes an
        // undelivered change, but request replies and commands retain ordering.
        if message["type"] as? String == "change" {
            messages.removeAll { $0["type"] as? String == "change" }
        }
        messages.append(message)
        signal()
    }

    private func signal() {
        guard !notified, !closed else { return }
        if WebEditors.channel.notify("\(id)\n") {
            notified = true
            retry?.cancel()
            retry = nil
        } else if retry == nil {
            retry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { return }
                self.retry = nil
                self.signal()
            }
        }
    }

    func takeMessages() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: messages)
        messages.removeAll(keepingCapacity: true)
        notified = false
        return String(decoding: data, as: UTF8.self)
    }

    func send(_ json: String) throws {
        let message = try JSONSerialization.jsonObject(with: Data(json.utf8))
        web.callAsyncJavaScript("return await window.portalEditor.receive(message)",
                                arguments: ["message": message], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                self?.emit(["type": "error", "message": error.localizedDescription])
            }
        }
    }

    func layout(title: String, edges: [Int]) throws {
        if edges.isEmpty { host.hide(web); return }
        guard let nextHost = NativeHost.bind(title: title) else {
            throw NativeError.message("Cannot find the editor's Emacs frame")
        }
        if nextHost !== host { host.remove(web); host = nextHost; input.host = nextHost }
        let rectangle = CGRect(x: edges[0], y: edges[1],
                               width: edges[2] - edges[0], height: edges[3] - edges[1])
        guard host.place(web, rectangle: rectangle) else {
            throw NativeError.message("The editor's frame was deleted")
        }
    }

    func focus() -> Bool {
        !web.isHidden && (web.window?.makeFirstResponder(web) ?? false)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url == url,
              let body = message.body as? [String: Any],
              body["type"] is String, JSONSerialization.isValidJSONObject(body) else { return }
        // Save can prompt for a filename in Emacs. Unlike the native prefix path,
        // this request originates in JS, so focus has not yet left WebKit.
        if body["type"] as? String == "save" { host.returnFocus(from: web) }
        emit(body)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.targetFrame?.isMainFrame == true && action.request.url == url ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emit(["type": "error", "message": error.localizedDescription])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        emit(["type": "error", "message": "The editor process stopped. Reopen the editor to recover the buffered drawing."])
    }

    // Image insertion uses the native file picker; document open/save stays in Emacs.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = web.window else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    func close() {
        closed = true
        retry?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "portal")
        web.stopLoading()
        host.remove(web)
    }
}

@MainActor
enum WebEditors {
    static let channel = NativeEventChannel()
    private static var sessions: [Int: WebEditorSession] = [:]
    private static var nextID = 0

    static func open(title: String, address: String) throws -> Int {
        guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.path.hasSuffix("/excalidraw"),
              let host = NativeHost.bind(title: title) else {
            throw NativeError.message("Expected a local editor URL and a live Emacs frame")
        }
        nextID += 1
        sessions[nextID] = WebEditorSession(id: nextID, host: host, url: url)
        return nextID
    }

    static func layout(_ id: Int, title: String, edges: [Int]) throws {
        guard edges.isEmpty || (edges.count == 4 && edges[2] > edges[0] && edges[3] > edges[1]) else {
            throw NativeError.message("Expected [] or [LEFT TOP RIGHT BOTTOM] with positive dimensions")
        }
        try session(id).layout(title: title, edges: edges)
    }

    static func send(_ id: Int, json: String) throws { try session(id).send(json) }
    static func take(_ id: Int) throws -> String { try session(id).takeMessages() }
    static func focus(_ id: Int) throws {
        guard try session(id).focus() else { throw NativeError.message("No visible editor to focus") }
    }
    static func close(_ id: Int) { sessions.removeValue(forKey: id)?.close() }

    private static func session(_ id: Int) throws -> WebEditorSession {
        guard let session = sessions[id] else { throw NativeError.message("No native editor with this ID") }
        return session
    }
}
