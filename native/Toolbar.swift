// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore

/// One view's toolbar as the core last drew it (`portal_toolbar` in
/// portal.h). The core owns every value; this only draws them.
struct ToolbarState: Sendable {
    enum Owner: Sendable { case emacs, view, pending, passthrough }
    var visible = false
    /// Face colors by role, as sRGB components; a missing role uses AppKit's default.
    var colors: [String: [Double]] = [:]
    var owner = Owner.emacs
    var buttons: UInt32 = 0
    var enabled: UInt32 = 0
    var selected: UInt32 = 0
    var value = 0.0
    var standard = 0.0
    var points = false
    var finding = false
    var query = ""
    var match = 0
    var matches = 0

    init() {}

    init(_ state: portal_toolbar) {
        visible = state.visible
        let colors = state.colors
        for (name, color) in [("background", colors.background), ("border", colors.border),
                              ("shadow", colors.shadow), ("foreground", colors.foreground),
                              ("success", colors.success), ("accent", colors.accent),
                              ("warning", colors.warning)] where color.set {
            self.colors[name] = [color.red, color.green, color.blue]
        }
        switch state.owner {
        case PORTAL_OWNER_VIEW: owner = .view
        case PORTAL_OWNER_PENDING: owner = .pending
        case PORTAL_OWNER_PASSTHROUGH: owner = .passthrough
        default: owner = .emacs
        }
        buttons = state.buttons
        enabled = state.enabled
        selected = state.selected
        value = state.value
        standard = state.standard
        points = state.unit == PORTAL_POINTS
        finding = state.finding
        query = String(copying: state.query)
        match = Int(state.match)
        matches = Int(state.matches)
    }

    func has(_ button: portal_button) -> Bool { buttons & 1 << button.rawValue != 0 }
    func allows(_ button: portal_button) -> Bool { enabled & 1 << button.rawValue != 0 }
    func toggled(_ button: portal_button) -> Bool { selected & 1 << button.rawValue != 0 }

    func color(_ name: String) -> NSColor {
        if let rgb = colors[name] { return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1) }
        switch name {
        case "background": return .windowBackgroundColor
        case "border": return .separatorColor
        case "foreground": return .labelColor
        case "success": return .systemGreen
        case "accent": return .systemBlue
        case "warning": return .systemOrange
        default: return .secondaryLabelColor
        }
    }
}

/// A view and, while the core shows one, its toolbar strip above it. The
/// feature keeps its identity and lifetime; only its available height changes.
@MainActor
final class NativeContainer: NSView {
    let content: NSView
    let target: String
    private(set) var toolbar: ToolbarView?
    private(set) var state: ToolbarState
    override var isFlipped: Bool { true }

    init(content: NSView, target: String, state: ToolbarState) {
        self.content = content
        self.target = target
        self.state = state
        super.init(frame: .zero)
        addSubview(content)
        apply(state)
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ state: ToolbarState) {
        self.state = state
        if state.visible, toolbar == nil {
            let strip = ToolbarView(target: target)
            toolbar = strip
            addSubview(strip)
        } else if !state.visible, let toolbar {
            toolbar.removeFromSuperview()
            self.toolbar = nil
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        toolbar?.apply(state)
    }

    override func layout() {
        super.layout()
        let height = toolbar == nil ? 0.0 : min(28, bounds.height)
        toolbar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        content.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }
}

@MainActor
private final class ToolbarButton: NSButton {
    var invoke: (() -> Void)?
    var symbol: String?
    var dot: ToolbarState.Owner?
    var selected = false
    var dimmed = true
    weak var strip: ToolbarView?
    private var hovering = false
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }

