// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CEmacs

enum NativeError: Error { case message(String) }
private typealias Environment = UnsafeMutablePointer<emacs_env>

private func symbol(_ env: Environment, _ name: String) -> emacs_value? {
    name.withCString { env.pointee.intern(env, $0) }
}

private func string(_ env: Environment, _ value: String) -> emacs_value? {
    value.withCString { env.pointee.make_string(env, $0, value.utf8.count) }
}

private func boolean(_ env: Environment, _ value: Bool) -> emacs_value? {
    symbol(env, value ? "t" : "nil")
}

private func readString(_ env: Environment, _ value: emacs_value?) -> String? {
    var count = 0
    guard env.pointee.copy_string_contents(env, value, nil, &count), count > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: count)
    guard env.pointee.copy_string_contents(env, value, &bytes, &count) else { return nil }
    return String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func list(_ env: Environment, _ values: [emacs_value?]) -> emacs_value? {
    var values = values
    return env.pointee.funcall(env, symbol(env, "list"), values.count, &values)
}

// Emacs pointers stay outside the actor closure.  Only owned, Sendable values
// cross this synchronous boundary, and no callback retains an Emacs environment.
private func call<T: Sendable>(_ env: Environment, _ body: @MainActor () throws -> T,
                               convert: (T) -> emacs_value?) -> emacs_value? {
    // Argument conversion may already have signalled a Lisp type error.
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return nil }
    do {
        guard Thread.isMainThread else { throw NativeError.message("Native calls require Emacs's main thread") }
        return convert(try MainActor.assumeIsolated { try body() })
    } catch {
        let message: String
        if case NativeError.message(let text) = error { message = text }
        else { message = error.localizedDescription }
        return fail(env, message)
    }
}

private func fail(_ env: Environment, _ message: String) -> emacs_value? {
    let nilValue = symbol(env, "nil")
    let error = symbol(env, "error")
    let data = list(env, [string(env, message)])
    env.pointee.non_local_exit_signal(env, error, data)
    return nilValue
}

private let bind: emacs_function = { env, _, args, _ in
    let env = env!
    guard let title = readString(env, args![0]) else { return symbol(env, "nil") }
    return call(env) {
        guard WebViews.bind(title: title) else {
            throw NativeError.message("Cannot find the requested native Emacs frame")
        }
        return true
    } convert: { boolean(env, $0) }
}

private let loadURL: emacs_function = { env, _, args, _ in
    let env = env!
    guard let url = readString(env, args![0]) else { return symbol(env, "nil") }
    return call(env) {
        guard WebViews.loadURL(url) else {
            throw NativeError.message("Expected an absolute http, https, file, data or about URL and a bound frame")
        }
        return true
    } convert: { boolean(env, $0) }
}

private let setLayout: emacs_function = { env, _, args, _ in
    let env = env! // Emacs guarantees a valid environment for module callbacks.
    let nilValue = symbol(env, "nil")
    let vector = args![0]
    let count = env.pointee.vec_size(env, vector)
    if env.pointee.non_local_exit_check(env) != emacs_funcall_exit_return {
        return nilValue
    }
    guard count % 5 == 0 else {
        return fail(env, "Layout must contain ID LEFT TOP RIGHT BOTTOM for each pane")
    }
    // Validate the entire snapshot before changing any native views.
    var values: [Int] = []
    for index in 0..<count {
        let value = env.pointee.vec_get(env, vector, index)
        let integer = env.pointee.extract_integer(env, value)
        if env.pointee.non_local_exit_check(env) != emacs_funcall_exit_return {
            return nilValue
        }
        values.append(Int(integer))
    }
    var layout: [PaneLayout] = []
    var ids = Set<Int>()
    for index in stride(from: 0, to: count, by: 5) {
        let id = values[index]
        guard id > 0, ids.insert(id).inserted else {
            return fail(env, "Layout needs a unique positive ID for each pane")
        }
        let edges = values[(index + 1)..<(index + 5)].map { CGFloat($0) }
        guard edges[2] > edges[0], edges[3] > edges[1] else {
            return fail(env, "Portal needs rectangles with positive width and height")
        }
        layout.append(PaneLayout(id: id, rectangle: CGRect(
            x: edges[0], y: edges[1],
            width: edges[2] - edges[0], height: edges[3] - edges[1])))
    }
    return call(env) {
        guard WebViews.setLayout(layout) else { throw NativeError.message("No bound native Emacs frame") }
        return true
    } convert: { boolean(env, $0) }
}

