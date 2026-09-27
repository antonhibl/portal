// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore
import WebKit

/// One WebKit page. It loads what the core decides and reports what the page
/// does: its navigations, commits and failures, and a hosted app's messages.
@MainActor
private final class WebPage: WKWebView, WKNavigationDelegate, WKUIDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var input: NativeInput?
    private var controls: WebToolbar?
    var toolbarModel: ToolbarModel? { controls?.model }

    /// Command-F opens the toolbar's find field, as in a browser. Without a
    /// visible toolbar, or in passthrough, the page gets the key.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if input?.handleKeyEvent(event) == true { return true }
        guard event.type == .keyDown, input?.ownership == .view,
              event.modifierFlags.intersection(NativeInput.modifiers) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "f",
              let model = toolbarModel, (try? model.perform("find")) != nil else { return false }
        return true
    }

    var loadError: String?
    /// The view's target, which names it in every call to the core.
    let target: String

    init(target: String, toolbar: ToolbarModel.Kind?, hosted: Bool) {
        self.target = target
        let configuration = WKWebViewConfiguration()
        if hosted { configuration.websiteDataStore = .nonPersistent() }
        super.init(frame: .zero, configuration: configuration)
        if let toolbar { controls = WebToolbar(web: self, kind: toolbar) }
        if hosted { PageMessages.install(in: self) }
        navigationDelegate = self
        uiDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// Load URL as a new document; a local file may read its directory.
    func open(_ url: URL) {
        loadError = nil
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    func go(_ step: portal_history) {
        switch step {
        case PORTAL_BACK: goBack()
        case PORTAL_FORWARD: goForward()
        default:
            loadError = nil
            reload()
        }
    }

    /// Pass MESSAGE, a JSON object, to the page's `portalBridge.receive` as
    /// data. A failure reaches the core with TOKEN, which tells it apart from
    /// failures on a later page.
    func post(_ json: String, token: UInt64) throws {
        guard let message = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NativeError.message("A bridge message must be a JSON object")
        }
        callAsyncJavaScript("return await window.portalBridge.receive(message)",
                            arguments: ["message": message], in: nil, in: .page) { [target] result in
            if case .failure(let error) = result {
                Core.failed(target, token: token, message: error.localizedDescription)
            }
        }
    }

    /// Ask the core whether the page may go to URL, and act on its answer:
    /// true to go on. It hands local files to Emacs itself.
    func mayNavigate(to url: URL, mainFrame: Bool) -> Bool {
        switch Core.navigating(target, url: url.absoluteString, mainFrame: mainFrame) {
        case .allow: return true
        case .external: WebSession.openInBrowser(url)
        case .emacs: break
        }
        return false
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        // A request for a new window counts as the main frame.
        decisionHandler(mayNavigate(to: url, mainFrame: action.targetFrame?.isMainFrame ?? true) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        controls?.model.hasHeadings = false
        controls?.model.changed?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    /// Every page the view commits, including after back and forward.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url { Core.committed(target, url: url.absoluteString) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { controls?.loaded() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Core.failed(target, token: 0, message: "The page's web process stopped.")
    }

    // File inputs, such as inserting an image, use the native file picker.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func record(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            loadError = error.localizedDescription
            Core.failed(target, token: 0, message: error.localizedDescription)
        }
    }
}

/// A hosted app's two script message handlers. The page's world gets the
/// bridge: bootstrap glue defines `portalBridge.postMessage`, the one place
/// a hosted app's messages meet WebKit's transport. An isolated world, out
/// of the page's reach, runs the core's shared links script, which reports
/// clicks on links to local files: WebKit never lets a page on the app host
/// navigate to a file: URL, and does not ask the navigation delegate either.
/// The core judges both by what WebKit says about the sending frame.
@MainActor
private final class PageMessages: NSObject, WKScriptMessageHandler {
    private static let links = WKContentWorld.world(name: "Portal links")
    private static let bridge = """
        window.portalBridge = {
          postMessage: (message) => window.webkit.messageHandlers.portal.postMessage(message),
        };
        """
    private weak var page: WebPage?

    static func install(in page: WebPage) {
        let messages = PageMessages()
        messages.page = page
        let controller = page.configuration.userContentController
        controller.add(messages, contentWorld: .page, name: "portal")
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.add(messages, contentWorld: links, name: "follow")
        controller.addUserScript(WKUserScript(source: Core.script(PORTAL_SCRIPT_LINKS, handler: "follow"),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                              in: links))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let page else { return }
        let mainFrame = message.frameInfo.isMainFrame
        if message.name == "follow" {
            guard let text = message.body as? String, let url = URL(string: text) else { return }
            // The script cancelled the click, so an allowed link loads here.
            if page.mayNavigate(to: url, mainFrame: mainFrame) { page.open(url) }
        } else if let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body),
                  let json = try? JSONSerialization.data(withJSONObject: body) {
            Core.posted(page.target, mainFrame: mainFrame,
                        url: message.frameInfo.request.url?.absoluteString ?? "",
                        type: body["type"] as? String ?? "", json: String(decoding: json, as: UTF8.self))
        }
    }
}

/// The web view kind: one WebKit page with its own browsing state. The page
/// stays loaded while the view is hidden, and its toolbar is fixed when it
/// opens. The core decides what it loads and where it may go, and keeps a
/// hosted app's bridge (native/Core/web.c).
@MainActor
final class WebSession: PortalView {
    /// Where a hosted app's links to other sites go. Checks replace it.
    static var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private static let toolbars: [String: ToolbarModel.Kind?] = [
        "navigation": .web, "contents": .preview, "markdown": .preview, "none": nil]
    private let toolbarName: String
    private let page: WebPage
    var surface: any NativeSurface { page }
    let input: NativeInput
    var toolbar: ToolbarModel? { page.toolbarModel }

    /// `:toolbar` is "navigation", "contents", "markdown" or "none"; "markdown"
    /// is "contents" with Open in Emacs when `:hosted`. With `:hosted`, the page
    /// keeps no data between sessions and gets the bridge's scripts.
    init(target: String, options: ViewOptions) throws {
        guard let name = try options.string("toolbar"), let kind = Self.toolbars[name] else {
            throw NativeError.message(
                "A web view's :toolbar must be \"navigation\", \"contents\", \"markdown\" or \"none\"")
        }
        toolbarName = name
        let hosted = options.flag("hosted")
        let page = WebPage(target: target, toolbar: kind, hosted: hosted)
        self.page = page
        if hosted && name == "markdown" { page.toolbarModel?.edit = { Core.edit(target) } }
        input = NativeInput(target: target, view: page, host: NativeView.parking) { [weak page] in
            guard let page, !page.isHidden else { return false }
            return page.window?.makeFirstResponder(page) ?? false
        }
        page.input = input
    }

    func close() {
        page.configuration.userContentController.removeAllScriptMessageHandlers()
        page.stopLoading()
    }

    func load(_ address: String) throws {
        guard let url = URL(string: address) else { throw NativeError.message("WebKit cannot parse the URL \(address)") }
        page.open(url)
    }

    func go(_ step: portal_history) { page.go(step) }

    func post(_ json: String, token: UInt64) throws { try page.post(json, token: token) }

    func describe() -> [(String, ViewValue)] {
        var state: [(String, ViewValue)] = [
            ("toolbar", .string(toolbarName)),
            ("loading", .flag(page.isLoading))]
        if let url = page.url { state.append(("url", .string(url.absoluteString))) }
        if let title = page.title { state.append(("title", .string(title))) }
        if let error = page.loadError { state.append(("error", .string(error))) }
        return state
    }
}
