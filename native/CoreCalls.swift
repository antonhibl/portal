// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

// Calls between Swift and the C core outside the Lisp operations: the core's
// notification pipe, input, what web pages do, the shared browser scripts,
// and the timer primitive, all in native/Core/include/portal.h. The standalone
// checks compile this file too.

extension String {
    /// A copy of borrowed UTF-8 from the core.
    init(copying string: portal_string) {
        self.init(decoding: UnsafeRawBufferPointer(start: string.data, count: string.length), as: UTF8.self)
    }
}

/// Call BODY with each of STRINGS borrowed as a `portal_string`.
private func borrowing<T>(_ strings: [String], _ body: ([portal_string]) -> T) -> T {
    var bytes: [CChar] = []
    var spans: [(start: Int, length: Int)] = []
    for string in strings {
        spans.append((bytes.count, string.utf8.count))
        bytes += string.utf8CString
    }
    return bytes.withUnsafeBufferPointer { bytes in
        body(spans.map { portal_string(data: bytes.baseAddress! + $0.start, length: $0.length) })
    }
}

/// The C core, as Swift features call it.
@MainActor
enum Core {
    /// Send Emacs the record `TYPE TARGET FIELD...` through the core's pipe,
    /// which delivers records in order and waits while the pipe is full or
    /// disconnected. Returns false only for a record that can never be sent.
    @discardableResult
    static func notify(_ type: String, target: String, fields: [String] = []) -> Bool {
        borrowing([type, target] + fields) { words in
            words.withUnsafeBufferPointer { portal_notify($0[0], $0[1], $0.baseAddress! + 2, fields.count) }
        }
    }

    /// What the core answers when a page asks to navigate.
    enum Navigation { case allow, external, emacs }

    /// The page in TARGET posted JSON, a JSON object whose "type" is TYPE,
    /// from its main frame or another, showing URL, as WebKit reports them.
    static func posted(_ target: String, mainFrame: Bool, url: String, type: String, json: String) {
        borrowing([target, url, type, json]) {
            portal_web_posted($0[0], portal_sender(main_frame: mainFrame, url: $0[1]), $0[2], $0[3])
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

    static func navigating(_ target: String, url: String, mainFrame: Bool) -> Navigation {
        let decision = borrowing([target, url]) { portal_web_navigating($0[0], $0[1], mainFrame) }
        return decision == PORTAL_NAVIGATION_EXTERNAL ? .external
            : decision == PORTAL_NAVIGATION_EMACS ? .emacs : .allow
    }

    static func committed(_ target: String, url: String) {
        borrowing([target, url]) { portal_web_committed($0[0], $0[1]) }
    }

    /// TOKEN is 0 for a failure of the page itself, or a post's token.
    static func failed(_ target: String, token: UInt64, message: String) {
        borrowing([target, message]) { portal_web_failed($0[0], token, $0[1]) }
    }

    static func edit(_ target: String) {
        borrowing([target]) { portal_web_edit($0[0]) }
    }

    /// The shared browser script SCRIPT, started in its world with a report
    /// function that posts to that world's script message HANDLER. This glue
    /// is the only part that names WebKit's transport.
    static func script(_ script: portal_script, handler: String) -> String {
        "(\n\(String(copying: portal_web_script(script)))\n)((value) => window.webkit.messageHandlers.\(handler).postMessage(value));\n"
    }
}

/// Call the core back from the main run loop, Emacs's thread.
@_cdecl("portal_timer_start")
public func portalTimerStart(_ token: UInt64, _ milliseconds: UInt64) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds))) {
        portal_timer_fired(token)
    }
}