private let destroy: emacs_function = { env, _, _, _ in
    let env = env!
    return call(env) { WebViews.destroy(); return false } convert: { boolean(env, $0) }
}

private let inspect: emacs_function = { env, _, _, _ in
    let env = env!
    return call(env, { WebViews.snapshots() }, convert: { snapshots in
        list(env, snapshots.map { snapshot in
            func string(_ value: String?) -> emacs_value? {
                guard let value else { return symbol(env, "nil") }
                return value.withCString { env.pointee.make_string(env, $0, value.utf8.count) }
            }
            let edges = list(env, snapshot.edges.map { env.pointee.make_integer(env, $0) })
            return list(env, [
                symbol(env, ":visible"), boolean(env, snapshot.visible),
                symbol(env, ":edges"), edges,
                symbol(env, ":window"), env.pointee.make_integer(env, snapshot.windowNumber),
                symbol(env, ":url"), string(snapshot.url),
                symbol(env, ":title"), string(snapshot.title),
                symbol(env, ":loading"), boolean(env, snapshot.loading),
                symbol(env, ":error"), string(snapshot.error)
            ])
        })
    })
}

private let openTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    guard let title = readString(env, args![0]), let directory = readString(env, args![1]) else {
        return symbol(env, "nil")
    }
    var theme: String?
    if nargs > 2, env.pointee.is_not_nil(env, args![2]) {
        guard let name = readString(env, args![2]) else { return symbol(env, "nil") }
        theme = name
    }
    let quick = nargs > 3 && env.pointee.is_not_nil(env, args![3])
    return call(env) {
        try Terminals.open(title: title, directory: directory, themeName: theme, quick: quick)
    } convert: { env.pointee.make_integer(env, $0) }
}

private let setTerminalTheme: emacs_function = { env, _, args, _ in
    let env = env!
    var theme: String?
    if env.pointee.is_not_nil(env, args![0]) {
        guard let name = readString(env, args![0]) else { return symbol(env, "nil") }
        theme = name
    }
    return call(env) {
        try Terminals.setTheme(theme)
        return true
    } convert: { boolean(env, $0) }
}

private let terminalThemes: emacs_function = { env, _, _, _ in
    let env = env!
    return call(env, { Terminals.themeNames() }, convert: { names in
        list(env, names.map { string(env, $0) })
    })
}

private let layoutTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 1)
    let vector = args![0]
    let count = env.pointee.vec_size(env, vector)
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return symbol(env, "nil") }
    var edges: [Int] = []
    for index in 0..<count { edges.append(env.pointee.extract_integer(env, env.pointee.vec_get(env, vector, index))) }
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return symbol(env, "nil") }
    return call(env) {
        guard edges.isEmpty || (edges.count == 4 && edges[2] > edges[0] && edges[3] > edges[1]) else {
            throw NativeError.message("Expected [] or [LEFT TOP RIGHT BOTTOM] with positive dimensions")
        }
        try Terminals.layout(edges, id: id)
        return true
    } convert: { boolean(env, $0) }
}

private let focusTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 0)
    return call(env) {
        try Terminals.focus(id)
        return true
    } convert: { boolean(env, $0) }
}

private let closeTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 0)
    return call(env) { Terminals.destroy(id); return false } convert: { boolean(env, $0) }
}

private let unfocusTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 0)
    return call(env) { Terminals.unfocus(id); return true } convert: { boolean(env, $0) }
}

private let inputTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 2)
    guard let text = readString(env, args![0]) else { return symbol(env, "nil") }
    let enter = env.pointee.is_not_nil(env, args![1])
    return call(env) {
        try Terminals.input(text, enter: enter, id: id)
        return true
    } convert: { boolean(env, $0) }
}

private let inspectTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 0)
    return call(env, { Terminals.snapshot(id) }, convert: { state in
        guard let state else { return symbol(env, "nil") }
        return list(env, [
            symbol(env, ":ready"), boolean(env, state.ready),
            symbol(env, ":visible"), boolean(env, state.visible),
            symbol(env, ":focused"), boolean(env, state.focused),
            symbol(env, ":title"), string(env, state.title),
            symbol(env, ":closed"), boolean(env, state.closed),
            symbol(env, ":columns"), env.pointee.make_integer(env, state.columns),
            symbol(env, ":rows"), env.pointee.make_integer(env, state.rows),
            symbol(env, ":edges"), list(env, state.edges.map { env.pointee.make_integer(env, $0) }),
            symbol(env, ":layer"), string(env, state.layer)
        ])
    })
}

