# Native minibuffer launcher: content-fitted sizing research

## Scope and source pins

Research only: source inspection, no implementation, tests, GUI actions, or interaction with the running Emacs. No commits or pushes. Read `AGENTS.md`, `CONTEXT.md`, and `docs/launcher-native-panel.md`. The implementation handoff is [Fit minibuffer launcher panels to their displayed content](../tasks/launcher-content-sizing.md).

Portal HEAD at inspection: **`64b4a1fbc29394cc34d4d67e3e01ca76bc9818a0`**. Repository-relative references below describe that checkout. Existing unrelated untracked files were left alone.

Primary external sources:

- GNU Emacs **31.1**, revision **`a360712c9d272d950d8d8255ef74570f7e90b7d9`**, the exact build accepted by `portal-launcher--check-support`. Retrieved source files at that revision, not moving `master`:
  - [lisp/window.el](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/lisp/window.el): `window--resize-mini-frame`, `fit-mini-frame-to-buffer`, `fit-frame-to-buffer-1`.
  - [src/xdisp.c](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/xdisp.c): `resize_mini_window`, `Fwindow_text_pixel_size`, `window_text_pixel_size`, `move_it_to`, overlay-string iteration.
  - [src/nsterm.m](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.m): `ns_set_window_size`, `ns_set_window_size_and_position`, `EmacsView`'s `resizeWithOldSuperviewSize:`.
  - [doc/lispref/minibuf.texi](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/doc/lispref/minibuf.texi): Minibuffer Windows, especially `resize-mini-frames`.
