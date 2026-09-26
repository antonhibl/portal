// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin

/// A nonblocking notification pipe into Emacs's command loop. Feature payloads
/// stay in their sessions; only short, newline-framed notifications use the pipe.
/// No asynchronous native callback may retain or call an emacs_env.
/// `Views.channel` is the one pipe, and carries every view's records.
@MainActor
final class NativeEventChannel {
    private var descriptor: Int32 = -1

    func connect(_ fd: Int32) {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = fd
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }

    /// Send the record `TYPE TARGET FIELD...`, one ASCII line. Records fit in
    /// PIPE_BUF, so each write is atomic: failure never leaves a partial record.
    /// Callers either retry notifications or cancel their pending operation.
    @discardableResult
    func notify(_ type: String, target: String, fields: [String] = []) -> Bool {
        let words = [type, target] + fields
        guard words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && !$0.isWhitespace } }) else {
            return false
        }
        let line = words.joined(separator: " ") + "\n"
        guard descriptor >= 0, line.utf8.count <= Int(PIPE_BUF) else { return false }
        return line.withCString { Darwin.write(descriptor, $0, line.utf8.count) } == line.utf8.count
    }
}
