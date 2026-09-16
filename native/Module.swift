// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private typealias Environment = UnsafeMutablePointer<emacs_env>

private func symbol(_ env: Environment, _ name: String) -> emacs_value? {
    name.withCString { env.pointee.intern(env, $0) }
}

private func list(_ env: Environment, _ values: [emacs_value?]) -> emacs_value? {
    var values = values
    return env.pointee.funcall(env, symbol(env, "list"), values.count, &values)
}

private func fail(_ env: Environment, _ message: String) -> emacs_value? {
    let nilValue = symbol(env, "nil")
    let error = symbol(env, "error")
    let text = message.withCString {
        env.pointee.make_string(env, $0, message.utf8.count)
    }
    let data = list(env, [text])
    env.pointee.non_local_exit_signal(env, error, data)
    return nilValue
}

private let bind: emacs_function = { env, _, args, _ in
    let env = env!
    let nilValue = symbol(env, "nil")
    var size = 0
    guard env.pointee.copy_string_contents(env, args![0], nil, &size) else { return nilValue }
    var bytes = [CChar](repeating: 0, count: size)
    guard env.pointee.copy_string_contents(env, args![0], &bytes, &size) else { return nilValue }
    let title = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard Thread.isMainThread else {
        return fail(env, "Anymacs must be called on Emacs's main thread")
    }
    let bound = MainActor.assumeIsolated { NativeView.bind(title: title) }
    return bound ? symbol(env, "t") : fail(env, "Cannot find the requested native Emacs frame")
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
            return fail(env, "Anymacs needs rectangles with positive width and height")
        }
        layout.append(PaneLayout(id: id, rectangle: CGRect(
            x: edges[0], y: edges[1],
            width: edges[2] - edges[0], height: edges[3] - edges[1])))
    }
    guard Thread.isMainThread else {
        return fail(env, "Anymacs must be called on Emacs's main thread")
    }

    let attached = MainActor.assumeIsolated {
        NativeView.setLayout(layout)
    }
    return attached ? symbol(env, "t") : fail(env, "No bound native Emacs frame")
}

private let destroy: emacs_function = { env, _, _, _ in
    let env = env!
    guard Thread.isMainThread else {
        return fail(env, "Anymacs must be called on Emacs's main thread")
    }
    MainActor.assumeIsolated { NativeView.destroy() }
    return symbol(env, "nil")
}

private let inspect: emacs_function = { env, _, _, _ in
    let env = env!
    guard Thread.isMainThread else {
        return fail(env, "Anymacs must be called on Emacs's main thread")
    }
    let snapshots = MainActor.assumeIsolated { NativeView.snapshots() }
    return list(env, snapshots.map { snapshot in
        let edges = list(env, snapshot.edges.map { env.pointee.make_integer(env, $0) })
        return list(env, [
            symbol(env, ":visible"), symbol(env, snapshot.visible ? "t" : "nil"),
            symbol(env, ":edges"), edges,
            symbol(env, ":window"), env.pointee.make_integer(env, snapshot.windowNumber)
        ])
    })
}

@_cdecl("anymacs_swift_init")
public func initializeAnymacs(_ env: UnsafeMutablePointer<emacs_env>) -> Int32 {
    for (name, arity, callback, doc) in [
        ("anymacs--bind", 1, bind, "Bind shared native content to the frame identified by TITLE."),
        ("anymacs--set-layout", 1, setLayout,
         "Apply a vector of ID LEFT TOP RIGHT BOTTOM entries; [] removes all pane views."),
        ("anymacs--destroy", 0, destroy, "Release all native views, shared content and host."),
        ("anymacs--native-views", 0, inspect,
         "Inspect attached native views as plists with :visible, :edges and :window.")
    ] {
        let nameSymbol = symbol(env, name)
        let function = doc.withCString {
            env.pointee.make_function(env, arity, arity, callback, $0, nil)
        }
        var args = [nameSymbol, function]
        _ = env.pointee.funcall(env, symbol(env, "fset"), args.count, &args)
        if env.pointee.non_local_exit_check(env) != emacs_funcall_exit_return {
            return 1
        }
    }
    return 0
}
