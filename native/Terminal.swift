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

/// The terminal view kind: one Ghostty session. Its shell starts when the view
/// first enters a frame, and keeps running while the view is hidden.
@MainActor
final class TerminalSession: PortalView {
    let target: String
    let quick: Bool
    fileprivate let terminal: HostedTerminal
    private var host: NativeHost?
    private(set) var input: NativeInput?
    let controls = ToolbarModel(.terminal)
    private var edges: [Int] = []

    init(target: String, options: ViewOptions) throws {
        guard let directory = try options.string("directory") else {
            throw NativeError.message("A terminal view needs a :directory")
        }
        self.target = target
        quick = options.flag("quick")
        terminal = HostedTerminal(directory: directory, theme: try Terminals.resolveTheme(options.string("theme")))
        if let issue = terminal.controller?.lastConfigurationIssue { throw NativeError.message(issue) }
        terminal.session = self
        controls.value = HostedTerminal.defaultFontSize
        controls.defaultValue = HostedTerminal.defaultFontSize
        controls.minimum = 1
        controls.maximum = 255
        controls.action = { [weak self] in try self?.textSize($0) }
    }

    func place(in host: NativeHost, rectangle: CGRect) throws {
        if let current = self.host, current !== host {
            throw NativeError.message("A terminal view cannot move to another frame")
        }
        self.host = host
        if input == nil {
            input = NativeInput(target: target, view: terminal, host: host,
                                profile: quick ? "quick" : "regular") { [weak self] in
                guard let terminal = self?.terminal, !terminal.isHidden else { return false }
                return terminal.acquireProgrammaticFocus()
            }
        }
        guard host.place(terminal, rectangle: rectangle) else {
            throw NativeError.message("The terminal's frame was deleted")
        }
        edges = [Int(rectangle.minX), Int(rectangle.minY), Int(rectangle.maxX), Int(rectangle.maxY)]
        terminal.setSurfaceVisible(true)
        terminal.fitToSize()
        guard terminal.terminalSurface != nil else {
            throw NativeError.message("Ghostty could not create a Metal terminal surface")
        }
    }

    func hide() {
        edges = []
        terminal.setSurfaceVisible(false)
        // Ghostty must stay attached so hidden shells keep draining their PTYs.
        host?.hide(terminal)
    }

    func close() { host?.remove(terminal) }

    func inspect() -> [(String, ViewValue)] {
        [("ready", .flag(terminal.terminalSurface != nil)),
         ("visible", .flag(terminal.window != nil && !terminal.isHiddenOrHasHiddenAncestor)),
         ("focused", .flag(host?.ownsFocus(terminal) ?? false)),
         ("title", .string(terminal.terminalTitle)),
         ("closed", .flag(terminal.closed)),
         ("columns", .integer(Int(terminal.grid?.columns ?? 0))),
         ("rows", .integer(Int(terminal.grid?.rows ?? 0))),
         ("edges", .integers(edges)),
         ("layer", .string(terminal.layer.map { NSStringFromClass(type(of: $0)) } ?? ""))]
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

    func returnFocus() { host?.returnFocus(from: terminal) }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if input?.handleKeyEvent(event) == true { return true }
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
}

/// Operations shared by all terminal views. Nothing here depends on the web feature.
@MainActor
enum Terminals {
    static func themeNames() -> [String] { GhosttyThemeCatalog.allThemes.map(\.name).sorted() }

    fileprivate static func resolveTheme(_ name: String?) throws -> TerminalTheme {
        guard let name else { return .default }
        guard let theme = GhosttyThemeCatalog.theme(named: name) else {
            throw NativeError.message("Unknown terminal theme: \(name)")
        }
        return theme.toTerminalTheme()
    }

    static func setTheme(_ name: String?) throws {
        // Resolve before touching any session, including when none are open.
        let theme = try resolveTheme(name)
        for session in Views.all(TerminalSession.self) {
            guard let controller = session.terminal.controller, controller.theme != theme else { continue }
            guard controller.setTheme(theme) else {
                throw NativeError.message(controller.lastConfigurationIssue ?? "Could not apply terminal theme")
            }
        }
    }

    static func paste(_ target: String, text: String, enter: Bool) throws {
        let terminal = try Views.view(target, as: TerminalSession.self).terminal
        guard terminal.paste(text: text) else { throw NativeError.message("No terminal accepting input") }
        if enter { _ = terminal.sendKey(.enter) }
    }

    static func text(_ target: String) throws -> String {
        guard let surface = try Views.view(target, as: TerminalSession.self).terminal.terminalSurface else {
            throw NativeError.message("No terminal surface to copy")
        }
        guard surface.performBindingAction("select_all") else {
            throw NativeError.message("Ghostty could not select terminal text")
        }
        return surface.readSelection() ?? ""
    }
}
