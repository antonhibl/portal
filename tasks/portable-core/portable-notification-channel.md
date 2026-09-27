---
id: portable-notification-channel
status: todo
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

- [ ] `portal.h` no longer declares `portal_channel`. The only new platform
  primitive is the timer, and a call into the core cannot reach Emacs.
- [ ] A C test uses real POSIX pipes and the fake platform's timer. It fills a
  pipe, queues several kinds of records, drains it, and sees exact FIFO
  delivery with nothing lost or duplicated.
- [ ] Tests cover queueing while disconnected, reconnecting with records
  waiting, malformed and oversized records, interrupted writes, and cancelled
  retries. Use a narrow injected write seam only where a real pipe cannot
  produce the case deterministically.
- [ ] Closing the reader cannot kill Emacs through SIGPIPE. The descriptor
  lifecycle and errors are tested without AppKit or Swift.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  native channel and focus checks and the graphical input and Excalidraw
  suites still show prefix handoff and bridge delivery through the production
  module.
- [ ] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Move Emacs module bindings into C](portable-module-bindings.md) supplies the
  C build, the Emacs channel binding and the fake-platform test module.
