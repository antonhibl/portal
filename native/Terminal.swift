// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import GhosttyTerminal
import GhosttyTheme

@MainActor
private final class HostedTerminal: TerminalView, TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceOpenURLDelegate, NativeSurface {
    var nativeView: NSView { self }
    var input: NativeInput? { session?.input }
    weak var session: TerminalSession?
    var toolbarModel: ToolbarModel? { session?.quick == false ? session?.controls : nil }
    func handleKeyEvent(_ event: NSEvent) -> Bool { session?.handleKeyEvent(event) ?? false }
    static let defaultFontSize = 14.0
    var terminalTitle = "Terminal"
    var grid: TerminalGridMetrics?
    var terminalSurface: TerminalSurface?
    var closed = false

    init(directory: String, theme: TerminalTheme) {
        super.init(frame: .zero)
        delegate = self
        configuration = TerminalSurfaceOptions(
            workingDirectory: directory,
            envVars: ["INSIDE_EMACS": "portal-ghostty"],
            waitAfterCommand: true)
        controller = TerminalController(theme: theme) { builder in
            builder.withFontThicken(false)
            builder.withFontSize(Float(Self.defaultFontSize))
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
private final class TerminalSession {
    let id: Int
    let quick: Bool
    let terminal: HostedTerminal
    let host: NativeHost
    let controls = ToolbarModel(.terminal)
    var edges: [Int] = []
    lazy var input = NativeInput(target: "terminal:\(id)", view: terminal, host: host,
                                 profile: quick ? "quick" : "regular") { [weak self] in
        guard let self, !terminal.isHidden, terminal.acquireProgrammaticFocus() else { return false }
        Terminals.didFocus(id)
        return true
    }

    init(id: Int, host: NativeHost, directory: String, theme: TerminalTheme, quick: Bool) throws {
        self.id = id
        self.quick = quick
        self.host = host
        terminal = HostedTerminal(directory: directory, theme: theme)
        if let issue = terminal.controller?.lastConfigurationIssue { throw NativeError.message(issue) }
        terminal.session = self
        controls.value = HostedTerminal.defaultFontSize
        controls.defaultValue = HostedTerminal.defaultFontSize
        controls.minimum = 1
        controls.maximum = 255
        controls.action = { [weak self] in try self?.textSize($0) }
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

    func textSize(_ action: String) throws {
        let binding: String
        let next: Double
        switch action {
        case "increase": next = min(controls.maximum, controls.value + 1); binding = "increase_font_size:1"
        case "decrease": next = max(controls.minimum, controls.value - 1); binding = "decrease_font_size:1"
        case "reset": next = controls.defaultValue; binding = "reset_font_size"
        default: throw NativeError.message("Unknown terminal toolbar action: \(action)")
        }
        guard next != controls.value else { return }
        guard terminal.terminalSurface?.performBindingAction(binding) == true else {
            throw NativeError.message("No terminal accepting text size changes")
        }
        controls.value = next
        controls.changed?()
    }

    func returnFocus() { host.returnFocus(from: terminal) }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        Terminals.didFocus(id)
        if input.handleKeyEvent(event) { return true }
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]) == .command {
            let key = event.charactersIgnoringModifiers ?? ""
            if let action = ["+": "increase", "=": "increase", "-": "decrease", "0": "reset"][key] {
                try? textSize(action)
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

    func close() {
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
    private static func session(_ id: Int?) -> TerminalSession? {
        guard let id = id ?? activeID else { return nil }
        return sessions[id]
    }

    static func didFocus(_ id: Int) { activeID = id }

    static func themeNames() -> [String] { GhosttyThemeCatalog.allThemes.map(\.name).sorted() }

    private static func resolveTheme(_ name: String?) throws -> TerminalTheme {
        guard let name else { return .default }
        guard let theme = GhosttyThemeCatalog.theme(named: name) else {
            throw NativeError.message("Unknown terminal theme: \(name)")
        }
        return theme.toTerminalTheme()
    }

    static func setTheme(_ name: String?) throws {
        // Resolve before touching any session, including when none are open.
        let theme = try resolveTheme(name)
        for session in sessions.values {
            guard let controller = session.terminal.controller, controller.theme != theme else { continue }
            guard controller.setTheme(theme) else {
                throw NativeError.message(controller.lastConfigurationIssue ?? "Could not apply terminal theme")
            }
        }
    }

    static func open(title: String, directory: String, themeName: String?, quick: Bool = false) throws -> Int {
        let theme = try resolveTheme(themeName)
        guard let host = NativeHost.bind(title: title) else {
            throw NativeError.message("Cannot find the requested native Emacs frame")
        }
        nextID += 1
        sessions[nextID] = try TerminalSession(id: nextID, host: host, directory: directory, theme: theme, quick: quick)
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

}
