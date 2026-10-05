---
id: launcher-content-sizing
status: todo
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

This document is the implementation handoff, not an implementation record.
Source-backed findings and remaining technical questions are recorded in
`docs/launcher-content-sizing-research.md`. No production code, tests, build
artifacts, or user configuration were changed while authoring this task.

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

## Decisions to settle before implementation

These details were not explicitly settled in the user discussion. Record the
chosen answers here before changing production behavior.

- **Explicit `auto` with buffer kind:** recommend rejecting `(WIDTH auto)` for
  `:kind 'buffer` and `portal-launcher-show` with a clear `user-error` before
  native work. This avoids pretending arbitrary-buffer fitting is supported.
  Default nil still resolves to the fixed buffer fallback.
- **Initial measurement and anchor:** determine whether the hidden attached
  frame can be measured reliably before presentation, or whether one initial
  fitting pass is needed. Document the first-placement rule and test for a
  visible size/position jump; do not silently make every update re-center.
- **Measurement and update seam:** first investigate Emacs's function-valued
  `resize-mini-frames` callback and rendered-text measurement. Verify overlay
  before/after-strings, wrapping, growth beyond the current height, font changes,
  and asynchronous completion updates in the supported build. Use a minimal
  session-scoped alternative if that seam is insufficient; do not assume
  `post-command-hook` alone catches all display changes.
- **Transient echo messages:** establish whether temporary minibuffer messages
  should participate in fitting or retain the last input layout. Prevent
  flicker and restore correct input dimensions afterward.
- **Explicit manual resize command:** preserve fixed-size uses of
  `portal-launcher-resize`; give its interactive numeric prompts sensible
  defaults when the configured option is nil or contains `auto`. Specify its
  behavior during an active automatic session rather than accidentally
  switching frame kind or invalidating that session.

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

- [ ] With the default nil setting, minibuffer panels fit dynamically at width
  720; buffer panels retain 720 × 420. Loading Portal remains inert.
- [ ] `(WIDTH auto)` keeps that width and fits minibuffer height; numeric pairs
  retain fixed behavior for both kinds. Buffer-auto policy and invalid values
  are documented and tested, including failure before native mutation.
- [ ] Five → two → zero matches → five visible rows shrink and regrow without
  the former fixed-height blank region, except unavoidable minimum/padding.
  Verify actual native panel and Emacs frame sizes, not just computed targets.
- [ ] Initial content is fitted without an obvious tall-panel flash; subsequent
  updates keep the prompt/top edge and horizontal placement stable. Moving
  the pointer to another display does not move the active panel.
- [ ] Wrapped input, overlay completion rows, group headings/annotations,
  font/line-height differences, internal borders, and nested prompt entry/exit
  produce correct measurements without clipping or double-counted padding.
- [ ] Content can grow beyond the panel's current height, stops at the
  available anchored screen space, remains navigable, and shrinks afterward.
  Asynchronous display changes are handled without requiring another keypress.
- [ ] Plain prompts work without Vertico or launcher.el. Optional Vertico
  tests pass with normal grow-only and shrink/grow settings, and ordinary
  minibuffer preferences remain unchanged after success and cancellation.
  Stock `*Completions*` remains suppressed as today for minibuffer-only panels;
  this task does not promise fitting a separate completions buffer.
- [ ] Resize preserves the native session ID and first responder, does not
  clear pending blur, and neither steals focus nor dismisses the panel.
  Cancellation, success, click-away, repeated invocation, errors, explicit
  hide, deletion, and disable still satisfy their existing contracts.
- [ ] Repeated presentations and configuration reloads leak no hooks/timers;
  late resize work cannot touch a hidden/replaced frame. No-op redraws issue
  no native resize, and fitting does not create a redisplay loop.
- [ ] Screen-space clamping, nonzero offsets, negative monitor origins,
  Retina logical-point sizing, and display-layout changes have native test
  coverage. Physical display/IME checks are reported separately as tested or
  not tested; preserved composition is checked in a live disposable session.
- [ ] Explicit fixed-size buffer panels, persistent buffer sessions, numeric
  `portal-launcher-resize`, shortcuts, and ordinary Emacs frames keep working.
- [ ] Documentation and migration examples match the implemented interface;
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

Planning only: all implementation acceptance items remain unchecked. No
implementation tests or graphical experiments were run as part of authoring.
The new task's YAML metadata, discovery, and detail rendering were checked
through the existing `host/tasks.ts` parser and task browser functions; the
all-tasks listing reported no Problems.
