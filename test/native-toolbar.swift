// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AppKit/WebKit integration test. See docs/testing.md for the compiler command.
// The core owns every toolbar's state (native/Core/toolbar.c); these checks
// click real buttons, type into the real field and read what AppKit shows.
import AppKit
import WebKit

@main
struct CheckToolbar {
    @MainActor
    static func wait(_ description: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        check(predicate(), description)
    }

    @MainActor
    static func main() {
        runChecks { try run() }
    }

    @MainActor
    static func key(_ window: NSWindow, _ characters: String, ignoring: String? = nil, code: UInt16,
                    flags: NSEvent.ModifierFlags = []) -> NSEvent {
        require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false,
                                 keyCode: code))
    }

    /// Press a key as the event loop delivers a real one, which makes it the
    /// current event: the find field reads Shift from there.
    @MainActor
    static func press(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: false)
        NSApp.sendEvent(require(NSApp.nextEvent(matching: .keyDown, until: .distantFuture, inMode: .default,
                                                dequeue: true)))
    }

    /// Where the checks put the page and, below it, its pane's mode line.
    static let edges = [0, 0, 640, 480], bar = [0, 480, 640, 506]

    @MainActor
    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 506),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portal toolbar check"
        let editor = NSTextView(frame: require(window.contentView).bounds)
        require(window.contentView).addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let target = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("contents")]))
        try Views.place(target, edges: edges, title: window.title, bar: bar)
        try Views.load(target, "data:text/html,<title>Toolbar test</title><h1>Heading</h1><p>needle one needle two needle three</p>")
        var container = require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        let web = require(container.content as? WKWebView)
        func state() throws -> [String: Any] { try Views.toolbar(target, "state") }
        func flag(_ name: String) -> Bool { (try? state())?[name] as? Bool ?? false }
        wait("page did not load") { web.title == "Toolbar test" && !web.isLoading && flag("headings") }
        // While Emacs has the keyboard, its mode line shows: no strip.
        check(container.toolbar == nil && web.frame.size == NSSize(width: 640, height: 480))
        // While the page has it, the strip covers the mode line, exactly, and
        // the page keeps its size.
        _ = try Views.input(target, action: "focus")
        let strip = require(container.toolbar, "No strip while the page has the keyboard")
        check(strip.frame == NSRect(x: 0, y: 480, width: 640, height: 26), "Strip at \(strip.frame)")
        check(web.frame == NSRect(x: 0, y: 0, width: 640, height: 480), "Page at \(web.frame)")
        // Clicks beside the page and strip reach Emacs, not the container.
        check(container.hitTest(NSPoint(x: 10, y: 10)) !== container)
        func button(_ tooltip: String) -> NSButton {
            require(require(container.toolbar).subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == tooltip }, "Missing toolbar button: \(tooltip)")
        }
        func dot() -> NSButton {
            require(require(container.toolbar).subviews.compactMap { $0 as? NSButton }.first { $0.frame.minX == 5 && !$0.isHidden },
                    "Missing ownership dot")
        }
        func field() -> NSSearchField {
            require(require(container.toolbar).subviews.compactMap { $0 as? NSSearchField }.first)
        }
        func inPage() -> Bool {
            window.firstResponder === web || (window.firstResponder as? NSView)?.isDescendant(of: web) == true
        }
        // Buttons sit inside the strip, whatever its height.
        check(button("Reload").frame.maxY <= 26 && button("Reload").frame.minY >= 0)
        check(field().isHidden && container.state.owner == .view)
        // Previews go back and forward like pages; only Markdown ones open in Emacs.
        check(!button("Back").isHidden && !button("Back").isEnabled && !button("Forward").isEnabled)
        check(button("Open in Emacs").isHidden && button("Table of contents").isEnabled)
        try Views.load(target, "data:text/html,<title>Second page</title>")
        wait("second page did not load") { web.title == "Second page" && button("Back").isEnabled }
        check(!button("Table of contents").isEnabled, "A page without headings offers its contents")
        // Buttons never take the keyboard: it stays in the page.
        button("Back").performClick(nil)
        wait("back did not return") { web.title == "Toolbar test" && !web.isLoading && flag("headings") }
        check(button("Forward").isEnabled && !button("Back").isEnabled && inPage())
        button("Zoom in").performClick(nil)
        check(web.pageZoom == 1.1 && inPage() && button("Reset to 100%").title == "110%")
        _ = try Views.toolbar(target, "increase")
        check(web.pageZoom == 1.25)
        for _ in 0..<20 { _ = try Views.toolbar(target, "increase") }
        check(web.pageZoom == 3 && !button("Zoom in").isEnabled)
        for _ in 0..<20 { button("Zoom out").performClick(nil) }
        check(web.pageZoom == 0.5 && !button("Zoom out").isEnabled && button("Zoom in").isEnabled)
        button("Reset to 100%").performClick(nil)
        check(web.pageZoom == 1 && button("Reset to 100%").title == "100%")
        button("Table of contents").performClick(nil)
        check(flag("toc") && button("Table of contents").accessibilityValue() as? Int == 1 && inPage())
        var tocVisible = false
        web.evaluateJavaScript("!!document.querySelector('nav[aria-label=\"Table of contents\"]:not([hidden])')") { value, _ in tocVisible = value as? Bool ?? false }
        wait("TOC missing") { tocVisible }
        button("Zoom in").performClick(nil)
        check(web.pageZoom == 1.1 && inPage())
        // The dot returns to Emacs, whose mode line shows again.
        check(dot().toolTip == "Click to return to Emacs")
        dot().performClick(nil)
        check(window.firstResponder === editor && container.state.owner == .emacs && container.toolbar == nil)
        // Find, from Emacs: the strip shows with its real field, which takes
        // the keyboard and edits natively.
        _ = try Views.toolbar(target, "find")
        check(container.toolbar != nil && !field().isHidden && container.state.owner == .view,
              "find did not own the keyboard")
        check(!inPage() && field().currentEditor() != nil)
        require(field().currentEditor()).insertText("needle")
        wait("find count") { container.state.matches == 3 && container.state.match == 1 }
        check(container.state.query == "needle" && field().stringValue == "needle")
        press(key(window, "\r", code: 36))
        wait("find next") { container.state.match == 2 }
        press(key(window, "\r", code: 36, flags: .shift))
        wait("find previous") { container.state.match == 1 }
        press(key(window, "\r", code: 36))
        press(key(window, "\r", code: 36))
        wait("rapid find next") { container.state.match == 3 }
        button("Next match").performClick(nil)
        wait("find wraps") { container.state.match == 1 }
        press(key(window, "\u{1b}", code: 53))
        check(!container.state.finding && container.state.owner == .view && field().isHidden)
        check(inPage(), "Closing find did not return the keyboard to the page")
        // The page does not use Command-F, so the toolbar's shortcut gets it.
        press(key(window, "f", code: 3, flags: .command))
        wait("Command-F did not open find") { container.state.finding && !inPage() }
        wait("find query was not retained") { container.state.matches == 3 }
        // Closing find after the user moved to Emacs leaves Emacs the keyboard,
        // and the mode line shows again.
        window.makeFirstResponder(editor)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        check(container.state.owner == .emacs && container.toolbar != nil)
        _ = try Views.toolbar(target, "close-find")
        check(window.firstResponder === editor && !container.state.finding && container.toolbar == nil,
              "Closing find took the keyboard or left the strip")
        // Visibility is live, the page never resizes, and it keeps its state.
        _ = try Views.input(target, action: "focus")
        Views.showToolbars(false)
        check(container.toolbar == nil && web.frame.height == 480)
        Views.showToolbars(true)
        check(container.toolbar != nil && web.frame.height == 480 && web.pageZoom == 1.1)
        // A pane without a mode line has no strip.
        try Views.place(target, edges: edges, title: window.title)
        check(container.toolbar == nil && web.frame.height == 480 && container.state.owner == .view)
        try Views.place(target, edges: edges, title: window.title, bar: bar)
        check(container.toolbar != nil)
        try Views.hide(target)
        check(web.window !== window && web.isHiddenOrHasHiddenAncestor && window.firstResponder === editor)
        try Views.place(target, edges: edges, title: window.title, bar: bar)
        container = require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        check(container.content === web && !container.isHidden && flag("toc") && web.pageZoom == 1.1)
        let kept = try state()["query"] as? String
        check(container.toolbar == nil && kept == "needle")
        _ = try Views.toolbar(target, "reload")
        wait("reload") { !web.isLoading }
        tocVisible = false
        web.evaluateJavaScript("!!document.querySelector('nav[aria-label=\"Table of contents\"]:not([hidden])')") { value, _ in tocVisible = value as? Bool ?? false }
        wait("TOC not kept across reload") { tocVisible }
        check(web.pageZoom == 1.1 && flag("toc"))
        // Command-R reloads as the button does, while the view has the keyboard.
        _ = try Views.input(target, action: "focus")
        var marked = false
        web.evaluateJavaScript("window.marked = true") { _, _ in marked = true }
        wait("page was not marked") { marked }
        press(key(window, "r", code: 15, flags: .command))
        wait("Command-R did not reload") {
            web.evaluateJavaScript("window.marked === undefined") { value, _ in marked = !(value as? Bool ?? false) }
            return !marked && !web.isLoading
        }
        check(button("Reset to 100%").title == "110%")
        // Colors are the core's; the strip draws them.
        var colors = portal_colors()
        colors.success = portal_color(set: true, red: 0, green: 1, blue: 0)
        colors.background = portal_color(set: true, red: 0.1, green: 0.2, blue: 0.3)
        Views.paintToolbars(colors)
        check(container.state.color("success") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        check(require(container.toolbar).state.color("background") == NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        Views.paintToolbars(portal_colors())
        check(container.state.color("success") == .systemGreen)
        // The tint is the dot's and the label's color, and falls back to success.
        check(container.state.color("tint") == .systemGreen && container.state.ownerColor == .systemGreen)
        colors.tint = portal_color(set: true, red: 1, green: 0, blue: 1)
        Views.paintToolbars(colors)
        check(container.state.ownerColor == NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        check(container.state.tintedBackground != container.state.color("background"), "Strip not tinted")
        // The strip keeps the tint's hue at the mode line's brightness.
        let tinted = require(container.state.tintedBackground.usingColorSpace(.sRGB))
        check(abs(tinted.hueComponent - 5.0 / 6) < 0.02 && abs(tinted.brightnessComponent - 0.3) < 0.02,
              "Tinted strip is \(tinted)")
        // A strip color is the background as it is, while the view has the keyboard.
        colors.strip = portal_color(set: true, red: 0.2, green: 0.4, blue: 0.3)
        Views.paintToolbars(colors)
        check(container.state.tintedBackground == NSColor(srgbRed: 0.2, green: 0.4, blue: 0.3, alpha: 1))
        colors.strip = portal_color()
        Views.paintToolbars(colors)
        // Text follows Emacs's font; without one, 11 point monospace.
        check(container.state.font.pointSize == 11)
        Views.paintToolbars(colors, family: "Menlo", points: 17)
        check(container.state.font.pointSize == 17 && container.state.font.familyName == "Menlo",
              "Font is \(container.state.font)")
        Views.paintToolbars(colors)
        // The label is the core's; the strip shows it, truncated, in the tint.
        func labelField() -> NSTextField? {
            require(container.toolbar).subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "~/notes/plan.md" }
        }
        check(labelField() == nil)
        try Views.label(target, "~/notes/plan.md")
        let shown = require(labelField(), "Missing toolbar label")
        check(!shown.isHidden && shown.textColor == container.state.ownerColor && shown.frame.minX == 95,
              "Label at \(shown.frame), hidden \(shown.isHidden)")
        check(shown.frame.maxX < button("Find in page").frame.minX)
        Views.paintToolbars(portal_colors())
        dot().performClick(nil)
        check(container.state.owner == .emacs && container.toolbar == nil)
        try Views.close(target)
        check(require(window.contentView).subviews.count == 1)
        try checkWithoutToolbar(window: window)
        try checkMarkdown(window: window, editor: editor)
        print("Toolbar over the mode line, focus, zoom limits, TOC, find, back, forward, theme and retained state passed")
    }

    /// A view without a toolbar fills its pane and leaves the mode line,
    /// even while it has the keyboard.
    @MainActor
    static func checkWithoutToolbar(window: NSWindow) throws {
        let target = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(target, edges: edges, title: window.title, bar: bar)
        _ = try Views.input(target, action: "focus")
        let container = require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        check(container.toolbar == nil && container.content.frame.height == 480)
        Views.showToolbars(false)
        Views.showToolbars(true)
        check(container.toolbar == nil && container.content.frame.height == 480)
        _ = try Views.input(target, action: "unfocus")
        try Views.close(target)
        print("Views without a toolbar fill their pane")
    }

    /// A hosted Markdown preview's Open in Emacs gives Emacs the keyboard and
    /// asks it, over the bridge, to open the file.
    @MainActor
    static func checkMarkdown(window: NSWindow, editor: NSView) throws {
        var fds: [Int32] = [0, 0]
        check(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        check(portal_channel_connect(fds[1]))
        defer { _ = portal_channel_connect(-1); close(fds[0]) }
        func container() -> NativeContainer {
            require(require(window.contentView).subviews.compactMap { $0 as? NativeContainer }.first)
        }
        func edit(hosted: Bool) throws -> (String, NSButton) {
            let target = try Views.open(kind: "web", options: ViewOptions(values: [
                "toolbar": .string("markdown"), "hosted": .flag(hosted)]))
            try Views.place(target, edges: edges, title: window.title, bar: bar)
            _ = try Views.input(target, action: "focus")
            check(!require(container().toolbar).subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "Table of contents" }!.isHidden)
            return (target, require(require(container().toolbar).subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "Open in Emacs" }, "Missing Open in Emacs button"))
        }
        // Without a bridge there is no way to ask Emacs, so no button.
        let (plain, hidden) = try edit(hosted: false)
        check(hidden.isHidden, "A preview without a bridge offers Open in Emacs")
        _ = try Views.input(plain, action: "unfocus")
        try Views.close(plain)
        let (target, button) = try edit(hosted: true)
        check(!button.isHidden)
        let focused = try Views.input(target, action: "focus")
        check(focused && window.firstResponder !== editor)
        // Clicking while Emacs reads a key sequence ends that read first, so
        // Emacs runs the edit instead of taking it for the sequence's next
        // key. The page does not use C-x, so Emacs reads from it.
        NSApp.sendEvent(key(window, "\u{18}", ignoring: "x", code: 7, flags: .control))
        wait("The chord did not reach Emacs") { container().state.owner == .pending }
        button.performClick(nil)
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(fds[0], &buffer, buffer.count)
        let records = count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        let kinds = records.split(separator: "\n").map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        check(kinds == ["key \(target)", "escape \(target)", "bridge \(target)"],
                     "Open in Emacs did not end the key sequence and notify Emacs: \(records)")
        let messages = try Views.receive(target)
        check(messages == #"[{"type":"edit"}]"#, "Open in Emacs did not ask Emacs to edit")
        check(window.firstResponder === editor, "Open in Emacs left the keyboard in the view")
        check(container().state.owner == .emacs)
        try Views.close(target)
        print("Markdown previews open their file in Emacs from the toolbar")
    }
}
