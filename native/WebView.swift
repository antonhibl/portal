// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit

@MainActor
private final class WebPage: WKWebView, WKNavigationDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var input: NativeInput?
    private var controls: WebToolbar?
    var toolbarModel: ToolbarModel? { controls?.model }
    func handleKeyEvent(_ event: NSEvent) -> Bool { input?.handleKeyEvent(event) ?? false }

    var loadError: String?

    init(toolbar: ToolbarModel.Kind?) {
        super.init(frame: .zero, configuration: WKWebViewConfiguration())
        if let toolbar { controls = WebToolbar(web: self, kind: toolbar) }
        navigationDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    func navigate(to url: URL) {
        loadError = nil
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
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

    private func record(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            loadError = error.localizedDescription
        }
    }
}

/// The web view kind: one WebKit page with its own browsing state. The page
/// stays loaded while the view is hidden, and its toolbar is fixed when it opens.
@MainActor
final class WebSession: PortalView {
    private static let toolbars: [String: ToolbarModel.Kind?] = [
        "navigation": .web, "contents": .preview, "none": nil]
    private let toolbar: String
    private let page: WebPage
    private var host: NativeHost
    private let input: NativeInput
    private var rectangle: CGRect
    private var edges: [Int] = []

    /// `:toolbar` is "navigation", "contents" or "none". `:hosted` is accepted,
    /// but has no effect yet.
    init(target: String, options: ViewOptions, parking: NativeHost) throws {
        guard let name = try options.string("toolbar"), let kind = Self.toolbars[name] else {
            throw NativeError.message("A web view's :toolbar must be \"navigation\", \"contents\" or \"none\"")
        }
        toolbar = name
        let page = WebPage(toolbar: kind)
        self.page = page
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

    func inspect() -> [(String, ViewValue)] {
        var state: [(String, ViewValue)] = [
            ("visible", .flag(page.window != nil && !page.isHiddenOrHasHiddenAncestor)),
            ("focused", .flag(host.ownsFocus(page))),
            ("edges", .integers(edges)),
            ("toolbar", .string(toolbar)),
            ("loading", .flag(page.isLoading))]
        if let url = page.url { state.append(("url", .string(url.absoluteString))) }
        if let title = page.title { state.append(("title", .string(title))) }
        if let error = page.loadError { state.append(("error", .string(error))) }
        return state
    }
}
