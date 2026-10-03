// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon

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
            // Real Carbon registrations and event dispatch, with the same C
            // notification pipe used by Emacs and no Portal views at all.
            var descriptors: [Int32] = [0, 0]
            check(pipe(&descriptors) == 0)
            check(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
            check(portal_channel_connect(descriptors[1]))
            defer { _ = try? LauncherShortcut.set(""); portal_channel_connect(-1); close(descriptors[0]) }
            func records() -> String {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptors[0], &bytes, bytes.count)
                return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
            }
            func hotkey(_ id: UInt32, _ pressed: Bool = true, at time: EventTime = GetCurrentEventTime()) {
                var event: EventRef?
                check(CreateEvent(nil, OSType(kEventClassKeyboard),
                                  UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),
                                  time, 0, &event) == noErr)
                let value = require(event)
                defer { ReleaseEvent(value) }
                var key = EventHotKeyID(signature: 0x5072744c, id: id)
                check(SetEventParameter(value, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key) == noErr)
                _ = SendEventToEventTarget(value, GetApplicationEventTarget())
            }
            @MainActor func invalidChord(_ chord: String) {
                do { _ = try LauncherShortcut.set(chord); fail("Accepted chord: \(chord)") }
                catch NativeError.message { }
                catch { fail("Unexpected error: \(error)") }
            }
            for chord in ["P", "Shift-P", "Hyper-P", "Control-Control-P", "Control-", "Control-F21", "Control-!", "Control-P Q"] {
                invalidChord(chord)
            }
            let original = try LauncherShortcut.set("Control-Option-Command-P")
            check(original != 0)
            let same = try LauncherShortcut.set("command-control-option-p")
            check(original == same)
            hotkey(original, at: GetCurrentEventTime() - 10)
            check(records().isEmpty)
            hotkey(original)
            hotkey(original) // Holding the chord must not toggle repeatedly.
            check(records() == "launcher \(original) 0\n")
            hotkey(original, false)
            hotkey(original)
            check(records() == "launcher \(original) 0\n")
            // A competing registration blocks replacement and initial enable.
            var competing: EventHotKeyRef?
            check(RegisterEventHotKey(40, UInt32(controlKey | optionKey | cmdKey),
                                      EventHotKeyID(signature: 0x54657374, id: 1), GetApplicationEventTarget(),
                                      OptionBits(kEventHotKeyExclusive), &competing) == noErr)
            invalidChord("Control-Option-Command-K")
            check(LauncherShortcut.token == original)
            hotkey(original, false)
            hotkey(original)
            check(records() == "launcher \(original) 0\n")
            let replacement = try LauncherShortcut.set("Control-Option-Command-L")
            check(replacement != original)
            hotkey(original, false)
            hotkey(original)
            check(records().isEmpty)
            hotkey(replacement)
            check(records() == "launcher \(replacement) 0\n")
            // The old chord is available as soon as replacement succeeds.
            var reclaimed: EventHotKeyRef?
            check(RegisterEventHotKey(35, UInt32(controlKey | optionKey | cmdKey),
                                      EventHotKeyID(signature: 0x54657374, id: 2), GetApplicationEventTarget(),
                                      OptionBits(kEventHotKeyExclusive), &reclaimed) == noErr)
            check(UnregisterEventHotKey(require(reclaimed)) == noErr)
            _ = try LauncherShortcut.set("")
            invalidChord("Control-Option-Command-K")
            check(LauncherShortcut.token == 0)
            check(UnregisterEventHotKey(require(competing)) == noErr)
            for _ in 0..<20 {
                let current = try LauncherShortcut.set("Control-Option-Command-P")
                hotkey(replacement, false)
                hotkey(replacement)
                hotkey(current)
                check(records() == "launcher \(current) 0\n")
                _ = try LauncherShortcut.set("")
                _ = try LauncherShortcut.set("")
                hotkey(current)
                check(records().isEmpty)
            }
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
                    let oldSession = NativeLauncher.session
                    try launcher.place(placement())
                    check(NativeLauncher.session > oldSession)
                    let registered = try LauncherShortcut.set("Control-Option-Command-P")
                    hotkey(registered, at: GetCurrentEventTime() - 10)
                    check(records().isEmpty)
                    hotkey(registered)
                    check(records() == "launcher \(registered) \(NativeLauncher.session)\n")
                    _ = try LauncherShortcut.set("")
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
            print("Launcher native checks passed: registration, conflicts, rebind, stale events, pipe delivery, geometry, rollback, ownership, 20 enable/disable and attach/detach cycles")
        }
    }
}
