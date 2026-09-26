// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class ToolbarModel {
    enum Kind { case web, preview, terminal }
    var kind: Kind { didSet { changed?() } }
    weak var input: NativeInput?
    var changed: (() -> Void)?
    var action: ((String) throws -> Void)?
    var focusFind: (() -> Void)?
    var search: ((String, Bool) -> Void)?
    var value = 100.0
    var defaultValue = 100.0
    var minimum = 50.0
    var maximum = 300.0
    var canGoBack = false
    var canGoForward = false
    var hasHeadings = false
    /// Whether the toolbar offers Open in Emacs, as a Markdown preview's does.
    var canEdit = false
    var tocOpen = false
    var finding = false
    var query = ""
    var matchCount = 0
    var matchIndex = 0

    init(_ kind: Kind) { self.kind = kind }

    func perform(_ command: String) throws {
        if command == "state" { return }
        if command == "find" {
            guard kind == .web || kind == .preview, NativeToolbar.enabled else {
                throw NativeError.message("Find needs a visible web toolbar")
            }
            let opening = !finding
            finding = true
            changed?()
            focusFind?()
            if opening && !query.isEmpty { find() }
        } else if command == "close-find" {
            finding = false
            search?("", false)
            // Only restore the content responder if find still owns the keyboard.
            if input?.view.map({ input?.host.ownsFocus($0) ?? false }) == true { _ = input?.focusView() }
        } else {
            try action?(command)
        }
        changed?()
    }

    func find(backwards: Bool = false) {
        search?(query, backwards)
    }

    func snapshot() throws -> String {
        let state: [String: Any] = ["value": value, "toc": tocOpen, "headings": hasHeadings,
                                    "find": finding, "query": query, "matches": matchCount,
                                    "match": matchIndex, "back": canGoBack, "forward": canGoForward]
        return String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self)
    }
}

@MainActor
enum NativeToolbar {
    static var enabled = true
    static var revision = 0
    static var colors: [String: NSColor] = [:]

    /// Perform ACTION on TARGET's toolbar and return the toolbar's state as JSON.
    static func perform(_ action: String, target: String) throws -> String {
        guard let model = Views.toolbar(target) else {
            throw NativeError.message("No toolbar controls for this native view")
        }
        try model.perform(action)
        return try model.snapshot()
    }

    static func configure(_ enabled: Bool) {
        self.enabled = enabled
        NativeHost.refreshToolbars(layout: true)
    }

