// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

extension portal_chord {
    /// EVENT's key as the core sees it: the character it types with Shift but
    /// no other modifier, and Portal's modifiers. Option is Meta, Command Super.
    @MainActor init(_ event: NSEvent) {
        let scalars = (event.charactersIgnoringModifiers ?? "").unicodeScalars
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        for (flag, modifier) in [(NSEvent.ModifierFlags.shift, PORTAL_SHIFT), (.control, PORTAL_CONTROL),
                                 (.option, PORTAL_META), (.command, PORTAL_SUPER)] where flags.contains(flag) {
            modifiers |= modifier.rawValue
        }
        self.init(character: scalars.count == 1 ? scalars.first!.value : 0, modifiers: modifiers)
    }
}

/// One view's native input, for Ghostty and WebKit alike. The core decides
/// what each key press does (native/Core/input.c); this keeps the native
/// events it holds, replays them, and tells the core when the view gains or
/// loses the keyboard.
@MainActor
final class NativeInput: NativeInputHandler {
    nonisolated static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    let target: String
    weak var view: NSView?
    var host: NativeHost
    let focusView: () -> Bool
    /// The key press that started Emacs's handoff, until the core discards it.
    /// While it is held, key events in its window are this view's.
    private(set) var trigger: NSEvent?
    /// The key events after the trigger, until the core replays them.
    private var held: [NSEvent]?
    /// Whether the core was last told the view has the keyboard.
    private var reported = false

    init(target: String, view: NSView, host: NativeHost, focus: @escaping () -> Bool) {
        self.target = target
        self.view = view
        self.host = host
        focusView = focus
    }

    /// Return to Emacs, as Command-Escape does, ending any handoff Emacs is
    /// handling: Emacs would otherwise read the next event as its next key.
    func escape() {
        if let view { host.returnFocus(from: view) }
        report(false)
    }

    /// The user is giving the view the keyboard, as a click does.
    func claim() { report(true) }

    /// Tell the core whether the view has the keyboard, when that changed.
    func observe() {
        let focused = view.map { host.ownsFocus($0) } ?? false
        if focused != reported { report(focused) }
    }

    private func report(_ focused: Bool) {
        reported = focused
        Core.focus(target, focused)
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Recovery must work even before Lisp acknowledges, without a JS flush.
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(Self.modifiers) == .command {
            escape()
            return true
        }
        if held != nil {
            held?.append(event)
            return true
        }
        guard event.type == .keyDown else { return false }
        switch Core.key(target, event) {
        case PORTAL_KEY_HOLD:
            if trigger == nil {
                trigger = event
                held = []
            } else {
                held?.append(event)
            }
            return true
        case PORTAL_KEY_TAKE: return true
        default: return false
        }
    }

    // The primitives of native/Core/include/portal.h.

    func focus() {
        _ = focusView()
        host.refreshOwnership()
    }

    func unfocus() {
        if let view { host.returnFocus(from: view) }
    }

    func replay() {
        let events = held ?? []
        held = nil
        for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
    }

    func discard() {
        trigger = nil
        held = nil
    }

    func literal() throws {
        guard let down = trigger, let view, let window = view.window,
              let up = NSEvent.keyEvent(with: .keyUp, location: down.locationInWindow,
                modifierFlags: down.modifierFlags, timestamp: down.timestamp,
                windowNumber: window.windowNumber, context: nil, characters: down.characters ?? "",
                charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "",
                isARepeat: false, keyCode: down.keyCode) else {
            throw NativeError.message("No captured prefix key to send")
        }
        // Deliver the matched pair to the actual native content responder.
        // NSWindow's key-up bookkeeping did not see the captured key-down.
        NativeHost.deliverLiteral(down, up: up, in: view)
    }
}
