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
}

extension NativeSurface { var input: NativeInput? { nil } }

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
    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]

    private init(view: NSView) {
        self.view = view
        editor = view.window?.firstResponder
    }

    static func bind(title: String) -> NativeHost? {
        guard let window = NSApp?.windows.first(where: { $0.title == title }),
              let view = window.contentView else { return nil }
        if let host = frames.object(forKey: window), host.view === view { return host }
        let host = NativeHost(view: view)
        frames.setObject(host, forKey: window)
        return host
    }

    private var focusedSurface: (any NativeSurface)? {
        surfaces.values.compactMap(\.value).first { ownsFocus($0.nativeView) }
    }

    func ownsFocus(_ surface: NSView) -> Bool {
        guard let responder = view?.window?.firstResponder as? NSView else { return false }
        return responder === surface || responder.isDescendant(of: surface)
    }

    func returnFocus(from surface: NSView) {
        if ownsFocus(surface) { view?.window?.makeFirstResponder(editor) }
    }

    func captureInput(_ handler: any NativeInputHandler) { inputCapture = handler }

    func releaseInput(_ handler: any NativeInputHandler) {
        if inputCapture === handler { inputCapture = nil }
    }

    func place(_ surface: any NativeSurface, rectangle: CGRect) -> Bool {
        guard let view else { return false }
        _ = surface.input // Register shared input before the first focus or key event.
        let child = surface.nativeView
        var frame = rectangle
        frame.origin.x += view.bounds.minX
        frame.origin.y = view.isFlipped
            ? view.bounds.minY + rectangle.minY : view.bounds.maxY - rectangle.maxY
        if child.frame != frame { child.frame = frame }
        surfaces[ObjectIdentifier(surface)] = WeakSurface(surface)
        if child.superview !== view { view.addSubview(child) }
        child.isHidden = false
        Self.startMonitoring()
        return true
    }

    /// Hiding deliberately retains the view. Features decide whether to remove it.
    func hide(_ surface: any NativeSurface) {
        surface.input?.cancel()
        returnFocus(from: surface.nativeView)
        surface.nativeView.isHidden = true
    }

    func remove(_ surface: any NativeSurface) {
        surface.input?.cancel()
        returnFocus(from: surface.nativeView)
        surfaces[ObjectIdentifier(surface)] = nil
        surface.nativeView.removeFromSuperview()
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
        let handled = handler?.handleKeyEvent(event) ?? false
        if !handled, handler is any NativeSurface, event.type == .keyDown { deliveredKeys.add(event) }
        return handled
    }
}
