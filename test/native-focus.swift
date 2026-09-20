// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AppKit check; run using the command in README.md.
import AppKit
import WebKit

@main
struct CheckFocus {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portal focus check"
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        precondition(WebViews.bind(title: window.title))
        precondition(WebViews.loadURL("data:text/html,<input autofocus><title>Focus</title>"))
        precondition(WebViews.setLayout([PaneLayout(id: 1, rectangle: editor.bounds)]))
        let web = window.contentView!.subviews.first { $0 is WKWebView }!
        // A responder nested below the webview exercises the same ancestry test
        // as WebKit's internal text input views.
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        web.addSubview(input)
        for (code, flags, characters) in [(UInt16(53), NSEvent.ModifierFlags(), "\u{1b}"),
                                          (UInt16(5), .control, "g")] {
            precondition(window.makeFirstResponder(input))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code)!
            app.sendEvent(event)
            precondition(window.firstResponder === editor, "Focus did not return")
        }
        precondition(window.makeFirstResponder(input))
        precondition(WebViews.setLayout([]))
        precondition(window.firstResponder === editor, "Removal did not restore focus")
        WebViews.destroy()
        print("Escape, C-g, and view removal restore focus")
    }
}
