// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore
import WebKit

/// How Emacs answered a page's request (portal_web_answer): the core has
/// checked that its JSON is true, false, null or a string.
private enum Answer: Sendable {
    case yes, no, cancelled
    case text(String)

    init(json: String) throws {
        switch json {
        case "true": self = .yes
        case "false": self = .no
        case "null": self = .cancelled
        default:
            guard let text = try JSONSerialization.jsonObject(with: Data(json.utf8),
                                                              options: .fragmentsAllowed) as? String else {
                throw NativeError.message("An answer must be JSON true, false, null or a string")
            }
            self = .text(text)
        }
    }
}

/// Windows that pages opened, waiting for Emacs to show each in a buffer of
/// its own, which adopts it with the :window option, or to discard it.
/// WebKit made each page related to its opener, so `window.opener` and
/// `postMessage` work as sign-in pop-ups expect. One Emacs never adopts goes
/// after a minute.
@MainActor
private enum OpenedWindows {
    private static var waiting: [String: WebPage] = [:]
    private static var count: UInt64 = 0

    static func keep(_ page: WebPage) -> String {
        count += 1
        let name = "window-\(count)"
        waiting[name] = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            MainActor.assumeIsolated { discard(name) }
        }
        return name
    }

    static func take(_ name: String) -> WebPage? { waiting.removeValue(forKey: name) }

    static func discard(_ name: String) { waiting.removeValue(forKey: name)?.end() }
}

