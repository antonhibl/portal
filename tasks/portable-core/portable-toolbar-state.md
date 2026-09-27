---
id: portable-toolbar-state
status: done
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

- [x] `portal.h` contains no Lisp-shaped operation. Every platform operation
  is a primitive by ADR 0003's rules, and the README lists them.
- [x] C tests with fake web, terminal and input platforms exercise the real
  core. They cover action availability, zoom and font limits, kept state, find
  sequencing, invalidation on navigation, hide and close, and stale results.
- [x] Button clicks and Lisp commands see the same state, and nothing
  serializes JSON just to decide whether controls need redrawing.
- [x] Native toolbar and focus checks and the graphical toolbar tests verify real
  layout, native text editing, focus preservation, live visibility and theme
  changes, and every toolbar variant, including toolbar-free Excalidraw and
  quick terminals.
- [x] `./build.sh`, `ctest --test-dir build --output-on-failure`, and the C core
  tests pass. The combined graphical suite in the README passes across both view
  kinds.
- [x] The C core tests run the production core with an ordinary C toolchain,
  without Swift, AppKit or Ghostty. That is this refactor's evidence of
  portability; a working Linux build is not a completion gate.
- [x] Record verification and mark this task done using the author-tasks skill;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Run Portal input handoff policy in the C core](portable-input-policy.md)
  supplies input ownership and the focus primitives.
- [Move web policy and the bridge into the C core](portable-web-bridge.md)
  supplies web primitives, calls into the core, and shared helper scripts.
- [Reduce terminal views to platform primitives](portable-terminal-adapter.md)
  supplies the font-size primitive and terminal state.

## Outcome

- `native/Core/toolbar.c` owns every view's toolbar. Its layout is fixed at
  open: the core now checks a web view's `:toolbar` ("navigation",
  "contents", "markdown", "none", or nil for none) and a terminal's `:quick`.
  It keeps the zoom (the twelve steps from 50 to 300%) or text size (1 to
  255 pt, starting at `PORTAL_TERMINAL_POINTS`, 14), the TOC's state and the
  page's heading count, the find field's text and matches, the queue of
  searches, and whether toolbars show and their colors. It reads who has the
  keyboard from `input.c` and back and forward availability from `web.c`,
  which now keeps what the platform reports; neither is copied.
- A click, the find field's text, `portal--toolbar-action` and the keyboard
  shortcuts run the same `act` on the same state. `portal--toolbar-action`
  keeps its JSON result and errors. The terminal's Command-Plus, Minus and 0
  and the web view's Command-F moved from Swift into the core's key decision
  (`portal_input_key` asks `portal_toolbar_shortcut` about keys the app
  would get), with the same rules: text size with or without a toolbar and
  in passthrough; find only with a visible toolbar and the view owning the
  keyboard.
- `portal.h` no longer declares `portal_toolbar`, `portal_toolbar_theme`,
  `portal_toolbar_action`, `portal_input_owner` (now core-internal, in
  `input.h`) or `portal_web_edit` (now a click on the EDIT button). It adds
  the primitives `portal_toolbar_draw`, `portal_toolbar_focus`,
  `portal_web_zoom`, `portal_web_find` and `portal_web_call`, reusing
  `portal_web_go` and `portal_terminal_set_font_size`, and the calls
  `portal_toolbar_clicked`, `portal_toolbar_typed`, `portal_web_loaded`,
  `portal_web_history`, `portal_web_found`, `portal_web_returned` and
  `portal_web_headings`. It now holds only 25 primitives and the calls into
  the core; the README lists them.
- `emacs.c` reads the theme's JSON with Emacs's `json-parse-string`, as it
  reads terminal bindings, into a `portal_colors` of plain sRGB values; a
  malformed color leaves the platform's default, as before.
- Swift keeps drawing: `Toolbar.swift` builds the strip from a `ToolbarState`
  copied from the snapshot, with the same layout, SF Symbols, tooltips,
  accessibility, tracking areas and appearance handling, and turns colors into
  `NSColor`s. `ToolbarModel`, `NativeToolbar`, the JSON refresh fingerprint,
  `WebToolbar`'s zoom, TOC and find logic, the terminal's text-size policy
  and `NativeInput.ownership` are gone. `WebToolbar.swift` is WebKit glue for
  the contents script, script calls and find. Every view now sits in a
  `NativeContainer`, which shows a strip only when the core draws one, and
  `NativeView` keeps the last snapshot to show wherever the view moves.
- Decisions:
  - **Snapshot, not revision.** The core builds a `portal_toolbar` after
    anything that may change a toolbar and draws it only when it differs from
    the last one drawn (a refused draw is retried next time). No module
    counts changes, and the platform compares nothing.
  - **Async results.** The core owns them. Each find and script call carries
    a token that is never reused; one search runs at a time, as a count by
    the contents script then a native find; newer text replaces waiting
    searches; `portal_web_loaded` starts a new generation that drops an older
    search's result and searches again. Results for another token, or a closed
    view, reach nothing. The heading count comes from the contents script's
    reports and the TOC call each load makes; a commit resets it to none.
  - **Focus.** Opening find calls `portal_toolbar_focus`, which gives the
    field, part of the view, the keyboard and reports it. Closing find calls
    `portal_view_focus` only while the input core says the view has the
    keyboard. The dot calls `portal_view_focus`, or `portal_input_escape`
    like Command-Escape.
  - **Script calls.** One primitive, `portal_web_call`, runs a function of a
    shared script with a JSON argument that crosses as data, and returns an
    integer; it serves both the TOC and the find count.
  - **Parity scope.** Closing a closed find field now does nothing, where it
    ran an empty search and could refocus the page. Headings reset at commit
    rather than at a provisional navigation's start. An absent `:toolbar`
    means none rather than an error; Lisp always passes one.

## Verification

Run on macOS 27.0 with Swift 6.4 and Emacs 31.1 on 2026-09-28:

- `./build.sh` built the module and app host with warnings as errors.
  `ctest --test-dir build --output-on-failure` passed all 19 tests, including
  the new `toolbar-core`. The core alone, `cmake -S native/Core -B
  build/core` with only a C compiler and Emacs, passed its 7 tests.
- Twelve mutations of `toolbar.c` each failed `portal-toolbar-tests`: stale
  counts or finds accepted, older queries kept, searches run in parallel, no
  search after a load, no backward wrap, closing find stealing focus, find in
  passthrough, ungated clicks, no font maximum, increase always enabled, and
  drawing every time.
- `build/check-toolbar` and `build/check-focus` passed with real AppKit and
  WebKit: layout, focus-keeping buttons, the dot, back and forward, zoom
  limits, the TOC across hiding and reload, typing into the real field,
  Return, Shift-Return and Escape, Command-F and passthrough, closing find
  after the keyboard went back to Emacs, live visibility and colors, a view
  without a toolbar filling its pane, and Open in Emacs sending `prefix`,
  `escape` and `bridge` in order. `test_native_checks.py` passed.
- The combined graphical suite (README, Verification) passed 56 of 56, with
  one skip, on two consecutive runs with Emacs in front, including new tests
  that type into the real find field and step matches with real keys, check
  that closing find leaves Emacs the keyboard, apply a theme live, and show
  that Excalidraw and a quick terminal have no strip. A first run failed three
  key- and click-injection tests (a stray `p` reached Emacs, a prefix did not
  wake Emacs, a click was not delivered) outside the toolbar code; a `main`
  build in the same session passed its 53 of 53, and the two later runs of
  this branch were clean.
