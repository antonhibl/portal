---
id: portable-view-lifecycle
status: todo
depends_on:
  - portable-module-bindings
  - portable-notification-channel
---

# Own native view lifetime in the C core

## Context and problem

This is a macOS-preserving refactor that prepares for another platform later.
It includes no Linux implementation, Linux experiments or CI, or Windows
support. Follow ADR 0003 (`docs/adr/0003-platform-interface-primitives.md`):
the core keeps Portal's rules, and the platform supplies primitives.

`native/Views.swift` combines target allocation and ownership with an AppKit
parking window. Its `PortalView` protocol exposes `NativeHost`, `CGRect`, and
Swift input and toolbar models. `WebSession` and `TerminalSession` duplicate
host, rectangle, edges, move and hide bookkeeping. `portal.h` still declares
the Lisp-shaped `portal_open`, `portal_place`, `portal_hide`, `portal_close`
and `portal_inspect`, so every platform would have to reimplement the registry.

## Outcome and scope

One C registry owns Portal view identities and the shared lifecycle state. The
platform owns the native views and attaches them. Both view kinds use this in
the production application.

- Move global, never-reused target IDs, target lookup, kind checks, cleanup
  after failed creation, and close ownership into the core. Keep the external
  `kind:id` targets and `portal--inspect` behavior. Do not keep a second
  authoritative Swift registry.
- Keep placement bookkeeping (edges, visibility, the attached frame) once, in
  the core, instead of in each Swift view kind.
- Keep the Lisp rule for choosing a pane, its geometry cache, and buffer hooks
  in `portal-view.el`. Moving code to C must not create a second pane-selection
  policy or a native polling loop.
- Keep native frame resolution, coordinate conversion, responder ownership,
  container attachment and the offscreen parking window in the macOS platform.
  Preserve the temporary-title lookup and its stale-window protection. Parking
  is how macOS implements detach, not a requirement for other platforms.
- Hide keeps the page or session and its last content size, place moves the same
  live view, and close ends it. On macOS, keep the existing attachment sequence
  so Ghostty keeps draining its PTY.
- Make resource ownership and invalidation explicit. A failure must not leave a
  half-registered view, close must release resources exactly once, and a late
  platform call must not reach a freed or different view. Document what a
  failed placement leaves behind.
- Update the README architecture and interface comments.

## Platform interface

- **Removes** `portal_open`, `portal_place`, `portal_hide`, `portal_close` and
  `portal_inspect`. The core implements these Lisp functions for `emacs.c`.
- **Adds, implemented by the platform:** create a native view of a kind from
  its options, returning an opaque handle; destroy it; attach it to the frame
  with a given title at a rectangle; detach it; and describe it. Describing
  returns only the facts the platform alone knows, such as a page's title or a
  terminal's grid. The core adds identity, kind, edges and visibility.
- The remaining Lisp-shaped web, terminal, input and toolbar operations take the
  platform's handle, which the core resolves and kind-checks. They no longer
  look up target strings in Swift.
- Add a call into the core only if the core must react to something the
  platform observes. Frame deletion, for example, already reaches Lisp through
  window changes. Follow the channel task's convention for such calls.

## Starting points

Read ADR 0003, `CONTEXT.md`, ADRs 0001 and 0002, `portal-view.el`,
`native/Views.swift`, `native/NativeHost.swift`, `native/WebView.swift`,
`native/Terminal.swift`, `native/Toolbar.swift`'s `NativeContainer`,
`native/Core/`, and `test/portal-fake-backend.c`. Use
`test/portal-view-tests.el`, `test/portal-integration-tests.el` and the native
focus checks as behavioral references.

## Decisions to settle during implementation

Choose how frames are identified without exposing AppKit types or keeping Emacs
values. Specify rectangle units and origin, where native scale conversion
happens, and who owns a view after a failed move. Keep current macOS behavior,
and do not design for hypothetical Linux rendering.

## Acceptance criteria and verification

- [ ] `portal.h` declares none of the removed operations. Its lifecycle part is
  the create, destroy, attach, detach and describe primitives.
- [ ] Both web and terminal views use the C registry in production. Target IDs
  never alias new views, including after close or failed creation.
- [ ] C tests with the fake platform cover the real core's lifecycle: success
  and failure, invalid targets, wrong-kind calls, invalid rectangles, repeated
  placement and hide, close, and a platform call arriving after close.
- [ ] Tests prove that hide keeps a session and its size, and that placing it
  elsewhere keeps the same platform handle. The tests do not duplicate native
  attachment policy.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  graphical web, terminal and combined integration suites keep splitting,
  hiding, frame movement and deletion, hidden-terminal output, and cleanup
  working. Run the native focus and toolbar checks after adapting their entry
  points.
- [ ] Record verification and mark this task done; follow `AGENTS.md` for the
  implementation worktree and PR.

## Blocked by

- [Move Emacs module bindings into C](portable-module-bindings.md) supplies the
  C bindings, the production C build and the fake-platform test module.
- [Own ordered native notifications in the C core](portable-notification-channel.md)
  sets the convention for platform calls into the core, which this task follows
  if it adds any. Doing it first keeps one definition of that convention.
