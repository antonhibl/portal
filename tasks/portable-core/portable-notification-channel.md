---
id: portable-notification-channel
status: todo
depends_on:
  - portable-module-bindings
---

# Share ordered native notifications through a C POSIX channel

## Context and problem

Portal is refactoring its current macOS implementation so a Linux adapter can
be added later. This task adds no Linux backend or CI and no Windows support.
The prerequisite moves Emacs bindings to C; view and feature implementations may
still be Swift when this task starts.

`native/NativeEventChannel.swift` owns the single notification queue and pipe.
It mixes portable record/order policy with `Darwin` calls, `F_SETNOSIGPIPE`, and
a Swift task that retries after 20 ms. Native notifications wake the Emacs
command loop; large bridge payloads remain in their sessions. Input handoff and
bridge coalescing depend on reliable record order across reconnects.

## Outcome and scope

One reusable C channel owns framing, pending records, and POSIX writes. A small
macOS scheduling adapter arranges retries. All production notifications use the
new channel, even when their callers have not yet moved from Swift.

- Preserve `portal--channel PROCESS`, including nil disconnect, and ownership
  of the descriptor returned by Emacs's `open_channel`. Closing/replacing it
  must neither leak nor accidentally close a descriptor now owned elsewhere.
- Preserve ASCII `TYPE TARGET FIELD...\n` records, validation, and the atomic
  pipe-write size limit. Keep full bridge payloads outside this pipe.
- Preserve FIFO delivery while full or disconnected. Waiting records move to
  a replacement channel in order; successful receipt must not depend on
  reconnecting. `notify` retains its distinction between an invalid record and
  an accepted record waiting for delivery.
- Handle interrupted writes, nonblocking backpressure, disconnect, and retry
  cancellation explicitly. Confine OS-specific descriptor/SIGPIPE handling to
  a small POSIX implementation; do not change Emacs's process-wide signal policy.
- Expose a minimal retry/flush scheduling hook. Keep one serialized owner for
  queue mutation, and ensure a pending callback cannot use a closed channel.
  Preserve the current scheduling behavior unless a simpler implementation has
  equivalent evidence; an event-loop framework is unnecessary.
- Remove the Swift queue implementation. A temporary thin Swift caller is
  acceptable until input/web extractions merge. This task must work without
  depending on the separate C registry extraction.
- Update `docs/terminal-input-bridge.md` and the README's channel description.

## Starting points

Read `native/NativeEventChannel.swift`, `native/Core/emacs.c`'s channel binding,
`native/Views.swift`, `native/NativeInput.swift`, `native/WebView.swift`'s
`WebBridge`, and `portal-view.el`'s pipe/filter code. Read
`test/native-focus.swift`'s full-pipe and reconnect checks and
`test/portal-view-tests.el`. Follow replacement files from the prerequisite.

## Decisions to settle during implementation

Choose a queue representation that avoids moving every remaining record when
one is sent. Specify descriptor ownership, retry cancellation, and write-size
handling in the C interface. Linux-specific behavior may be documented as a
future adapter concern; proving a Linux port is not required.

## Acceptance criteria and verification

- [ ] A C test using real POSIX pipes fills a pipe, enqueues multiple record
  kinds, drains it, and observes exact FIFO delivery with no loss/duplication.
- [ ] Tests cover disconnected enqueue, reconnect with queued records, malformed
  and oversized records, interrupted writes, and cancellation of stale retries.
  Use a narrow injected write/scheduler seam only where a real pipe cannot
  deterministically produce the case.
- [ ] Closing the reader cannot terminate Emacs through SIGPIPE. The descriptor
  lifecycle and error behavior are exercised without AppKit or Swift.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass; the
  native channel/focus checks and graphical input/Excalidraw checks preserve
  prefix handoff and bridge delivery through the production module.
- [ ] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Move Emacs module bindings into C](portable-module-bindings.md) supplies the
  C build and the real Emacs channel binding. The separate C view-lifetime task
  is not a prerequisite.