- Installed Vertico: `/Users/xiaoxing/.config/emacs/elpa/vertico-20260830.123/vertico.el`, package version **20260830.123**, header revision **`cd2eb6daff6a`**; [upstream source at that revision](https://github.com/minad/vertico/blob/cd2eb6daff6a/vertico.el). Local file SHA-256: `e91e8be9c35ba3ac398a3a924dd8fd542a4b2afbbaa092feeda72b0ef80493ad`.

Historical graphical results in `docs/launcher-native-panel.md` are existing project evidence, **not GUI verification performed for this research**.

## Intended policy (agreed, not implemented)

| `portal-launcher-size` | Minibuffer kind | Buffer kind |
| --- | --- | --- |
| `nil` (new default) | Width 720; automatic height | Fixed 720×420 |
| `'(720 auto)` | Width 720; automatic height | Task proposes rejecting explicit auto; settle before implementation |
| `'(720 240)` | Fixed 720×240, existing behavior | Fixed 720×240, existing behavior |

No separate fit boolean. Automatic height follows the rendered prompt and currently rendered completion rows, including padding, not the total number of completion matches. Width stays fixed subject to usable-monitor bounds. Preserve the presentation's top edge; grow/shrink its bottom edge. Retain the native requested-height floor of 100 points and clamp to the usable monitor area. Core must not acquire an application-launcher or Vertico dependency.

## Verified facts from sources

### 1. Emacs has a purpose-built callback, not merely a post-command hook

`resize-mini-frames` accepts a function of one argument, the minibuffer-only frame. The manual explicitly guarantees that its minibuffer window's buffer is the buffer to be displayed next. A nil value disables automatic resizing; another non-nil value invokes `fit-mini-frame-to-buffer`.

The concrete path is `src/xdisp.c:resize_mini_window` → `lisp/window.el:window--resize-mini-frame` → the configured function. The minibuffer-only branch is separate from normal minibuffer-window resizing. A non-nil `resize-mini-frames` still enables this branch when `resize-mini-windows` is nil. Normal-window `grow-only` handling and `max-mini-window-height` are in the other branch; they do not define the height policy of this callback.

`resize_mini_window` declines resizing when redisplay is inhibited and uses `dsafe_call1` for the Lisp callback. This is a redisplay-sensitive integration point: it is not permission to recursively call `redisplay`, run a command, or re-present the panel inside the callback.

`fit-mini-frame-to-buffer` is **not just a measurement helper**. It calls `fit-frame-to-buffer-1`, preserving leading/trailing empty lines. That helper measures, computes width and height, applies margins/position adjustments, potentially rounds to character cells, and finally calls `modify-frame-parameters` with left, top, width, and height. Calling it directly would delegate Portal's geometry policy to Emacs. It is not the proposed native-panel resize implementation.

### 2. `window-text-pixel-size` is the relevant generic measurement primitive

`src/xdisp.c:Fwindow_text_pixel_size` documents:

- Return the maximum text-line width and total text height of the accessible buffer portion.
- Nil FROM/TO retain leading/trailing empty lines; `t` strips them via position selection.
- **Nil X-LIMIT uses the current window body's pixel width**, explicitly recommended for measuring height while keeping width unchanged. `t` instead permits maximum width and is unsuitable for the intended fixed-width wrapping policy.
- Nil Y-LIMIT measures all accessible text, rather than limiting measurement to the current window height. A finite budget can cap work for unusually large content.
- MODE-LINES can include existing mode/header/tab lines. It does not promise to include frame internal borders.
- IGNORE-LINE-AT-END excludes the screen line containing TO; it is not a general-purpose “remove a completion package's final blank row” switch.

The implementation uses the display iterator, not `count-lines`: display properties, faces, wrapping/truncation and overlay strings are relevant. In particular, `move_it_to`'s `MOVE_LINE_TRUNCATED` handling explicitly continues at end-of-buffer until display/overlay strings there are exhausted. Overlay iteration includes both `before-string` and `after-string`.

There is nevertheless **no new empirical guarantee here that every end-of-buffer overlay shape yields exactly the desired height**. `resize_mini_window` itself contains a FIXME about a final newline supplied by an overlay/display string losing its final empty line; its oversized ordinary-minibuffer path also has special handling for after-strings at ZV (icomplete/ido-vertical). Those are in the normal-window path, not a ready-made fix for minibuffer-only frames. They identify boundary cases to test, not proof that Portal must copy that code.

Consequently: use actual rendered-window measurement as the first candidate, including generic after-string fixtures. Do not reduce sizing to buffer line counts, assume all inline completion uses after-strings, or invent a Vertico row-count dependency.

### 3. Installed Vertico uses an end-of-buffer **before-string**

In the pinned installed `vertico.el`:

- `vertico--exhibit` updates candidates, prompt selection and count, then calls `vertico--display-candidates` with `vertico--arrange-candidates`.
- `vertico--arrange-candidates` selects the visible candidate slice, adds group titles, drops excess lines against `vertico-count` (default 10), and formats the rows. Count every displayed row's rendered height, not all matching candidates.
- `vertico--display-candidates` moves a zero-length overlay to `(point-max)` and assigns its **`before-string`**: a cursor-bearing space, a newline if there are rows, and the formatted lines. Candidate formatting ends rows with newlines. Zero candidates still leave the cursor-bearing space, without the candidates' separating newline.
- `vertico--resize-window` always sets buffer-local `truncate-lines` according to point versus roughly 80% of the available width, `resize-mini-windows` to `grow-only`, and `max-mini-window-height` to 1.0. It then **skips its own window-resize logic when the active minibuffer is the frame root window**.
- Outside that root-window case, `vertico-resize=nil` reserves at least `vertico-count`; positive deltas grow, while negative deltas shrink only for `vertico-resize=t`. Its default is initialized from `resize-mini-windows`, normally `grow-only`.

**Implication:** for Portal's minibuffer-only frame, neither `vertico-resize='grow-only` nor its nil fixed-capacity option forces a previous large native-panel height to remain. Vertico skips that part of its resize method; the proposed `resize-mini-frames` callback can shrink from the newly rendered overlay. There is no source-based reason to bind `vertico-resize=t` in core. Its truncation setting still affects measurement, and extensions replacing these generics need separate validation.

Vertico installs `vertico--exhibit` in a buffer-local `post-command-hook`. A Portal hook that measured earlier could see stale rows. The Emacs pre-display callback is the better generic seam than advising Vertico or assuming post-command-hook ordering; actual update ordering still needs graphical testing, including asynchronous completion.

### 4. Existing Portal presentation is not a safe repeated resize operation

`portal-launcher.el:portal-launcher-present` currently binds `resize-mini-frames` to nil for the session. Both kinds currently use numeric `portal-launcher-size`, default 720×420; `portal-launcher--placement` validates two integers. `portal-launcher--show` selects the frame, invokes native show, enables Emacs visibility and redisplays. `portal-launcher-resize` simply changes the numeric setting and **shows a buffer launcher again**; it is not an automatic minibuffer layout API.

The native call chain is:

`native/Core/emacs.c:Flauncher_show` → `native/Core/include/portal.h:portal_launcher_show` → `native/Backend.swift:portalLauncherShow` → `native/Launcher.swift:NativeLauncher.place`.

`NativeLauncher.place(..., present: true)` increments the native session, resets `lostFocus`, establishes focus watchers, calls `makeKeyAndOrderFront`, and makes the editor first responder. Repeating show can therefore invalidate blur IDs and interfere with focus semantics. `portal-launcher--queue-blur` and `portal-launcher--blur` depend on matching the presentation's native ID.

There is already an internal layout-only precedent: the screen-change observer calls `place(..., present: false)`, bypassing those presentation actions. However, **that method still recomputes centered placement and resolves the pointer monitor again**. Simply exposing it unchanged does not preserve a presentation's top edge or monitor when content changes.

`NativeLauncher.rectangle` floors coordinates and clamps size and position to `NSScreen.visibleFrame`. `place` and the C binding require width ≥200 and requested height ≥100. The final rectangle can be smaller if the usable screen itself is smaller; the floor is a request constraint, not a promise to overflow a tiny usable area.

### 5. Native ownership and frame safety are real constraints

`native/Launcher.swift:NativeLauncher.attach` moves the Emacs content into a borderless, nonactivating `LauncherPanel`, keeps the original donor window's delegate, and attaches the Emacs delegate to the panel. The panel implements a bounded compatibility surface, not the full `EmacsWindow` interface. `portal-launcher.el:portal-launcher--guard-parameters` protects fixed role parameters and even drops unchanged ones; `portal-launcher--check-guard` checks native trampolines.

The pinned NS source's `ns_set_window_size` already has top-left-preserving arithmetic, but its existence does **not** establish blanket safety for Lisp frame setters on the transplanted panel. Stock fitting also changes position/width and applies its own sizing policies. Keep the existing build restriction and guards, and use a deliberately bounded native layout operation rather than blindly calling `set-frame-size`, `set-frame-height`, or stock fitting.

There is a source-supported synchronization path for native layout: `EmacsView.resizeWithOldSuperviewSize:` computes the new superview bounds, calls `change_frame_size`, marks the frame garbaged, and sends an app-defined wakeup. The existing Portal native placement already uses `panel.setFrame`. Whether repeated calls **during the resize callback** settle synchronously enough for correct measurement/redisplay is unverified here.

## Proposed integration (not implemented or GUI-verified)

1. **Resolve sizing per presentation kind.** Normalize nil/numeric/auto before native presentation, maintaining numeric-size behavior. Keep the unresolved buffer `auto` policy explicit in the task. Audit `portal-launcher-resize`'s interactive defaults, which currently take `car`/`cadr` of the size option.
2. **Dynamically bind a Portal `resize-mini-frames` callback only for automatic minibuffer presentations.** Keep nil for fixed presentations. Scope the callback to the owned live minibuffer-only frame and active presentation; never resize another frame or delegate the Portal frame to the user's arbitrary fitter. Restore surrounding settings naturally on unwind. Handle nested prompts using the buffer currently installed in the passed frame's minibuffer window.
3. **Measure generically at the effective fixed width.** Start with `window-text-pixel-size` on the explicit minibuffer window, nil FROM/TO/X-LIMIT, and appropriate Y budget. Add the frame/window non-text vertical extent exactly once, including internal borders (default 16 points per edge in `portal-launcher-frame-parameters`). A candidate formula is measured body height plus frame-height minus window-body-height, provided the same mode/header/tab-line convention is used on both sides. Validate this rather than hard-coding a font-height × candidate-count estimate. Establish the actual width before measuring wrapped text.
4. **Add a native layout-only resize operation through the existing C/platform bridge.** Validate attached/presenting ownership and preferably the expected native session ID; use the stored presentation width/screen/anchor, and do nothing when the effective rectangle is unchanged. Never call prepare/show, select frames, change native session, reset blur state, reinstall observers, or request focus/first responder. Ignore/reject late calls after hide, detach or a replacement session.
5. **Anchor explicitly.** Store the actual top edge and X coordinate established for this presentation. With AppKit's bottom-left origin, set `newY = anchoredTop - newHeight`. Bound growth by the space from that top to the usable area's bottom, not merely the full monitor height, so bottom clamping does not silently move the top. Choose/document initial auto placement: anchoring the initial floor-sized panel versus measuring before first visible placement yields different top positions. Monitor removal/usable-area changes require an explicit exceptional reanchor policy; content updates must not follow the mouse to a different screen.
6. **Prevent resize feedback.** Skip identical rounded/clamped rectangles, guard reentry, and do not force redisplay inside the callback. Determine in a disposable NS Emacs whether direct native layout is safe there; defer/coalesce only if necessary, with stale-session checks and cleanup. A deferred design must also avoid keeping an obsolete candidate height or leaving timers after cancellation.

## Test implications and unresolved measurement questions

Existing fixtures are useful starting points, not proof of automatic sizing:

- `test/portal-launcher-tests.el:portal-launcher-presentation-settings-are-scoped` currently asserts nil `resize-mini-frames` inside minibuffer sessions. Split automatic/fixed expectations while retaining restoration checks. `portal-launcher-rejects-invalid-input-before-enabling` currently rejects nil size. The mocked panel/session fixtures do not exercise real NS redisplay.
- `test/portal-launcher-gui-tests.el:portal-launcher-gui--minibuffer-layout` records native and Emacs dimensions, text clipping and padding. `portal-launcher-gui-minibuffer-panel-vertico` tests explicit fixed sizes and should remain a regression test. It already deliberately waits for Vertico to redraw before capturing a layout.
- `test/native-launcher.swift` covers geometry, rollback, focus records, screen notifications and lifecycle, but uses fake Emacs classes. Extend layout/session invariants there; only a supported real NS Emacs can validate view/frame synchronization and safety.

Required disposable supported-NS-Emacs experiments during implementation:

- Measure grow **and shrink** across zero/one/many visible rows, including initial prompt, no matches, group titles, long prompt/input, wrapping, font changes, line spacing and styled/variable-height annotations. Compare native points, Emacs pixel dimensions and visible last rows; do not multiply by Retina scale based on naming alone.
- Test an arbitrary end-of-buffer **after-string** separately from Vertico's before-string, with/without trailing newline, empty buffer, truncation and wrapping. Determine exactly what the measurement includes and whether a trailing empty display row is required for the cursor. Do not automatically subtract one line or set IGNORE-LINE-AT-END without evidence.
- Confirm the callback observes fresh overlays after typing and asynchronous updates, and that it can measure beyond the current short panel without self-clamping. Check initial-show flash, stale frame metrics, repeated redisplay loops and fractional/rounded height oscillation.
- Assert constant top edge, width, native session ID, key/first responder state and focus observers over many content resizes. Check that genuine queued blur still dismisses after a resize, and stale callbacks cannot revive hidden panels. Exercise cancel, error, nested minibuffers, deletion/disable, and kind replacement.
- Test near-bottom offsets, negative-origin monitors, screen changes, tiny usable areas, and capped content where not every row can fit. Specify overflow/scroll behavior without taking over completion navigation. Preserve fixed numeric placement and buffer defaults.
- Run with Vertico absent, stock completion, and the installed Vertico with `vertico-resize` nil/t/grow-only. Core should load no completion package. Extensions that render elsewhere are not automatically equivalent to inline Vertico.

**Bottom line:** `resize-mini-frames` plus generic rendered-text measurement is the strongest source-supported integration seam. The missing piece is a bounded native, top-anchored layout API, not repeated presentation or a Vertico-specific fitting hook. End-of-buffer overlay measurement and redisplay-time native resize behavior remain implementation-time validation questions, not established GUI results.
