// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The status panel, portal.h's portal_status_show and portal_status_hide: a
/// capsule with a line of text at the bottom center of a screen, above every
/// application's windows, on every Space and over fullscreen apps. It never
/// becomes key or main and ignores the mouse, and showing it never activates
/// Emacs, so the frontmost application keeps the keyboard.
@MainActor
enum StatusPanel {
    /// Space between the capsule and the bottom of the screen's usable area.
    static let margin: CGFloat = 48
    static let padding = NSSize(width: 16, height: 7)

    private(set) static var panel: Panel?

    final class Panel: NSPanel {
        let label = NSTextField(labelWithString: "")
        let background = NSVisualEffectView()

        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: true)
            isReleasedWhenClosed = false
            hidesOnDeactivate = false
            isFloatingPanel = true
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            ignoresMouseEvents = true
            tabbingMode = .disallowed
            animationBehavior = .none
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            background.material = .hudWindow
            background.blendingMode = .behindWindow
            background.state = .active
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            background.addSubview(label)
            contentView = background
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static func show(_ text: String) {
        let panel = panel ?? Panel()
        self.panel = panel
        panel.label.stringValue = text
        // A new status appears where the user is; an update stays put.
        let screen = panel.isVisible ? panel.screen : NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }
        guard let area = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let fitting = panel.label.fittingSize
        let size = NSSize(width: min(ceil(fitting.width) + 2 * padding.width, area.width - 2 * margin),
                          height: ceil(fitting.height) + 2 * padding.height)
        panel.setFrame(NSRect(x: floor(area.midX - size.width / 2), y: area.minY + margin,
                              width: size.width, height: size.height), display: false)
        panel.label.frame = NSRect(origin: .zero, size: size).insetBy(dx: padding.width, dy: padding.height)
        panel.background.maskImage = capsule(height: size.height)
        panel.orderFrontRegardless()
    }

    static func hide() { panel?.orderOut(nil) }

    /// A mask that rounds a rectangle HEIGHT high into a capsule at any width.
    private static func capsule(height: CGFloat) -> NSImage {
        let radius = height / 2
        let image = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
