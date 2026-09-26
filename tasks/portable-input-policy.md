---
status: todo
---

# Run Portal input handoff policy in C

## Context and problem

This task preserves macOS behavior while preparing shared logic for a possible
Linux adapter later. Do not implement Linux input, Linux CI, or Windows support.
The prerequisites provide the C view registry and ordered notification channel.

`native/NativeInput.swift` mixes Portal's prefix/command handoff rules with
`NSEvent`, native focus, and event replay. State is represented by overlapping
`active`, `waiting`, and `reading` flags. `portal-input.el` also serializes
AppKit modifier bit positions, coupling Lisp configuration to macOS.

## Outcome and scope

A C input state machine decides whether Portal consumes a chord, starts or
cancels a handoff, or requests an effect. Swift performs native capture, focus,
and replay. Terminal and web views both use the same production policy.

- Define Portal modifier values and normalized first-chord data independent of
  AppKit. Update Lisp/native conversion together, preserving user `kbd`
  configuration, aliases, supported modified ASCII chords, punctuation/Shift
  behavior, and atomic collision validation.
- Replace overlapping handoff flags with explicit states for idle, awaiting
  acknowledgement, reading a command, and executing a command. Keep native
  focus observations and passthrough orthogonal where appropriate; do not
  invent invalid-state combinations or a second Emacs command executor.
- Move prefix matching, regular/quick binding selection, literal/cancel
  decisions, serial validation, and state transitions into C. Commands, prefix
  tails, minibuffer interaction, and resume decisions remain in Lisp.
- Retain serial invalidation on cancellation, hide, close, and newer handoffs.
  A late acknowledgement/completion must never focus or affect another view.
- Keep the native trigger and queued native events in the macOS adapter;
  normalized key data is for decisions, not a replacement for real event replay.
  Preserve ordering, repeats, key releases, modifier transitions, and delivery
  to the intended responder. Browser literal input must not use synthetic JS
  `KeyboardEvent` objects.
- Keep AppKit monitors, responder traversal, IME/text handling, WebKit resend
  suppression, and unmatched key-up handling in the host adapter. Preserve
  immediate Command-Escape recovery without a Lisp or JavaScript round trip.
- Use the C channel for notifications and typed effects/callbacks for native
  work. Document the serialized execution and callback ownership contract.
  Update input documentation and remove the displaced Swift policy.

## Starting points

Read `native/NativeInput.swift`, `native/NativeHost.swift`, the terminal key
handler in `native/Terminal.swift`, `portal-input.el`, and
`portal-terminal-bindings.el`. `docs/terminal-input-bridge.md` and the README
describe current behavior; `docs/input-design.md` includes historical proposals
and must not be treated as a mandate for new features. Relevant suites include
`test/portal-input-tests.el`, `test/portal-terminal-bindings-tests.el`,
`test/portal-input-gui-tests.el`, and `test/native-focus.swift`.
Follow current C files introduced by the prerequisites.

## Decisions to settle during implementation

Choose the smallest state/event/effect vocabulary that preserves existing
behavior, and specify who owns retained native events. Keep Command/Option
mapping in the macOS adapter; portable modifier values are not a promise to
support every future OS shortcut. This task does not expand web shortcut maps
or add prefix timeouts/watchdogs.

## Acceptance criteria and verification

- [ ] C tests exercise real transitions for delayed acknowledgement, rapid
  tails, repeated prefixes, literal delivery requests, cancellation, command
  completion, stale serials, passthrough, and hide/close during a handoff.
- [ ] Rebinding remains atomic and a collision leaves the previous working
  configuration intact. No shared input declaration or Lisp payload uses
  AppKit modifier bit values.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass;
  graphical input and terminal tests plus the native focus checks verify real
  replay, key-up handling, minibuffer commands, and focus changes for both kinds.
- [ ] Ordinary Escape/C-g still reach the view while it owns input; C-b remains
  the default prefix, Command-Escape returns to Emacs, and no global physical
  shortcut is introduced.
- [ ] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  target identity, lookup, and lifecycle invalidation.
- [Share ordered native notifications](portable-notification-channel.md)
  supplies reliable handoff records and retry ownership.
