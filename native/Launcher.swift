// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Compatibility with GNU Emacs NS 31.1, a360712c9d272d950d8d8255ef74570f7e90b7d9.
/// No forwarding, class replacement, private frame layout, or second module.
/// The original window must keep its delegate: setAppearance reads its frame.
@MainActor
final class LauncherPanel: NSPanel {
    let donor: NSWindow
    @objc var lastDragEvent: NSEvent?

    init(donor: NSWindow) {
        self.donor = donor
        super.init(contentRect: donor.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        tabbingMode = .disallowed
        isOpaque = false
        backgroundColor = donor.backgroundColor
        appearance = donor.appearance
        acceptsMouseMovedEvents = true
        title = donor.title
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    @objc func borderWidth() -> Int { Int(frame.width - (contentView?.frame.width ?? 0)) }

    @objc(setAppearance) func applyEmacsAppearance() {
        _ = donor.perform(NSSelectorFromString("setAppearance"))
        appearance = donor.appearance
    }

    override func accessibilityValue() -> Any? {
        donor.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXValue")?.takeUnretainedValue()
    }

    @objc(restackWindow:above:) func restack(_ window: NSWindow, above: Bool) -> Bool {
        guard parent === window.parent else { return false }
        order(above ? .above : .below, relativeTo: window.windowNumber)
        return true
    }

    @objc(mustNotDropOn:) func mustNotDrop(on receiver: NSView) -> Bool { false }

    // System drag-and-drop out of the launcher is unsupported; cancel safely.
    @objc(beginDrag:forPasteboard:withMode:returnFrameTo:prohibitSame:followTooltip:)
    func beginDrag(_ operation: UInt, pasteboard: NSPasteboard, mode: Int32,
                   frame: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                   prohibitSame: Bool, followTooltip: Bool) -> UInt {
        frame?.pointee = nil
        return 0
    }
}

/// One dedicated Emacs frame. Lisp owns creation/deletion; this owns its native
/// attachment until Lisp's pre-deletion hook restores the original window.
@MainActor
final class NativeLauncher {
    static var attached: NativeLauncher?
    let panel: LauncherPanel
    private let content: NSView
    private let editor: NSView
    private let delegate: any NSWindowDelegate
    private let wantedLayer: Bool
    private let cornerRadius: CGFloat
    private let masksToBounds: Bool
    private var displayObserver: NSObjectProtocol?
    private var placement: Placement?
    private var requested = NSRect.zero

    struct Placement {
        let width: Int64, height: Int64, dx: Int64, dy: Int64, screen: Int64
        let shadow: Bool
        let radius: Int64
    }

    static func attach(title: String) throws {
        guard attached == nil else { throw NativeError.message("Portal launcher is already attached") }
        guard let donor = NSApp?.windows.first(where: { $0.title == title }),
              let windowClass = NSClassFromString("EmacsWindow"), donor.isKind(of: windowClass),
              let viewClass = NSClassFromString("EmacsView"),
              let editor = donor.delegate as? NSView, editor.isKind(of: viewClass),
              let delegate = donor.delegate, let content = donor.contentView,
              editor === content || editor.isDescendant(of: content),
              !donor.isVisible, donor.parent == nil, donor.childWindows?.isEmpty != false,
              !donor.styleMask.contains(.titled), !donor.styleMask.contains(.fullScreen),
              donor.toolbar == nil, donor.responds(to: NSSelectorFromString("setAppearance")) else {
            throw NativeError.message("Portal launcher needs a new hidden, undecorated GNU Emacs NS frame")
        }
        let launcher = NativeLauncher(donor: donor, content: content, editor: editor, delegate: delegate)
        // Nothing can throw after the move except the responder check; roll that
        // back before releasing any state. Never leave an EmacsView orphaned.
        donor.contentView = NSView(frame: .zero)
        launcher.panel.contentView = content
        launcher.panel.delegate = delegate
        guard launcher.panel.makeFirstResponder(editor), launcher.panel.firstResponder === editor,
              editor.window === launcher.panel else {
            launcher.detach()
            throw NativeError.message("Cannot give the launcher Emacs's content view")
        }
        attached = launcher
        launcher.displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak launcher] _ in
            MainActor.assumeIsolated {
                guard let launcher, launcher.panel.isVisible, let placement = launcher.placement else { return }
                try? launcher.place(placement, present: false)
            }
        }
    }

