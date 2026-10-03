// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// These stand in for the validated port's ObjC selectors. The GUI suite uses
// the real EmacsView; here attachment failure and display arrangements can be
// driven deterministically without reaching into a private Emacs frame struct.
@objc(EmacsView)
final class LauncherTestEditor: NSView, NSWindowDelegate {
    var acceptsFocus = true
    override var acceptsFirstResponder: Bool { acceptsFocus }
    override func becomeFirstResponder() -> Bool { acceptsFocus }
}

@objc(EmacsWindow)
final class LauncherTestWindow: NSWindow {
    @objc(setAppearance) func emacsAppearance() { appearance = NSAppearance(named: .darkAqua) }
}

@main
struct LauncherChecks {
    @MainActor static func main() {
        runChecks {
            _ = NSApplication.shared
            func placement(_ width: Int64 = 713, _ height: Int64 = 407,
                           _ dx: Int64 = 0, _ dy: Int64 = 0) -> NativeLauncher.Placement {
                .init(width: width, height: height, dx: dx, dy: dy, screen: -1, shadow: true, radius: 14)
            }
            // Captured experiment displays; same physical point placement at
            // either Retina scale. Synthetic negative-X origins cover left displays.
            let areas = [NSRect(x: 0, y: 0, width: 2560, height: 1410),
                         NSRect(x: 2560, y: -483, width: 1440, height: 2530),
                         NSRect(x: -1920, y: -300, width: 1920, height: 1057)]
            for area in areas {
                for (width, height): (Int64, Int64) in [(640, 320), (720, 420), (860, 520), (713, 407)] {
                    let rect = NativeLauncher.rectangle(placement(width, height, -137, 81), in: area)
                    check(rect.width == CGFloat(width) && rect.height == CGFloat(height))
                    check(rect.minX == floor(area.midX - CGFloat(width) / 2 - 137))
                    check(rect.minY == floor(area.midY - CGFloat(height) / 2 - 81))
                    check(area.contains(rect))
                }
                check(NativeLauncher.rectangle(placement(100000, 100000, -100000, 100000), in: area) == area)
                check(NativeLauncher.rectangle(placement(713, 407, -100000, 100000), in: area).origin == area.origin)
            }
            func rejected(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
                do { try body(); fail("Accepted invalid launcher operation", file: file, line: line) }
                catch NativeError.message { }
                catch { fail("Unexpected error: \(error)") }
            }
            rejected { try NativeLauncher.attach(title: "missing") }
            let donor = LauncherTestWindow(contentRect: NSRect(x: 50, y: 80, width: 720, height: 420),
                                           styleMask: .borderless, backing: .buffered, defer: false)
            donor.isReleasedWhenClosed = false
            donor.title = "launcher-native-checks"
            let editor = LauncherTestEditor(frame: donor.frame)
            donor.contentView = editor
            donor.delegate = editor
            donor.orderFront(nil)
            rejected { try NativeLauncher.attach(title: donor.title) }
            donor.orderOut(nil)
            // Refusing first responder after the view move rolls it back.
            editor.acceptsFocus = false
            autoreleasepool { rejected { try NativeLauncher.attach(title: donor.title) } }
            check(editor.window === donor && donor.delegate === editor)
            check(NativeLauncher.attached == nil)
            editor.acceptsFocus = true
            for _ in 0..<20 {
                try autoreleasepool {
                    try NativeLauncher.attach(title: donor.title)
                    let launcher = require(NativeLauncher.attached)
                    check(editor.window === launcher.panel)
                    check(donor.delegate === editor)
                    rejected { try NativeLauncher.attach(title: donor.title) }
                    try launcher.place(placement())
                    check(launcher.panel.frame == NativeLauncher.rectangle(placement(), in: require(launcher.panel.screen).visibleFrame))
                    check(launcher.panel.styleMask.contains(.nonactivatingPanel))
                    check(launcher.panel.canBecomeKey && !launcher.panel.canBecomeMain)
                    launcher.panel.applyEmacsAppearance()
                    check(launcher.panel.appearance?.name == .darkAqua)
                    // Reapply after the system reports a changed arrangement,
                    // without a new presentation/focus request.
                    launcher.panel.setFrameOrigin(NSPoint(x: -100000, y: -100000))
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                    check(NSScreen.screens.contains { $0.visibleFrame.contains(launcher.panel.frame) })
                    rejected { try launcher.place(placement(199, 407)) }
                    launcher.hide()
                    check(!launcher.panel.isVisible)
                    NativeLauncher.detach()
                    NativeLauncher.detach()
                    check(editor.window === donor && donor.delegate === editor)
                    check(NativeLauncher.attached == nil)
                }
            }
            donor.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            check(NSApp.windows.allSatisfy { !($0 is LauncherPanel) }, "Closed panels remain: \(NSApp.windows)")
            print("Launcher native checks passed: geometry, rejection, rollback, ownership, appearance, 20 attach/detach cycles")
        }
    }
}
