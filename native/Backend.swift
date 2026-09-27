// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PortalCore

// The macOS backend of the operations in native/Core/include/portal.h, whose
// comments define ownership. The C bindings call each one synchronously; it
// copies its arguments, runs on the main actor, and returns memory the
// bindings free. Nothing here sees an Emacs value or environment. The timer
// primitive is in CoreCalls.swift, which the standalone checks share.

private extension String {
    init(copying string: portal_string) {
        self.init(decoding: UnsafeRawBufferPointer(start: string.data, count: string.length), as: UTF8.self)
    }
}

/// Uninitialized memory for COUNT values, allocated for the bindings to free.
private func allocate<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
    malloc(max(count, 1) * MemoryLayout<T>.stride)!.bindMemory(to: type, capacity: max(count, 1))
}

/// VALUE's UTF-8, allocated for the bindings to free.
private func owned(_ value: String) -> portal_text {
    var value = value
    return value.withUTF8 { bytes in
        let data = allocate(CChar.self, bytes.count)
        if let base = bytes.baseAddress { memcpy(data, base, bytes.count) }
        return portal_text(data: data, length: bytes.count)
    }
}

/// Run BODY on the main actor, Emacs's thread, or describe its failure in FAILURE.
private func perform<T: Sendable>(_ failure: UnsafeMutablePointer<portal_text>,
                                  _ body: @MainActor () throws -> T) -> T? {
    do {
        guard Thread.isMainThread else { throw NativeError.message("Native calls require Emacs's main thread") }
        return try MainActor.assumeIsolated(body)
    } catch {
        let message = if case NativeError.message(let text) = error { text } else { error.localizedDescription }
        failure.pointee = owned(message)
        return nil
    }
}

/// Run BODY as above, then store the text it returns in OUTPUT.
private func perform(_ failure: UnsafeMutablePointer<portal_text>, into output: UnsafeMutablePointer<portal_text>,
                     _ body: @MainActor () throws -> String) -> Bool {
    guard let text = perform(failure, body) else { return false }
    output.pointee = owned(text)
    return true
}

/// VALUE as JSON text.
private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
           as: UTF8.self)
}

@_cdecl("portal_open")
public func portalOpen(_ kind: portal_string, _ options: UnsafePointer<portal_option>?, _ count: Int,
                       _ target: UnsafeMutablePointer<portal_text>,
                       _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let kind = String(copying: kind)
    var values: [String: ViewOption] = [:]
    for option in UnsafeBufferPointer(start: options, count: count) {
        values[String(copying: option.name)] = option.is_string ? .string(String(copying: option.string))
            : .flag(option.flag)
    }
    let options = ViewOptions(values: values)
    return perform(error, into: target) { try Views.open(kind: kind, options: options) }
}

@_cdecl("portal_place")
public func portalPlace(_ target: portal_string, _ edges: portal_edges, _ title: portal_string,
                        _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target), title = String(copying: title)
    let edges = [edges.left, edges.top, edges.right, edges.bottom].map { Int($0) }
    return perform(error) { try Views.place(target, edges: edges, title: title) } != nil
}

@_cdecl("portal_hide")
public func portalHide(_ target: portal_string, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target)
    return perform(error) { try Views.hide(target) } != nil
}

@_cdecl("portal_close")
public func portalClose(_ target: portal_string, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target)
    return perform(error) { try Views.close(target) } != nil
}

@_cdecl("portal_inspect")
public func portalInspect(_ target: portal_string, _ state: UnsafeMutablePointer<portal_text>,
                          _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target)
    return perform(error, into: state) {
        guard let properties = Views.inspect(target) else { return "null" }
        var object: [String: Any] = [:]
        for (name, value) in properties {
            switch value {
            case .flag(let flag): object[name] = flag
            case .integer(let integer): object[name] = integer
            case .integers(let integers): object[name] = integers
            case .string(let text): object[name] = text
            }
        }
        return try json(object)
    }
}

@_cdecl("portal_web_load")
public func portalWebLoad(_ target: portal_string, _ url: portal_string,
                          _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target), url = String(copying: url)
    return perform(error) { try Views.view(target, as: WebSession.self).load(url) } != nil
}

@_cdecl("portal_web_send")
public func portalWebSend(_ target: portal_string, _ json: portal_string,
                          _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target), json = String(copying: json)
    return perform(error) { try Views.view(target, as: WebSession.self).send(json) } != nil
}

@_cdecl("portal_web_receive")
public func portalWebReceive(_ target: portal_string, _ json: UnsafeMutablePointer<portal_text>,
                             _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target)
    return perform(error, into: json) { try Views.view(target, as: WebSession.self).receive() }
}

@_cdecl("portal_terminal_theme")
public func portalTerminalTheme(_ name: UnsafePointer<portal_string>?,
                                _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let name = name.map { String(copying: $0.pointee) }
    return perform(error) { try Terminals.setTheme(name) } != nil
}

@_cdecl("portal_terminal_themes")
public func portalTerminalThemes(_ names: UnsafeMutablePointer<portal_text>,
                                 _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error, into: names) { try json(Terminals.themeNames()) }
}

@_cdecl("portal_terminal_paste")
public func portalTerminalPaste(_ target: portal_string, _ text: portal_string, _ enter: Bool,
                                _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target), text = String(copying: text)
    return perform(error) { try Terminals.paste(target, text: text, enter: enter) } != nil
}

@_cdecl("portal_terminal_text")
public func portalTerminalText(_ target: portal_string, _ text: UnsafeMutablePointer<portal_text>,
                               _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target)
    return perform(error, into: text) { try Terminals.text(target) }
}

@_cdecl("portal_terminal_bindings")
public func portalTerminalBindings(_ json: portal_string, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let json = String(copying: json)
    return perform(error) { try NativeInput.configureBindings(json) } != nil
}

@_cdecl("portal_input_prefix")
public func portalInputPrefix(_ character: portal_string, _ flags: Int64,
                              _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let character = String(copying: character)
    return perform(error) { try NativeInput.configurePrefix(character, flags: Int(flags)) } != nil
}

@_cdecl("portal_input")
public func portalInput(_ target: portal_string, _ action: portal_string, _ serial: Int64,
                        _ result: UnsafeMutablePointer<Bool>, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target), action = String(copying: action)
    guard let performed = perform(error, { try NativeInput.perform(target, action: action, serial: Int(serial)) })
    else { return false }
    result.pointee = performed
    return true
}

@_cdecl("portal_toolbar")
public func portalToolbar(_ enabled: Bool, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    perform(error) { NativeToolbar.configure(enabled) } != nil
}

@_cdecl("portal_toolbar_theme")
public func portalToolbarTheme(_ json: portal_string, _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let json = String(copying: json)
    return perform(error) { try NativeToolbar.theme(json) } != nil
}

@_cdecl("portal_toolbar_action")
public func portalToolbarAction(_ target: portal_string, _ action: portal_string,
                                _ state: UnsafeMutablePointer<portal_text>,
                                _ error: UnsafeMutablePointer<portal_text>) -> Bool {
    let target = String(copying: target), action = String(copying: action)
    return perform(error, into: state) { try NativeToolbar.perform(action, target: target) }
}
