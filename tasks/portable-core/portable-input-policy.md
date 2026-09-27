---
id: portable-input-policy
status: done
depends_on:
  - portable-view-lifecycle
  - portable-notification-channel
---

# Run Portal input handoff policy in the C core

## Context and problem

This task preserves macOS behavior while preparing for another platform later.
Do not implement Linux input, Linux CI or Windows support. Follow ADR 0003
(`docs/adr/0003-platform-interface-primitives.md`).

`native/NativeInput.swift` mixes Portal's prefix and command handoff rules with
`NSEvent`, native focus and event replay. Its state is spread across
overlapping `active`, `waiting` and `reading` flags. `portal-input.el` also
serializes AppKit modifier bit positions, which ties Lisp configuration to
macOS. `portal.h` still declares the Lisp-shaped `portal_input`,
`portal_input_prefix` and `portal_terminal_bindings`, so every platform would
have to reimplement the handoff.

## Outcome and scope

A C state machine decides whether Portal takes a key, starts or cancels a
handoff, or asks the platform for an effect. The platform captures keys, moves
focus and replays events. Terminal and web views both use this in production.

- Define Portal modifier values and normalized first-chord data independent of
  AppKit. Change the Lisp and native conversion together. Preserve users' `kbd`
  configuration, aliases, supported modified ASCII chords, punctuation and Shift
  behavior, and atomic collision checks.
- Replace the overlapping flags with explicit states: idle, awaiting
  acknowledgement, reading a command, and executing a command. Keep native focus
  observations and passthrough separate where appropriate. Do not invent invalid
  state combinations or a second Emacs command executor.
- Move prefix matching, regular and quick binding selection, literal and cancel
  decisions, serial checks and state transitions into the core. Commands, prefix
  tails, minibuffer interaction and resume decisions stay in Lisp.
- Keep serial invalidation on cancellation, hide, close and newer handoffs. A
  late acknowledgement or completion must never focus or affect another view.
- Keep the native trigger and queued native events in the platform. Normalized
  key data is for decisions, not a replacement for replaying real events.
  Preserve ordering, repeats, key releases, modifier transitions, and delivery
  to the intended responder. Literal input in a browser must not use synthetic
  JavaScript `KeyboardEvent` objects.
- Keep AppKit monitors, responder traversal, IME and text handling, WebKit
  resend suppression and unmatched key-up handling in the platform. Keep
  immediate Command-Escape recovery with no Lisp or JavaScript round trip.
- Update the input documentation and remove the displaced Swift policy.

## Platform interface

- **Removes** the Lisp-shaped `portal_input`, `portal_input_prefix` and
  `portal_terminal_bindings`. The core implements these Lisp functions,
  including the actions `portal--input` accepts.
- **Adds, implemented by the platform, on one view handle:**
  - give the view the keyboard;
  - return the keyboard to Emacs;
  - replay or discard the key events it is holding;
  - deliver the held trigger key as a literal key press.
- **Adds, implemented by the core, called by the platform:**
  - a key was pressed in a view, as a normalized chord with its repeat flag. The
    core answers pass it on, take it, or hold it for replay.
  - a view gained or lost the keyboard.
- Command-Escape and the Command and Option mapping stay in the macOS platform;
  the platform reports the result, such as returning the keyboard to Emacs.

## Starting points

Read ADR 0003, `native/NativeInput.swift`, `native/NativeHost.swift`, the
terminal key handler in `native/Terminal.swift`, `portal-input.el`,
`portal-terminal-bindings.el`, and the prerequisites' C files.
`docs/terminal-input-bridge.md` and the README describe current behavior.
`docs/input-design.md` includes historical proposals and is not a mandate for
new features. Relevant suites include `test/portal-input-tests.el`,
`test/portal-terminal-bindings-tests.el`, `test/portal-input-gui-tests.el` and
`test/native-focus.swift`.

## Decisions to settle during implementation

Choose the smallest set of states, events and platform effects that preserves
existing behavior, and specify who owns held native events. Decide whether
"deliver the trigger literally" is a separate primitive or part of replay, and
keep only one. Portable modifier values are not a promise to support every
future OS shortcut. This task does not expand web shortcut maps or add prefix
timeouts or watchdogs.

## Acceptance criteria and verification

