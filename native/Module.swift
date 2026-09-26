// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CEmacs

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

private func readIntegers(_ env: Environment, _ vector: emacs_value?) -> [Int]? {
    let count = env.pointee.vec_size(env, vector)
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return nil }
    let values = (0..<count).map { env.pointee.extract_integer(env, env.pointee.vec_get(env, vector, $0)) }
    return env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return ? values : nil
}

/// Read a plist of keywords to strings, t or nil, such as (:directory "~/" :quick t).
private func readOptions(_ env: Environment, _ plist: emacs_value?) -> ViewOptions? {
    var arguments = [plist]
    let vector = env.pointee.funcall(env, symbol(env, "vconcat"), 1, &arguments)
    let count = env.pointee.vec_size(env, vector)
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return nil }
    guard count % 2 == 0 else { _ = fail(env, "Options must be a plist"); return nil }
    var values: [String: ViewOption] = [:]
    for index in stride(from: 0, to: count, by: 2) {
        var key = [env.pointee.vec_get(env, vector, index)]
        let value = env.pointee.vec_get(env, vector, index + 1)
        guard let name = readString(env, env.pointee.funcall(env, symbol(env, "symbol-name"), 1, &key)),
              name.hasPrefix(":") else {
            if env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return {
                _ = fail(env, "Option names must be keywords")
            }
            return nil
        }
        if !env.pointee.is_not_nil(env, value) {
            values[String(name.dropFirst())] = .flag(false)
        } else if env.pointee.eq(env, value, symbol(env, "t")) {
            values[String(name.dropFirst())] = .flag(true)
        } else if env.pointee.eq(env, env.pointee.type_of(env, value), symbol(env, "string")),
                  let text = readString(env, value) {
            values[String(name.dropFirst())] = .string(text)
        } else {
            _ = fail(env, "Option \(name) must be a string, t or nil")
            return nil
        }
    }
    return ViewOptions(values: values)
}

private func lisp(_ env: Environment, _ value: ViewValue) -> emacs_value? {
    switch value {
    case .flag(let flag): return boolean(env, flag)
    case .integer(let integer): return env.pointee.make_integer(env, integer)
    case .integers(let integers): return list(env, integers.map { env.pointee.make_integer(env, $0) })
    case .string(let text): return string(env, text)
    }
}

private let openView: emacs_function = { env, _, args, _ in
    let env = env!
    guard let kind = readString(env, args![0]), let options = readOptions(env, args![1]) else { return nil }
    return call(env) { try Views.open(kind: kind, options: options) } convert: { string(env, $0) }
}

private let placeView: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]), let edges = readIntegers(env, args![1]),
          let title = readString(env, args![2]) else { return nil }
    return call(env) { try Views.place(target, edges: edges, title: title); return true }
        convert: { boolean(env, $0) }
}

private let hideView: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]) else { return nil }
    return call(env) { try Views.hide(target); return true } convert: { boolean(env, $0) }
}

private let closeView: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]) else { return nil }
    return call(env) { try Views.close(target); return true } convert: { boolean(env, $0) }
}

private let inspectView: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]) else { return nil }
    return call(env, { Views.inspect(target) }, convert: { state in
        guard let state else { return symbol(env, "nil") }
        return list(env, state.flatMap { [symbol(env, ":" + $0.0), lisp(env, $0.1)] })
    })
}

private let loadWeb: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]), let url = readString(env, args![1]) else { return nil }
    return call(env) { try Views.view(target, as: WebSession.self).load(url); return true }
        convert: { boolean(env, $0) }
}

private let sendWeb: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]), let json = readString(env, args![1]) else { return nil }
    return call(env) { try Views.view(target, as: WebSession.self).send(json); return true }
        convert: { boolean(env, $0) }
}

private let receiveWeb: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]) else { return nil }
    return call(env) { try Views.view(target, as: WebSession.self).receive() } convert: { string(env, $0) }
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

private let pasteTerminal: emacs_function = { env, nargs, args, _ in
    let env = env!
    guard let target = readString(env, args![0]), let text = readString(env, args![1]) else { return nil }
    let enter = nargs > 2 && env.pointee.is_not_nil(env, args![2])
    return call(env) {
        try Terminals.paste(target, text: text, enter: enter)
        return true
    } convert: { boolean(env, $0) }
}

private let terminalText: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]) else { return nil }
    return call(env) { try Terminals.text(target) } convert: { string(env, $0) }
}

private let connectChannel: emacs_function = { env, _, args, _ in
    let env = env!
    let fd = env.pointee.is_not_nil(env, args![0]) ? env.pointee.open_channel(env, args![0]) : -1
    guard env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return else { return symbol(env, "nil") }
    return call(env) {
        Views.channel.connect(fd)
        return true
    } convert: { boolean(env, $0) }
}

private let configureBindings: emacs_function = { env, _, args, _ in
    let env = env!
    guard let json = readString(env, args![0]) else { return symbol(env, "nil") }
    return call(env) {
        try NativeInput.configureBindings(json)
        return true
    } convert: { boolean(env, $0) }
}

