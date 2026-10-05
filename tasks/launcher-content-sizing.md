---
id: launcher-content-sizing
status: done
---

# Fit minibuffer launcher panels to their displayed content

## Problem and outcome

A user-configured application launcher presents `launcher.el` in a Portal
minibuffer panel with `portal-launcher-size` bound to `(720 240)` and
`vertico-count` bound to `5`. The candidate list occupies less than the fixed
height, leaving permanent empty space. Filtering down to fewer results makes
the mismatch worse.

Make automatic height the default for minibuffer presentations. The panel must
shrink and grow dynamically with its rendered prompt and completion display,
not merely choose a smaller height when it opens. Keep the width stable and
the prompt stationary: after initial placement, anchor the top edge and move
only the bottom edge. Explicit numeric dimensions retain fixed-size behavior.

Implemented on 2026-10-05; the decisions and completion record are below.
Source-backed findings are recorded in
`docs/launcher-content-sizing-research.md`, and the implemented design and
measurements in `docs/launcher-native-panel.md` (content-fitted minibuffer
panels). No user configuration was changed.

## Agreed interface and behavior

Use the existing `portal-launcher-size` option; do not add a competing
fit-to-content boolean or infer whether a user explicitly assigned a variable.

| Value | Minibuffer presentation | Buffer presentation |
| --- | --- | --- |
| `nil` (new default) | Width 720 points, automatic height | Existing fixed default, 720 × 420 points |
| `(WIDTH auto)` | Explicit fixed width, automatic height | Policy below; general buffer fitting is out of scope |
| `(WIDTH HEIGHT)` | Fixed numeric dimensions | Fixed numeric dimensions |

- Dimensions remain AppKit logical points. Numeric width is an integer of at
  least 200; numeric height is an integer of at least 100. Preserve the existing
  native floor of 100 points for automatically fitted height. All requested
  dimensions remain subject to the monitor's usable area.
- Numeric sizes are fixed, not maxima. An existing explicit `(720 240)` must
  not silently start resizing. A user who wants the new behavior removes the
  binding or replaces it with `(720 auto)`.
- `auto` means ongoing fitting to the rendered minibuffer content: prompt,
  input (including wrapping), visible completion rows, group headings or
  inline no-match messages where present, and actual frame padding. Do not
  size from the total number of candidates or from buffer line count alone.
- A typical sequence is prompt + five rows → prompt + two rows → prompt/no
  matches → prompt + five rows. Height follows each change, subject to the
  minimum and available space. There may still be spare space at the native
  minimum; do not promise a zero-padding one-line panel.
- Width must not change with query length, candidate labels, or filtering.
  Candidate count, ordering, selection, annotations, and input semantics stay
  under the caller's completion UI; Portal does not choose a new row limit.
- The completion display remains authoritative. Fitting should still shrink
  when rendered content shrinks even if ordinary minibuffers use a grow-only
  window policy. Do not globally change `vertico-resize`, `resize-mini-windows`,
  or any other completion preference.
- The setting is resolved per presentation, respecting `let` bindings. Fitting
  must not replace the configured `auto`/nil value with the latest measured
  numeric height or leak policy into ordinary Emacs frames.

Proposed user configuration after implementation (not applied by this task):

```emacs-lisp
(defun my/app-launcher ()
  "Launch an app or search the web in Portal's fitted panel."
  (interactive)
  (let ((portal-launcher-size '(720 auto))
        (vertico-count 5))
    (portal-launcher-present #'launcher :kind 'minibuffer)))
```

Omitting `portal-launcher-size` entirely should give the same automatic
minibuffer behavior when the option retains its new default.

## Scope and non-goals

- Implement fitting for `:kind 'minibuffer`, including nested prompts within
  the same presentation. Refit when returning from an inner prompt.
- Keep `:kind 'buffer`, `portal-launcher-show`, persistent buffer panels,
  split windows, and their own minibuffers fixed-size by default. This is not
  automatic fitting of arbitrary editable buffers or documents.
- Portal remains generic infrastructure. No production dependency on
  `launcher.el` or Vertico; use generic prompt fixtures in core tests, with
  optional Vertico integration coverage.
- Do not add horizontal fitting, animated resizing, new shortcuts, application
  search policies, or a broad layout framework. Do not change the user's
  Emacs configuration or other repositories during implementation unless
  separately requested.
