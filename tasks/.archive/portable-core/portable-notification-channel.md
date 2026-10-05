---
id: portable-notification-channel
status: done
depends_on:
  - portable-module-bindings
---

# Own ordered native notifications in the C core

## Context and problem

Portal is refactoring its macOS implementation so that another platform can be
added later. This task adds no Linux platform, no Linux CI and no Windows
support. The prerequisite moved the Emacs bindings into C. For now, the
platform interface `native/Core/include/portal.h` mirrors the Lisp functions.
ADR 0003 (`docs/adr/0003-platform-interface-primitives.md`) describes the
primitive interface it should become.

`native/NativeEventChannel.swift` owns the single notification queue and pipe.
It mixes Portal's record and ordering rules with `Darwin` calls,
`F_SETNOSIGPIPE`, and a Swift task that retries after 20 ms. Input handoff and
bridge coalescing depend on records arriving in order, including across
reconnects. A future platform should not have to reimplement any of this.

This is the first task that has a platform call into the core. It sets the
convention that later tasks follow.

## Outcome and scope

The C core owns the pipe: framing, validation, the queue of waiting records,
and POSIX writes. Platform code reports notifications by calling the core. All
production notifications use the core's channel, including those whose callers
are still Swift.

- Preserve `portal--channel PROCESS`, including nil to disconnect, and ownership
  of the descriptor that Emacs's `open_channel` returns. Closing or replacing
  it must neither leak it nor close a descriptor that something else now owns.
- Preserve the ASCII `TYPE TARGET FIELD...\n` records, their validation, and
  the atomic pipe-write size limit. Keep full bridge payloads out of the pipe.
- Preserve FIFO delivery while the pipe is full or disconnected. Waiting records
  move to a replacement pipe in order, and delivery must not depend on
  reconnecting. `notify` keeps distinguishing an invalid record from an accepted
  record that is still waiting.
- Handle interrupted writes, nonblocking backpressure, disconnects and retry
  cancellation explicitly. Keep descriptor and SIGPIPE handling in a small POSIX
  part of the core; do not change Emacs's process-wide signal policy.
- Remove the Swift queue. Swift callers in input and the web bridge call the
  core's notify function until their own tasks move them.
- Update `docs/terminal-input-bridge.md` and the README's channel description.

## Platform interface

- **Removes** `portal_channel`. `emacs.c` connects the pipe through the core.
- **Adds, implemented by the platform:** one timer primitive that asks the
  platform to call the core back after a delay. The core uses it to retry a full
  pipe, and later tasks may reuse it. Do not add a channel-specific hook.
- **Adds, implemented by the core:** notify, called by platform code, with the
  record's type, target and fields as borrowed strings. Also the timer's
  callback.
- **Records the convention for calls into the core in `portal.h`.** They run on
  the thread that runs module calls, borrow their arguments, and never reach
  Emacs. Replace the header's "no callbacks" rule with "no callbacks into
  Emacs".

## Starting points

Read ADR 0003, `native/NativeEventChannel.swift`, `native/Core/emacs.c`'s
channel binding, `native/Core/include/portal.h`, `native/NativeInput.swift`,
`native/WebView.swift`'s `WebBridge`, and `portal-view.el`'s pipe and filter
code. Read `test/native-focus.swift`'s full-pipe and reconnect checks,
`test/portal-view-tests.el`, and `test/portal-fake-backend.c`.

## Decisions to settle during implementation

Choose a queue representation that avoids moving every remaining record when
one is sent. Specify descriptor ownership, timer cancellation, and write-size
handling in the interface comments. Behavior specific to other platforms may be
documented as a future concern; proving a port is not required.

## Acceptance criteria and verification

- [x] `portal.h` no longer declares `portal_channel`. The only new platform
  primitive is the timer, and a call into the core cannot reach Emacs.
- [x] A C test uses real POSIX pipes and the fake platform's timer. It fills a
  pipe, queues several kinds of records, drains it, and sees exact FIFO
  delivery with nothing lost or duplicated.
- [x] Tests cover queueing while disconnected, reconnecting with records
  waiting, malformed and oversized records, interrupted writes, and cancelled
  retries. Use a narrow injected write seam only where a real pipe cannot
  produce the case deterministically.
- [x] Closing the reader cannot kill Emacs through SIGPIPE. The descriptor
  lifecycle and errors are tested without AppKit or Swift.
- [x] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  native channel and focus checks and the graphical input and Excalidraw
  suites still show prefix handoff and bridge delivery through the production
  module.
- [x] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Move Emacs module bindings into C](portable-module-bindings.md) supplies the
  C build, the Emacs channel binding and the fake-platform test module.

## Outcome

- `native/Core/channel.c` owns the pipe: validation, the queue of waiting
  records, retries and the descriptor. It never includes `emacs-module.h`, and
  CMake compiles it, with the fake backend, into an object library that has no
  Emacs include path, so nothing the platform calls can reach Emacs.