private let configurePrefix: emacs_function = { env, _, args, _ in
    let env = env!
    guard let character = readString(env, args![0]) else { return symbol(env, "nil") }
    let flags = env.pointee.extract_integer(env, args![1])
    return call(env) {
        try NativeInput.configurePrefix(character, flags: flags)
        return true
    } convert: { boolean(env, $0) }
}

private let inputAction: emacs_function = { env, nargs, args, _ in
    let env = env!
    guard let target = readString(env, args![0]), let action = readString(env, args![1]) else { return nil }
    let serial = nargs > 2 ? env.pointee.extract_integer(env, args![2]) : 0
    return call(env) { try NativeInput.perform(target, action: action, serial: serial) }
        convert: { boolean(env, $0) }
}

private let configureToolbar: emacs_function = { env, _, args, _ in
    let env = env!
    let enabled = env.pointee.is_not_nil(env, args![0])
    return call(env) { NativeToolbar.configure(enabled); return enabled } convert: { boolean(env, $0) }
}

private let toolbarTheme: emacs_function = { env, _, args, _ in
    let env = env!
    guard let json = readString(env, args![0]) else { return nil }
    return call(env) { try NativeToolbar.theme(json); return true } convert: { boolean(env, $0) }
}

private let toolbarAction: emacs_function = { env, _, args, _ in
    let env = env!
    guard let target = readString(env, args![0]), let action = readString(env, args![1]) else { return nil }
    return call(env) { try NativeToolbar.perform(action, target: target) }
        convert: { string(env, $0) }
}

@_cdecl("portal_swift_init")
public func initializePortal(_ env: UnsafeMutablePointer<emacs_env>) -> Int32 {
    let viewFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--open", 2, 2, openView,
         "Open a view of KIND (\"terminal\" or \"web\") with an OPTIONS plist; return its target, such as \"web:1\"."),
        ("portal--place", 3, 3, placeView, "Show TARGET at EDGES [LEFT TOP RIGHT BOTTOM] in the frame titled TITLE."),
        ("portal--hide", 1, 1, hideView, "Hide TARGET, keeping its session alive."),
        ("portal--close", 1, 1, closeView, "End TARGET and release its view."),
        ("portal--inspect", 1, 1, inspectView, "Return TARGET's native state as a plist, or nil for an unknown target."),
        ("portal--channel", 1, 1, connectChannel,
         "Send every view's records, lines of \"TYPE TARGET FIELD...\", to pipe PROCESS; nil disconnects.")
    ]
    let webFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--web-load", 2, 2, loadWeb, "Load URL, an absolute http, https, file, data or about URL, in web view TARGET."),
        ("portal--web-send", 2, 2, sendWeb, "Send the JSON object JSON to hosted web view TARGET's app over its bridge."),
        ("portal--web-receive", 1, 1, receiveWeb,
         "Return the messages hosted web view TARGET's app sent over its bridge, as a JSON array.")
    ]
    let terminalFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--terminal-theme", 1, 1, setTerminalTheme, "Apply named THEME to all terminals; nil restores system appearance defaults."),
        ("portal--terminal-themes", 0, 0, terminalThemes, "Return the available terminal theme names."),
        ("portal--terminal-paste", 2, 3, pasteTerminal, "Paste TEXT into terminal TARGET; press Enter if ENTER is non-nil."),
        ("portal--terminal-text", 1, 1, terminalText, "Select all of TARGET's scrollback and return its text. Leaves the native selection active."),
        ("portal--terminal-bindings", 1, 1, configureBindings, "Atomically replace runtime binding profiles from JSON."),
        ("portal--input-prefix", 2, 2, configurePrefix, "Set the native prefix CHARACTER and AppKit modifier FLAGS."),
        ("portal--input", 2, 3, inputAction, "Perform ACTION on native TARGET, optionally validating its handoff SERIAL.")
    ]
    let toolbarFunctions: [(String, Int, Int, emacs_function, String)] = [
        ("portal--toolbar", 1, 1, configureToolbar, "Show or hide native toolbars live."),
        ("portal--toolbar-theme", 1, 1, toolbarTheme, "Apply toolbar face colors from JSON RGB arrays."),
        ("portal--toolbar-action", 2, 2, toolbarAction, "Perform ACTION on TARGET and return its native state as JSON.")
    ]
    for (name, minimum, maximum, callback, doc) in viewFunctions + webFunctions + terminalFunctions
        + toolbarFunctions {
        let function = doc.withCString { env.pointee.make_function(env, minimum, maximum, callback, $0, nil) }
        var args = [symbol(env, name), function]
        _ = env.pointee.funcall(env, symbol(env, "fset"), args.count, &args)
        if env.pointee.non_local_exit_check(env) != emacs_funcall_exit_return { return 1 }
    }
    var feature = [symbol(env, "portal-native-module")]
    _ = env.pointee.funcall(env, symbol(env, "provide"), 1, &feature)
    return env.pointee.non_local_exit_check(env) == emacs_funcall_exit_return ? 0 : 1
}
