// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import GhosttyTerminal
import Darwin

@MainActor
private final class HostedTerminal: TerminalView, TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceOpenURLDelegate, NativeSurface {
    var nativeView: NSView { self }
    weak var session: TerminalSession?
    func handleKeyEvent(_ event: NSEvent) -> Bool { session?.handleKeyEvent(event) ?? false }
    var terminalTitle = "Terminal"
    var grid: TerminalGridMetrics?
    var terminalSurface: TerminalSurface?
    var closed = false

    init(directory: String) {
        super.init(frame: .zero)
        delegate = self
        configuration = TerminalSurfaceOptions(
            workingDirectory: directory,
            envVars: ["INSIDE_EMACS": "portal-ghostty"],
            waitAfterCommand: true)
        controller = TerminalController { builder in
            builder.withFontThicken(false)
            // Window/tab actions belong to Emacs, not the embedded engine.
            builder.withCustom("keybind", "super+n=unbind")
            builder.withCustom("keybind", "super+t=unbind")
            builder.withCustom("keybind", "super+w=unbind")
            builder.withCustom("keybind", "super+q=unbind")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func terminalDidChangeTitle(_ title: String) { terminalTitle = title }
    func terminalDidResize(_ size: TerminalGridMetrics) { grid = size }
    func terminalDidAttachSurface(_ surface: TerminalSurface) { terminalSurface = surface }
    func terminalDidDetachSurface() { terminalSurface = nil }
    func terminalDidClose(processAlive: Bool) {
        closed = true
        session?.returnFocus()
    }
    func terminalDidRequestOpenURL(_ text: String, kind: TerminalOpenURLKind) {
        guard let url = URL(string: text),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class TerminalSession: NativeInputHandler {
    let id: Int
    let terminal: HostedTerminal
    let host: NativeHost
    var edges: [Int] = []
    var prefixEvent: NSEvent?
    private var waitingForLisp = false
    private var readingPrefix = false
    private var pendingEvents: [NSEvent] = []

    init(id: Int, host: NativeHost, directory: String) throws {
        self.id = id
        self.host = host
        terminal = HostedTerminal(directory: directory)
        if let issue = terminal.controller?.lastConfigurationIssue { throw NativeError.message(issue) }
        terminal.session = self
    }

    func layout(_ rectangle: [Int]) throws {
        edges = rectangle
        if rectangle.isEmpty {
            terminal.setSurfaceVisible(false)
            // Ghostty must stay attached so hidden shells keep draining their PTYs.
            host.hide(terminal)
            return
        }
        let frame = CGRect(x: rectangle[0], y: rectangle[1],
                           width: rectangle[2] - rectangle[0], height: rectangle[3] - rectangle[1])
        guard host.place(terminal, rectangle: frame) else {
            throw NativeError.message("The terminal's frame was deleted")
        }
        terminal.setSurfaceVisible(true)
        terminal.fitToSize()
        guard terminal.terminalSurface != nil else {
            throw NativeError.message("Ghostty could not create a Metal terminal surface")
        }
    }

    func returnFocus() { host.returnFocus(from: terminal) }

    // Prefix buffering and key policy belong to the terminal. NativeHost calls
    // this only for its focused surface or its explicitly captured prefix input.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if waitingForLisp {
            pendingEvents.append(event)
            return true
        }
        if readingPrefix {
            guard event.type == .keyDown else { return false }
            let literal = Terminals.isPrefix(event)
            let cancel = event.modifierFlags.intersection(Terminals.modifiers) == .control &&
                event.charactersIgnoringModifiers == "g"
            let escape = event.keyCode == 53 && event.modifierFlags.contains(.command)
            if literal || cancel || escape {
                if !event.isARepeat {
                    let kind = literal ? "literal" : (cancel ? "cancel" : "escape")
                    _ = Terminals.notify("\(kind) \(id)\n")
                }
                return true
            }
            return false
        }
        Terminals.didFocus(id)
        if event.type == .keyDown {
            if event.keyCode == 53 && event.modifierFlags.contains(.command) {
                returnFocus()
                return true
            }
            if Terminals.isPrefix(event) {
                if !event.isARepeat {
                    prefixEvent = event
                    returnFocus()
                    if Terminals.notify("\(id)\n") {
                        waitingForLisp = true
                        host.captureInput(self)
                    }
                }
                return true
            }
        }
        switch event.type {
        case .keyDown: terminal.keyDown(with: event)
        case .keyUp: terminal.keyUp(with: event)
        case .flagsChanged: terminal.flagsChanged(with: event)
        default: break
        }
        return true
    }

    @discardableResult
    func acknowledge(replay: Bool) -> Bool {
        if !replay {
            readingPrefix = false
            host.releaseInput(self)
        }
        guard waitingForLisp else { return false }
        waitingForLisp = false
        readingPrefix = replay
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        if replay {
            for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
        }
        return true
    }

    func close() {
        acknowledge(replay: false)
        host.remove(terminal)
    }
}

struct TerminalSnapshot: Sendable {
    var ready: Bool
    var visible: Bool
    var focused: Bool
    var title: String
    var closed: Bool
    var columns: Int
    var rows: Int
    var edges: [Int]
    var layer: String
}

/// Independent Ghostty sessions. Nothing here depends on the web feature.
@MainActor
enum Terminals {
    private static var sessions: [Int: TerminalSession] = [:]
    private static var nextID = 0
    private static var activeID: Int?
    private static var channel: Int32 = -1
    private static var prefixCharacter = "b"
    private static var prefixModifiers: NSEvent.ModifierFlags = .control
    static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    static func isPrefix(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(modifiers) == prefixModifiers &&
            event.charactersIgnoringModifiers?.lowercased() == prefixCharacter
    }

    static func notify(_ message: String) -> Bool {
        message.withCString { Darwin.write(channel, $0, message.utf8.count) } == message.utf8.count
    }

    private static func session(_ id: Int?) -> TerminalSession? {
        guard let id = id ?? activeID else { return nil }
        return sessions[id]
    }

    static func didFocus(_ id: Int) { activeID = id }

    static func open(title: String, directory: String) throws -> Int {
        guard let host = NativeHost.bind(title: title) else {
            throw NativeError.message("Cannot find the requested native Emacs frame")
        }
        nextID += 1
        sessions[nextID] = try TerminalSession(id: nextID, host: host, directory: directory)
        activeID = nextID
        return nextID
    }

    static func layout(_ edges: [Int], id: Int?) throws {
        guard let session = session(id) else { throw NativeError.message("No native terminal is open") }
        try session.layout(edges)
    }

    static func focus(_ id: Int?) throws {
        guard let session = session(id), !session.terminal.isHidden,
              session.terminal.acquireProgrammaticFocus() else {
            throw NativeError.message("No visible terminal to focus")
        }
        activeID = session.id
    }

    static func unfocus(_ id: Int?) { session(id)?.returnFocus() }

    static func destroy(_ id: Int?) {
        guard let session = session(id) else { return }
        session.close()
        sessions[session.id] = nil
        if activeID == session.id { activeID = sessions.keys.max() }
    }

    static func acknowledge(_ id: Int, replay: Bool) -> Bool {
        session(id)?.acknowledge(replay: replay) ?? false
    }

    static func connectChannel(_ fd: Int32) {
        if channel >= 0 { Darwin.close(channel) }
        channel = fd
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }

    static func configurePrefix(_ character: String, flags: Int) throws {
        guard flags >= 0 else { throw NativeError.message("Prefix modifiers must be nonnegative") }
        prefixCharacter = character.lowercased()
        prefixModifiers = NSEvent.ModifierFlags(rawValue: UInt(flags)).intersection(modifiers)
    }

    static func input(_ text: String, enter: Bool, id: Int?) throws {
        guard let terminal = session(id)?.terminal, terminal.paste(text: text) else {
            throw NativeError.message("No terminal accepting input")
        }
        if enter { _ = terminal.sendKey(.enter) }
    }

    static func text(_ id: Int?) throws -> String {
        guard let surface = session(id)?.terminal.terminalSurface else {
            throw NativeError.message("No terminal surface to copy")
        }
        guard surface.performBindingAction("select_all") else {
            throw NativeError.message("Ghostty could not select terminal text")
        }
        return surface.readSelection() ?? ""
    }

    static func snapshot(_ id: Int?) -> TerminalSnapshot? {
        guard let session = session(id) else { return nil }
        let terminal = session.terminal
        return TerminalSnapshot(
            ready: terminal.terminalSurface != nil,
            visible: terminal.window != nil && !terminal.isHiddenOrHasHiddenAncestor,
            focused: session.host.ownsFocus(terminal),
            title: terminal.terminalTitle, closed: terminal.closed,
            columns: Int(terminal.grid?.columns ?? 0), rows: Int(terminal.grid?.rows ?? 0),
            edges: session.edges,
            layer: terminal.layer.map { NSStringFromClass(type(of: $0)) } ?? "")
    }

    static func sendPrefix(_ id: Int) throws {
        guard let session = session(id), let down = session.prefixEvent,
              let up = NSEvent.keyEvent(with: .keyUp, location: down.locationInWindow,
                modifierFlags: down.modifierFlags, timestamp: down.timestamp,
                windowNumber: down.windowNumber, context: nil, characters: down.characters ?? "",
                charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "",
                isARepeat: false, keyCode: down.keyCode) else {
            throw NativeError.message("No captured prefix key to send")
        }
        // AppKit interpretation must run with the terminal as first responder.
        try focus(id)
        session.terminal.keyDown(with: down)
        session.terminal.keyUp(with: up)
    }
}
