// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct NativeKey: Hashable {
    let character: String
    let flags: UInt

    init(character: String, flags: UInt) {
        self.character = character.lowercased()
        var modifiers = flags & NativeInput.modifiers.rawValue
        // AppKit retains Shift for punctuation ("!"), whereas Emacs encodes
        // the resulting character. Preserve Shift for letters and space.
        if let ascii = character.utf8.first, character.utf8.count == 1,
           ascii > 32, !(65...90).contains(ascii), !(97...122).contains(ascii) {
            modifiers &= ~NSEvent.ModifierFlags.shift.rawValue
        }
        self.flags = modifiers
    }

    @MainActor init(_ event: NSEvent) {
        self.init(character: event.charactersIgnoringModifiers ?? "", flags: event.modifierFlags.rawValue)
    }
}

private struct TerminalBinding: Decodable {
    let character: String
    let flags: UInt
    let event: Int
}

private struct TerminalBindingProfiles: Decodable {
    let regular: [TerminalBinding]
    let quick: [TerminalBinding]
}

/// One input policy for Ghostty and WebKit. Only first chords cross into Lisp.
@MainActor
final class NativeInput: NativeInputHandler {
    nonisolated static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
    private static var prefix = NativeKey(character: "b", flags: NSEvent.ModifierFlags.control.rawValue)
    private static var regularBindings: [NativeKey: Int] = [:]
    private static var quickBindings: [NativeKey: Int] = [:]

    let target: String
    weak var view: NSView?
    var host: NativeHost
    let focusView: () -> Bool
    private let profile: String
    private var trigger: NSEvent?
    private var pending: [NSEvent] = []
    private var waiting = false
    private var reading = false
    private var firstTail = true
    private var active = false
    private var serial = 0
    private var passthrough = false

    init(target: String, view: NSView, host: NativeHost, profile: String = "web",
         focus: @escaping () -> Bool) {
        self.target = target
        self.view = view
        self.host = host
        self.profile = profile
        focusView = focus
    }

    static func configurePrefix(_ character: String, flags: Int) throws {
        guard flags > 0, character.utf8.count == 1,
              let ascii = character.utf8.first, (32...126).contains(ascii),
              UInt(flags) & ~modifiers.rawValue == 0 else {
            throw NativeError.message("Expected one modified ASCII prefix")
        }
        let key = NativeKey(character: character, flags: UInt(flags))
        guard regularBindings[key] == nil, quickBindings[key] == nil else {
            throw NativeError.message("Portal prefix conflicts with a native binding")
        }
        prefix = key
    }

    static func configureBindings(_ json: String) throws {
        let profiles = try JSONDecoder().decode(TerminalBindingProfiles.self, from: Data(json.utf8))
        func table(_ bindings: [TerminalBinding]) throws -> [NativeKey: Int] {
            var result: [NativeKey: Int] = [:]
            for binding in bindings {
                guard binding.character.utf8.count == 1,
                      let ascii = binding.character.utf8.first, (32...126).contains(ascii),
                      binding.flags != 0, binding.flags & ~modifiers.rawValue == 0,
                      binding.event > 0 else {
                    throw NativeError.message("Invalid native terminal binding")
                }
                let key = NativeKey(character: binding.character, flags: binding.flags)
                guard key.flags != 0, key != prefix, result[key] == nil else {
                    throw NativeError.message("Conflicting native terminal binding")
                }
                result[key] = binding.event
            }
            return result
        }
        let regular = try table(profiles.regular)
        let quick = try table(profiles.quick)
        regularBindings = regular
        quickBindings = quick
    }

    private func notify(_ kind: String, key: Int = 0) -> Bool {
        Views.channel.notify(kind, target: target, fields: [String(serial), String(key)])
    }

    enum Ownership { case emacs, view, pending, passthrough }
    var ownership: Ownership {
        if active { return .pending }
        guard let view, host.ownsFocus(view) else { return .emacs }
        return passthrough ? .passthrough : .view
    }

    func toggleOwnership() {
        switch ownership {
        case .pending: break
        case .emacs: _ = focusView()
        case .view, .passthrough: escape()
        }
        host.refreshOwnership()
    }

    /// Return to Emacs, ending any prefix Emacs is reading, as Command-Escape
    /// does. Emacs would otherwise read the next event as the prefix's tail.
    func escape() {
        let wasActive = active
        cancel()
        if let view { host.returnFocus(from: view) }
        if wasActive { _ = notify("escape") }
    }

    func cancel() {
        defer { host.refreshOwnership() }
        serial += 1 // Invalidate queued notifications and late command completion.
        active = false
        waiting = false
        reading = false
        pending.removeAll()
        passthrough = false
        host.releaseInput(self)
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Recovery must work even before Lisp acknowledges, without a JS flush.
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(Self.modifiers) == .command {
            escape()
            return true
        }
        if waiting { pending.append(event); return true }
        if active {
            guard reading, event.type == .keyDown else { return false }
            let literal = firstTail && (trigger.map { NativeKey($0) == NativeKey(event) } ?? false)
            let cancel = NativeKey(event) == NativeKey(character: "g", flags: NSEvent.ModifierFlags.control.rawValue)
            if literal || cancel {
                if !event.isARepeat { _ = notify(literal ? "literal" : "cancel") }
                return true
            }
            firstTail = false
            return false
        }
        guard !passthrough, event.type == .keyDown else { return false }
        let key = NativeKey(event)
        let binding = (profile == "quick" ? Self.quickBindings :
                       profile == "regular" ? Self.regularBindings : [:])[key]
        guard key == Self.prefix || binding != nil else { return false }
        if !event.isARepeat {
            serial += 1
            trigger = event
            if let view { host.returnFocus(from: view) }
            if notify(binding == nil ? "prefix" : "binding", key: binding ?? 0) {
                active = true
                waiting = true
                host.captureInput(self)
            }
        }
        return true
    }

    static func perform(_ target: String, action: String, serial: Int = 0) throws -> Bool {
        guard let input = Views.input(target) else { return false }
        if serial != 0 && (serial != input.serial || !input.active) { return false }
        return try input.perform(action)
    }

    private func perform(_ action: String) throws -> Bool {
        defer { host.refreshOwnership() }
        switch action {
        case "pending": return active
        case "focused": return view.map { host.ownsFocus($0) } ?? false
        case "passthrough-p": return passthrough
        case "focus":
            passthrough = false
            return focusView()
        case "unfocus":
            cancel()
            if let view { host.returnFocus(from: view) }
        case "ack":
            guard waiting else { return false }
            waiting = false
            reading = true
            firstTail = true
            let events = pending
            pending.removeAll(keepingCapacity: true)
            for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
        case "command": reading = false
        case "finish":
            active = false
            reading = false
            waiting = false
            pending.removeAll()
            host.releaseInput(self)
        case "passthrough":
            passthrough = true
            return focusView()
        case "literal":
            guard let down = trigger, focusView(), let window = view?.window,
                  let up = NSEvent.keyEvent(with: .keyUp, location: down.locationInWindow,
                    modifierFlags: down.modifierFlags, timestamp: down.timestamp,
                    windowNumber: window.windowNumber, context: nil, characters: down.characters ?? "",
                    charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "",
                    isARepeat: false, keyCode: down.keyCode) else {
                throw NativeError.message("No captured prefix key to send")
            }
            // Deliver the matched pair to the actual native content responder.
            // NSWindow's key-up bookkeeping did not see the captured key-down.
            if let view { NativeHost.deliverLiteral(down, up: up, in: view) }
        default: throw NativeError.message("Unknown Portal input action: \(action)")
        }
        return true
    }
}
