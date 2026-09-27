// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone tests report failure without triggering macOS crash dialogs.
import Darwin
import Foundation

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
    FileHandle.standardError.write(Data("\(file):\(line): FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Check failed",
           file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { fail(message(), file: file, line: line) }
}

func require<T>(_ value: @autoclosure () throws -> T?, _ message: String = "Required value is missing or has the wrong type",
                file: StaticString = #filePath, line: UInt = #line) -> T {
    do {
        guard let result = try value() else { fail(message, file: file, line: line) }
        return result
    } catch {
        fail("Unexpected error: \(error)", file: file, line: line)
    }
}

func runChecks(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try body() } catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
