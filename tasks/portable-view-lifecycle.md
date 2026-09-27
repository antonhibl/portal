---
status: todo
---

# Own native view lifetime in the C core

## Context and problem

This is a macOS-preserving architecture refactor for a possible future Linux
implementation. Linux implementation, Linux experiments/CI, and Windows support
are outside scope. The prerequisite provides real C Emacs bindings and a typed
interface to the working Swift implementation.

`native/Views.swift` combines target allocation and ownership with an AppKit
parking window. Its `PortalView` protocol exposes `NativeHost`, `CGRect`, and
Swift input/toolbar models. `WebSession` and `TerminalSession` duplicate host,
rectangle, edges, move, and hide bookkeeping. Those details make the shared
lifecycle depend on macOS.

## Outcome and scope

One C registry owns native Portal view identities and shared lifecycle state.
The macOS adapter owns the actual native views and their attachment mechanics.
Both existing view kinds run through this seam in the production application.

- Move global, never-reused target IDs, target lookup, kind checking,
  creation-failure cleanup, and close ownership into C. Retain the external
  `kind:id` targets and `portal--inspect` behavior. Avoid a second authoritative
  Swift target registry.
- Define small typed lifecycle operations around opaque adapter handles and a
  plain rectangle. Centralize repeated placement bookkeeping and combine it
  with kind-specific inspection data where appropriate.
- Keep the Lisp rule for choosing a pane, its geometry cache, and buffer hooks
  in `portal-view.el`. Moving code to C must not create a second pane-selection
  policy or native polling loop.
- Keep native frame resolution, coordinate conversion, responder ownership,
  container attachment, and the offscreen parking window in the macOS host.
  Preserve the temporary-title lookup and its stale-window protection. The
  shared interface must not require every future adapter to have a parking
  window or treat a frame title as a universal native handle.
- Define hide as preserving the page/session and its last content size, place
  as moving the same live view, and close as ending it. macOS still needs its
  existing attachment sequence so Ghostty continues draining its PTY.
- Make resource ownership and invalidation explicit: failure must not leave a
  half-registered view, close must release resources once, and late callbacks
  must not reach a freed or different view. Document failed-placement behavior.
- Leave feature-specific operations and input/toolbar policy in their current
  implementations. Provide only the lookup/attachment hooks needed by their
  later extractions. Update the architecture documentation.

## Starting points

Read `CONTEXT.md`, both existing ADRs under `docs/adr/`, `portal-view.el`,
`native/Views.swift`, `native/NativeHost.swift`, `native/WebView.swift`,
`native/Terminal.swift`, and `native/Toolbar.swift`'s `NativeContainer`.
Use `test/portal-view-tests.el`, `test/portal-integration-tests.el`, and the
native focus checks as behavioral references. Paths identify original
ownership; follow the prerequisite's replacement C files after it merges.

## Decisions to settle during implementation

Choose the representation of frame resolution and adapter handles without
exposing AppKit types or retaining Emacs values. Specify rectangle units and
origin, where native scale conversion occurs, and ownership on a failed move.
Keep the current macOS behavior; do not design hypothetical Linux rendering.

## Acceptance criteria and verification

- [ ] Both web and terminal production views use the C registry; target IDs
  never alias new views, including after close or failed creation.
- [ ] Fake-adapter C tests exercise lifecycle success/failure, invalid targets,
  wrong-kind calls, invalid rectangles, repeated placement/hide, close, and
  callback invalidation through the real core interface.
- [ ] Tests prove that hide preserves a session and its size, and placing it
  elsewhere keeps the same adapter instance. Native attachment policy is not
  duplicated in those tests.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass.
  The graphical web/terminal and combined integration suites preserve splitting,
  hiding, frame movement/deletion, continued hidden-terminal output, and cleanup.
  Run the native focus/toolbar checks after adapting their entry points.
- [ ] README architecture and interface comments explain shared ownership and
  the macOS parking implementation. Record verification and mark this task done;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Move Emacs module bindings into C](portable-module-bindings.md) supplies the
  common interface, production C build, and fake-backend test entry point.
