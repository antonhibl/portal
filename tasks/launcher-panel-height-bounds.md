---
id: launcher-panel-height-bounds
status: done
depends_on:
  - launcher-content-sizing
---

# Add generic bounded height requests for native launcher panels

## Problem and outcome

A caller may show short content, then a long editable result, in the same normal
Emacs frame hosted by Portal. Native geometry should support small content heights
and a configurable maximum without closing/re-presenting the panel. This is
infrastructure only: no completion package, Launcher prefix, dictionary, or chat
logic belongs here.

## Blocked by

[Existing content sizing](.archive/launcher-content-sizing.md), done, supplies
`portal--launcher-fit` and top-anchored layout. Reuse that separation from native
presentation/focus. The next task adds generic Emacs-window measurement.

## Proposed contract

Add `portal-launcher-height-limits` with value `(MIN MAX)`, resolved per
presentation and respecting `let` bindings:

- Default `(100 nil)` preserves the current automatic minimum and screen-bound
  maximum for existing callers.
- MIN is a positive logical-point count or `content`. `content` requests the
  smallest legal height for the actual Emacs frame/windows plus decorations, not
  a zero-height native view. MAX is nil (usable-screen bound) or a positive count.
- Apply these limits to automatic/content height requests. Explicit numeric
  `portal-launcher-size` values remain fixed as today and are still constrained
  by the monitor; do not silently turn them into automatic maxima.
- The effective floor includes Emacs's actual safe window minima, mandatory
  minibuffer/echo row, mode/header lines and internal borders. A normal frame may
  therefore need more than one visible text row overall. Do not promise a literal
  one-row frame or change Emacs's global safe-minimum variables.
- Invalid ranges, including a requested maximum below the legal frame floor,
  fail before showing/mutating/cancelling another presentation. At runtime, a
  shrunken usable display takes precedence: clamp to reachable screen space and
  document the unavoidable exception to configured minimum height.

Names are proposed, not available on main yet. Record any necessary refinement
here and in the downstream launcher configuration task before implementation.

### Refinements recorded at implementation

The names above are kept. Implementation refined the contract as follows:

- MIN and MAX are positive fixnums (or `content`/nil), and a numeric MIN must
  not exceed MAX. Limits are validated for every presentation and show, fixed
  or automatic, together with the other launcher settings, before anything is
  shown, mutated or cancelled. They bound only automatic heights.
- The legal frame floor is Emacs's own resize minimum: `frame-windows-min-size`
  with IGNORE t, pixelwise (one text line per window plus its tab, header and
  mode lines, rounded to whole lines, and the minibuffer's line), or the frame's
  `min-height` parameter if larger, plus internal borders and tab bar. A numeric
  MIN below it gives the floor.
- A maximum below the legal frame floor stays invalid, as specified above: it
  fails before anything is shown, mutated or cancelled, including an active
  session or an explicitly shown panel of the other kind (human decision on
  review round 1, 2026-10-06, keeping the original contract). The floor
  depends on the frame's font and parameters, so a preflight in
  `portal-launcher-present` measures the frame the presentation would show
  before cancelling or replacing anything: the dedicated frame when presenting
  reuses it unchanged (same kind, no `portal-launcher-font` to apply), or else
  a hidden, unattached candidate frame, deleted again. When presenting reuses
  the live frame with a font, the candidate has that frame's own
  floor-affecting parameters (internal border, `min-height`, horizontal scroll
  bars, bottom divider) and the font; only when presenting makes or replaces
  the frame does it use a new frame's parameters (review round 2). If the floor grows later during a presentation (a font
  change), the floor wins over MAX rather than clipping the prompt.
- The seam is internal: `portal-launcher--request-height SESSION HEIGHT`, taking
  the session object, not a native ID. The minibuffer fitter uses it, so there
  is one resizing path. Configuration only sets the option.
- The downstream launcher.el configuration task
  (`tasks/configuration-and-acceptance.md` in that repository) is not edited
  from this repository; it should adopt these names and the refinements above.

## Plan

1. Follow Portal's worktree, native-safety, and testing instructions. Read
   `docs/architecture.md`, `docs/launcher-native-panel.md`, and the platform
   interface before changing validators or lifecycle code.
2. Inspect both initial placement and layout-only resize paths in Lisp, C and
   `native/Launcher.swift`: today height is hard-limited to at least 100 in more
   than one place. Preserve all old default/numeric call behavior while allowing
   a smaller validated automatic height for opted-in content sizing.
3. Keep legal-height/limits policy in the appropriate generic Lisp/core layer;
   keep AppKit placement, screen clamping, and native ownership in the backend.
   Expose a safe session-bound Lisp seam for the generic fitter; configuration
   should not call private native functions or pass raw session IDs. Avoid a
   second resizing path that re-presents the panel.
4. Clamp requested height by configured limits and available space below the
   anchored top edge. Keep width/left/top/monitor, native session, first responder,
   previous-app capture, and pending focus-loss state intact. Do not call native
   `place` as though this were a new presentation.
5. Ignore stale requests after session exit/replacement; unchanged geometry must
   be a no-op. Any async requester must be tied to the session/window it belongs
   to, not implicitly whichever panel was opened most recently.
