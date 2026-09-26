// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AppKit/WebKit integration test. See README.md for the compiler command.
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
        precondition(predicate(), description)
    }

    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Portal toolbar check"
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let target = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("contents")]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        try Views.view(target, as: WebSession.self).load("data:text/html,<title>Toolbar test</title><h1>Heading</h1><p>needle one needle two needle three</p>")
        var container = window.contentView!.subviews.compactMap { $0 as? NativeContainer }.first!
        let web = container.content as! WKWebView
        let model = container.model
        wait("page did not load") { web.title == "Toolbar test" && !web.isLoading && model.hasHeadings }
        precondition(web.frame.height == 452 && container.toolbar!.frame.height == 28)
        func button(_ tooltip: String) -> NSButton {
            container.toolbar!.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == tooltip }!
        }
        // Previews go back and forward like pages; only Markdown ones open in Emacs.
        precondition(!button("Back").isHidden && !button("Back").isEnabled && !button("Forward").isEnabled)
        precondition(button("Open in Emacs").isHidden)
        try Views.view(target, as: WebSession.self).load("data:text/html,<title>Second page</title>")
        wait("second page did not load") { web.title == "Second page" && button("Back").isEnabled }
        button("Back").performClick(nil)
        wait("back did not return") { web.title == "Toolbar test" && !web.isLoading && model.hasHeadings }
        precondition(button("Forward").isEnabled && !button("Back").isEnabled && window.firstResponder === editor)
        button("Zoom in").performClick(nil)
        precondition(web.pageZoom == 1.1 && window.firstResponder === editor)
        try model.perform("increase")
        precondition(web.pageZoom == 1.25)
        for _ in 0..<20 { try model.perform("increase") }
        precondition(web.pageZoom == 3 && !button("Zoom in").isEnabled)
        for _ in 0..<20 { try model.perform("decrease") }
        precondition(web.pageZoom == 0.5 && !button("Zoom out").isEnabled)
        try model.perform("reset")
        precondition(web.pageZoom == 1)
        try model.perform("toc")
        precondition(model.tocOpen)
        var tocVisible = false
        web.evaluateJavaScript("!!document.querySelector('nav[aria-label=\"Table of contents\"]:not([hidden])')") { value, _ in tocVisible = value as? Bool ?? false }
        wait("TOC missing") { tocVisible }
        model.input?.toggleOwnership()
        precondition(model.input?.ownership == .view)
        let responder = window.firstResponder
        button("Zoom in").performClick(nil)
        precondition(window.firstResponder === responder)
        model.input?.toggleOwnership()
        precondition(window.firstResponder === editor && model.input?.ownership == .emacs)
        try model.perform("find")
        precondition(model.input?.ownership == .view, "find did not own the keyboard")
        precondition(window.firstResponder !== web)
        model.query = "needle"
        model.find()
        wait("find count") { model.matchCount == 3 && model.matchIndex == 1 }
        model.find()
        wait("find next") { model.matchIndex == 2 }
        model.find(backwards: true)
        wait("find previous") { model.matchIndex == 1 }
        model.find()
        model.find()
        wait("rapid find next") { model.matchIndex == 3 }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        app.sendEvent(escape)
        precondition(!model.finding && model.input?.ownership == .view)
        try model.perform("find")
        wait("find query was not retained") { model.matchCount == 3 }
        _ = try NativeInput.perform(target, action: "unfocus")
        try model.perform("find")
        precondition(model.input?.ownership == .view, "Repeated find must focus its field")
        try model.perform("close-find")
        _ = try NativeInput.perform(target, action: "passthrough")
        precondition(model.input?.ownership == .passthrough)
        model.input?.toggleOwnership()
        precondition(model.input?.ownership == .emacs)
        NativeToolbar.configure(false)
        precondition(container.toolbar == nil && web.frame.height == 480)
        NativeToolbar.configure(true)
        precondition(container.toolbar != nil && web.frame.height == 452 && web.pageZoom == 1.1)
        try Views.hide(target)
        precondition(web.window !== window && web.isHiddenOrHasHiddenAncestor && window.firstResponder === editor)
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        container = window.contentView!.subviews.compactMap { $0 as? NativeContainer }.first!
        precondition(container.content === web && !container.isHidden && model.tocOpen && web.pageZoom == 1.1)
        try model.perform("reload")
        wait("reload") { !web.isLoading }
        precondition(web.pageZoom == 1.1 && model.tocOpen)
        try NativeToolbar.theme(#"{"background":[0.1,0.2,0.3],"success":[0,1,0]}"#)
        precondition(NativeToolbar.color("success") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        try Views.close(target)
        precondition(window.contentView!.subviews.count == 1)
        try checkMarkdown(window: window, editor: editor)
        print("Toolbar layout, focus, zoom limits, TOC, find, back, forward, theme and retained state passed")
    }

    /// A hosted Markdown preview's Open in Emacs gives Emacs the keyboard and
    /// asks it, over the bridge, to open the file.
    @MainActor
    static func checkMarkdown(window: NSWindow, editor: NSView) throws {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        Views.channel.connect(fds[1])
        defer { Views.channel.connect(-1); close(fds[0]) }
        func container(_ target: String) -> NativeContainer {
            window.contentView!.subviews.compactMap { $0 as? NativeContainer }.first!
        }
        func edit(hosted: Bool) throws -> (String, NSButton) {
            let target = try Views.open(kind: "web", options: ViewOptions(values: [
                "toolbar": .string("markdown"), "hosted": .flag(hosted)]))
            try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
            let container = window.contentView!.subviews.compactMap { $0 as? NativeContainer }.first!
            precondition(container.model.kind == .preview)
            return (target, container.toolbar!.subviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == "Open in Emacs" }!)
        }
        // Without a bridge there is no way to ask Emacs, so no button.
        let (plain, hidden) = try edit(hosted: false)
        precondition(hidden.isHidden, "A preview without a bridge offers Open in Emacs")
        try Views.close(plain)
        let (target, button) = try edit(hosted: true)
        precondition(!button.isHidden)
        let focused = try NativeInput.perform(target, action: "focus")
        precondition(focused && window.firstResponder !== editor)
        // Clicking while Emacs reads a prefix ends that read first, so Emacs
        // runs the edit instead of taking it for the prefix's next key.
        NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{2}",
                                         charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!)
        precondition(container(target).model.input?.ownership == .pending, "The prefix is not pending")
        button.performClick(nil)
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(fds[0], &buffer, buffer.count)
        let records = count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        let kinds = records.split(separator: "\n").map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        precondition(kinds == ["prefix \(target)", "escape \(target)", "bridge \(target)"],
                     "Open in Emacs did not end the prefix and notify Emacs: \(records)")
        let messages = try Views.view(target, as: WebSession.self).receive()
        precondition(messages == #"[{"type":"edit"}]"#, "Open in Emacs did not ask Emacs to edit")
        precondition(window.firstResponder === editor, "Open in Emacs left the keyboard in the view")
        try Views.close(target)
        print("Markdown previews open their file in Emacs from the toolbar")
    }
}
