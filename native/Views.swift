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
/// rendering, input and session. Hiding keeps the view alive; closing ends it.
@MainActor
protocol PortalView: AnyObject {
    init(target: String, options: ViewOptions) throws
    func place(in host: NativeHost, rectangle: CGRect) throws
    func hide()
    func close()
    func inspect() -> [(String, ViewValue)]
}

/// Every Portal view, keyed by its native target (`kind:id`). IDs are global
/// across kinds and never reused, so a stale target can never reach a new view.
@MainActor
enum Views {
    private static let kinds: [String: any PortalView.Type] = ["terminal": TerminalSession.self]
    private static var views: [String: any PortalView] = [:]
    private static var nextID = 0

    static func open(kind: String, options: ViewOptions) throws -> String {
        guard let type = kinds[kind] else { throw NativeError.message("Unknown Portal view kind: \(kind)") }
        nextID += 1
        let target = "\(kind):\(nextID)"
        views[target] = try type.init(target: target, options: options)
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

    static func hide(_ target: String) throws { try view(target).hide() }

    static func close(_ target: String) throws {
        guard let view = views.removeValue(forKey: target) else { throw unknown(target) }
        view.close()
    }

    static func inspect(_ target: String) -> [(String, ViewValue)]? { views[target]?.inspect() }

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
