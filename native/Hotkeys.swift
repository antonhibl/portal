// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon
import Foundation
import PortalCore

/// The system-wide hot keys of portal.h, as Carbon registrations whose IDs
/// are the core's hot keys. The handler only reports presses and releases
/// to the core, which decides what reaches Emacs.
@MainActor
enum Hotkeys {
    private struct Registration {
        let reference: EventHotKeyRef
        let code: UInt32, flags: UInt32
        /// Events from before this are stale: registering again restarts it.
        var started = GetCurrentEventTime()
    }
    nonisolated static let signature: OSType = 0x5072744c // PrtL
    private static var registrations: [UInt32: Registration] = [:]
    private static var handler: EventHandlerRef?
    /// Whether the Carbon handler is installed, which it is only while a hot key is.
    static var handling: Bool { handler != nil }

    /// Carbon's virtual key code for each key portal.h names: positions on
    /// a US keyboard, independent of the input source. Posted keys share
    /// its Space and function keys, whose codes no layout changes.
    static let codes: [UInt32: UInt32] = {
        let keys: [(Character, UInt32)] = [
            ("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7),
            ("C", 8), ("V", 9), ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15),
            ("Y", 16), ("T", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
            ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29), ("O", 31), ("U", 32),
            ("I", 34), ("P", 35), ("L", 37), ("J", 38), ("K", 40), ("N", 45), ("M", 46),
            (" ", 49)
        ]
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                      105, 107, 113, 106, 64, 79, 80, 90]
        var codes = Dictionary(uniqueKeysWithValues: keys.map { (UInt32($0.0.asciiValue!), $0.1) })
        for (index, code) in functionKeys.enumerated() {
            codes[UInt32(PORTAL_FUNCTION_KEY) + UInt32(index) + 1] = code
        }
        return codes
    }()

    static func register(_ hotkey: UInt64, key: UInt32, modifiers: UInt32) throws {
        guard let id = UInt32(exactly: hotkey) else {
            throw NativeError.message("Portal has used up its shortcut IDs; restart Emacs")
        }
        guard let code = codes[key] else { throw NativeError.message("No such key: \(key)") }
        var flags: UInt32 = 0
        for (modifier, flag) in [(PORTAL_SHIFT, shiftKey), (PORTAL_CONTROL, controlKey),
                                 (PORTAL_META, optionKey), (PORTAL_SUPER, cmdKey)]
            where modifiers & modifier.rawValue != 0 {
            flags |= UInt32(flag)
        }
        if let registration = registrations[id] {
            guard registration.code == code, registration.flags == flags else {
                throw NativeError.message("Hot key \(hotkey) has another chord")
            }
            registrations[id]?.started = GetCurrentEventTime()
            return
        }
        if handler == nil {
            let events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                MainActor.assumeIsolated { Hotkeys.receive(event) }
            }, events.count, events, nil, &handler)
            guard status == noErr else { throw NativeError.message("Cannot install the hot key handler (macOS \(status))") }
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(code, flags, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            releaseHandler()
            throw NativeError.message("the system or another application has it (macOS \(status))")
        }
        registrations[id] = Registration(reference: reference, code: code, flags: flags)
    }

    static func unregister(_ hotkey: UInt64) throws {
        guard let id = UInt32(exactly: hotkey), let registration = registrations[id] else { return }
        let status = UnregisterEventHotKey(registration.reference)
        guard status == noErr else { throw NativeError.message("Cannot release a shortcut (macOS \(status))") }
        registrations[id] = nil
        releaseHandler()
    }

    /// Remove the handler once no hot key needs it.
    private static func releaseHandler() {
        guard registrations.isEmpty, let installed = handler else { return }
        RemoveEventHandler(installed)
        handler = nil
    }

    private static func receive(_ event: EventRef?) -> OSStatus {
        guard let event, GetEventClass(event) == OSType(kEventClassKeyboard) else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == signature, let registration = registrations[id.id] else {
            return OSStatus(eventNotHandledErr)
        }
        switch Int(GetEventKind(event)) {
        case kEventHotKeyPressed:
            // An event from before this registration belongs to an older one.
            if GetEventTime(event) >= registration.started { Core.hotkeyPressed(UInt64(id.id)) }
        case kEventHotKeyReleased:
            Core.hotkeyReleased(UInt64(id.id))
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
