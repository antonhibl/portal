// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum NativeError: Error { case message(String) }

/// A temporary input owner (for example, a terminal prefix awaiting Lisp).
@MainActor
protocol NativeInputHandler: AnyObject {
    func handleKeyEvent(_ event: NSEvent) -> Bool
}

/// Feature views keep their own rendering, input policy and session lifetime.
@MainActor
protocol NativeSurface: NativeInputHandler {
    var nativeView: NSView { get }
    var input: NativeInput? { get }
    var toolbarModel: ToolbarModel? { get }
}

extension NativeSurface {
    var input: NativeInput? { nil }
    var toolbarModel: ToolbarModel? { nil }
}

@MainActor
private final class WeakSurface {
    weak var value: (any NativeSurface)?
    init(_ value: any NativeSurface) { self.value = value }
}

/// Shared AppKit ownership for one Emacs frame. No WebKit or Ghostty dependency.
@MainActor
final class NativeHost: NSObject {
    private static let frames = NSMapTable<NSWindow, NativeHost>(
        keyOptions: .weakMemory, valueOptions: .weakMemory)
    private static var keyMonitor: Any?
    private struct KeyOwner: Equatable {
        let window: Int
        let handler: ObjectIdentifier?
    }
    // WebKit re-sends unhandled key-downs through NSApplication asynchronously.
    // Once delivered to a guest, they must not become Emacs commands later.
    private static let deliveredKeys = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])
    private static var pressedKeys: [UInt16: KeyOwner] = [:]

    weak var view: NSView?
    private weak var editor: NSResponder?
    private weak var inputCapture: (any NativeInputHandler)?
    private var containers: [ObjectIdentifier: NativeContainer] = [:]
    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]

    private init(view: NSView) {
        self.view = view
        editor = view.window?.firstResponder
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated),
                                              name: NSWindow.didUpdateNotification, object: view.window)
    }

    static func bind(title: String) -> NativeHost? {
        guard let window = NSApp?.windows.first(where: { $0.title == title }) else { return nil }
        return bind(window: window)
    }

    static func bind(window: NSWindow) -> NativeHost? {
        guard let view = window.contentView else { return nil }
        if let host = frames.object(forKey: window), host.view === view { return host }
        let host = NativeHost(view: view)
        frames.setObject(host, forKey: window)
        return host
    }

    private var focusedSurface: (any NativeSurface)? {
        surfaces.values.compactMap(\.value).first { ownsFocus($0.nativeView) }
    }

    @objc private func windowUpdated() { refreshOwnership() }

    func refreshOwnership() {
        for container in containers.values { container.toolbar?.refresh() }
    }

    static func refreshToolbars(layout: Bool = false) {
        for host in frames.objectEnumerator()?.allObjects as? [NativeHost] ?? [] {
            for container in host.containers.values {
                if layout { container.updateToolbar() } else { container.toolbar?.refresh() }
            }
        }
    }

    static func toolbarAction(target: String, action: String) throws -> String {
        for host in frames.objectEnumerator()?.allObjects as? [NativeHost] ?? [] {
            for surface in host.surfaces.values.compactMap(\.value) where surface.input?.target == target {
                guard let model = surface.toolbarModel else { break }
                try model.perform(action)
                return try model.snapshot()
            }
        }
        throw NativeError.message("No toolbar controls for this native view")
    }

    func ownsFocus(_ surface: NSView) -> Bool {
        guard let responder = view?.window?.firstResponder as? NSView else { return false }
        let root = surface.superview as? NativeContainer ?? surface
        return responder === root || responder.isDescendant(of: root)
    }

    func returnFocus(from surface: NSView) {
        if ownsFocus(surface) { view?.window?.makeFirstResponder(editor) }
        refreshOwnership()
    }

    func captureInput(_ handler: any NativeInputHandler) { inputCapture = handler }

    func releaseInput(_ handler: any NativeInputHandler) {
        if inputCapture === handler { inputCapture = nil }
    }

    func place(_ surface: any NativeSurface, rectangle: CGRect) -> Bool {
        guard let view else { return false }
        _ = surface.input // Register shared input before the first focus or key event.
        let key = ObjectIdentifier(surface)
        let child: NSView
        if let model = surface.toolbarModel {
            model.input = surface.input
            let container = containers[key] ?? NativeContainer(content: surface.nativeView, model: model)
            containers[key] = container
            child = container
        } else { child = surface.nativeView }
        var frame = rectangle
        frame.origin.x += view.bounds.minX
        frame.origin.y = view.isFlipped
            ? view.bounds.minY + rectangle.minY : view.bounds.maxY - rectangle.maxY
        if child.frame != frame { child.frame = frame }
        surfaces[ObjectIdentifier(surface)] = WeakSurface(surface)
        if child.superview !== view { view.addSubview(child) }
        child.isHidden = false
        surface.nativeView.isHidden = false
        child.layoutSubtreeIfNeeded()
        refreshOwnership()
        Self.startMonitoring()
        return true
    }

    /// Hiding deliberately retains the view. Features decide whether to remove it.
    func hide(_ surface: any NativeSurface) {
        surface.input?.cancel()
        returnFocus(from: surface.nativeView)
        surface.nativeView.isHidden = true
        containers[ObjectIdentifier(surface)]?.isHidden = true
    }

    func remove(_ surface: any NativeSurface) {
        surface.input?.cancel()
        returnFocus(from: surface.nativeView)
        surfaces[ObjectIdentifier(surface)] = nil
        surface.nativeView.removeFromSuperview()
        containers.removeValue(forKey: ObjectIdentifier(surface))?.removeFromSuperview()
        let hosts = Self.frames.objectEnumerator()?.allObjects as? [NativeHost] ?? []
        if hosts.allSatisfy({ $0.surfaces.values.allSatisfy { $0.value == nil } }) {
            if let monitor = Self.keyMonitor { NSEvent.removeMonitor(monitor) }
            Self.keyMonitor = nil
            Self.pressedKeys.removeAll()
        }
    }

    private static func startMonitoring() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let handled = MainActor.assumeIsolated { route(event) }
            return handled ? nil : event
        }
    }

    static func deliverLiteral(_ down: NSEvent, up: NSEvent, in view: NSView) {
        guard let responder = view.window?.firstResponder else { return }
        deliveredKeys.add(down)
        responder.keyDown(with: down)
        responder.keyUp(with: up)
    }

    private static func route(_ event: NSEvent) -> Bool {
        if deliveredKeys.contains(event) { return true }
        guard let window = event.window ?? NSApp.keyWindow else { return false }
        let host = frames.object(forKey: window)
        let handler: (any NativeInputHandler)? = host?.inputCapture ?? host?.focusedSurface
        let owner = KeyOwner(window: window.windowNumber, handler: handler.map(ObjectIdentifier.init))
        if event.type == .keyUp, let pressed = pressedKeys.removeValue(forKey: event.keyCode), pressed != owner {
            // A command can move focus before its release. Never deliver that
            // unmatched release to the newly focused terminal or web page.
            return true
        }
        if event.type == .keyDown { pressedKeys[event.keyCode] = owner }
        // Search fields belong to the surface for ownership, but keep AppKit text editing.
        let finding = host?.focusedSurface?.toolbarModel?.finding == true
        let inContent = host?.focusedSurface.map { surface in
            guard let responder = window.firstResponder as? NSView else { return false }
            return responder === surface.nativeView || responder.isDescendant(of: surface.nativeView)
        } ?? false
        let handled: Bool
        if finding && !inContent && host?.inputCapture == nil {
            handled = host?.focusedSurface?.input?.handleKeyEvent(event) ?? false
        } else { handled = handler?.handleKeyEvent(event) ?? false }
        host?.refreshOwnership()
        if !handled, handler is any NativeSurface, event.type == .keyDown { deliveredKeys.add(event) }
        return handled
    }
}
