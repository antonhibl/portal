// SPDX-License-Identifier: GPL-3.0-or-later
// Stands in for the terminal kind, so the standalone AppKit checks build without Ghostty.
import AppKit

@MainActor
final class TerminalSession: PortalView {
    init(target: String, options: ViewOptions) throws {
        throw NativeError.message("The standalone checks have no terminals")
    }
    var surface: any NativeSurface { fail("The standalone checks have no terminals") }
    var input: NativeInput { fail("The standalone checks have no terminals") }
    var toolbar: ToolbarModel? { nil }
    func describe() -> [(String, ViewValue)] { [] }
}

@MainActor
enum Terminals {
    static func themeNames() -> [String] { [] }
    static func setTheme(_ name: String?, sessions: [TerminalSession]) throws {}
    static func paste(_ session: TerminalSession, text: String, enter: Bool) throws {}
    static func text(_ session: TerminalSession) throws -> String { "" }
}