- Preserve the existing validated Emacs NS build restriction, native frame
  guards, shortcut ownership, command return values, and dismissal behavior.

## Placement and lifecycle requirements

1. Resolve initial placement using the existing screen and offset settings.
   Aim to present at the initial fitted size without flashing a tall empty
   panel. Establish the top-edge anchor from that first fitted placement; do
   not re-center on each candidate update.
2. Within one presentation, keep the selected monitor, horizontal position,
   width, and top edge stable. Moving the mouse to another display while
   typing must not migrate the panel.
3. Clamp growth to usable space below the anchored top edge. At the limit,
   preserve usable completion navigation and scrolling instead of moving the
   prompt upward or letting the panel extend offscreen.
4. Screen disconnection or display-layout changes may force repositioning;
   keeping the panel reachable takes precedence over preserving the old
   anchor. Establish a valid new anchor after that adjustment. The next
   explicit presentation still resolves screen/offset settings afresh.
5. Resizing is layout, not presentation. It must not increment the native
   session ID, clear recorded focus loss, capture the previous application
   again, make the panel key again, or emit a spurious dismissal. Preserve the
   current first responder and IME composition.
6. Coalesce redundant measurements; unchanged desired geometry must not
   trigger another native resize. Prevent resize → redisplay → resize loops
   and avoid permanent polling.
7. Fit only a live, visible, automatic minibuffer presentation. Stale callbacks
   after dismissal, deletion, disable, or replacement must not resize or
   reopen a panel. Remove session-specific hooks/timers on every exit path.
8. Preserve Escape/C-g, repeated invocation, click-away, error, hide, deletion,
   and disable semantics. Cancellation restores focus only under the existing
   ownership rules; success and click-away keep the destination's focus.

## Research findings that constrain implementation

See `docs/launcher-content-sizing-research.md` for sources and caveats.

- `portal-launcher-present` currently binds `resize-mini-frames` to nil.
  Both its docstring and `docs/launcher-native-panel.md` explicitly describe
  fixed height and blank space. Changing only a user-side Vertico setting is
  not sufficient.
- A minibuffer panel is a minibuffer-only Emacs frame, not a small minibuffer
  below an ordinary buffer window. Measure the displayed minibuffer in that
  actual layout.
- The installed Vertico renders candidate rows in an end-of-buffer overlay's
  `before-string`. Its normal resize path does not resize a root minibuffer
  window. A buffer-text-only measurement will miss the candidate display;
  generic fitting should also cover other UIs' `after-string` overlays.
- `NativeLauncher.place` currently recomputes centered geometry. Its normal
  presentation path also advances the native session and requests focus.
  The existing `present: false` path used for display changes avoids those
  presentation effects but still centers placement. It is a useful existing
  separation, not a complete top-anchored fitting implementation.
- `portal-launcher-resize` calls the public buffer-show path; it is not a safe
  per-keystroke fitting operation for an active minibuffer session.
- The NSPanel hosts an internal Emacs NS view. Blindly enabling Emacs's default
  frame-fitting setters is not sufficient evidence of native compatibility.
  Validate the measurement and native resize route in a disposable supported
  graphical Emacs before relying on them.

## Decisions

These details were not explicitly settled in the user discussion. The answers
below were chosen during implementation, before production behavior changed.

- **Explicit `auto` with buffer kind:** rejected, as recommended.
  `(WIDTH auto)` with `:kind 'buffer` or `portal-launcher-show` signals a
  `user-error` before native work, and `portal-launcher-present` checks the
  setting before cancelling an active session. Default nil still resolves to
  the fixed 720 × 420 buffer panel.
- **Initial measurement and anchor:** the hidden frame can be measured, but
  the function's prompt does not exist yet when the panel is shown. The first
  placement therefore uses the height of what the minibuffer shows at that
  moment, normally the 100-point minimum, centered by the screen and offset
  settings. Its top edge is the anchor: when the prompt and candidates arrive
  the panel grows downward, never re-centers and never opens taller than its
  content. GUI tests compare the rectangle before the prompt's first display
  with every later one.
- **Measurement and update seam:** a function-valued `resize-mini-frames`,
  bound only for automatic minibuffer presentations, measures with
  `window-text-pixel-size` during redisplay. It sees before- and after-string
  overlays, wrapping, line spacing, taller faces, growth beyond the current
  height and timer-driven updates. It can miss a nested prompt starting or
  ending, because the minibuffer window's change counter carries over from the
  previous buffer, so the session also refits from `post-command-hook`. No
  timers, polling or completion-package advice.
