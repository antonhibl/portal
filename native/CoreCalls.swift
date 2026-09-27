// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

// Calls between Swift and the C core outside the Lisp operations: the core's
// notification pipe, input, and the timer primitive, all in
// native/Core/include/portal.h. The standalone checks compile this file too.

/// The C core, as Swift features call it.
@MainActor
enum Core {
    /// Send Emacs the record `TYPE TARGET FIELD...` through the core's pipe,
    /// which delivers records in order and waits while the pipe is full or
    /// disconnected. Returns false only for a record that can never be sent.
    @discardableResult
    static func notify(_ type: String, target: String, fields: [String] = []) -> Bool {
        var bytes: [CChar] = []
        var spans: [(start: Int, length: Int)] = []
        for word in [type, target] + fields {
            spans.append((bytes.count, word.utf8.count))
            bytes += word.utf8CString
        }
        return bytes.withUnsafeBufferPointer { bytes in
            let base = bytes.baseAddress!
            let words = spans.map { portal_string(data: base + $0.start, length: $0.length) }
            return words.withUnsafeBufferPointer {
                portal_notify($0[0], $0[1], $0.baseAddress! + 2, fields.count)
            }
        }
    }

    /// What to do with EVENT, a key press in TARGET's view or its window.
    static func key(_ target: String, _ event: NSEvent) -> portal_key {
        let chord = portal_chord(event)
        return borrow(target) { portal_input_key($0, chord, event.isARepeat) }
    }

    /// TARGET's view gained or lost the keyboard.
    static func focus(_ target: String, _ focused: Bool) {
        borrow(target) { portal_input_focus($0, focused) }
    }

    /// Who has TARGET's keyboard.
    static func owner(_ target: String) -> portal_owner {
        borrow(target) { portal_input_owner($0) }
    }

    private static func borrow<T>(_ text: String, _ body: (portal_string) -> T) -> T {
        text.withCString { body(portal_string(data: $0, length: text.utf8.count)) }
    }
}

/// Call the core back from the main run loop, Emacs's thread.
@_cdecl("portal_timer_start")
public func portalTimerStart(_ token: UInt64, _ milliseconds: UInt64) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds))) {
        portal_timer_fired(token)
    }
}
