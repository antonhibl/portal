# Native minibuffer launcher: content-fitted sizing research

## Scope and source pins

Source research only: no implementation, tests, GUI actions, running-Emacs interaction, commits or pushes. Read `AGENTS.md`, `CONTEXT.md`, and `docs/launcher-native-panel.md`. Handoff: [Fit minibuffer launcher panels to their displayed content](../tasks/launcher-content-sizing.md).

Portal HEAD at inspection: **`64b4a1fbc29394cc34d4d67e3e01ca76bc9818a0`**. Repository-relative references describe that checkout. Unrelated untracked files were untouched.

Primary external sources:

- GNU Emacs **31.1**, revision **`a360712c9d272d950d8d8255ef74570f7e90b7d9`**, the build accepted by `portal-launcher--check-support`. Sources retrieved at that revision, not moving `master`:
  - [lisp/window.el](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/lisp/window.el): `window--resize-mini-frame`, `fit-mini-frame-to-buffer`, `fit-frame-to-buffer-1`.
  - [src/xdisp.c](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/xdisp.c): `resize_mini_window`, `Fwindow_text_pixel_size`, `window_text_pixel_size`, `move_it_to`, overlay-string iteration.
  - [src/nsterm.m](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.m): `ns_set_window_size`, `ns_set_window_size_and_position`, `EmacsView`'s `resizeWithOldSuperviewSize:`.
  - [doc/lispref/minibuf.texi](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/doc/lispref/minibuf.texi): Minibuffer Windows, especially `resize-mini-frames`.