- **Transient echo messages:** an echo-area message, which temporarily puts its
  own buffer in the minibuffer window, keeps the last input layout: no flicker,
  and the next redisplay of the input measures it again. Messages Emacs shows
  inline in an active minibuffer, such as `minibuffer-message`, are content and
  fit.
- **Explicit manual resize command:** `portal-launcher-resize` keeps setting
  numeric dimensions for both kinds and re-showing the buffer launcher. Its
  prompts default to the setting's numbers, or 720 and 420 for nil or `auto`.
  During a minibuffer presentation it signals a `user-error` before prompting
  and changes nothing, since that panel cannot become a buffer panel; during a
  buffer presentation it behaves as before.

## Implementation plan

1. Re-read the findings against the implementation checkout. Work on a fresh
   branch/worktree as required by `AGENTS.md`; this task authoring did not
   authorize starting implementation. Check current launcher tests rather
   than treating older task files' unchecked statuses as missing code.
2. Add failing policy tests for kind-specific default resolution, explicit
   automatic height, fixed numeric sizes, malformed settings, dynamic binding,
   and the selected buffer-auto policy. Resolve sizes before native work;
   invalid settings must not partially mutate native state.
3. Establish a real graphical regression fixture: five visible rows shrink
   to two and regrow, while panel bounds, root-window dimensions, prompt
   position, and session ID are observed. Include a fixed-size control. Prove
   the existing fixed-height path fails the automatic behavior assertion.
4. Add the smallest layout-only native operation needed for top-anchored
   resizing, through the existing Swift/C/Lisp layers. Keep session/focus
   transitions separate from geometry updates. Extend native tests for
   anchoring, clamping, unchanged-session behavior, and monitor changes.
5. Integrate rendered-content measurement with session-scoped automatic
   sizing. Include internal borders exactly once, retain the fixed width,
   cap to usable space, suppress no-op resizes, and preserve cleanup safety.
   Test the actual display path rather than only a mocked row-count formula.
6. Extend batch and graphical coverage through the public presentation
   interface and verify coexistence with fixed buffer/minibuffer panels,
   ordinary frames, nested prompts, and existing focus/dismissal behavior.
7. Update option types/docstrings and `README.md` examples/customization notes,
   `docs/launcher-native-panel.md`, and the relevant daily-use guide sections.
   Replace current claims that both kinds are always fixed-size. Document
   migration (`(720 240)` stays fixed; nil/`(720 auto)` enables fitting), the
   minimum height, and the supported completion-display scope.
8. Run the checks below, record exact versions and results here, and only then
   mark acceptance and task status complete. Do not claim manual acceptance
   from historical launcher validation.

## Acceptance

- [x] With the default nil setting, minibuffer panels fit dynamically at width
  720; buffer panels retain 720 × 420. Loading Portal remains inert.
- [x] `(WIDTH auto)` keeps that width and fits minibuffer height; numeric pairs
  retain fixed behavior for both kinds. Buffer-auto policy and invalid values
  are documented and tested, including failure before native mutation.
- [x] Five → two → zero matches → five visible rows shrink and regrow without
  the former fixed-height blank region, except unavoidable minimum/padding.
  Verify actual native panel and Emacs frame sizes, not just computed targets.
- [x] Initial content is fitted without an obvious tall-panel flash; subsequent
  updates keep the prompt/top edge and horizontal placement stable. Moving
  the pointer to another display does not move the active panel.
- [x] Wrapped input, overlay completion rows, group headings/annotations,
  font/line-height differences, internal borders, and nested prompt entry/exit
  produce correct measurements without clipping or double-counted padding.
- [x] Content can grow beyond the panel's current height, stops at the
  available anchored screen space, remains navigable, and shrinks afterward.
  Asynchronous display changes are handled without requiring another keypress.
- [x] Plain prompts work without Vertico or launcher.el. Optional Vertico
  tests pass with normal grow-only and shrink/grow settings, and ordinary
  minibuffer preferences remain unchanged after success and cancellation.
  Stock `*Completions*` remains suppressed as today for minibuffer-only panels;
  this task does not promise fitting a separate completions buffer.
- [x] Resize preserves the native session ID and first responder, does not
  clear pending blur, and neither steals focus nor dismisses the panel.
  Cancellation, success, click-away, repeated invocation, errors, explicit
  hide, deletion, and disable still satisfy their existing contracts.
