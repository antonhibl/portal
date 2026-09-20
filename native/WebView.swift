// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit

@MainActor
private final class NativeContent {
    var url: URL?
    let color = NSColor.green
    let size: CGFloat = 32 // AppKit points, independent of the Retina scale.
}

@MainActor
private final class GreenView: NSView, NativeSurface {
    var nativeView: NSView { self }
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    let content: NativeContent

    init(content: NativeContent, frame: NSRect) {
        self.content = content
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let square = NSRect(x: bounds.midX - content.size / 2,
                            y: bounds.midY - content.size / 2,
                            width: content.size, height: content.size)
        content.color.setFill()
        // AppKit can invalidate an area larger than this view's bounds.
        square.intersection(bounds).intersection(dirtyRect).fill()
    }

    // Leave mouse and keyboard handling with Emacs.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A separate browsing session per pane; the buffer shares only its requested URL.
@MainActor
private final class WebView: WKWebView, WKNavigationDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var host: NativeHost?

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let controlG = event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "g"
        guard event.keyCode == 53 || controlG else { return false }
        host?.returnFocus(from: self)
        return true
    }

    var loadError: String?

    init(frame: NSRect, url: URL) {
        super.init(frame: frame, configuration: WKWebViewConfiguration())
        navigationDelegate = self
        navigate(to: url)
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
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    private func record(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            loadError = error.localizedDescription
        }
    }
}

struct PaneLayout: Sendable {
    let id: Int
    let rectangle: CGRect
}

struct ViewSnapshot: Sendable {
    let visible: Bool
    let edges: [Int]
    let windowNumber: Int
    let url: String?
    let title: String?
    let loading: Bool
    let error: String?
}

/// Owns shared content and one view per pane, without retaining Emacs values.
@MainActor
enum WebViews {
    private static var content: NativeContent?
    private static var views: [Int: any NativeSurface] = [:]
    private static var host: NativeHost?

    static func loadURL(_ text: String) -> Bool {
        guard let content, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "data", "about"].contains(scheme),
              !["http", "https"].contains(scheme) || !(url.host ?? "").isEmpty
        else { return false }
        content.url = url
        for view in views.values {
            (view as? WebView)?.navigate(to: url)
        }
        return true
    }

    /// Lisp briefly gives the requested frame a unique title, then restores it.
    static func bind(title: String) -> Bool {
        guard let host = NativeHost.bind(title: title) else { return false }
        destroy()
        self.host = host
        content = NativeContent()
        return true
    }

    /// Apply a complete layout measured from the top-left of Emacs's content area.
    /// An empty layout releases the views while retaining the buffer's content.
    static func setLayout(_ layout: [PaneLayout]) -> Bool {
        guard let host, let content else { return false }

        let wanted = Set(layout.map(\.id))
        for id in Set(views.keys).subtracting(wanted) {
            if let view = views.removeValue(forKey: id) {
                (view as? WKWebView)?.stopLoading()
                host.remove(view)
            }
        }
        for pane in layout {
            if let child = views[pane.id], content.url != nil && !(child is WebView) {
                host.remove(child)
                views.removeValue(forKey: pane.id)
            }
            let child: any NativeSurface
            if let existing = views[pane.id] {
                child = existing
            } else if let url = content.url {
                let web = WebView(frame: .zero, url: url)
                web.host = host
                child = web
                views[pane.id] = child
            } else {
                child = GreenView(content: content, frame: .zero)
                views[pane.id] = child
            }
            guard host.place(child, rectangle: pane.rectangle) else { return false }
            child.nativeView.needsDisplay = true
        }
        return true
    }

    static func destroy() {
        for view in views.values {
            (view as? WKWebView)?.stopLoading()
            host?.remove(view)
        }
        views.removeAll()
        content = nil
        host = nil
    }

    /// Inspect the actual hierarchy, including any accidentally orphaned views.
    static func snapshots() -> [ViewSnapshot] {
        (NSApp?.windows ?? []).flatMap { window -> [ViewSnapshot] in
            guard let host = window.contentView else { return [] }
            return host.subviews.compactMap { child in
                guard child is GreenView || child is WebView else { return nil }
                let rect = child.convert(child.bounds, to: host)
                let left = rect.minX - host.bounds.minX
                let top = host.isFlipped
                    ? rect.minY - host.bounds.minY
                    : host.bounds.maxY - rect.maxY
                return ViewSnapshot(
                    visible: !child.isHiddenOrHasHiddenAncestor,
                    edges: [left, top, left + rect.width, top + rect.height].map { Int($0) },
                    windowNumber: window.windowNumber,
                    url: (child as? WebView)?.url?.absoluteString,
                    title: (child as? WebView)?.title,
                    loading: (child as? WebView)?.isLoading ?? false,
                    error: (child as? WebView)?.loadError)
            }
        }
    }
}
