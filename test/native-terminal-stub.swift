// SPDX-License-Identifier: GPL-3.0-or-later
// Stands in for the terminal kind, so the standalone AppKit checks build without Ghostty.
import AppKit

@MainActor
final class TerminalSession: PortalView {
    init(target: String, options: ViewOptions, parking: NativeHost) throws {
        throw NativeError.message("The standalone checks have no terminals")
    }
    func place(in host: NativeHost, rectangle: CGRect) throws {}
    func hide(in parking: NativeHost) {}
    func close() {}
    func inspect() -> [(String, ViewValue)] { [] }
}