- Installed Vertico: `/Users/xiaoxing/.config/emacs/elpa/vertico-20260830.123/vertico.el`, package version **20260830.123**, header revision **`cd2eb6daff6a`**; [upstream source at that revision](https://github.com/minad/vertico/blob/cd2eb6daff6a/vertico.el). Local file SHA-256: `e91e8be9c35ba3ac398a3a924dd8fd542a4b2afbbaa092feeda72b0ef80493ad`.

Historical graphical results in `docs/launcher-native-panel.md` are prior project evidence, **not this research's GUI verification**.

## Intended policy (agreed, not implemented)

| `portal-launcher-size` | Minibuffer kind | Buffer kind |
| --- | --- | --- |
| `nil` (new default) | Width 720; automatic height | Fixed 720×420 |
| `'(720 auto)` | Width 720; automatic height | Task proposes rejecting explicit auto; settle before implementation |
| `'(720 240)` | Fixed 720×240, existing behavior | Fixed 720×240, existing behavior |

No separate fit boolean. Automatic height follows the rendered prompt, displayed completion rows and padding—not total matches. Keep width fixed within usable-monitor bounds. Preserve the top edge; grow/shrink the bottom. Retain the native requested-height floor of 100 points and clamp to the usable monitor area. Core must not depend on an application launcher or Vertico.

## Verified facts from sources

### 1. Emacs has a purpose-built callback, not merely a post-command hook

`resize-mini-frames` accepts a function taking only the minibuffer-only frame. The manual guarantees its minibuffer window holds the buffer to display next. Nil disables automatic resizing; other non-nil values invoke `fit-mini-frame-to-buffer`.

The path is `src/xdisp.c:resize_mini_window` → `lisp/window.el:window--resize-mini-frame` → configured function. Minibuffer-only and normal minibuffer-window resizing use separate branches. Non-nil `resize-mini-frames` enables the former even with nil `resize-mini-windows`. Normal-window `grow-only` handling and `max-mini-window-height` belong to the other branch, not this callback's height policy.

`resize_mini_window` skips resizing when redisplay is inhibited and calls Lisp through `dsafe_call1`. This redisplay-sensitive callback must not recursively call `redisplay`, run commands or re-present the panel.

`fit-mini-frame-to-buffer` is **not merely measurement**: it calls `fit-frame-to-buffer-1`, preserving leading/trailing empty lines. That helper measures, computes dimensions, adjusts margins/position, may round to character cells, then calls `modify-frame-parameters` with left, top, width and height. Direct use would delegate Portal's geometry policy to Emacs, not implement the proposed native resize.

### 2. `window-text-pixel-size` is the relevant generic measurement primitive

`src/xdisp.c:Fwindow_text_pixel_size` documents:

- Returns maximum text-line width and total text height of the accessible buffer portion.
- Nil FROM/TO retain leading/trailing empty lines; `t` strips them via position selection.
- **Nil X-LIMIT uses the current window body's pixel width**, explicitly recommended for fixed-width height measurement. `t` permits maximum width, unsuitable for fixed-width wrapping.
- Nil Y-LIMIT measures all accessible text, not just current window height. A finite budget can cap work on unusually large content.
- MODE-LINES can include existing mode/header/tab lines, without guaranteeing inclusion of frame internal borders.
- IGNORE-LINE-AT-END excludes the screen line containing TO; it is not a generic “remove a completion package's final blank row” switch.

Measurement uses the display iterator, not `count-lines`: display properties, faces, wrapping/truncation and overlay strings matter. `move_it_to`'s `MOVE_LINE_TRUNCATED` handling continues at end-of-buffer until display/overlay strings are exhausted. Overlay iteration includes `before-string` and `after-string`.

This provides **no new empirical guarantee of exact height for every end-of-buffer overlay shape**. `resize_mini_window` has a FIXME about an overlay/display string's final newline losing its final empty line. Its oversized ordinary-minibuffer path specially handles after-strings at ZV (icomplete/ido-vertical). These normal-window cases need testing; they are neither a ready-made minibuffer-only fix nor proof Portal must copy that code.

Try rendered-window measurement first, including generic after-string fixtures. Do not substitute buffer line counts, assume all inline completion uses after-strings or introduce a Vertico row-count dependency.

### 3. Installed Vertico uses an end-of-buffer **before-string**

In the pinned installed `vertico.el`:

- `vertico--exhibit` updates candidates, prompt selection and count, then calls `vertico--display-candidates` with `vertico--arrange-candidates`.
- `vertico--arrange-candidates` selects visible candidates, adds group titles, drops lines beyond `vertico-count` (default 10), and formats rows. Measure every displayed row's height, not all matches.
- `vertico--display-candidates` moves a zero-length overlay to `(point-max)` and sets its **`before-string`**: cursor-bearing space, newline if rows exist, then formatted lines ending in newlines. Zero candidates leave only the cursor-bearing space, without the separating newline.
- `vertico--resize-window` always sets buffer-local `truncate-lines` based on point versus roughly 80% of available width, `resize-mini-windows` to `grow-only`, and `max-mini-window-height` to 1.0. It then **skips window-resize logic if the active minibuffer is the frame root window**.
- Otherwise, `vertico-resize=nil` reserves at least `vertico-count`; positive deltas grow, negative deltas shrink only with `vertico-resize=t`. Its default comes from `resize-mini-windows`, normally `grow-only`.

**Implication:** neither `vertico-resize='grow-only` nor nil fixed capacity forces a previous large panel height to remain in Portal's minibuffer-only frame: Vertico skips that resize logic. The proposed `resize-mini-frames` callback can shrink from the new overlay. Sources give no reason to bind `vertico-resize=t` in core. Truncation still affects measurement; extensions replacing these generics need separate validation.

Vertico installs `vertico--exhibit` in buffer-local `post-command-hook`; an earlier Portal hook could measure stale rows. Emacs's pre-display callback is a better generic seam than Vertico advice or assumed hook ordering. Actual ordering still needs graphical tests, including asynchronous completion.

### 4. Existing Portal presentation is not a safe repeated resize operation

`portal-launcher.el:portal-launcher-present` currently binds `resize-mini-frames` to nil for the session. Both kinds use numeric `portal-launcher-size`, default 720×420; `portal-launcher--placement` validates two integers. `portal-launcher--show` selects the frame, calls native show, enables Emacs visibility and redisplays. `portal-launcher-resize` changes the numeric setting and **re-shows a buffer launcher**; it is not an automatic minibuffer layout API.

The native call chain is:

`native/Core/emacs.c:Flauncher_show` → `native/Core/include/portal.h:portal_launcher_show` → `native/Backend.swift:portalLauncherShow` → `native/Launcher.swift:NativeLauncher.place`.

`NativeLauncher.place(..., present: true)` increments the native session, resets `lostFocus`, establishes focus watchers, calls `makeKeyAndOrderFront`, and makes the editor first responder. Repeated show can invalidate blur IDs and disrupt focus semantics: `portal-launcher--queue-blur` and `portal-launcher--blur` require matching native presentation IDs.

The screen-change observer already calls layout-only `place(..., present: false)`, bypassing presentation actions. But **it still recenters and resolves the pointer monitor again**. Exposing it unchanged would not preserve the presentation's top edge or monitor across content changes.

`NativeLauncher.rectangle` floors coordinates and clamps dimensions and position to `NSScreen.visibleFrame`. `place` and the C binding require width ≥200 and requested height ≥100. A smaller usable screen can yield a smaller rectangle: request floors do not force overflow.

### 5. Native ownership and frame safety are real constraints

`native/Launcher.swift:NativeLauncher.attach` moves Emacs content into a borderless, nonactivating `LauncherPanel`, retaining the donor's delegate and attaching the Emacs delegate to the panel. Panel compatibility is bounded, not the full `EmacsWindow` interface. `portal-launcher.el:portal-launcher--guard-parameters` protects fixed role parameters, dropping even unchanged ones; `portal-launcher--check-guard` checks native trampolines.

The pinned NS `ns_set_window_size` has top-left-preserving arithmetic, but does **not** establish blanket safety for Lisp frame setters on the transplanted panel. Stock fitting also changes position/width with its own policies. Retain build restrictions and guards; use bounded native layout rather than blindly calling `set-frame-size`, `set-frame-height` or stock fitting.

Sources support a native-layout synchronization path: `EmacsView.resizeWithOldSuperviewSize:` computes new superview bounds, calls `change_frame_size`, marks the frame garbaged and sends an app-defined wakeup. Portal placement already uses `panel.setFrame`. Whether repeated calls **during the resize callback** settle synchronously enough for correct measurement/redisplay remains unverified.

## Proposed integration (not implemented or GUI-verified)

1. **Resolve sizing per presentation kind.** Normalize nil/numeric/auto before native presentation, preserving numeric behavior. Keep buffer `auto` policy explicitly unresolved in the task. Audit `portal-launcher-resize`'s interactive defaults, currently using `car`/`cadr` of the size option.
2. **Dynamically bind a Portal `resize-mini-frames` callback only for automatic minibuffer presentations.** Keep fixed presentations nil. Scope it to the owned live minibuffer-only frame and active presentation; never resize other frames or use the user's arbitrary fitter for Portal. Unwind restores surrounding settings. For nested prompts, use the passed frame's current minibuffer-window buffer.
3. **Measure generically at the effective fixed width.** Try `window-text-pixel-size` on the explicit minibuffer window with nil FROM/TO/X-LIMIT and an appropriate Y budget. Add non-text frame/window height exactly once, including internal borders (default 16 points per edge in `portal-launcher-frame-parameters`). Candidate formula: measured body height + frame-height − window-body-height, with matching mode/header/tab-line conventions. Validate it; do not hard-code font-height × candidate-count. Establish actual width before measuring wrapping.
4. **Add native layout-only resizing through the existing C/platform bridge.** Validate attached/presenting ownership and preferably the expected native session ID. Use stored presentation width/screen/anchor; skip unchanged effective rectangles. Never call prepare/show, select frames, change native session, reset blur state, reinstall observers or request focus/first responder. Ignore/reject late calls after hide, detach or session replacement.
5. **Anchor explicitly.** Store this presentation's actual top edge and X coordinate. With AppKit's bottom-left origin, set `newY = anchoredTop - newHeight`. Bound growth by space from anchored top to usable-area bottom, not full monitor height, so bottom clamping cannot silently move the top. Choose/document initial auto placement: anchoring a floor-sized panel and measuring before first visible placement yield different tops. Define exceptional reanchoring for monitor removal/usable-area changes; content updates must not follow the mouse across screens.
6. **Prevent resize feedback.** Skip identical rounded/clamped rectangles, guard reentry and never force redisplay inside the callback. Test direct native layout safety there in disposable NS Emacs; defer/coalesce only if necessary, with stale-session checks and cleanup. Deferred designs must not retain obsolete candidate heights or leave timers after cancellation.

## Test implications and unresolved measurement questions

Existing fixtures are useful starting points, not proof of automatic sizing:

- `test/portal-launcher-tests.el:portal-launcher-presentation-settings-are-scoped` asserts nil `resize-mini-frames` in minibuffer sessions. Split automatic/fixed expectations; retain restoration checks. `portal-launcher-rejects-invalid-input-before-enabling` rejects nil size. Mocked panel/session fixtures do not exercise real NS redisplay.
- `test/portal-launcher-gui-tests.el:portal-launcher-gui--minibuffer-layout` records native/Emacs dimensions, clipping and padding. Keep `portal-launcher-gui-minibuffer-panel-vertico`'s explicit fixed-size regressions; it already waits for Vertico redraw before capture.
- `test/native-launcher.swift` covers geometry, rollback, focus records, screen notifications and lifecycle using fake Emacs classes. Extend layout/session invariants there; only supported real NS Emacs can validate view/frame synchronization and safety.

Required disposable supported-NS-Emacs experiments during implementation:

- Measure growth **and shrinkage** across zero/one/many visible rows: initial prompt, no matches, group titles, long prompt/input, wrapping, font changes, line spacing and styled/variable-height annotations. Compare native points, Emacs pixel dimensions and visible last rows; names alone do not justify multiplying by Retina scale.
- Test arbitrary end-of-buffer **after-strings** separately from Vertico's before-string: with/without trailing newline, empty buffer, truncation and wrapping. Establish measurement contents and whether the cursor requires a trailing empty display row. Do not subtract a line or set IGNORE-LINE-AT-END without evidence.
- Confirm fresh overlays after typing/asynchronous updates and measurement beyond a short panel without self-clamping. Check initial-show flash, stale frame metrics, redisplay loops and fractional/rounded height oscillation.
- Assert constant top edge, width, native session ID, key/first responder state and focus observers across many resizes. Verify queued genuine blur still dismisses and stale callbacks cannot revive hidden panels. Exercise cancel, error, nested minibuffers, deletion/disable and kind replacement.
- Test near-bottom offsets, negative-origin monitors, screen changes, tiny usable areas and content caps that cannot fit every row. Specify overflow/scroll behavior without taking over completion navigation. Preserve fixed numeric placement and buffer defaults.
- Test without Vertico, with stock completion, and with installed Vertico's `vertico-resize` nil/t/grow-only. Core should load no completion package. Extensions rendering elsewhere are not automatically equivalent to inline Vertico.

**Bottom line:** `resize-mini-frames` plus generic rendered-text measurement is the strongest source-supported seam. It needs a bounded native top-anchored layout API, not repeated presentation or Vertico-specific fitting. End-of-buffer overlay measurement and redisplay-time native resizing still need implementation-time validation; they are not established GUI results.