    private init(donor: NSWindow, content: NSView, editor: NSView, delegate: any NSWindowDelegate) {
        panel = LauncherPanel(donor: donor)
        self.content = content
        self.editor = editor
        self.delegate = delegate
        wantedLayer = content.wantsLayer
        cornerRadius = content.layer?.cornerRadius ?? 0
        masksToBounds = content.layer?.masksToBounds ?? false
    }

    /// AppKit points, bottom-left global origin. Offset is right/down from the
    /// usable area's center. Clamp before placement; never scale to device pixels.
    static func rectangle(_ placement: Placement, in area: NSRect) -> NSRect {
        let width = min(CGFloat(placement.width), area.width)
        let height = min(CGFloat(placement.height), area.height)
        let x = floor(area.midX - width / 2 + CGFloat(placement.dx))
        let y = floor(area.midY - height / 2 - CGFloat(placement.dy))
        return NSRect(x: min(max(x, area.minX), area.maxX - width),
                      y: min(max(y, area.minY), area.maxY - height), width: width, height: height)
    }

    func place(_ placement: Placement, present: Bool = true) throws {
        guard editor.window === panel else { throw NativeError.message("Emacs replaced the native launcher window") }
        guard placement.width >= 200, placement.height >= 100, placement.screen >= -1,
              placement.radius >= 0 else { throw NativeError.message("Invalid Portal launcher placement") }
        let screens = NSScreen.screens
        guard let screen = screens.indices.contains(Int(placement.screen)) ? screens[Int(placement.screen)]
            : screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else {
            throw NativeError.message("No display is available for the Portal launcher")
        }
        requested = Self.rectangle(placement, in: screen.visibleFrame)
        self.placement = placement
        panel.hasShadow = placement.shadow
        content.wantsLayer = true
        content.layer?.cornerRadius = min(CGFloat(placement.radius), min(requested.width, requested.height) / 2)
        content.layer?.masksToBounds = true
        panel.setFrame(requested, display: true)
        if present {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(editor)
        }
    }

    func hide() { panel.orderOut(nil) }

    func detach() {
        if let observer = displayObserver { NotificationCenter.default.removeObserver(observer) }
        displayObserver = nil
        panel.orderOut(nil)
        // Children belong to Emacs. Move them back too, before Emacs deletes
        // them with their parent; do not close an Emacs-owned child ourselves.
        let children = panel.childWindows ?? []
        for child in children { panel.removeChildWindow(child) }
        panel.delegate = nil
        panel.contentView = NSView(frame: .zero)
        content.layer?.cornerRadius = cornerRadius
        content.layer?.masksToBounds = masksToBounds
        content.wantsLayer = wantedLayer
        panel.donor.contentView = content
        panel.donor.delegate = delegate
        panel.donor.makeFirstResponder(editor)
        for child in children { panel.donor.addChildWindow(child, ordered: .above) }
        panel.close()
    }

    static func detach() {
        attached?.detach()
        attached = nil
    }

    static func describe() -> [String: Any] {
        func rect(_ value: NSRect) -> [Double] {
            [value.minX, value.minY, value.width, value.height]
        }
        var state: [String: Any] = ["attached": attached != nil, "screens": NSScreen.screens.map {
            ["name": $0.localizedName, "frame": rect($0.frame), "visible": rect($0.visibleFrame),
             "scale": $0.backingScaleFactor] as [String: Any]
        }]
        if let launcher = attached {
            state.merge(["visible": launcher.panel.isVisible, "key": launcher.panel.isKeyWindow,
                         "viewAttached": launcher.editor.window === launcher.panel,
                         "requested": rect(launcher.requested), "actual": rect(launcher.panel.frame),
                         "content": rect(launcher.content.bounds),
                         "appearance": launcher.panel.appearance?.name.rawValue ?? "system",
                         "class": NSStringFromClass(type(of: launcher.panel))]) { _, new in new }
        }
        return state
    }
}