6. Keep existing minibuffer-only default sizing and all focus/dismissal behavior
   unchanged. Cover normal-frame low-height legality, default100 compatibility,
   offsets/negative origins, Retina units, maximum clamping and monitor changes.
7. Document the generic limits and the distinction between requested content
   height, legal frame floor, configured maximum, and physical available space.
   Do not introduce tool/completion-specific options or a new panel kind.

## Acceptance

- [x] Existing valid calls and default minibuffer-only tests retain their current
  geometry/lifecycle, and explicit numeric sizes remain fixed.
- [x] Configurable automatic max height is enforced without re-presentation;
  default max still uses available screen space.
- [x] `MIN=content` permits an actually legal sub-100-point panel where the
  selected font/decorations allow it; no negative mini-window heights, native
  errors, unsafe zero-height windows, or clipped prompt caused by an illegal floor.
- [x] Invalid options/ranges fail before state mutation; limits remain unchanged
  in user config after fitting and respect dynamic bindings. A maximum below
  the frame-dependent legal floor is caught by the preflight described above.
- [x] Resizing preserves frame/native session, top/left/width/monitor, responder,
  IME marked text where tested, and pending blur; it does not steal focus.
- [x] Stale/no-op requests are harmless; no reopen after dismissal or resize loop.
- [x] Bounds/clamping and errors have batch/native checks; real low-height and
  maximum-height input behavior has disposable VM evidence. Record physical IME,
  VoiceOver, and monitor-disconnect coverage separately from injected tests.

## Verification and completion record

Run host checks from `CONTRIBUTING.md`, relevant standalone native and graphical
checks only via `bash test/vm.sh ...`, and byte compilation/diff checks. Restart
Emacs after any native rebuild. Record actual versions/results and screenshots.
No live config changes. This task is independent of launcher.el implementation.

### Completion record, 2026-10-06

Implemented from base `a23027e` on branch
`task/implement-next-todo-in-tasks-862ecc04`. Host: macOS 27.0.1 on Apple
Silicon, GNU Emacs NS 31.1 at `a360712c9d272d950d8d8255ef74570f7e90b7d9`,
Swift 6.4, Bun 1.3.14, CMake 4.0.3. VM: macOS 27.0.1 guest, same Emacs build,
one "Apple Virtual" display, usable area `(0, 74, 1326, 742)`, scale 2.

Host checks, all passed:

- `./build.sh`
- `ctest --test-dir build --output-on-failure`: 34 of 34, including `launcher`
  (41 tests) and `module`
- `bun run --cwd host check` and `bun run --cwd host typecheck`
- `python3 -B -m unittest discover -s test -p 'test_*.py'`: 8 tests
- `git diff --check`, and byte compilation of `portal-launcher.el` and both
  launcher test files without warnings

VM checks through `bash test/vm.sh sh -c '…'`, run twice:

- Standalone native launcher check, built as in `docs/testing.md` with
  `test/native-launcher.swift`: passed, including heights below 100 points
- Combined graphical launcher suite in a disposable `emacs -Q
  --module-assertions` with `portal.el`, the test injector and
  `test/portal-launcher-daily-use-tests.el`, selector `^portal-launcher-`:
  29 passed, 0 failed, 1 skipped in 105 s; rerun at the final commit after
  review round 2, with the new regressions: 32 tests, 31 passed, 0 failed, 1
  skipped in 105 s. The skipped
  `portal-launcher-gui-minibuffer-panel-stays-on-its-display` needs a second
  display, which the VM lacks.

Measured heights and screenshots are in `docs/launcher-native-panel.md`,
section "Height limits and legal frame heights". A minibuffer frame's legal
height with Menlo 24 was 60 points. `(content 144)` gave 144 (clipped), 116, 60
and 144 for five, two, no and five rows; the default gave the earlier 200,
116, 100 and 200. A `(content 1)` invocation, measured on a hidden candidate
frame during a live prompt, and again with a buffer panel shown, failed with
"Launcher maximum height 1 is below the legal height of its panel, 60 points"
and left the session, prompt, key status, frames and buffers unchanged. After
the live panel's internal border changed from 16 to 80 points, its legal height
with the launcher font was 188: a `(content 144)` invocation failed, in a
session and outside one, leaving the same state, and `(content 188)` presented
at 188 points. A normal frame with Menlo 13 reached its legal height, 77 points with a mode line
and 62 without, with Emacs's frame matching and its minibuffer reading input.
Five
mutants of `portal-launcher.el` (no maximum, no legal floor, no session check,
no duplicate suppression, no MIN/MAX order check) and five of the preflight
(removed, moved after the session's cancellation, candidate not deleted,
launcher font ignored, new-frame parameters for a reused frame) each failed the
batch suite.

GNU ELPA was unreachable from host and VM during this work. The host build
reused the main checkout's extracted copies of the pinned packages. For the VM
runs only, with the user's approval, `CMakeLists.txt` temporarily fetched the
same tarballs from the Tsinghua ELPA mirror; all eight matched the pinned
SHA256 hashes, which CMake checked again. That edit was reverted before
committing; the build files are unchanged.

Not tested: a physical input method (marked text was injected through Emacs's
NS text-input client), VoiceOver with a short panel, and monitor
disconnection (display changes are covered by standalone native
notifications). The hands-on daily-use checklist was not re-run.
