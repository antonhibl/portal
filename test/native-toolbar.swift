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
        precondition(WebViews.bind(title: window.title))
        precondition(WebViews.loadURL("data:text/html,<title>Toolbar test</title><h1>Heading</h1><p>needle one needle two needle three</p>", preview: true))
        let layout = [PaneLayout(id: 1, rectangle: editor.bounds)]
        precondition(WebViews.setLayout(layout))
        let container = window.contentView!.subviews.compactMap { $0 as? NativeContainer }.first!
        let web = container.content as! WKWebView
        let model = container.model
        wait("page did not load") { web.title == "Toolbar test" && !web.isLoading && model.hasHeadings }
        precondition(web.frame.height == 452 && container.toolbar!.frame.height == 28)
        func button(_ tooltip: String) -> NSButton {
            container.toolbar!.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == tooltip }!
        }
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
        _ = try NativeInput.perform("web:1", action: "unfocus")
        try model.perform("find")
        precondition(model.input?.ownership == .view, "Repeated find must focus its field")
        try model.perform("close-find")
        _ = try NativeInput.perform("web:1", action: "passthrough")
        precondition(model.input?.ownership == .passthrough)
        model.input?.toggleOwnership()
        precondition(model.input?.ownership == .emacs)
        NativeToolbar.configure(false)
        precondition(container.toolbar == nil && web.frame.height == 480)
        NativeToolbar.configure(true)
        precondition(container.toolbar != nil && web.frame.height == 452 && web.pageZoom == 1.1)
        precondition(WebViews.setLayout([]))
        precondition(container.isHidden && window.firstResponder === editor)
        precondition(WebViews.setLayout(layout))
        precondition(container.content === web && !container.isHidden && model.tocOpen && web.pageZoom == 1.1)
        try model.perform("reload")
        wait("reload") { !web.isLoading }
        precondition(web.pageZoom == 1.1 && model.tocOpen)
        try NativeToolbar.theme(#"{"background":[0.1,0.2,0.3],"success":[0,1,0]}"#)
        precondition(NativeToolbar.color("success") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        WebViews.destroy()
        precondition(window.contentView!.subviews.count == 1)
        print("Toolbar layout, focus, zoom limits, TOC, find, theme and retained state passed")
    }
}