/// One WebKit page. It loads what the core decides and reports what the page
/// does: its navigations, commits, loads, history and failures, and a hosted
/// app's messages. What the page asks its buffer for, such as an alert, a
/// confirmation or a new window, goes to Emacs as a request, and the page
/// waits for the answer.
@MainActor
private final class WebPage: WKWebView, WKNavigationDelegate, WKUIDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var input: NativeInput?
    private var toolbar: WebToolbar?
    private var observations: [NSKeyValueObservation] = []

    /// The core decides what each key does: the page gets typing, and is
    /// offered each chord (`offer`), which the toolbar's Command-F or Emacs
    /// gets if the page does not use it.
    func handleKeyEvent(_ event: NSEvent) -> Bool { input?.handleKeyEvent(event) == true }

    /// A page focusing an element, as autofocus does, makes WebKit ask the
    /// window to make the page first responder, even while Emacs or another
    /// view has the keyboard. The page gets it only from its input: from
    /// Emacs, the core, or the user's click.
    override func becomeFirstResponder() -> Bool {
        guard input?.mayTakeKeyboard == true else { return false }
        return super.becomeFirstResponder()
    }

    /// The press offered to the page, until it answers, and whether the key
    /// script has seen it reach the page.
    private var offered: NSEvent?
    private var seen = false
    private var offerTimer: Timer?

    /// Give the page EVENT, a key press the core offers it, and tell the input
    /// whether the page used it. WebKit hands back a press the page did not
    /// use, which the input sees again. It is known to have used one once the
    /// key script (`KeyReports`) reports the press reached the page, and
    /// WebKit has then finished with every key it had: typed into editable
    /// content, a press reaches WebKit's queue only after the input method
    /// is done with it. A page that never answers used the press if it saw
    /// it, as when the page hangs in its handler; if not, as when the view
    /// has no page yet, the press was never the page's.
    func offer(_ event: NSEvent) {
        offered = event
        seen = false
        offerTimer?.invalidate()
        offerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let event = self.offered else { return }
                self.answer(event, used: self.seen)
            }
        }
        keyDown(with: event)
    }

    /// The key script saw a press with these modifiers reach the page.
    fileprivate func saw(control: Bool, option: Bool, command: Bool) {
        guard let event = offered, !seen else { return }
        let flags = event.modifierFlags
        guard flags.contains(.control) == control, flags.contains(.option) == option,
              flags.contains(.command) == command else { return }
        seen = true
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
        guard responds(to: selector) else { return answer(event, used: true) }
        let done: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.answer(event, used: true) }
        }
        perform(selector, with: unsafeBitCast(done, to: AnyObject.self))
    }

    /// The page USED EVENT, or not, unless WebKit already handed it back.
    private func answer(_ event: NSEvent, used: Bool) {
        guard offered === event else { return }
        offered = nil
        offerTimer?.invalidate()
        offerTimer = nil
        input?.settle(event, used: used)
    }

    var loadError: String?
    /// The view's target, which names it in every call to the core: "" for
    /// a window a page opened, until a view adopts it (`adopt`).
    private(set) var target: String
    /// Whether a view shows this page, so the core knows its target.
    private var adopted: Bool
    private let hosted: Bool

    /// The requests the page waits on, by ID, and the windows it opened that
    /// no view has adopted yet, by the request that announced them.
    private var requests: UInt64 = 0
    private var waiting: [UInt64: CheckedContinuation<Answer, Never>] = [:]
    private var windows: [UInt64: String] = [:]

    /// With CONTENTS, the page runs the contents script for its toolbar. With
    /// CONFIGURATION, the one WebKit gave for a window a page opens, the page
    /// is that window, which waits for a view to adopt it.
    init(target: String, contents: Bool, hosted: Bool, configuration opened: WKWebViewConfiguration? = nil) {
        self.target = target
        self.hosted = hosted
        adopted = opened == nil
        let configuration = opened ?? WKWebViewConfiguration()
        if hosted { configuration.websiteDataStore = .nonPersistent() }
        // The opener's configuration carries its script handlers, which name
        // the opener; this page installs its own.
        if opened != nil { configuration.userContentController = WKUserContentController() }
        super.init(frame: .zero, configuration: configuration)
        if contents { toolbar = WebToolbar(web: self, target: target) }
        if hosted { PageMessages.install(in: self) }
        KeyReports.install(in: self)
        navigationDelegate = self
        uiDelegate = self
        observations = [observe(\.canGoBack) { page, _ in
            MainActor.assumeIsolated { page.historyChanged() }
        }, observe(\.canGoForward) { page, _ in
            MainActor.assumeIsolated { page.historyChanged() }
        }]
    }

    private func historyChanged() { Core.history(target, back: canGoBack, forward: canGoForward) }

    /// Become TARGET's page, a window that a page opened. The core learns of
    /// the view after it is made, so the page reports what it already did
    /// once the current call returns.
    func adopt(_ target: String) {
        self.target = target
        adopted = true
        toolbar?.target = target
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let url = self.url { Core.committed(target, url: url.absoluteString) }
                self.historyChanged()
                if !self.isLoading { Core.loaded(target) }
            }
        }
    }

    /// End the page: answer whatever it waits on as if cancelled, discard
    /// the windows it opened that no view adopted, and stop it.
    func end() {
        for (_, continuation) in waiting { continuation.resume(returning: .cancelled) }
        waiting = [:]
        for (_, window) in windows { OpenedWindows.discard(window) }
        windows = [:]
        configuration.userContentController.removeAllScriptMessageHandlers()
        stopLoading()
    }

    /// The next request's ID.
    private func nextRequest() -> UInt64 {
        requests += 1
        return requests
    }

    /// Ask Emacs REQUEST, an alert, confirmation or prompt, and wait for its
    /// answer. A window no view has adopted yet has no buffer to ask.
    private func ask(_ request: [String: Any]) async -> Answer {
        guard adopted else { return .cancelled }
        return await withCheckedContinuation { continuation in
            let id = nextRequest()
            waiting[id] = continuation
            var request = request
            request["id"] = id
            Core.requested(target, request)
        }
    }

    /// Emacs answered request ID: a dialog it waits on, or a window it opened,
    /// which false discards.
    func respond(_ id: UInt64, _ answer: Answer) throws {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(returning: answer)
        } else if let window = windows.removeValue(forKey: id) {
            if case .no = answer { OpenedWindows.discard(window) }
        } else {
            throw NativeError.message("The page is not waiting on request \(id)")
        }
    }

    /// Where a dialog comes from, for Emacs to show: its frame's origin.
    private func origin(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty else { return origin.protocol }
        return origin.port == 0 ? "\(origin.protocol)://\(origin.host)"
            : "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(["type": "alert", "message": message, "origin": origin(frame)])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        if case .yes = await ask(["type": "confirm", "message": message, "origin": origin(frame)]) {
            return true
        }
        return false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await ask(["type": "prompt", "message": prompt, "default": defaultText ?? "",
                                "origin": origin(frame)])
        if case .text(let text) = answer { return text }
        return nil
    }

    /// A page opens a window, with `window.open` or a link to a new one.
    /// WebKit has already asked the core whether it may navigate there.  The
    /// window is a new page, related to this one, which waits for Emacs to
    /// show it in a buffer of its own.  A hosted app opens none.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard adopted, !hosted else { return nil }
        let opened = WebPage(target: "", contents: true, hosted: false, configuration: configuration)
        let window = OpenedWindows.keep(opened)
        let id = nextRequest()
        windows[id] = window
        var request: [String: Any] = ["id": id, "type": "popup", "window": window]
        if let url = action.request.url?.absoluteString, !url.isEmpty { request["url"] = url }
        Core.requested(target, request)
        return opened
    }

    /// The page closes its window, as a sign-in pop-up does when it is done.
    func webViewDidClose(_ webView: WKWebView) {
        guard adopted else { return }
        Core.requested(target, ["id": nextRequest(), "type": "close"])
    }

    /// Follows the system's appearance while the page shows it.
    private var system: NSKeyValueObservation?

    /// Show the page in APPEARANCE, which WebKit gives it as
    /// prefers-color-scheme. The view's own appearance overrides its
    /// window's, which an Emacs frame may force, so even the system's is set
    /// here, and again whenever it changes.
    func show(_ choice: portal_appearance) {
        system = nil
        switch choice {
        case PORTAL_APPEARANCE_LIGHT: appearance = NSAppearance(named: .aqua)
        case PORTAL_APPEARANCE_DARK: appearance = NSAppearance(named: .darkAqua)
        default:
            showSystem()
            system = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.showSystem() }
            }
        }
    }

    /// NSApp's appearance is the system's: Emacs sets only its windows'.
    private func showSystem() {
        appearance = NSAppearance(named: NSApp.effectiveAppearance.isDark ? .darkAqua : .aqua)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Core.loaded(target) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let offered { answer(offered, used: seen) }
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

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The key script, in every frame of every page, in its own world out of the
/// page's reach. It reports each real key press with Control, Option or
/// Command that reaches the page, before the page's own handlers see it, so
/// a page knows when a press offered to it has arrived (`WebPage.offer`).
@MainActor
private final class KeyReports: NSObject, WKScriptMessageHandler {
    private static let script = """
        addEventListener("keydown", (event) => {
          if (event.isTrusted && (event.ctrlKey || event.altKey || event.metaKey)
              && !["Control", "Alt", "Meta", "Shift", "CapsLock", "Fn", "AltGraph"].includes(event.key))
            window.webkit.messageHandlers.key.postMessage([event.ctrlKey, event.altKey, event.metaKey]);
        }, true);
        """
    private weak var page: WebPage?

    static func install(in page: WebPage) {
        let reports = KeyReports()
        reports.page = page
        let world = WKContentWorld.world(name: "portal-keys")
        let controller = page.configuration.userContentController
        controller.add(reports, contentWorld: world, name: "key")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let flags = message.body as? [Bool], flags.count == 3 else { return }
        page?.saw(control: flags[0], option: flags[1], command: flags[2])
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
        let links = WKContentWorld.portal(PORTAL_SCRIPT_LINKS)
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
/// stays loaded while the view is hidden. The core decides what it loads,
/// where it may go and what its toolbar shows, and keeps a hosted app's
/// bridge (native/Core/web.c, toolbar.c).
@MainActor
final class WebSession: PortalView {
    /// Where a hosted app's links to other sites go. Checks replace it.
    static var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private let page: WebPage
    var surface: any NativeSurface { page }
    let input: NativeInput

    /// A view with a `:toolbar`, which the core has checked, runs the contents
    /// script. With `:hosted`, the page keeps no data between sessions and
    /// gets the bridge's scripts. With `:window`, the view adopts the window
    /// a page opened, which runs the contents script whatever its toolbar.
    /// It starts in its `:appearance`, which the core has checked too.
    init(target: String, options: ViewOptions) throws {
        let toolbar = try options.string("toolbar").map { $0 != "none" } ?? false
        let hosted = options.flag("hosted")
        let page: WebPage
        if let window = try options.string("window") {
            guard !hosted, let opened = OpenedWindows.take(window) else {
                throw NativeError.message("The window \(window) has closed")
            }
            page = opened
            page.adopt(target)
        } else {
            page = WebPage(target: target, contents: toolbar, hosted: hosted)
        }
        let appearance = switch try options.string("appearance") {
        case "light": PORTAL_APPEARANCE_LIGHT
        case "dark": PORTAL_APPEARANCE_DARK
        default: PORTAL_APPEARANCE_SYSTEM
        }
        page.show(appearance)
        self.page = page
        input = NativeInput(target: target, view: page, host: NativeView.parking) { [weak page] in
            guard let page, !page.isHidden else { return false }
            return page.window?.makeFirstResponder(page) ?? false
        }
        page.input = input
        input.offer = { [weak page] event in page?.offer(event) }
    }

    func close() { page.end() }

    /// Emacs answered the page's request ID with ANSWER, JSON the core checked.
    func answer(_ id: UInt64, json: String) throws { try page.respond(id, Answer(json: json)) }

    func load(_ address: String) throws {
        guard let url = URL(string: address) else { throw NativeError.message("WebKit cannot parse the URL \(address)") }
        page.open(url)
    }

    func go(_ step: portal_history) { page.go(step) }

    func post(_ json: String, token: UInt64) throws { try page.post(json, token: token) }

    func zoom(_ scale: Double) { page.pageZoom = scale }

    func copy() throws { NSApp.sendAction(#selector(NSText.copy(_:)), to: keyboard, from: nil) }

    func paste() throws { NSApp.sendAction(#selector(NSText.paste(_:)), to: keyboard, from: nil) }

    /// Where the view's keyboard input goes: the page, or its find field.
    private var keyboard: NSResponder {
        input.host.ownsFocus(page) ? page.window?.firstResponder ?? page : page
    }

    func show(_ appearance: portal_appearance) { page.show(appearance) }

    func find(_ query: String, backwards: Bool, token: UInt64) {
        WebToolbar.find(page, target: page.target, query: query, backwards: backwards, token: token)
    }

    func call(_ script: portal_script, function: String, argument: String, token: UInt64) throws {
        try WebToolbar.call(page, target: page.target, script: script, function: function,
                            argument: argument, token: token)
    }

    func describe() -> [(String, ViewValue)] {
        var state: [(String, ViewValue)] = [("loading", .flag(page.isLoading)),
                                            ("dark", .flag(page.effectiveAppearance.isDark))]
        if let url = page.url { state.append(("url", .string(url.absoluteString))) }
        if let title = page.title { state.append(("title", .string(title))) }
        if let error = page.loadError { state.append(("error", .string(error))) }
        return state
    }
}
