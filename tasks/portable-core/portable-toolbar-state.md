---
id: portable-toolbar-state
status: todo
depends_on:
  - portable-input-policy
  - portable-web-bridge
  - portable-terminal-adapter
---

# Own toolbar state in the C core and finish the platform interface

## Context and problem

This finishes moving Portal's rules into the core for the existing macOS
application. Linux remains a future implementation: do not build a GTK toolbar,
run Linux experiments or CI, or add Windows support. Follow ADR 0003
(`docs/adr/0003-platform-interface-primitives.md`). This is the last task that
removes Lisp-shaped operations from `portal.h`.

`native/Toolbar.swift` contains both `ToolbarModel` and the AppKit drawing and
controls. The model reaches into native focus, and `ToolbarView.refresh`
serializes its state to JSON to detect changes. Web zoom and find state live in
`native/WebToolbar.swift`, and terminal text-size policy lives in
`native/Terminal.swift`.

## Outcome and scope

The core owns each view's toolbar state and actions. The platform draws a
toolbar from the state it is given, and reports clicks and edits. Toolbar
appearance and interaction stay the same.

- Move the toolbar kind and configuration, availability, zoom and font-size
  values and limits, TOC and find state, and action transitions into the core.
  Input ownership stays with input, and browser and terminal state stay with
  their modules; derive the toolbar's display state instead of copying them.
- Route button clicks and Lisp actions through the same core model. Preserve
  navigation controls, zoom steps, terminal size limits, Markdown Open in Emacs,
  and views that have no toolbar on purpose.
- Preserve the find query and direction, serialized requests, a newer query
  replacing an older one, and invalidation on navigation. Preserve existing
  match reporting; a new search algorithm is out of scope.
- Keep AppKit buttons and text fields, layout, drawing, SF Symbols,
  accessibility, tracking areas, appearance changes and responder changes in
  Swift. Pass theme colors as plain values until the platform makes `NSColor`s.
- Keep the external `portal--toolbar-action` JSON result and Lisp behavior
  compatible. Replace JSON as an internal refresh fingerprint with a snapshot
  or revision.
- Preserve the 28-pixel strip, live visibility and theme settings, state kept
  across hide, reload and frame moves, and clicks that keep focus. Closing find
  must not steal focus after the user has moved to Emacs or another view.
- Remove the displaced Swift policy and move meaningful model tests to the C
  interface. Keep native tests for layout, focus, rendering and accessibility.
  Update the README architecture and toolbar documentation with the final
  ownership.

## Platform interface

- **Removes** the Lisp-shaped `portal_toolbar`, `portal_toolbar_theme` and
  `portal_toolbar_action`.
- **Adds, implemented by the platform:** draw one view's toolbar from a state
  snapshot, including none. Global visibility and colors are part of that
  state, not separate operations.
- **Adds, implemented by the core, called by the platform:** a toolbar button
  was clicked, and the find text changed.
- Zoom, find and font size need platform primitives on the web and terminal
  handles: set zoom, find with an asynchronous result, and set font size. The
  terminal task adds the last. Add each capability once and reuse what earlier
  tasks added, such as a primitive that runs a shared helper script.
- **Finishes the interface.** Afterwards `portal.h` holds only primitives and
  calls into the core. List them in the README.

## Starting points

Read ADR 0003, `native/Toolbar.swift`, `native/WebToolbar.swift`,
`native/Terminal.swift`, `portal-toolbar.el` and `docs/toolbar-design.md`.
Distinguish historical design ideas from implemented behavior. Use
`test/native-toolbar.swift`, `test/portal-toolbar-tests.el`,
`test/portal-toolbar-gui-tests.el`, and the relevant web and input tests. Follow
the prerequisites' C files and shared JavaScript resources.

## Decisions to settle during implementation

Choose between a snapshot and revision-based refresh, and define who owns an
asynchronous find result. Document which module owns each state value and how
the platform is asked to move focus. Avoid a general GUI toolkit, a
cross-platform widget schema, or moving the toolbar into a web view just to
remove Swift.

## Acceptance criteria and verification

- [ ] `portal.h` contains no Lisp-shaped operation. Every platform operation
  is a primitive by ADR 0003's rules, and the README lists them.
- [ ] C tests with fake web, terminal and input platforms exercise the real
  core. They cover action availability, zoom and font limits, kept state, find
  sequencing, invalidation on navigation, hide and close, and stale results.
- [ ] Button clicks and Lisp commands see the same state, and nothing
  serializes JSON just to decide whether controls need redrawing.
- [ ] Native toolbar and focus checks and the graphical toolbar tests verify real
  layout, native text editing, focus preservation, live visibility and theme
  changes, and every toolbar variant, including toolbar-free Excalidraw and
  quick terminals.
- [ ] `./build.sh`, `ctest --test-dir build --output-on-failure`, and the C core
  tests pass. The combined graphical suite in the README passes across both view
  kinds.
- [ ] The C core tests run the production core with an ordinary C toolchain,
  without Swift, AppKit or Ghostty. That is this refactor's evidence of
  portability; a working Linux build is not a completion gate.
- [ ] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Run Portal input handoff policy in the C core](portable-input-policy.md)
  supplies input ownership and the focus primitives.
- [Move web policy and the bridge into the C core](portable-web-bridge.md)
  supplies web primitives, calls into the core, and shared helper scripts.
- [Reduce terminal views to platform primitives](portable-terminal-adapter.md)
  supplies the font-size primitive and terminal state.
