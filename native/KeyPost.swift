// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import Carbon
import PortalCore

/// Posting a chord to the frontmost application, portal.h's portal_key_post,
/// as a key down and a key up. A letter or digit is found in the current
/// keyboard layout, so that Command-V pastes on Dvorak as on QWERTY.
@MainActor
enum KeyPost {
    static func post(key: UInt32, modifiers: UInt32) throws {
        // Without permission macOS drops posted events without a word.
        guard trusted() else {
            throw NativeError.message("Emacs has no Accessibility permission; switch it on in System Settings "
                                      + "> Privacy & Security > Device Control and Data Access "
                                      + "(Accessibility before macOS 27)")
        }
        let command = modifiers & PORTAL_SUPER.rawValue != 0
        let code: CGKeyCode
        if key == UInt32(Character(" ").asciiValue!) || key > UInt32(PORTAL_FUNCTION_KEY) {
            guard let fixed = Hotkeys.codes[key] else { throw NativeError.message("No such key: \(key)") }
            code = CGKeyCode(fixed)
        } else {
            code = try self.code(typing: key, command: command)
        }
        var flags: CGEventFlags = []
        for (modifier, flag) in [(PORTAL_SHIFT, CGEventFlags.maskShift), (PORTAL_CONTROL, .maskControl),
                                 (PORTAL_META, .maskAlternate), (PORTAL_SUPER, .maskCommand)]
            where modifiers & modifier.rawValue != 0 {
            flags.insert(flag)
        }
        // A private source keeps the modifiers the user holds out of the events.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw NativeError.message("Cannot create key events")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Whether this process has asked for the permission. macOS shows its
    /// alert again on every request once the last alert is gone (macOS
    /// 27.0.1), so only the first failed post asks; later ones only fail.
    private static var asked = false

    /// Whether macOS lets Emacs post events, asking the user once when it does
    /// not: the system alert "Emacs would like to control this Mac and access
    /// your data" offers Open System Settings, and adds Emacs to that list,
    /// switched off, so the user only flips the switch.
    /// Only a post asks, never loading Portal or setting a global shortcut:
    /// Apple's guidance is to ask for a permission when the feature needing it
    /// is used.
    private static func trusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !asked {
            asked = true
            // kAXTrustedCheckOptionPrompt's value, spelled out: Swift 6 rejects
            // the global as not concurrency-safe.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return false
    }

    /// The first key that types CHARACTER, an ASCII letter or digit, ignoring
    /// case, in the current keyboard layout, with Command held if COMMAND.
    private static func code(typing character: UInt32, command: Bool) throws -> CGKeyCode {
        let wanted = lowercase(character)
        let layout = try currentLayout()
        let bytes = UnsafeRawPointer(CFDataGetBytePtr(layout)!).assumingMemoryBound(to: UCKeyboardLayout.self)
        let state = command ? UInt32(cmdKey >> 8) & 0xff : 0
        for code in UInt16(0)..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var typed = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(bytes, code, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                        typed.count, &length, &typed)
            if status == noErr, length == 1, lowercase(UInt32(typed[0])) == wanted { return code }
        }
        let name = String(UnicodeScalar(UInt8(wanted)))
        throw NativeError.message("no key types \(name)\(command ? " with Command" : "") in the current keyboard layout")
    }

    /// The current keyboard layout's data, or the current ASCII-capable
    /// layout's, for an input source with none, such as an input method.
    private static func currentLayout() throws -> CFData {
        for copy in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            if let source = copy()?.takeRetainedValue(),
               let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                return Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
            }
        }
        throw NativeError.message("Cannot read the current keyboard layout")
    }

    private static func lowercase(_ character: UInt32) -> UInt32 {
        (0x41...0x5a).contains(character) ? character + 0x20 : character
    }
}
