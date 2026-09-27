---
id: portable-view-lifecycle
status: done
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

- [x] `portal.h` declares none of the removed operations. Its lifecycle part is
  the create, destroy, attach, detach and describe primitives.
- [x] Both web and terminal views use the C registry in production. Target IDs
  never alias new views, including after close or failed creation.
- [x] C tests with the fake platform cover the real core's lifecycle: success
  and failure, invalid targets, wrong-kind calls, invalid rectangles, repeated
  placement and hide, close, and a platform call arriving after close.
- [x] Tests prove that hide keeps a session and its size, and that placing it
  elsewhere keeps the same platform handle. The tests do not duplicate native
  attachment policy.
- [x] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  graphical web, terminal and combined integration suites keep splitting,
  hiding, frame movement and deletion, hidden-terminal output, and cleanup
  working. Run the native focus and toolbar checks after adapting their entry
  points.
- [x] Record verification and mark this task done; follow `AGENTS.md` for the
  implementation worktree and PR.

## Blocked by

- [Move Emacs module bindings into C](portable-module-bindings.md) supplies the
  C bindings, the production C build and the fake-platform test module.
- [Own ordered native notifications in the C core](portable-notification-channel.md)
  sets the convention for platform calls into the core, which this task follows
  if it adds any. Doing it first keeps one definition of that convention.

## Outcome

- `native/Core/views.c` is the one registry. It gives out `kind:id` targets
  with global IDs that are never reused, even after a failed open. It holds each
  platform view from create to destroy, checks the kind of every view that a
  web, terminal, input or toolbar operation names, and keeps whether a view is
  attached and at which edges. `portal--inspect` merges the platform's
  description with the core's `:id`, `:kind`, `:visible` and `:edges`.
  `emacs.c` calls it through the core-private `native/Core/views.h`.
- `portal.h` no longer declares `portal_open`, `portal_place`, `portal_hide`,
  `portal_close` or `portal_inspect`. Its lifecycle part is five primitives:
  `portal_view_create`, `_destroy`, `_attach`, `_detach` and `_describe`,
  on an opaque `portal_view`. The web, terminal, input and toolbar operations
  take that handle, and `portal_terminal_theme` takes the open terminals' handles
  from the core, so Swift no longer looks up target strings or lists views.
- Swift: `Views` is gone. `native/Views.swift` holds `NativeView`, which
  attaches, parks and closes either kind, once, and owns the parking window.
  `WebSession` and `TerminalSession` keep only their own session and react to
  `opened`, `attached` and `detaching`; neither tracks its host, rectangle or
  edges. `Backend.swift` hands the core a retained `NativeView` as the handle
  and releases it on destroy.
- No new call into the core. `portal_notify` now checks that the record's
  target names an open view, so a late record from a closed view never reaches
  Emacs; `channel.c`'s sender became `portal_channel_send`.
- Decisions:
  - **Frames.** Each attach names the frame by the temporary title of ADR 0002.
    The core never identifies frames. The platform finds the window again on
    each call, and on macOS finds a view's current window from the view itself.
  - **Rectangles.** `portal_rect` is `x, y, width, height` in Emacs's frame
    pixels from the top left of the frame's content area, as
    `window-inside-pixel-edges` reports them. The core checks for positive
    dimensions and 32-bit values. On macOS Emacs's pixels are AppKit points, so
    the platform only flips the y axis; any scale conversion is the platform's.
  - **Failure.** A primitive either does all it says or changes nothing. A failed
    open registers nothing, and the platform has already released what it made.
    A failed attach, such as for a deleted frame, leaves the view where it was,
    attached or not, and still owned by the core, for Lisp to place again or
    close: `NativeView` checks the frame before moving anything. Detach and
    destroy fail only when the platform cannot run at all, as on a Lisp
    thread, and then leave the view attached or open.
  - **Close.** The core unlinks the target before destroying the platform
    view, so the platform destroys it exactly once and nothing it does meanwhile
    reaches the view. Hide calls detach only for an attached view.
  - **Error text.** A stale target passed to `portal--toolbar-action` now says
    "No Portal view TARGET", like every other operation.
- Tests: `test/portal-views-tests.c` drives the registry with the fake
  platform, which counts each primitive call and any call naming a destroyed
  or wrong-kind view, and can fail creation (`:fail`), attachment (a frame
  titled `deleted…`) or every primitive (as on the wrong thread). The module
  tests read the fake's global settings through a view's `:fake`. The
  standalone checks now build `Backend.swift` and link `views.c`, driving views
  through the core with `test/native-views.swift`.
- README describes the registry, the primitives, rectangle units and failure
  ownership, and the new check and test commands.

## Verification

Run on macOS 27.0 with Swift 6.4, Emacs 31.1, and CMake 4.4.3 on 2026-09-27:

- `ctest --test-dir build/core --output-on-failure` passed `channel`, `views`
  and `module`. Each of these single changes to `views.c` makes
  `portal-views-tests` fail: reusing a failed open's ID, detaching a view that
  is not attached, a stale tail after close, recording a placement before the
  attach succeeds, sending records for unknown targets, ignoring the kind,
  dropping the 32-bit range check, not restoring a view whose destroy was
  refused, and marking a view detached when its detach was refused. The fake
  counted no call naming a destroyed or wrong-kind view. A description with
  JSON whitespace, such as `{ }` or a pretty-printed object, gave malformed
  JSON before the core learned to skip it; the test now covers both.
- `./build.sh` built without warnings. `nm` shows the five `portal_view_*`
  primitives defined in `portal.dylib`, none of the removed operations, and no
  undefined `portal_*` symbols. `ctest --test-dir build --output-on-failure`
  passed 15 of 15, with `main`'s broken task-row test pattern fixed by
  [PR #34](https://github.com/xiaoxinghu/portal/pull/34), merged into this
  branch. Before that fix, `ui-host` failed on `main` too.
- `build/check-focus` and `build/check-toolbar`, now built with `Backend.swift`
  and the core's registry, passed, including the full-pipe check on an open
  view and a closed view's record being dropped.
- The README's combined graphical suite, run through the production module
  with `--module-assertions`, passed 52 of 52. After the JSON whitespace fix
  it passed 51 of 52: `portal-excalidraw-gui-revert-reloads-the-saved-drawing`
  timed out waiting for the drawing, and all seven Excalidraw GUI tests then
  passed on their own. An earlier run failed four
  injection tests one after another: a stray `down-mouse-1` reached the
  Excalidraw save test, and its command then arrived late in the next test. A
  rerun of the web, terminal, integration, Excalidraw and input suites failed
  only the Excalidraw save test. That suite alone passed 26 of 26, as it did
  with the `main` module. The suite covers splitting, hiding, frame movement and
  deletion, hidden-terminal output, and cleanup.
- On 2026-09-28, the combined graphical suite passed 52 of 52 on `main` at
  526ae93, after the input and terminal tasks merged, including the web,
  terminal, integration and Excalidraw suites.
