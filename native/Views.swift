// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A value from the options plist passed to `portal--open`: a string, t or nil.
enum ViewOption: Sendable {
    case string(String)
    case flag(Bool)
}

struct ViewOptions: Sendable {
    let values: [String: ViewOption]

    /// A string option; nil when absent or nil.
    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .flag(false): return nil
        case .string(let value): return value
        case .flag(true): throw NativeError.message("Option :\(key) must be a string")
        }
    }

    /// A flag option; any non-nil value is true, as in Lisp.
    func flag(_ key: String) -> Bool {
        switch values[key] {
        case nil, .flag(false): return false
        default: return true
        }
    }
}

/// A value in the plist returned by `portal--inspect`.
enum ViewValue: Sendable {
    case flag(Bool)
    case integer(Int)
    case integers([Int])
    case string(String)
}

/// One view kind. The registry owns each view's lifetime; the kind owns its
/// rendering, input and session. A view is always in a window: a frame's while
/// it is shown, otherwise the parking window. Moving it between windows must
/// happen inside one call, so it is never windowless. Closing ends it.
@MainActor
protocol PortalView: AnyObject {
    /// Open the view in PARKING, hidden.
    init(target: String, options: ViewOptions, parking: NativeHost) throws
    var input: NativeInput { get }
    /// The view's toolbar controls, or nil when it has no toolbar.
    var toolbar: ToolbarModel? { get }
    /// Show the view in HOST, moving it there from its current window.
    func place(in host: NativeHost, rectangle: CGRect) throws
    /// Hide the view by moving it into PARKING, keeping its session and size.
    func hide(in parking: NativeHost)
    func close()
    func inspect() -> [(String, ViewValue)]
}

/// Every Portal view, keyed by its native target (`kind:id`). IDs are global
/// across kinds and never reused, so a stale target can never reach a new view.
@MainActor
enum Views {
    private static let kinds: [String: any PortalView.Type] = [
        "terminal": TerminalSession.self, "web": WebSession.self]
    private static var views: [String: any PortalView] = [:]
    private static var nextID = 0
    /// The pipe carrying every view's records to Emacs; see `portal--channel`.
    static let channel = NativeEventChannel()
    /// Hidden views live in this offscreen window, which is never shown, so
    /// their sessions keep running whatever happens to Emacs frames.
    private static let parkingWindow: NSWindow = {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 960, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }()
    private static let parking = NativeHost.bind(window: parkingWindow)!

    static func open(kind: String, options: ViewOptions) throws -> String {
        guard let type = kinds[kind] else { throw NativeError.message("Unknown Portal view kind: \(kind)") }
        nextID += 1
        let target = "\(kind):\(nextID)"
        views[target] = try type.init(target: target, options: options, parking: parking)
        return target
    }

    static func place(_ target: String, edges: [Int], title: String) throws {
        guard edges.count == 4, edges[2] > edges[0], edges[3] > edges[1] else {
            throw NativeError.message("Expected [LEFT TOP RIGHT BOTTOM] with positive dimensions")
        }
        let view = try view(target)
        guard let host = NativeHost.bind(title: title) else {
            throw NativeError.message("Cannot find the requested native Emacs frame")
        }
        try view.place(in: host, rectangle: CGRect(x: edges[0], y: edges[1],
                                                   width: edges[2] - edges[0], height: edges[3] - edges[1]))
    }

    static func hide(_ target: String) throws { try view(target).hide(in: parking) }

    static func close(_ target: String) throws {
        guard let view = views.removeValue(forKey: target) else { throw unknown(target) }
        view.close()
    }

    static func inspect(_ target: String) -> [(String, ViewValue)]? { views[target]?.inspect() }

    static func input(_ target: String) -> NativeInput? { views[target]?.input }

    static func toolbar(_ target: String) -> ToolbarModel? { views[target]?.toolbar }

    static func view<Kind: PortalView>(_ target: String, as kind: Kind.Type) throws -> Kind {
        guard let view = views[target] as? Kind else { throw unknown(target) }
        return view
    }

    static func all<Kind: PortalView>(_ kind: Kind.Type) -> [Kind] {
        views.values.compactMap { $0 as? Kind }
    }

    private static func view(_ target: String) throws -> any PortalView {
        guard let view = views[target] else { throw unknown(target) }
        return view
    }

    private static func unknown(_ target: String) -> NativeError {
        NativeError.message("No Portal view \(target)")
    }
}
