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
private final class GreenView: NSView {
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
private final class WebView: WKWebView, WKNavigationDelegate {
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
enum NativeView {
    private static var content: NativeContent?
    private static var views: [Int: NSView] = [:]
    private static weak var host: NSView?
    private static weak var emacsResponder: NSResponder?
    private static var keyMonitor: Any?

    /// Escape or C-g returns focus even when a WebKit child owns the keyboard.
    private static func returnFocus(from view: NSView) {
        guard let responder = view.window?.firstResponder as? NSView,
              responder === view || responder.isDescendant(of: view) else { return }
        view.window?.makeFirstResponder(emacsResponder)
    }

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
        guard let target = NSApp?.windows.first(where: { $0.title == title })?.contentView
        else { return false }
        destroy()
        host = target
        content = NativeContent()
        emacsResponder = target.window?.firstResponder
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                let controlG = event.modifierFlags.contains(.control)
                    && event.charactersIgnoringModifiers == "g"
                if event.keyCode == 53 || controlG {
                    for view in views.values where view is WebView && view.window === event.window {
                        if let responder = event.window?.firstResponder as? NSView,
                           responder === view || responder.isDescendant(of: view) {
                            returnFocus(from: view)
                            return true
                        }
                    }
                }
                return false
            }
            return handled ? nil : event
        }
        return true
    }

    /// Apply a complete layout measured from the top-left of Emacs's content area.
    /// An empty layout releases the views while retaining the buffer's content.
    static func setLayout(_ layout: [PaneLayout]) -> Bool {
        guard let host, let content else { return false }

        let wanted = Set(layout.map(\.id))
        for id in Set(views.keys).subtracting(wanted) {
            if let view = views.removeValue(forKey: id) {
                returnFocus(from: view)
                (view as? WKWebView)?.stopLoading()
                view.removeFromSuperview()
            }
        }
        for pane in layout {
            var frame = pane.rectangle
            frame.origin.x += host.bounds.minX
            frame.origin.y = host.isFlipped
                ? host.bounds.minY + pane.rectangle.minY
                : host.bounds.maxY - pane.rectangle.maxY

            if let child = views[pane.id], content.url != nil && !(child is WebView) {
                child.removeFromSuperview()
                views.removeValue(forKey: pane.id)
            }
            if let child = views[pane.id] {
                if child.frame != frame {
                    child.frame = frame
                    child.needsDisplay = true
                }
            } else {
                let child: NSView
                if let url = content.url {
                    child = WebView(frame: frame, url: url)
                } else {
                    child = GreenView(content: content, frame: frame)
                }
                host.addSubview(child)
                child.needsDisplay = true
                views[pane.id] = child
            }
        }
        return true
    }

    static func destroy() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for view in views.values {
            returnFocus(from: view)
            (view as? WKWebView)?.stopLoading()
            view.removeFromSuperview()
        }
        emacsResponder = nil
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