    init(_ tooltip: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        invoke = action
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        title = ""
        isBordered = false
        focusRingType = .none
        target = self
        self.action = #selector(clicked)
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func clicked() { invoke?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let colors = strip?.state ?? ToolbarState()
        let accent = colors.color("accent")
        let foreground = colors.color("foreground")
        if isEnabled && (hovering || isHighlighted || selected) {
            (selected ? accent : foreground).withAlphaComponent(isHighlighted ? 0.20 : hovering ? 0.13 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = (selected ? accent : hovering && isEnabled || !dimmed ? foreground : colors.color("shadow"))
            .withAlphaComponent(isEnabled ? 1 : 0.3)
        if let dot {
            let dotColor = colors.color(dot == .emacs ? "shadow" : dot == .pending ? "accent" : dot == .passthrough ? "warning" : "success")
            let rect = NSRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8)
            if dot == .view {
                dotColor.withAlphaComponent(0.13).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3)).fill()
            }
            dotColor.set()
            let path = NSBezierPath(ovalIn: rect)
            if dot == .emacs { path.lineWidth = 1.4; path.stroke() } else { path.fill() }
        } else if let symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) {
            let configured = icon.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? icon
            let tinted = NSImage(size: configured.size, flipped: false) { rect in
                configured.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14))
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "JetBrains Mono", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]
            let text = title as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

/// The strip: the ownership dot and the buttons the core gives the view, or
/// the find field with its matches. A click, or an edit of the field, goes
/// to the core, which draws the result.
@MainActor
final class ToolbarView: NSView, NSSearchFieldDelegate {
    let target: String
    private(set) var state = ToolbarState()
    private var buttons: [UInt32: ToolbarButton] = [:]
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private var separators: [CGFloat] = []
    override var isFlipped: Bool { true }

