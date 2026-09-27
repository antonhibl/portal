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
    var toolbarModel: ToolbarModel? { session?.toolbar }
    func handleKeyEvent(_ event: NSEvent) -> Bool { session?.handleKeyEvent(event) ?? false }
    static let defaultFontSize = 14.0
    var terminalTitle = "Terminal"
    var grid: TerminalGridMetrics?
    var terminalSurface: TerminalSurface?
    /// The process has ended. The view stays, showing its last output.
    var exited = false

    init(directory: String, command: String?, theme: TerminalTheme) {
        super.init(frame: .zero)
        delegate = self
        configuration = TerminalSurfaceOptions(
            workingDirectory: directory,
            envVars: ["INSIDE_EMACS": "portal-ghostty"],
            command: command,
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
    /// Ghostty asks to close the surface when its process ends, and also when
    /// a close is requested while the process still runs.
    func terminalDidClose(processAlive: Bool) {
        if !processAlive { exited = true }
        session?.returnFocus()
    }
    func terminalDidRequestOpenURL(_ text: String, kind: TerminalOpenURLKind) {
        guard let url = URL(string: text),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The terminal view kind: one Ghostty session. Its shell starts in the parking
/// window when the view opens, and keeps running while the view is hidden.
/// The core owns Portal's terminal rules (native/Core/terminals.c): it checks
/// the options and theme names, and calls the primitives below on one session.
@MainActor
final class TerminalSession: PortalView {
    let target: String
    let quick: Bool
    private let terminal: HostedTerminal
    var surface: any NativeSurface { terminal }
    let input: NativeInput
    let controls = ToolbarModel(.terminal)
    var toolbar: ToolbarModel? { quick ? nil : controls }

    init(target: String, options: ViewOptions) throws {
        guard let directory = try options.string("directory") else {
            throw NativeError.message("The core passed a terminal without a :directory")
        }
        self.target = target
        quick = options.flag("quick")
        let terminal = HostedTerminal(directory: directory, command: try options.string("command"),
                                      theme: try Terminals.theme(named: options.string("theme")))
        if let issue = terminal.controller?.lastConfigurationIssue { throw NativeError.message(issue) }
        self.terminal = terminal
        input = NativeInput(target: target, view: terminal, host: NativeView.parking) { [weak terminal] in
            guard let terminal, !terminal.isHidden else { return false }
            return terminal.acquireProgrammaticFocus()
        }
        terminal.session = self
        controls.value = HostedTerminal.defaultFontSize
        controls.defaultValue = HostedTerminal.defaultFontSize
        controls.minimum = 1
        controls.maximum = 255
        controls.action = { [weak self] in try self?.textSize($0) }
    }

    /// Ghostty makes its surface once the view is in a window.
    func opened() throws {
        terminal.fitToSize()
        guard terminal.terminalSurface != nil else {
            throw NativeError.message("Ghostty could not create a Metal terminal surface")
        }
    }

    func attached() {
        terminal.setSurfaceVisible(true)
        terminal.fitToSize()
    }

    /// Parking keeps the last size, so hiding never resizes the shell's grid.
    func detaching() { terminal.setSurfaceVisible(false) }

    func describe() -> [(String, ViewValue)] {
        [("ready", .flag(terminal.terminalSurface != nil)),
         ("title", .string(terminal.terminalTitle)),
         ("exited", .flag(terminal.exited)),
         ("columns", .integer(Int(terminal.grid?.columns ?? 0))),
         ("rows", .integer(Int(terminal.grid?.rows ?? 0))),
         ("layer", .string(terminal.layer.map { NSStringFromClass(type(of: $0)) } ?? ""))]
    }

    /// The toolbar's and keyboard's text size steps, until the core owns them.
    func textSize(_ action: String) throws {
        let next: Double
        switch action {
        case "increase": next = min(controls.maximum, controls.value + 1)
        case "decrease": next = max(controls.minimum, controls.value - 1)
        case "reset": next = controls.defaultValue
        default: throw NativeError.message("Unknown terminal toolbar action: \(action)")
        }
        guard next != controls.value else { return }
        try setFontSize(next)
        controls.value = next
        controls.changed?()
    }

    // The terminal primitives of native/Core/include/portal.h.

    func applyTheme(_ name: String?) throws {
        let theme = try Terminals.theme(named: name)
        guard let controller = terminal.controller, controller.theme != theme else { return }
        guard controller.setTheme(theme) else {
            throw NativeError.message(controller.lastConfigurationIssue ?? "Could not apply terminal theme")
        }
    }

    func paste(_ text: String) throws {
        guard terminal.paste(text: text) else { throw NativeError.message("No terminal accepting input") }
    }

    func pressEnter() throws {
        guard terminal.sendKey(.enter) else { throw NativeError.message("No terminal accepting input") }
    }

    /// Select all and read the selection, which stays active.
    func text() throws -> String {
        guard let surface = terminal.terminalSurface else {
            throw NativeError.message("No terminal surface to copy")
        }
        guard surface.performBindingAction("select_all") else {
            throw NativeError.message("Ghostty could not select terminal text")
        }
        return surface.readSelection() ?? ""
    }

    func setFontSize(_ points: Double) throws {
        let binding = String(format: "set_font_size:%g", points)
        guard terminal.terminalSurface?.performBindingAction(binding) == true else {
            throw NativeError.message("No terminal accepting text size changes")
        }
    }

    func returnFocus() { input.host.returnFocus(from: terminal) }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
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
}

/// The Ghostty theme catalog.
@MainActor
enum Terminals {
    static func themeNames() -> [String] { GhosttyThemeCatalog.allThemes.map(\.name) }

    /// The theme NAME, which the core has checked, or the default for nil,
    /// which follows the system's appearance.
    static func theme(named name: String?) throws -> TerminalTheme {
        guard let name else { return .default }
        guard let theme = GhosttyThemeCatalog.theme(named: name) else {
            throw NativeError.message("Unknown terminal theme: \(name)")
        }
        return theme.toTerminalTheme()
    }
}
