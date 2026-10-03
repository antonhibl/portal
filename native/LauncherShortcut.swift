// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon
import Foundation

/// One process-wide launcher chord. Carbon callbacks only write pipe records;
/// frame selection and presentation belong to the Emacs command loop.
@MainActor
enum LauncherShortcut {
    struct Chord: Equatable {
        let key: UInt32
        let modifiers: UInt32

        init(_ text: String) throws {
            var parts = text.uppercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.popLast() else { throw NativeError.message("Empty launcher shortcut") }
            let keys: [String: UInt32] = [
                "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
                "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
                "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
                "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "O": 31, "U": 32,
                "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
                "SPACE": 49, "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96,
                "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103,
                "F12": 111, "F13": 105, "F14": 107, "F15": 113, "F16": 106,
                "F17": 64, "F18": 79, "F19": 80, "F20": 90
            ]
            let flags = ["CONTROL": UInt32(controlKey), "OPTION": UInt32(optionKey),
                         "COMMAND": UInt32(cmdKey), "SHIFT": UInt32(shiftKey)]
            var modifiers: UInt32 = 0
            for part in parts {
                guard let flag = flags[part], modifiers & flag == 0 else {
                    throw NativeError.message("Invalid launcher modifier: \(part); use Control, Option, Command or Shift once each")
                }
                modifiers |= flag
            }
            guard let key = keys[name], modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
                throw NativeError.message("Launcher shortcut needs Control, Option or Command plus A-Z, 0-9, Space or F1-F20 (for example Control-Option-Command-P)")
            }
            self.key = key
            self.modifiers = modifiers
        }
    }

    private struct Registration {
        let chord: Chord
        let id: UInt32
        let reference: EventHotKeyRef
        let started = GetCurrentEventTime()
        var held = false
    }
    private static let signature: OSType = 0x5072744c // PrtL
    private static var registration: Registration?
    private static var handler: EventHandlerRef?
    private static var sequence: UInt32 = 0
    static var token: UInt32 { registration?.id ?? 0 }

    /// Empty text disables. Same chord is idempotent; a failed replacement
    /// preserves the previous chord and token, including queued valid records.
    static func set(_ text: String) throws -> UInt32 {
        if text.isEmpty {
            if let current = registration {
                let status = UnregisterEventHotKey(current.reference)
                guard status == noErr else { throw NativeError.message("Cannot release launcher shortcut (macOS \(status))") }
            }
            registration = nil
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return 0
        }
        let chord = try Chord(text)
        if registration?.chord == chord { return token }
        guard sequence < UInt32.max else { throw NativeError.message("Launcher shortcut IDs exhausted; restart Emacs") }
        if handler == nil {
            let events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                MainActor.assumeIsolated { LauncherShortcut.receive(event) }
            }, events.count, events, nil, &handler)
            guard status == noErr else { throw NativeError.message("Cannot install launcher shortcut handler (macOS \(status))") }
        }
        sequence += 1 // Never reuse an ID, even after failed registration.
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.key, chord.modifiers,
                                         EventHotKeyID(signature: signature, id: sequence),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if registration == nil {
                if let handler { RemoveEventHandler(handler) }
                handler = nil
            }
            throw NativeError.message("Cannot register launcher shortcut \(text): chord unavailable or reserved (macOS \(status)); previous shortcut retained")
        }
        if let current = registration {
            let status = UnregisterEventHotKey(current.reference)
            guard status == noErr else {
                UnregisterEventHotKey(reference)
                throw NativeError.message("Cannot replace launcher shortcut (macOS \(status)); previous shortcut retained")
            }
        }
        registration = Registration(chord: chord, id: sequence, reference: reference)
        return sequence
    }

    private static func receive(_ event: EventRef?) -> OSStatus {
        guard let event, GetEventClass(event) == OSType(kEventClassKeyboard) else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == signature, id.id == registration?.id else { return OSStatus(eventNotHandledErr) }
        switch Int(GetEventKind(event)) {
        case kEventHotKeyPressed:
            if registration?.held == false,
               GetEventTime(event) >= (registration?.started ?? 0),
               GetEventTime(event) >= NativeLauncher.sessionStarted {
                registration?.held = true
                Core.launcherInvoked(registration: UInt64(id.id), session: NativeLauncher.session)
            }
        case kEventHotKeyReleased:
            registration?.held = false
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
