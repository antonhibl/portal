// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin

/// A nonblocking notification pipe into Emacs's command loop. Feature payloads
/// stay in their sessions; only short, newline-framed notifications use the pipe.
/// No asynchronous native callback may retain or call an emacs_env.
/// `Views.channel` is the one pipe, and carries every view's records; connect
/// it through `Views.connect`.
@MainActor
final class NativeEventChannel {
    private var descriptor: Int32 = -1
    /// Records the pipe could not take yet, oldest first.
    private var waiting: [String] = []
    private var retry: Task<Void, Never>?

    /// Records still waiting for the old pipe are dropped.
    func connect(_ fd: Int32) {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = fd
        waiting.removeAll()
        retry?.cancel()
        retry = nil
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }

    /// Send the record `TYPE TARGET FIELD...`, one ASCII line. Records reach
    /// Emacs in the order they are sent: while the pipe is full, a record waits
    /// with those after it and is retried, so none is lost. Records fit in
    /// PIPE_BUF, so each write is atomic: failure never leaves a partial record.
    /// Returns false only for a record that can never be sent: malformed, too
    /// long, or with no pipe connected.
    @discardableResult
    func notify(_ type: String, target: String, fields: [String] = []) -> Bool {
        let words = [type, target] + fields
        guard words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && !$0.isWhitespace } }) else {
            return false
        }
        let line = words.joined(separator: " ") + "\n"
        guard descriptor >= 0, line.utf8.count <= Int(PIPE_BUF) else { return false }
        waiting.append(line)
        flush()
        return true
    }

    /// Write waiting records in order until the pipe is full, then retry soon.
    private func flush() {
        while let line = waiting.first {
            let written = line.withCString { Darwin.write(descriptor, $0, line.utf8.count) }
            if written == line.utf8.count {
                waiting.removeFirst()
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                if retry == nil {
                    retry = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(20))
                        guard !Task.isCancelled, let self else { return }
                        self.retry = nil
                        self.flush()
                    }
                }
                return
            } else {
                // Emacs closed its end; nothing will read these records.
                waiting.removeAll()
                return
            }
        }
    }
}
