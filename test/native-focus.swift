// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AppKit check; run using the command in README.md.
import AppKit
import WebKit

@main
struct CheckFocus {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portal focus check"
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let target = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("navigation")]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        try Views.view(target, as: WebSession.self).load("data:text/html,<input autofocus><title>Focus</title>")
        let web = window.contentView!.subviews.compactMap { ($0 as? NativeContainer)?.content as? WKWebView }.first!
        // A responder nested below the webview exercises the same ancestry test
        // as WebKit's internal text input views.
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        web.addSubview(input)
        for (code, flags, characters) in [(UInt16(53), NSEvent.ModifierFlags(), "\u{1b}"),
                                          (UInt16(5), .control, "g"),
                                          (UInt16(53), .command, "\u{1b}")] {
            precondition(window.makeFirstResponder(input))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code)!
            app.sendEvent(event)
            if flags == .command {
                precondition(window.firstResponder === editor, "Command-Escape did not return focus")
            } else {
                precondition(window.firstResponder === input, "Guest key unexpectedly left the app")
            }
        }
        precondition(window.makeFirstResponder(input))
        try Views.hide(target)
        precondition(window.firstResponder === editor, "Hiding did not restore focus")
        try Views.close(target)
        print("Guest Escape/C-g retain focus; Command-Escape and hiding restore Emacs focus")
        try checkHosted(window: window)
    }

    /// A hosted app keeps no data between sessions, and a page it leaves the
    /// app host for opens in the browser while the app stays.
    @MainActor
    static func checkHosted(window: NSWindow) throws {
        var opened: [URL] = []
        WebSession.openInBrowser = { opened.append($0) }
        let target = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        let app = "data:text/html,<title>App</title><script>onload=()=>location.href='https://example.com/'</script>"
        try Views.view(target, as: WebSession.self).load(app)
        let web = window.contentView!.subviews.compactMap { $0 as? WKWebView }.first!
        precondition(!web.configuration.websiteDataStore.isPersistent, "A hosted app keeps its data")
        let deadline = Date(timeIntervalSinceNow: 10)
        while opened.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        precondition(opened == [URL(string: "https://example.com/")!], "The link did not open in the browser")
        precondition(web.url?.scheme == "data" && web.title == "App", "The hosted app left its page")
        try Views.close(target)
        print("Hosted apps keep no data, and open other sites in the browser")
    }
}