- [x] Repeated presentations and configuration reloads leak no hooks/timers;
  late resize work cannot touch a hidden/replaced frame. No-op redraws issue
  no native resize, and fitting does not create a redisplay loop.
- [x] Screen-space clamping, nonzero offsets, negative monitor origins,
  Retina logical-point sizing, and display-layout changes have native test
  coverage. Physical display/IME checks are reported separately as tested or
  not tested; preserved composition is checked in a live disposable session.
- [x] Explicit fixed-size buffer panels, persistent buffer sessions, numeric
  `portal-launcher-resize`, shortcuts, and ordinary Emacs frames keep working.
- [x] Documentation and migration examples match the implemented interface;
  no mandatory completion/application dependency or user-config changes.

## Verification and completion record

During implementation, start with the focused suites and then run the full
project checks. Current entry points (confirm in `README.md` at that time):

```sh
ctest --test-dir build -R launcher --output-on-failure
sh test/launcher-daily-use.sh
ctest --test-dir build --output-on-failure
```

Also extend and run `test/native-launcher.swift` using the README's standalone
native launcher instructions. Run the combined graphical launcher suite in a
**disposable** supported NS Emacs with selector `^portal-launcher-`, including
`test/portal-launcher-gui-tests.el` and
`test/portal-launcher-daily-use-tests.el`. Record exact commands, revisions,
completion settings, font/padding, and display geometry. Batch tests alone
cannot establish native sizing, rendering, focus, or IME behavior. Never
replace the native module already loaded in the user's running Emacs.

### Completion record, 2026-10-05

Implemented from base `879cbfb` on branch
`task/implement-tasks-launcher-content-siz-70050e29`. Environment: GNU Emacs
NS 31.1 at `a360712c9d272d950d8d8255ef74570f7e90b7d9`, macOS 27.0.1 (26A434)
on Apple Silicon, Swift 6.4, Bun 1.3.14, CMake 4.0.3. Displays: Gigabyte
M32U, usable `(0, 0, 2560, 1410)`, and LG ULTRAFINE, usable
`(2560, −483, 1440, 2530)`, both at scale 2. Completion: stock completion,
generic after-string row fixtures and CMake's Vertico 2.15, with Orderless
1.8 and Marginalia 2.13 in the existing tests. Fitting tests use Menlo 24
(28-point lines) and the default 16-point internal borders.

All passed:

- `./build.sh`
- `ctest --test-dir build --output-on-failure`: 33 of 33, including
  `launcher` (35 tests, after review) and `module`
- `bun run --cwd host check` and `bun run --cwd host typecheck`
- `python3 -B -m unittest discover -s test -p 'test_*.py'`: 8 tests
- `git diff --check`
- Standalone native launcher check, built as in `docs/testing.md` with
  `test/native-launcher.swift`: geometry, fitting, rollback, ownership,
  focus-loss delivery and 20 attach/detach cycles
- `sh test/launcher-daily-use.sh`: 2 of 2
- Combined graphical launcher suite in one disposable `emacs -Q
  --module-assertions` with `portal.el`, the test injector and
  `test/portal-launcher-daily-use-tests.el` (which loads
  `test/portal-launcher-gui-tests.el`), selector `^portal-launcher-`: 28 of 28
  in 77 s

Measured heights and screenshots are in `docs/launcher-native-panel.md`; in
short, five rows 200 points, two 116, none 100, with the top edge, left edge,
width and native session unchanged and the Emacs frame matching. Two mutants
loaded in place of `portal-launcher.el` fail the new GUI tests: one that never
fits (the old fixed path), and one without the `post-command-hook` refit (the
nested-prompt regression).

Notes on the graphical runs: the machine was in use, and earlier partial runs
had three intermittent dismissals from native focus loss while another app was
active; each test passed when rerun, and the final combined run had none.
Marked text was composed and committed through Emacs's NS text-input client
by a test event monitor while the panel resized; a physical CJK input method
was not tested. Physical display disconnection and VoiceOver with a fitted
panel were not tested; display changes are covered by standalone native
notifications. The hands-on daily-use checklist was not re-run.

Review follow-up: enabling `portal-launcher-mode` now also requires the
module's `portal--launcher-fit`, so new Lisp with a module loaded before the
rebuild asks for a rebuild and restart instead of failing in redisplay. The
full checks above and three graphical tests passed again.
