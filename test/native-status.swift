// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// The status panel through portal.h's primitives, as the Emacs bindings call
// them, with no Portal view or launcher. Whether it shows on other Spaces and
// over fullscreen apps, and keeps another app's keyboard, is a manual check.
@main
struct StatusChecks {
    @MainActor static func main() {
        runChecks {
            _ = NSApplication.shared
            func show(_ text: String) {
                var error = portal_text()
                defer { free(error.data) }
                check(text.withCString {
                    portalStatusShow(portal_string(data: $0, length: text.utf8.count), &error)
                }, "Cannot show \(text)")
            }
            func hide() {
                var error = portal_text()
                defer { free(error.data) }
                check(portalStatusHide(&error))
            }
            // Hiding before anything was shown does nothing.
            hide()
            check(StatusPanel.panel == nil)

            let active = NSApp.isActive
            let frontmost = NSWorkspace.shared.frontmostApplication
            let keyWindow = NSApp.keyWindow
            show("Recording")
            let panel = require(StatusPanel.panel)
            check(panel.isVisible && panel.label.stringValue == "Recording")
            check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
            check(NSApp.isActive == active && NSApp.keyWindow === keyWindow)
            check(NSWorkspace.shared.frontmostApplication == frontmost)
            check(panel.ignoresMouseEvents && panel.level == .statusBar)
            check(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
            check(panel.styleMask.contains(.nonactivatingPanel))

            // At the bottom center of its screen's usable area.
            let area = require(panel.screen?.visibleFrame)
            let first = panel.frame
            check(abs(first.midX - area.midX) <= 1, "Not centered: \(first) in \(area)")
            check(first.minY == area.minY + StatusPanel.margin && area.contains(first))

            // New text replaces the old in the same panel, centered again.
            show("Transcribing a much longer status")
            check(StatusPanel.panel === panel && panel.isVisible)
            check(panel.label.stringValue == "Transcribing a much longer status")
            check(panel.frame.width > first.width && panel.frame.minY == first.minY)
            check(abs(panel.frame.midX - area.midX) <= 1)

            // Text wider than the screen is cut, not the panel.
            show(String(repeating: "Very long status ", count: 500))
            check(area.contains(panel.frame), "Off screen: \(panel.frame) in \(area)")

            hide()
            check(!panel.isVisible)
            hide()
            check(!panel.isVisible)
            show("Done")
            check(StatusPanel.panel === panel && panel.isVisible && panel.label.stringValue == "Done")
            check(NSApp.isActive == active && NSWorkspace.shared.frontmostApplication == frontmost)
            hide()
        }
        print("Status checks passed")
    }
}