    init(target: String) {
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        field.delegate = self
        field.placeholderString = "Find in page"
        field.font = .systemFont(ofSize: 11)
        field.setAccessibilityLabel("Find in page")
        count.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addSubview(field)
        addSubview(count)
        let specs: [(portal_button, String, String?)] = [
            (PORTAL_BUTTON_OWNER, "Click to enter", nil), (PORTAL_BUTTON_BACK, "Back", "chevron.left"),
            (PORTAL_BUTTON_FORWARD, "Forward", "chevron.right"),
            (PORTAL_BUTTON_FIND, "Find in page", "magnifyingglass"),
            (PORTAL_BUTTON_CONTENTS, "Table of contents", "list.bullet"),
            (PORTAL_BUTTON_EDIT, "Open in Emacs", "square.and.pencil"),
            (PORTAL_BUTTON_DECREASE, "Zoom out", "minus"), (PORTAL_BUTTON_RESET, "Reset to 100%", nil),
            (PORTAL_BUTTON_INCREASE, "Zoom in", "plus"), (PORTAL_BUTTON_RELOAD, "Reload", "arrow.clockwise"),
            (PORTAL_BUTTON_PREVIOUS, "Previous match", "chevron.up"),
            (PORTAL_BUTTON_NEXT, "Next match", "chevron.down"), (PORTAL_BUTTON_CLOSE, "Close find", "xmark")]
        for (id, tooltip, symbol) in specs {
            let button = ToolbarButton(tooltip, symbol: symbol) { [weak self] in self?.click(id) }
            button.strip = self
            if id == PORTAL_BUTTON_CONTENTS { button.setAccessibilityRole(.checkBox) }
            buttons[id.rawValue] = button
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { nil }

    private func button(_ id: portal_button) -> ToolbarButton? { buttons[id.rawValue] }

    private func click(_ id: portal_button) { Core.clicked(target, id) }

    private func label(_ id: portal_button, _ name: String) {
        button(id)?.toolTip = name
        button(id)?.setAccessibilityLabel(name)
    }

    func apply(_ state: ToolbarState) {
        self.state = state
        let owner = button(PORTAL_BUTTON_OWNER)
        owner?.dot = state.owner
        switch state.owner {
        case .emacs: label(PORTAL_BUTTON_OWNER, "Click to enter")
        case .view: label(PORTAL_BUTTON_OWNER, "Click to return to Emacs · ⌘⎋")
        case .pending: label(PORTAL_BUTTON_OWNER, "Emacs is reading a command")
        case .passthrough: label(PORTAL_BUTTON_OWNER, "Passthrough · ⌘⎋ returns to Emacs")
        }
        for (id, button) in buttons { button.isEnabled = state.allows(portal_button(rawValue: id)) }
        let contents = button(PORTAL_BUTTON_CONTENTS)
        contents?.selected = state.toggled(PORTAL_BUTTON_CONTENTS)
        contents?.setAccessibilityValue(contents?.selected == true ? 1 : 0)
        let reading = String(format: "%g", state.standard)
        let value = String(format: state.points ? "%g pt" : "%g%%", state.value)
        label(PORTAL_BUTTON_DECREASE, state.points ? "Decrease text size" : "Zoom out")
        label(PORTAL_BUTTON_INCREASE, state.points ? "Increase text size" : "Zoom in")
        label(PORTAL_BUTTON_RESET, state.points ? "Reset to \(reading) pt" : "Reset to \(reading)%")
        let reset = button(PORTAL_BUTTON_RESET)
        reset?.title = value
        reset?.dimmed = state.value == state.standard
        reset?.setAccessibilityValue(value)
        count.stringValue = "\(state.match) of \(state.matches)"
        count.textColor = state.color("shadow")
        if field.stringValue != state.query { field.stringValue = state.query }
        needsLayout = true
        needsDisplay = true
        for button in buttons.values { button.needsDisplay = true }
        layoutSubtreeIfNeeded()
    }

    func focusSearch() {
        window?.makeFirstResponder(field)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(state)
    }

    override func layout() {
        super.layout()
        for button in buttons.values { button.isHidden = true }
        separators = []
        field.isHidden = !state.finding
        count.isHidden = !state.finding
        func place(_ id: portal_button, _ x: CGFloat, width: CGFloat = 24) {
            guard state.has(id), id == PORTAL_BUTTON_OWNER || x >= 31 else { return }
            button(id)?.frame = NSRect(x: x, y: 3, width: width, height: 22)
            button(id)?.isHidden = false
        }
        place(PORTAL_BUTTON_OWNER, 5, width: 22)
        var right = bounds.width - 6
        func trailing(_ id: portal_button, width: CGFloat = 24) {
            guard state.has(id) else { return }
            right -= width; place(id, right, width: width); right -= 2
        }
        func separator() { right -= 5; separators.append(right); right -= 6 }
        if state.finding {
            trailing(PORTAL_BUTTON_CLOSE)
            if bounds.width >= 240 { trailing(PORTAL_BUTTON_NEXT); trailing(PORTAL_BUTTON_PREVIOUS) }
            count.isHidden = bounds.width < 180
            if !count.isHidden { right -= 68 }
            count.frame = NSRect(x: right, y: 7, width: 66, height: 16)
            field.frame = NSRect(x: 33, y: 3, width: max(20, right - 38), height: 22)
        } else {
            if state.has(PORTAL_BUTTON_RELOAD) { trailing(PORTAL_BUTTON_RELOAD); separator() }
            trailing(PORTAL_BUTTON_INCREASE); trailing(PORTAL_BUTTON_RESET, width: 46); trailing(PORTAL_BUTTON_DECREASE)
            if state.has(PORTAL_BUTTON_FIND) {
                separator()
                trailing(PORTAL_BUTTON_CONTENTS)
                trailing(PORTAL_BUTTON_EDIT)
                trailing(PORTAL_BUTTON_FIND)
                if right >= 93 { separators.append(33); place(PORTAL_BUTTON_BACK, 39); place(PORTAL_BUTTON_FORWARD, 65) }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        state.color("background").setFill(); bounds.fill()
        state.color("border").setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for x in separators { NSRect(x: x, y: 7, width: 1, height: 14).fill() }
    }

    func controlTextDidChange(_ notification: Notification) {
        Core.typed(target, field.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { click(PORTAL_BUTTON_CLOSE); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            click(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? PORTAL_BUTTON_PREVIOUS : PORTAL_BUTTON_NEXT)
            return true
        }
        return false
    }
}
