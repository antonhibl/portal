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
        try checkBridge(window: window)
        try checkLinks(window: window, editor: editor)
        checkChannel()
        try checkReconnect(window: window)
    }

    /// Replacing the pipe ends a prefix whose record it dropped, so the view
    /// does not keep the keyboard waiting for an answer that cannot come.
    @MainActor
    static func checkReconnect(window: NSWindow) throws {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        Views.connect(fds[1])
        let filler = [UInt8](repeating: UInt8(ascii: "."), count: 512)
        while write(fds[1], filler, filler.count) > 0 {}
        while write(fds[1], filler, 1) > 0 {}
        let target = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("none")]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        let input = Views.input(target)!
        let prefix = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{2}",
                                      charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        precondition(input.handleKeyEvent(prefix) && input.ownership == .pending, "The prefix was not captured")
        close(fds[0])
        precondition(pipe(&fds) == 0)
        Views.connect(fds[1])
        defer { Views.connect(-1); close(fds[0]) }
        precondition(input.ownership != .pending, "Reconnecting left a dropped prefix pending")
        try Views.close(target)
        print("Replacing the pipe ends a prefix whose record it dropped")
    }

    /// A full pipe delays records, without losing or reordering them.
    @MainActor
    static func checkChannel() {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        Views.channel.connect(fds[1])
        defer { Views.channel.connect(-1); close(fds[0]) }
        precondition(!Views.channel.notify("two words", target: "web:1"), "A malformed record was accepted")
        // Fill the pipe, as an Emacs busy with a long command leaves it.
        let filler = [UInt8](repeating: UInt8(ascii: "."), count: 512)
        var filled = 0
        while case let count = write(fds[1], filler, filler.count), count > 0 { filled += count }
        precondition(Views.channel.notify("escape", target: "web:1", fields: ["2", "0"])
                     && Views.channel.notify("bridge", target: "web:1"), "A full pipe refused records")
        let expected = "escape web:1 2 0\nbridge web:1\n"
        var received: [UInt8] = []
        let deadline = Date(timeIntervalSinceNow: 5)
        while received.count < filled + expected.utf8.count && Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fds[0], &buffer, buffer.count)
            if count > 0 { received += buffer[..<count] }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        let records = String(decoding: received.dropFirst(filled), as: UTF8.self)
        precondition(records == expected, "Records were lost or reordered: \(records)")
        print("A full pipe delays records in order, and loses none")
    }

    /// A pipe standing in for Emacs's end of `Views.channel`.
    @MainActor
    static func connectRecords() -> (read: () -> String, close: () -> Void) {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        Views.channel.connect(fds[1])
        return ({
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fds[0], &buffer, buffer.count)
            return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        }, { Views.channel.connect(-1); close(fds[0]) })
    }

    /// A hosted app reports each page it commits over its bridge. Clicking it
    /// asks Emacs to select its pane, and its links to local files go to Emacs,
    /// with the keyboard, over the bridge too, however long their paths.
    @MainActor
    static func checkLinks(window: NSWindow, editor: NSView) throws {
        let (records, disconnect) = connectRecords()
        defer { disconnect() }
        let target = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(target, edges: [0, 0, 640, 480], title: window.title)
        let session = try Views.view(target, as: WebSession.self)
        var received = ""
        /// Wait for RECORD, then return the bridge's messages as [type, url] pairs.
        func wait(for record: String) -> [[String]] {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !received.contains(record) && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                received += records()
            }
            precondition(received.contains(record), "Expected \(record), got \(received)")
            received = ""
            let messages = try! JSONSerialization.jsonObject(with: Data(session.receive().utf8)) as! [[String: Any]]
            return messages.map { [$0["type"] as! String, $0["url"] as? String ?? ""] }
        }
        let file = "file:///tmp/" + String(repeating: "r%C3%A9sum%C3%A9%20", count: 40) + "notes.ts#L4"
        let page = "<title>Links</title><a style='display:block;height:80px' href='\(file)'>code</a>"
        let app = "data:text/html;base64," + Data(page.utf8).base64EncodedString()
        let first = "data:text/html,%3Ctitle%3EFirst%3C/title%3E"
        let web = window.contentView!.subviews.compactMap { $0 as? WKWebView }.first!
        // Every committed page is reported, including after going back.
        try session.load(first)
        precondition(wait(for: "bridge \(target)\n") == [["page", first]])
        try session.load(app)
        precondition(wait(for: "bridge \(target)\n") == [["page", app]])
        web.goBack()
        precondition(wait(for: "bridge \(target)\n") == [["page", first]])
        web.goForward()
        precondition(wait(for: "bridge \(target)\n") == [["page", app]])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        precondition(window.makeFirstResponder(editor))
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 440), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // This process cannot activate, so AppKit swallows a click in its window
        // after the monitor sees it; the page gets the same events directly.
        let down = mouse(.leftMouseDown)
        NSApp.sendEvent(down)
        web.mouseDown(with: down)
        web.mouseUp(with: mouse(.leftMouseUp))
        precondition(file.utf8.count > Int(PIPE_BUF))
        precondition(wait(for: "select \(target)\nbridge \(target)\n") == [["follow", file]],
                     "The link did not reach Emacs")
        precondition(window.firstResponder === editor, "Following a link left the keyboard in the view")
        precondition(web.url?.scheme == "data" && !web.isLoading, "Following a local link left the page")
        try Views.close(target)
        print("Hosted apps report their pages, clicks select their pane, and local links go to Emacs")
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

    /// Only a hosted app has a bridge, and only its main frame may post. One
    /// record announces queued messages until Emacs receives them, in order.
    @MainActor
    static func checkBridge(window: NSWindow) throws {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        Views.channel.connect(fds[1])
        defer { Views.channel.connect(-1); close(fds[0]) }
        func records() -> String {
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = read(fds[0], &buffer, buffer.count)
            return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
        }
        func wait(until done: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        }
        func types(_ web: WebSession) -> [String] {
            let messages = try! JSONSerialization.jsonObject(with: Data(web.receive().utf8)) as! [[String: Any]]
            return messages.map { $0["type"] as! String }
        }

        let page = """
            <iframe srcdoc="<script>webkit.messageHandlers.portal.postMessage({type:'frame'})</script>"
              onload="webkit.messageHandlers.portal.postMessage({type:'second'})"></iframe>
            <script>
            window.portalBridge = {receive: async (m) => webkit.messageHandlers.portal.postMessage({type: 'echo-' + m.type})};
            webkit.messageHandlers.portal.postMessage({type: 'follow', url: 'file:///etc/passwd'});
            webkit.messageHandlers.portal.postMessage({type: 'first'});
            </script>
            """
        let app = "data:text/html;base64," + Data(page.utf8).base64EncodedString()
        let hosted = try Views.open(kind: "web", options: ViewOptions(values: [
            "toolbar": .string("none"), "hosted": .flag(true)]))
        try Views.place(hosted, edges: [0, 0, 640, 480], title: window.title)
        let web = try Views.view(hosted, as: WebSession.self)
        try web.load(app)
        var received = ""
        wait { received += records(); return received.contains("\n") }
        precondition(received == "bridge \(hosted)\n", "Expected one bridge record, got \(received)")
        // Let the frame load and post too.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        precondition(records().isEmpty, "A second record went out before Emacs received the first")
        precondition(types(web) == ["page", "first", "second"], "The bridge lost, reordered or accepted a frame's or reserved message")
        precondition(types(web).isEmpty, "Receiving did not drain the bridge")
        try web.send(#"{"type":"ping"}"#)
        received = ""
        wait { received += records(); return received.contains("\n") }
        precondition(received == "bridge \(hosted)\n", "Receiving did not re-arm the bridge record")
        precondition(types(web) == ["echo-ping"], "The app did not receive Emacs's message")
        // A record still waiting when Emacs replaces its pipe is dropped, so the
        // bridge announces its messages again on the new one.
        let filler = [UInt8](repeating: UInt8(ascii: "."), count: 512)
        while write(fds[1], filler, filler.count) > 0 {}
        while write(fds[1], filler, 1) > 0 {}
        try web.send(#"{"type":"pong"}"#)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        close(fds[0])
        precondition(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        Views.connect(fds[1])
        received = ""
        wait { received += records(); return received.contains("\n") }
        precondition(received == "bridge \(hosted)\n", "Reconnecting the channel stalled the bridge")
        precondition(types(web) == ["echo-pong"], "The bridge lost a message across reconnecting")
        try Views.close(hosted)

        let plain = try Views.open(kind: "web", options: ViewOptions(values: ["toolbar": .string("none")]))
        try Views.place(plain, edges: [0, 0, 640, 480], title: window.title)
        try Views.view(plain, as: WebSession.self).load(app)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        precondition(records().isEmpty, "A page that is not a hosted app reached the bridge")
        for use in [{ try Views.view(plain, as: WebSession.self).send("{}") },
                    { _ = try Views.view(plain, as: WebSession.self).receive() }] {
            do { try use(); preconditionFailure("A page that is not a hosted app has a bridge") } catch {}
        }
        try Views.close(plain)
        print("Only a hosted app's main frame uses the bridge, which announces its messages once until received")
    }
}