- `portal.h` no longer declares `portal_channel`. It adds one platform
  primitive, `portal_timer_start(token, milliseconds)`, and two calls into
  the core: `portal_notify(type, target, fields, count)` and
  `portal_timer_fired(token)`. The header now says the platform calls the core
  only on the module thread, with borrowed arguments, and that no callback
  reaches Emacs.
- `portal--channel` keeps its behavior. `emacs.c` passes the descriptor from
  `open_channel` to `portal_channel_connect`, declared in the core's private
  `native/Core/channel.h`. On failure, the descriptor stays the caller's, the old
  pipe stays connected, and `emacs.c` closes it and signals with `strerror`.
- Decisions:
  - **Queue.** A singly linked list of `malloc`ed records, so sending one
    never moves the rest.
  - **Descriptors.** Connecting sets `O_NONBLOCK`, `FD_CLOEXEC` and
    `F_SETNOSIGPIPE`. Replacing or disconnecting closes the old descriptor
    once and never retries `close`. Reconnecting the same descriptor keeps it.
  - **Timers.** The platform's timers cannot be cancelled. The core cancels
    a retry by forgetting its token, which is never 0 or reused, so a stale
    callback neither writes nor starts another timer. Any connect cancels the
    pending retry, and at most one retry is pending.
  - **Write size.** A record, newline included, fits in `PIPE_BUF`, so each
    write is all or nothing. A short write, which POSIX rules out, would
    resume where it stopped. A new pipe always gets whole records.
  - **Errors.** `EINTR` retries at once, and `EAGAIN` retries after 20 ms. Any
    other error, such as `EPIPE`, leaves records waiting for Emacs to connect
    a pipe.
  - **Validation.** Words must be nonempty printable ASCII (0x21 to 0x7e),
    which is slightly stricter than before: the Swift check let control
    characters other than whitespace through. `notify` returns false only for
    a record it will never send (malformed, too long, or out of memory).
  - **Other platforms.** Other platforms are a future concern. Without
    `F_SETNOSIGPIPE`, `channel.c` stops with `#error`. Its comment records
    the Linux approach: block SIGPIPE in the writing thread and consume the
    signal a closed reader raises.
- Swift: `native/NativeEventChannel.swift` and `Views.channel` are gone.
  `native/CoreCalls.swift` holds `Core.notify`, which input, pane selection and
  the web bridge call, and the timer, `DispatchQueue.main.asyncAfter`.
  `native/Core/include/module.modulemap` names `portal.h` `PortalCore`, so
  SwiftPM and the standalone checks import it the same way. The checks link
  `channel.c` and use `channel.h` as their bridging header.
- The fake backend implements the timer: its timers fire only when a test fires
  them (`test/portal-fake-backend.h`). Its hosted app announces echoed
  messages with one `bridge` record, as the real bridge does. That replaces
  the "fake connected" line.
- README and `docs/terminal-input-bridge.md` describe the core's pipe, the
  new tests and the new check commands.

## Verification

Run on macOS 27.0 with Swift 6.4, Emacs 31.1, and CMake 4.4.3 on 2026-09-27:

- `ctest --test-dir build/core --output-on-failure` passed `channel` and
  `module` (11 ERT tests under `--module-assertions`). `otool -L` shows that the
  channel test links only `libSystem`. In `test/portal-channel-tests.c`, each of
  these single changes to `channel.c` makes the test fail:
  - dropping `F_SETNOSIGPIPE`, which kills the test with SIGPIPE (exit 141)
  - keeping the retry token across a connect, or letting stale tokens fire
  - treating `EINTR` as an error
  - restarting a short write
  - resuming a partial record on a new pipe
  - closing a reconnected descriptor
  - starting a timer per notify
  - dropping `FD_CLOEXEC`
  - an off-by-one size limit
  - losing queued records
- `./build.sh` built without warnings. `nm` shows `portal_notify`,
  `portal_timer_fired` and `portal_timer_start` defined in `portal.dylib`, no
  `portal_channel`, and no undefined `portal_*` symbols. `ctest --test-dir
  build --output-on-failure` passed 14 of 14.
- `build/check-focus` passed, including the full-pipe and reconnect check
  retried on the Swift timer and the bridge and `select` records.
  `build/check-toolbar` passed, including the Markdown preview's
  `prefix`/`escape`/`bridge` records. `test_native_checks.py` passed.
- The README's combined graphical suite, run through the production module with
  `--module-assertions`, passed 52 of 52 in three of four runs. It covers prefix
  handoff, Excalidraw bridge delivery and Markdown link handoff. In the other,
  slower run, `portal-markdown-gui-link-click-ends-a-pending-prefix` and
  `portal-markdown-gui-source-links-hand-off-and-return` found no
  `portal-web-follow` event after an injected link click. The log showed no
  record errors, and the four Markdown tests then passed in three separate runs.
