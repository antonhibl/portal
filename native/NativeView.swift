// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
private final class GreenContent {
    let color = NSColor.green
    let size: CGFloat = 32 // AppKit points, independent of the Retina scale.
}

@MainActor
private final class GreenView: NSView {
    let content: GreenContent

    init(content: GreenContent, frame: NSRect) {
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

struct PaneLayout: Sendable {
    let id: Int
    let rectangle: CGRect
}

struct ViewSnapshot: Sendable {
    let visible: Bool
    let edges: [Int]
    let windowNumber: Int
}

/// Owns shared content and one view per pane, without retaining Emacs values.
@MainActor
enum NativeView {
    private static var content: GreenContent?
    private static var views: [Int: GreenView] = [:]
    private static weak var host: NSView?

    /// Lisp briefly gives the requested frame a unique title, then restores it.
    static func bind(title: String) -> Bool {
        guard let target = NSApp?.windows.first(where: { $0.title == title })?.contentView
        else { return false }
        destroy()
        host = target
        content = GreenContent()
        return true
    }

    /// Apply a complete layout measured from the top-left of Emacs's content area.
    /// An empty layout releases the views while retaining the buffer's content.
    static func setLayout(_ layout: [PaneLayout]) -> Bool {
        guard let host, let content else { return false }

        let wanted = Set(layout.map(\.id))
        for id in Set(views.keys).subtracting(wanted) {
            views.removeValue(forKey: id)?.removeFromSuperview()
        }
        for pane in layout {
            var frame = pane.rectangle
            frame.origin.x += host.bounds.minX
            frame.origin.y = host.isFlipped
                ? host.bounds.minY + pane.rectangle.minY
                : host.bounds.maxY - pane.rectangle.maxY

            if let child = views[pane.id] {
                if child.frame != frame {
                    child.frame = frame
                    child.needsDisplay = true
                }
            } else {
                let child = GreenView(content: content, frame: frame)
                host.addSubview(child)
                child.needsDisplay = true
                views[pane.id] = child
            }
        }
        return true
    }

    static func destroy() {
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
        content = nil
        host = nil
    }

    /// Inspect the actual hierarchy, including any accidentally orphaned views.
    static func snapshots() -> [ViewSnapshot] {
        (NSApp?.windows ?? []).flatMap { window -> [ViewSnapshot] in
            guard let host = window.contentView else { return [] }
            return host.subviews.compactMap { child in
                guard child is GreenView else { return nil }
                let rect = child.convert(child.bounds, to: host)
                let left = rect.minX - host.bounds.minX
                let top = host.isFlipped
                    ? rect.minY - host.bounds.minY
                    : host.bounds.maxY - rect.maxY
                return ViewSnapshot(
                    visible: !child.isHiddenOrHasHiddenAncestor,
                    edges: [left, top, left + rect.width, top + rect.height].map { Int($0) },
                    windowNumber: window.windowNumber)
            }
        }
    }
}