private let snapshotTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    let id = optionalID(env, nargs, args, 0)
    return call(env) {
        try Terminals.text(id)
    } convert: { string(env, $0) }
}

private func optionalID(_ env: Environment, _ count: Int, _ args: UnsafeMutablePointer<emacs_value?>?,
                        _ index: Int) -> Int? {
    guard count > index, env.pointee.is_not_nil(env, args![index]) else { return nil }
    return env.pointee.extract_integer(env, args![index])
}

private let connectChannel: emacs_function = { env, _, args, _ in
    let env = env!
    let fd = env.pointee.is_not_nil(env, args![0]) ? env.pointee.open_channel(env, args![0]) : -1
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return symbol(env, "nil") }
    return call(env) {
        Terminals.connectChannel(fd)
        return true
    } convert: { boolean(env, $0) }
}

private let configureBindings: emacs_function = { env, _, args, _ in
    let env = env!
    guard let json = readString(env, args![0]) else { return symbol(env, "nil") }
    return call(env) {
        try Terminals.configureBindings(json)
        return true
    } convert: { boolean(env, $0) }
}

private let configurePrefix: emacs_function = { env, _, args, _ in
    let env = env!
    guard let character = readString(env, args![0]) else { return symbol(env, "nil") }
    let flags = env.pointee.extract_integer(env, args![1])
    return call(env) {
        try Terminals.configurePrefix(character, flags: flags)
        return true
    } convert: { boolean(env, $0) }
}

private let acknowledgePrefix: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    let replay = env.pointee.is_not_nil(env, args![1])
    return call(env) { Terminals.acknowledge(id, replay: replay) } convert: { boolean(env, $0) }
}

private let sendPrefix: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    return call(env) {
        try Terminals.sendPrefix(id)
        return true
    } convert: { boolean(env, $0) }
}

private let openEditor: emacs_function = { env, _, args, _ in
    let env = env!
    guard let title = readString(env, args![0]), let url = readString(env, args![1]) else { return nil }
    return call(env) { try WebEditors.open(title: title, address: url) }
        convert: { env.pointee.make_integer(env, $0) }
}

private let layoutEditor: emacs_function = { env, _, args, _ in
    let env = env!
    guard let title = readString(env, args![0]) else { return nil }
    let id = env.pointee.extract_integer(env, args![1])
    let count = env.pointee.vec_size(env, args![2])
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return nil }
    var edges: [Int] = []
    for index in 0..<count {
        edges.append(env.pointee.extract_integer(env, env.pointee.vec_get(env, args![2], index)))
    }
    return call(env) { try WebEditors.layout(id, title: title, edges: edges); return true }
        convert: { boolean(env, $0) }
}

private let sendEditor: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    guard let json = readString(env, args![1]) else { return nil }
    return call(env) { try WebEditors.send(id, json: json); return true }
        convert: { boolean(env, $0) }
}

private let takeEditor: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    return call(env) { try WebEditors.take(id) } convert: { string(env, $0) }
}

private let focusEditor: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    return call(env) { try WebEditors.focus(id); return true } convert: { boolean(env, $0) }
}

private let closeEditor: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    return call(env) { WebEditors.close(id); return false } convert: { boolean(env, $0) }
}

private let acknowledgeEditor: emacs_function = { env, _, args, _ in
    let env = env!
    let id = env.pointee.extract_integer(env, args![0])
    let replay = env.pointee.is_not_nil(env, args![1])
    return call(env) { WebEditors.acknowledge(id, replay: replay); return true }
        convert: { boolean(env, $0) }
}

private let connectEditorChannel: emacs_function = { env, _, args, _ in
    let env = env!
    let fd = env.pointee.is_not_nil(env, args![0]) ? env.pointee.open_channel(env, args![0]) : -1
    return call(env) { WebEditors.channel.connect(fd); return true } convert: { boolean(env, $0) }
}