- [x] `portal.h` no longer declares the removed operations. Its input part is
  the primitives and calls into the core above.
- [x] C tests with a fake platform exercise the real transitions. They cover
  delayed acknowledgement, rapid tails, repeated prefixes, literal delivery,
  cancellation, command completion, stale serials, passthrough, and hide or
  close during a handoff.
- [x] Rebinding stays atomic, and a collision leaves the previous working
  configuration intact. No shared declaration or Lisp payload uses AppKit
  modifier bit values.
- [x] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  graphical input and terminal suites and the native focus checks verify real
  replay, key-up handling, minibuffer commands, and focus changes for both view
  kinds.
- [x] Ordinary Escape and C-g still reach the view while it owns input. C-b
  remains the default prefix, Command-Escape returns to Emacs, and no global
  physical shortcut is introduced.
- [x] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Decisions

- **States.** Each view's handoff is `idle`, `awaiting` acknowledgement,
  `reading` the key sequence, or `executing` the command. A `first` flag inside
  `reading` marks the key that may repeat the trigger. `focused` (as the
  platform reports) and `passthrough` are separate flags. The input state lives
  with each view in the registry (`struct portal_input` in
  `native/Core/input.h`).
- **Serials** come from one counter and are never reused. An action with a
  serial applies only while that handoff is still going. That covers
  cancellation, hide, close and newer handoffs without bumping serials on
  cancel.
- **Held events belong to the platform.** A `PORTAL_KEY_HOLD` answer makes the
  press the trigger and holds every key event after it, until the core calls
  `portal_view_replay`. Replaying keeps the trigger. Discarding drops
  everything, and ends the platform's capture of the window's keys.
- **Literal delivery is its own primitive**, `portal_view_literal`, because
  replay posts events through normal routing, while a literal goes straight
  to the view's responder after the core focuses it.
- **Focus reports.** The platform reports every change in whether a view has
  the keyboard, and reports a change it makes for the core before returning.
  It also reports the user's gestures as they happen: a click about to focus
  the view, and Command-Escape. A report that arrives while no Lisp function
  or core call is running is the user's doing and abandons the handoff with an
  `escape` record. Losing the keyboard always ends passthrough. `emacs.c`
  marks every Lisp call as Emacs's request, so `C-b s-f` (find) or a command
  focusing a view never abandons its own handoff.
- **One extra query**, `portal_input_owner`, lets the Swift toolbar's ownership
  dot and Command-F read the core's state until
  [the toolbar task](portable-toolbar-state.md) moves toolbar state into the
  core.
- `portal--terminal-bindings` still takes JSON. `emacs.c` parses it with
  `json-parse-string`, and each entry's `flags` became `modifiers`, using
  Portal's values (Shift 1, Control 2, Meta 4, Super 8).

## Verification (2026-09-28)

- `./build.sh` and `ctest --test-dir build --output-on-failure`: 16 of 16
  pass, including the new `input-core` (`test/portal-input-tests.c`) and the
  updated `module`, `input` and `terminal-bindings` tests. Mutating eight
  input rules in `input.c` (for example, the request guard, Shift
  normalization, the first-key literal, the serial check, repeat
  suppression, passthrough ending and the prefix collision) each fails
  `input-core`.
- The standalone checks `build/check-focus` and `build/check-toolbar` pass.
  They cover guest Escape and C-g, Command-Escape, hiding, click-to-select,
  link handoff, the owner dot, Command-F in passthrough, and Open in Emacs
  ending a pending prefix (records `prefix`, `escape`, `bridge`).
- Graphical suites: the first run was while the screen was locked
  (`loginwindow` in front), so no key or click injection could reach Emacs:
  25 of 52 passed and 27 failed. Unchanged `main` failed the same 27 under
  the same conditions.
- After merging, on merged `main` at 526ae93 (which also includes
  [the terminal task](portable-terminal-adapter.md)), the combined graphical
  suite passed 52 of 52 with Emacs able to take the keyboard, including all 6
  input, 19 terminal and 2 integration tests. `./build.sh`, `ctest` (17 of
  17, including `input-core`), `check-focus` and `check-toolbar` passed on the
  same commit.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  handles, lookup and invalidation on close.
- [Own ordered native notifications in the C core](portable-notification-channel.md)
  supplies reliable handoff records and the convention for platform calls into
  the core.
