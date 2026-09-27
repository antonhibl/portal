// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import GhosttyTerminal
import GhosttyTheme

/// Ghostty accepts only string environment overrides. A null removal needs
/// the bundled child launcher, which unsets it immediately before exec.
@MainActor
private struct TerminalLaunch {
    var command: String?
    var environment: [String: String] = [:]
    var shellIntegration: String?

    init(options: ViewOptions) throws {
        command = try options.string("command")
        var arguments: [String]?
        if let json = try options.string("argv") {
            guard command == nil,
                  let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String],
                  let program = values.first, program.hasPrefix("/"),
                  values.allSatisfy({ !$0.contains("\0") }) else {
                throw NativeError.message("Terminal :argv must be an absolute program and literal arguments, without :command")
            }
            arguments = values
            command = values.map(Self.quote).joined(separator: " ")
        }
        var removals: [String] = []
        if let json = try options.string("environment") {
            guard let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw NativeError.message("Terminal :environment must be a JSON object")
            }
            for (name, value) in values {
                guard !name.isEmpty && !name.contains("=") && !name.contains("\0") else {
                    throw NativeError.message("Invalid terminal environment name")
                }
                if value is NSNull {
                    removals.append(name)
                } else if let value = value as? String, !value.contains("\0") {
                    environment[name] = value
                } else {
                    throw NativeError.message("Terminal environment values must be strings or null")
                }
            }
        }
        guard !removals.isEmpty else { return }
        guard let arguments else {
            throw NativeError.message("Terminal environment removals require :argv")
        }
        let program = arguments[0]
        guard let launcher = Bundle(for: HostedTerminal.self).executableURL?
            .deletingLastPathComponent().appendingPathComponent("portal-terminal-launcher"),
              FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw NativeError.message("Rebuild Portal to install its terminal launcher")
        }
        // The command still has exactly the target's arguments, so Ghostty
        // can prepare shell integration (including Bash/Nushell flag edits).
        // Only argv[0] changes; the launcher forwards the resulting arguments.
        let shell = URL(fileURLWithPath: program).lastPathComponent
        shellIntegration = program == "/bin/bash" ? "none"
            : ["bash": "bash", "zsh": "zsh", "fish": "fish", "elvish": "elvish", "nu": "nushell"][shell] ?? "none"
        command = ([launcher.path] + arguments.dropFirst()).map(Self.quote).joined(separator: " ")
        let transport = "PORTAL_TERMINAL_LAUNCH"
        var request: [String: Any] = ["program": program, "unset": removals.sorted()]
        // Preserve a caller's variable even if it shares the transport name.
        if let original = environment[transport] ?? ProcessInfo.processInfo.environment[transport] {
            request["restore"] = original
        } else {
            request["restore"] = NSNull()
        }
        environment[transport] = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

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

    init(directory: String, launch: TerminalLaunch, theme: TerminalTheme) {
        super.init(frame: .zero)
        delegate = self
        configuration = TerminalSurfaceOptions(
            workingDirectory: directory,
            envVars: launch.environment.merging(["INSIDE_EMACS": "portal-ghostty"]) { _, value in value },
            command: launch.command,
            waitAfterCommand: true)
        controller = TerminalController(theme: theme) { builder in
            builder.withFontThicken(false)
            builder.withFontSize(Float(Self.defaultFontSize))
            if let shell = launch.shellIntegration { builder.withCustom("shell-integration", shell) }
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
        let terminal = HostedTerminal(directory: directory, launch: try TerminalLaunch(options: options),
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