@_cdecl("portal_swift_init")
public func initializePortal(_ env: UnsafeMutablePointer<emacs_env>) -> Int32 {
    let webFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--bind", 1, 1, bind, "Bind shared native content to the frame identified by TITLE."),
        ("portal--load-url", 1, 1, loadURL, "Load URL in all web panes; new panes start at this URL."),
        ("portal--set-layout", 1, 1, setLayout,
         "Apply a vector of ID LEFT TOP RIGHT BOTTOM entries; [] removes all pane views."),
        ("portal--destroy", 0, 0, destroy, "Release web/demo views and content; terminal sessions are unaffected."),
        ("portal--native-views", 0, 0, inspect,
         "Inspect attached native views as plists with :visible, :edges, :window, :url, :title, :loading and :error.")
    ]
    let terminalFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--terminal-open", 2, 4, openTerminal, "Create a native Ghostty session in frame TITLE at DIRECTORY with optional THEME and QUICK flag."),
        ("portal--terminal-theme", 1, 1, setTerminalTheme, "Apply named THEME to all terminals; nil restores system appearance defaults."),
        ("portal--terminal-themes", 0, 0, terminalThemes, "Return the available terminal theme names."),
        ("portal--terminal-layout", 1, 2, layoutTerminal, "Set native terminal EDGES, or [] to hide without ending the session."),
        ("portal--terminal-focus", 0, 1, focusTerminal, "Give the visible Ghostty view keyboard focus."),
        ("portal--terminal-unfocus", 0, 1, unfocusTerminal, "Return native keyboard focus to Emacs without ending the session."),
        ("portal--terminal-close", 0, 1, closeTerminal, "Destroy the terminal view and end its session."),
        ("portal--terminal-input", 2, 3, inputTerminal, "Paste TEXT into the terminal; press Enter if ENTER is non-nil."),
        ("portal--terminal-text", 0, 1, snapshotTerminal, "Select all terminal scrollback and return its text. Leaves the native selection active."),
        ("portal--terminal-state", 0, 1, inspectTerminal, "Inspect the native terminal's actual surface, focus and grid."),
        ("portal--terminal-channel", 1, 1, connectChannel, "Connect a pipe PROCESS for prefix notifications; nil disconnects."),
        ("portal--terminal-bindings", 1, 1, configureBindings, "Atomically replace runtime binding profiles from JSON."),
        ("portal--terminal-prefix", 2, 2, configurePrefix, "Set the native prefix CHARACTER and AppKit modifier FLAGS."),
        ("portal--terminal-ack", 2, 2, acknowledgePrefix, "Acknowledge a prefix for ID, replaying held events if REPLAY."),
        ("portal--terminal-send-prefix", 1, 1, sendPrefix, "Send the captured prefix key to terminal ID using native key events.")
    ]
    let editorFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--editor-open", 2, 2, openEditor, "Create a persistent local editor in frame TITLE at URL; return its ID."),
        ("portal--editor-layout", 3, 3, layoutEditor, "Place editor ID in frame TITLE at EDGES; [] hides it without unloading."),
        ("portal--editor-send", 2, 2, sendEditor, "Send JSON to editor ID asynchronously."),
        ("portal--editor-events", 1, 1, takeEditor, "Drain editor ID's pending messages as a JSON array."),
        ("portal--editor-focus", 1, 1, focusEditor, "Focus the visible editor ID."),
        ("portal--editor-close", 1, 1, closeEditor, "Release editor ID and its document session."),
        ("portal--editor-ack", 2, 2, acknowledgeEditor, "Release editor ID's input capture, replaying held keys if REPLAY."),
        ("portal--editor-channel", 1, 1, connectEditorChannel, "Connect a pipe PROCESS for editor notifications; nil disconnects.")
    ]
    for (name, minimum, maximum, callback, doc) in webFunctions + terminalFunctions + editorFunctions {
        let function = doc.withCString { env.pointee.make_function(env, minimum, maximum, callback, $0, nil) }
        var args = [symbol(env, name), function]
        _ = env.pointee.funcall(env, symbol(env, "fset"), args.count, &args)
        if env.pointee.non_local_exit_check(env) != emacs_funcall_exit_return { return 1 }
    }
    var feature = [symbol(env, "portal-native-module")]
    _ = env.pointee.funcall(env, symbol(env, "provide"), 1, &feature)
    return env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 1
}
