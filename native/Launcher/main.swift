// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

// Runs only inside Ghostty's PTY child. Ghostty has already prepared terminal
// metadata, shell integration, cwd and argv. Never runs in the Emacs process.
func launch() throws {
    let transport = "PORTAL_TERMINAL_LAUNCH"
    guard let json = ProcessInfo.processInfo.environment[transport],
          let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let program = request["program"] as? String, program.hasPrefix("/"), !program.contains("\0"),
          let removals = request["unset"] as? [String],
          removals.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.contains("\0") }),
          request["restore"] is String || request["restore"] is NSNull else {
        throw NSError(domain: "PortalTerminalLauncher", code: 64,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid terminal launch request"])
    }
    if let value = request["restore"] as? String {
        guard !value.contains("\0"), setenv(transport, value, 1) == 0 else { throw POSIXError(.EINVAL) }
    } else if unsetenv(transport) != 0 {
        throw POSIXError(.EINVAL)
    }
    for name in removals {
        if unsetenv(name) != 0 { throw POSIXError(.EINVAL) }
    }
    // Ghostty's macOS wrapper marks argv[0] as a login command. Retain that
    // marker so shells still load their login startup files.
    let argv0 = CommandLine.arguments[0].hasPrefix("-") ? "-" + program : program
    let arguments = [argv0] + CommandLine.arguments.dropFirst()
    var pointers = arguments.map { strdup($0) }
    defer { for pointer in pointers { free(pointer) } }
    guard pointers.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
    pointers.append(nil)
    execv(program, &pointers)
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

do {
    try launch()
} catch {
    FileHandle.standardError.write(Data("Portal terminal launch failed: \(error.localizedDescription)\n".utf8))
    exit((error as? POSIXError)?.code == .ENOENT ? 127 : 126)
}