    static func theme(_ json: String) throws {
        let values = try JSONDecoder().decode([String: [Double]].self, from: Data(json.utf8))
        revision += 1
        colors = values.compactMapValues { rgb in
            guard rgb.count == 3, rgb.allSatisfy({ (0...1).contains($0) }) else { return nil }
            return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        NativeHost.refreshToolbars()
    }

    static func color(_ name: String) -> NSColor {
        if let color = colors[name] { return color }
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

/// The feature keeps its identity and lifetime; only its available height changes.
@MainActor
final class NativeContainer: NSView {
    let content: NSView
    let model: ToolbarModel
    private(set) var toolbar: ToolbarView?
    override var isFlipped: Bool { true }

    init(content: NSView, model: ToolbarModel) {
        self.content = content
        self.model = model
        super.init(frame: .zero)
        addSubview(content)
        model.changed = { [weak self] in self?.toolbar?.refresh() }
        model.focusFind = { [weak self] in self?.toolbar?.focusSearch() }
        updateToolbar()
    }
    required init?(coder: NSCoder) { nil }

    func updateToolbar() {
        if NativeToolbar.enabled, toolbar == nil {
            let strip = ToolbarView(model: model)
            toolbar = strip
            addSubview(strip)
        } else if !NativeToolbar.enabled, let toolbar {
            if model.finding { try? model.perform("close-find") }
            toolbar.removeFromSuperview()
            self.toolbar = nil
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        toolbar?.refresh()
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
    var dot: NativeInput.Ownership?
    var selected = false
    var dimmed = true
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
        let accent = NativeToolbar.color("accent")
        let foreground = NativeToolbar.color("foreground")
        if isEnabled && (hovering || isHighlighted || selected) {
            (selected ? accent : foreground).withAlphaComponent(isHighlighted ? 0.20 : hovering ? 0.13 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = (selected ? accent : hovering && isEnabled || !dimmed ? foreground : NativeToolbar.color("shadow"))
            .withAlphaComponent(isEnabled ? 1 : 0.3)
        if let dot {
            let dotColor = NativeToolbar.color(dot == .emacs ? "shadow" : dot == .pending ? "accent" : dot == .passthrough ? "warning" : "success")
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

@MainActor
final class ToolbarView: NSView, NSSearchFieldDelegate {
    let model: ToolbarModel
    private var buttons: [String: ToolbarButton] = [:]
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private var separators: [CGFloat] = []
    private var lastState = ""
    override var isFlipped: Bool { true }

    init(model: ToolbarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        field.delegate = self
        field.placeholderString = "Find in page"
        field.font = .systemFont(ofSize: 11)
        field.setAccessibilityLabel("Find in page")
        count.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addSubview(field)
        addSubview(count)
        let specs: [(String, String, String?)] = [
            ("owner", "Click to enter", nil), ("back", "Back", "chevron.left"),
            ("forward", "Forward", "chevron.right"), ("find", "Find in page", "magnifyingglass"),
            ("toc", "Table of contents", "list.bullet"), ("edit", "Open in Emacs", "square.and.pencil"),
            ("decrease", "Zoom out", "minus"),
            ("reset", "Reset to 100%", nil), ("increase", "Zoom in", "plus"),
            ("reload", "Reload", "arrow.clockwise"), ("previous", "Previous match", "chevron.up"),
            ("next", "Next match", "chevron.down"), ("close-find", "Close find", "xmark")]
        for (id, tooltip, symbol) in specs {
            let button = ToolbarButton(tooltip, symbol: symbol) { [weak self] in self?.activate(id) }
            if id == "toc" { button.setAccessibilityRole(.checkBox) }
            buttons[id] = button
            addSubview(button)
        }
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    private func activate(_ id: String) {
        switch id {
        case "owner": model.input?.toggleOwnership()
        case "edit": model.input?.handOff("edit")
        case "previous": model.find(backwards: true)
        case "next": model.find()
        default: try? model.perform(id)
        }
        refresh()
    }

    func refresh() {
        let owner = model.input?.ownership ?? .emacs
        let signature = "\(owner) \(model.kind) \(NativeToolbar.revision) \((try? model.snapshot()) ?? "") \(model.minimum) \(model.maximum)"
        guard signature != lastState else { return }
        lastState = signature
        buttons["owner"]?.dot = owner
        let tooltip: String
        switch owner {
        case .emacs: tooltip = "Click to enter"
        case .view: tooltip = "Click to return to Emacs · ⌘⎋"
        case .pending: tooltip = "Emacs is reading a command"
        case .passthrough: tooltip = "Passthrough · ⌘⎋ returns to Emacs"
        }
        buttons["owner"]?.toolTip = tooltip
        buttons["owner"]?.setAccessibilityLabel(tooltip)
        buttons["owner"]?.isEnabled = owner != .pending
        buttons["back"]?.isEnabled = model.canGoBack
        buttons["forward"]?.isEnabled = model.canGoForward
        buttons["toc"]?.isEnabled = model.hasHeadings
        buttons["toc"]?.selected = model.tocOpen
        buttons["toc"]?.setAccessibilityValue(model.tocOpen ? 1 : 0)
        buttons["decrease"]?.isEnabled = model.value > model.minimum
        buttons["increase"]?.isEnabled = model.value < model.maximum
        buttons["reset"]?.title = String(format: model.kind == .terminal ? "%g pt" : "%g%%", model.value)
        buttons["reset"]?.dimmed = model.value == model.defaultValue
        if model.kind == .terminal {
            for (id, name) in [("decrease", "Decrease text size"), ("increase", "Increase text size"),
                               ("reset", "Reset to \(String(format: "%g", model.defaultValue)) pt")] {
                buttons[id]?.toolTip = name
                buttons[id]?.setAccessibilityLabel(name)
            }
        }
        buttons["reset"]?.setAccessibilityValue(buttons["reset"]?.title)
        count.stringValue = "\(model.matchIndex) of \(model.matchCount)"
        count.textColor = NativeToolbar.color("shadow")
        for id in ["previous", "next"] { buttons[id]?.isEnabled = model.matchCount > 0 }
        if field.stringValue != model.query { field.stringValue = model.query }
        needsLayout = true
        needsDisplay = true
        for button in buttons.values { button.needsDisplay = true }
        layoutSubtreeIfNeeded()
    }

    func focusSearch() {
        window?.makeFirstResponder(field)
        model.input?.host.refreshOwnership()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lastState = ""
        refresh()
    }

    override func layout() {
        super.layout()
        for button in buttons.values { button.isHidden = true }
        separators = []
        field.isHidden = !model.finding
        count.isHidden = !model.finding
        func place(_ id: String, _ x: CGFloat, width: CGFloat = 24) {
            guard id == "owner" || x >= 31 else { return }
            buttons[id]?.frame = NSRect(x: x, y: 3, width: width, height: 22)
            buttons[id]?.isHidden = false
        }
        place("owner", 5, width: 22)
        var right = bounds.width - 6
        func trailing(_ id: String, width: CGFloat = 24) { right -= width; place(id, right, width: width); right -= 2 }
        func separator() { right -= 5; separators.append(right); right -= 6 }
        if model.finding {
            trailing("close-find")
            if bounds.width >= 240 { trailing("next"); trailing("previous") }
            count.isHidden = bounds.width < 180
            if !count.isHidden { right -= 68 }
            count.frame = NSRect(x: right, y: 7, width: 66, height: 16)
            field.frame = NSRect(x: 33, y: 3, width: max(20, right - 38), height: 22)
        } else {
            if model.kind != .terminal { trailing("reload"); separator() }
            trailing("increase"); trailing("reset", width: 46); trailing("decrease")
            if model.kind != .terminal {
                separator()
                if model.kind == .preview { trailing("toc") }
                if model.canEdit { trailing("edit") }
                trailing("find")
                if right >= 93 { separators.append(33); place("back", 39); place("forward", 65) }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NativeToolbar.color("background").setFill(); bounds.fill()
        NativeToolbar.color("border").setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for x in separators { NSRect(x: x, y: 7, width: 1, height: 14).fill() }
    }

    func controlTextDidChange(_ notification: Notification) {
        model.query = field.stringValue
        model.find()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { activate("close-find"); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            model.find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }
}
