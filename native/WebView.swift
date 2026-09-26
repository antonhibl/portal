// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit

@MainActor
private final class WebPage: WKWebView, WKNavigationDelegate, WKUIDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var input: NativeInput?
    private var controls: WebToolbar?
    var toolbarModel: ToolbarModel? { controls?.model }
    func handleKeyEvent(_ event: NSEvent) -> Bool { input?.handleKeyEvent(event) ?? false }

    var loadError: String?
    /// Whether this page shows a hosted app, which never leaves the app host.
    private let hosted: Bool
    /// The URL Emacs loaded last. A hosted app's app host is its origin.
    private(set) var address: URL?
    /// A hosted app's bridge, which hears about failures the app cannot report.
    weak var bridge: WebBridge?

    init(toolbar: ToolbarModel.Kind?, hosted: Bool) {
        self.hosted = hosted
        let configuration = WKWebViewConfiguration()
        if hosted { configuration.websiteDataStore = .nonPersistent() }
        super.init(frame: .zero, configuration: configuration)
        if let toolbar { controls = WebToolbar(web: self, kind: toolbar) }
        navigationDelegate = self
        uiDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    func navigate(to url: URL) {
        loadError = nil
        address = url
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    private static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? -1)"
    }

    /// A hosted app's main frame stays on the app host: any other page opens in
    /// the default browser instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard hosted, action.targetFrame?.isMainFrame ?? true, let url = action.request.url,
              url.scheme?.lowercased() != "about", Self.origin(url) != address.map(Self.origin) else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        WebSession.openInBrowser(url)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { controls?.loaded() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridge?.emit(["type": "error", "message": "The page's web process stopped."])
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
            bridge?.emit(["type": "error", "message": error.localizedDescription])
        }
    }
}

/// The message channel between a hosted app and its buffer. The app posts
/// JSON objects to `window.webkit.messageHandlers.portal`, and Emacs's messages
/// arrive through `window.portalBridge.receive`. Messages wait here, outside the
/// notification pipe, until Emacs receives them all; one `bridge TARGET` record
/// announces them, and no other goes out until Emacs has received them.
@MainActor
private final class WebBridge: NSObject, WKScriptMessageHandler {
    private let target: String
    private weak var page: WebPage?
    private var messages: [[String: Any]] = []
    private var notified = false
    private var retry: Task<Void, Never>?
    private var closed = false

    init(target: String, page: WebPage) {
        self.target = target
        self.page = page
        super.init()
        page.configuration.userContentController.add(self, name: "portal")
        page.bridge = self
    }

    /// Only the main frame, at the app-host URL Emacs loaded, may post.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let address = page?.address,
              message.frameInfo.request.url == address,
              let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body) else { return }
        emit(body)
    }

    func emit(_ message: [String: Any]) {
        guard !closed else { return }
        // Large payloads, such as Excalidraw scenes, stay out of the pipe. A
        // newer change supersedes one not yet received; all else keeps its order.
        if message["type"] as? String == "change" {
            messages.removeAll { $0["type"] as? String == "change" }
        }
        messages.append(message)
        signal()
    }

    /// Send the record, retrying while the pipe is full.
    private func signal() {
        guard !notified, !closed, !messages.isEmpty else { return }
        if Views.channel.notify("bridge", target: target) {
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

    /// Return every queued message as a JSON array, and allow the next record.
    func receive() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: messages)
        messages.removeAll(keepingCapacity: true)
        notified = false
        return String(decoding: data, as: UTF8.self)
    }

    func send(_ json: String) throws {
        guard let message = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NativeError.message("A bridge message must be a JSON object")
        }
        page?.callAsyncJavaScript("return await window.portalBridge.receive(message)",
                                  arguments: ["message": message], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                self?.emit(["type": "error", "message": error.localizedDescription])
            }
        }
    }

    func close() {
        closed = true
        retry?.cancel()
        page?.configuration.userContentController.removeScriptMessageHandler(forName: "portal")
    }
}

/// The web view kind: one WebKit page with its own browsing state. The page
/// stays loaded while the view is hidden, and its toolbar is fixed when it opens.
/// Only a hosted app has a bridge.
@MainActor
final class WebSession: PortalView {
    /// Where a hosted app's links to other sites go. Checks replace it.
    static var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private static let toolbars: [String: ToolbarModel.Kind?] = [
        "navigation": .web, "contents": .preview, "none": nil]
    private let target: String
    private let toolbarName: String
    private let page: WebPage
    private let bridge: WebBridge?
    private var host: NativeHost
    let input: NativeInput
    var toolbar: ToolbarModel? { page.toolbarModel }
    private var rectangle: CGRect
    private var edges: [Int] = []

    /// `:toolbar` is "navigation", "contents" or "none". With `:hosted`, the page
    /// keeps no data between sessions, never leaves the app host, and has a bridge.
    init(target: String, options: ViewOptions, parking: NativeHost) throws {
        guard let name = try options.string("toolbar"), let kind = Self.toolbars[name] else {
            throw NativeError.message("A web view's :toolbar must be \"navigation\", \"contents\" or \"none\"")
        }
        self.target = target
        toolbarName = name
        let hosted = options.flag("hosted")
        let page = WebPage(toolbar: kind, hosted: hosted)
        self.page = page
        bridge = hosted ? WebBridge(target: target, page: page) : nil
        host = parking
        rectangle = parking.view?.bounds ?? .zero
        input = NativeInput(target: target, view: page, host: parking) { [weak page] in
            guard let page, !page.isHidden else { return false }
            return page.window?.makeFirstResponder(page) ?? false
        }
        page.input = input
        try move(to: parking)
        hide(in: parking)
    }

    /// Remove the page from its current window and add it to NEXT's, in one step.
    private func move(to next: NativeHost) throws {
        if next !== host {
            host.remove(page)
            host = next
            input.host = next
        }
        guard next.place(page, rectangle: rectangle) else {
            throw NativeError.message("The web view's frame was deleted")
        }
    }

    func place(in host: NativeHost, rectangle: CGRect) throws {
        self.rectangle = rectangle
        try move(to: host)
        edges = [Int(rectangle.minX), Int(rectangle.minY), Int(rectangle.maxX), Int(rectangle.maxY)]
    }

    func hide(in parking: NativeHost) {
        edges = []
        try? move(to: parking)
        parking.hide(page)
    }

    func close() {
        bridge?.close()
        page.stopLoading()
        host.remove(page)
    }

    func load(_ address: String) throws {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "data", "about"].contains(scheme),
              !["http", "https"].contains(scheme) || !(url.host ?? "").isEmpty else {
            throw NativeError.message("Expected an absolute http, https, file, data or about URL")
        }
        page.navigate(to: url)
    }

    func send(_ json: String) throws { try hostedBridge().send(json) }

    func receive() throws -> String { try hostedBridge().receive() }

    private func hostedBridge() throws -> WebBridge {
        guard let bridge else { throw NativeError.message("Web view \(target) is not a hosted app, so it has no bridge") }
        return bridge
    }

    func inspect() -> [(String, ViewValue)] {
        var state: [(String, ViewValue)] = [
            ("visible", .flag(page.window != nil && !page.isHiddenOrHasHiddenAncestor)),
            ("focused", .flag(host.ownsFocus(page))),
            ("edges", .integers(edges)),
            ("toolbar", .string(toolbarName)),
            ("loading", .flag(page.isLoading))]
        if let url = page.url { state.append(("url", .string(url.absoluteString))) }
        if let title = page.title { state.append(("title", .string(title))) }
        if let error = page.loadError { state.append(("error", .string(error))) }
        return state
    }
}
