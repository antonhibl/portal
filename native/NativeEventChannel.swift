// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin

/// A nonblocking notification pipe into Emacs's command loop. Feature payloads
/// stay in their sessions; only short, newline-framed notifications use the pipe.
/// No asynchronous native callback may retain or call an emacs_env.
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

    /// PIPE_BUF-sized writes are atomic: failure never leaves a partial record.
    /// Callers either retry notifications or cancel their pending operation.
    @discardableResult
    func notify(_ message: String) -> Bool {
        guard descriptor >= 0, message.utf8.count <= Int(PIPE_BUF) else { return false }
        return message.withCString { Darwin.write(descriptor, $0, message.utf8.count) } == message.utf8.count
    }
}
