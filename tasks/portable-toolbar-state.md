---
status: todo
---

# Share toolbar state while keeping macOS controls native

## Context and problem

This finishes the shared-policy extraction for the existing macOS application.
Linux remains a future implementation; do not build a GTK toolbar, run Linux
experiments/CI, or add Windows support. The prerequisites provide C lifecycle,
input, web, and terminal operations used by the toolbar.

`native/Toolbar.swift` contains both `ToolbarModel` and AppKit drawing/controls.
The model reaches into native focus, while `ToolbarView.refresh` serializes its
state to JSON to detect changes. Web zoom/find state also lives in
`native/WebToolbar.swift`, and terminal text-size policy lives in
`native/Terminal.swift`. Future adapters should share these decisions without
copying an AppKit model.

## Outcome and scope

One C model owns each view's toolbar state and action policy. Native macOS
controls render typed snapshots and report user actions through the same
interface used by Lisp commands. Toolbar appearance and interaction are retained.

- Move toolbar kind/configuration, availability, zoom/font-size value and limits,
  TOC/find state, and relevant action transitions into C. Keep input ownership
  in the input module and browser/terminal state in their owning modules; derive
  toolbar display state rather than creating duplicate authoritative copies.
- Route button and Lisp actions through the same model and typed web/terminal
  operations. Preserve current navigation controls, zoom steps, terminal size
  limits, Markdown Open in Emacs, and views that intentionally have no toolbar.
- Preserve find query/direction, serialized requests, superseding query behavior,
  and navigation-generation invalidation. The macOS web adapter still performs
  WKWebView find calls and executes the shared helper scripts. Preserve existing
  match reporting; a new search algorithm is outside this refactor.
- Keep AppKit buttons/text fields, layout, drawing, SF Symbols, accessibility,
  tracking areas, effective-appearance handling, and responder changes in Swift.
  Represent theme colors as plain values until the adapter creates NSColor.
- Replace JSON serialization as an internal refresh fingerprint with a typed
  snapshot or revision. Keep the external `portal--toolbar-action` JSON result
  and Lisp-facing behavior compatible; internal C/Swift calls need not use JSON.
- Preserve the 28-pixel strip, live visibility/theme settings, retained state
  across hide/reload/frame moves, and focus-preserving clicks. Closing find must
  not steal focus after the user has moved to Emacs or another view.
- Remove displaced Swift policy and migrate meaningful model tests to the real
  C interface. Keep native tests for layout, focus, rendering, and accessibility.
  Update README architecture and toolbar documentation with the final ownership.

## Starting points

Read `native/Toolbar.swift`, `native/WebToolbar.swift`, `native/Terminal.swift`,
`portal-toolbar.el`, and `docs/toolbar-design.md`; distinguish historical design
ideas from implemented behavior. Use `test/native-toolbar.swift`,
`test/portal-toolbar-tests.el`, `test/portal-toolbar-gui-tests.el`, and relevant
web/input tests. Follow the merged prerequisites' typed C interfaces and shared
JavaScript resources; original file paths describe pre-refactor ownership.

## Decisions to settle during implementation

Choose snapshot versus revision-based refresh and define async search completion
ownership. Document which module owns each state value and how the adapter
requests focus effects. Avoid a general GUI toolkit, cross-platform widget
schema, or moving toolbar UI into a webview merely to remove Swift.

## Acceptance criteria and verification

- [ ] C tests cover action availability, zoom/font limits, retained state,
  find/query sequencing, navigation invalidation, hide/close, and stale callbacks
  through the production model with fake web/terminal/input operations.
- [ ] Button actions and Lisp commands observe the same state; internals do not
  serialize JSON solely to decide whether controls need refreshing.
- [ ] Native toolbar/focus checks and graphical toolbar tests verify real layout,
  native text editing, focus preservation, live enable/theme changes, and all
  toolbar variants including toolbar-free Excalidraw and quick terminals.
- [ ] `./build.sh`, `ctest --test-dir build --output-on-failure`, and the common
  C tests pass. Run the combined graphical suite described in README to verify
  the completed extraction works across both view kinds.
- [ ] The common tests exercise shared production code using an ordinary C
  toolchain without Swift/AppKit/Ghostty. This is the portability evidence for
  this refactor; successful Linux application builds are not a completion gate.
- [ ] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Run Portal input handoff policy in C](portable-input-policy.md) supplies input
  ownership and focus-effect operations.
- [Separate shared web behavior from WKWebView](portable-web-bridge.md) supplies
  web actions/events and packaged helper scripts.
- [Confine Ghostty integration to its adapter](portable-terminal-adapter.md)
  supplies typed terminal text-size operations and state.
