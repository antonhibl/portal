---
id: launcher-panel-height-bounds
status: todo
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

- [ ] Existing valid calls and default minibuffer-only tests retain their current
  geometry/lifecycle, and explicit numeric sizes remain fixed.
- [ ] Configurable automatic max height is enforced without re-presentation;
  default max still uses available screen space.
- [ ] `MIN=content` permits an actually legal sub-100-point panel where the
  selected font/decorations allow it; no negative mini-window heights, native
  errors, unsafe zero-height windows, or clipped prompt caused by an illegal floor.
- [ ] Invalid options/ranges fail before state mutation; limits remain unchanged
  in user config after fitting and respect dynamic bindings.
- [ ] Resizing preserves frame/native session, top/left/width/monitor, responder,
  IME marked text where tested, and pending blur; it does not steal focus.
- [ ] Stale/no-op requests are harmless; no reopen after dismissal or resize loop.
- [ ] Bounds/clamping and errors have batch/native checks; real low-height and
  maximum-height input behavior has disposable VM evidence. Record physical IME,
  VoiceOver, and monitor-disconnect coverage separately from injected tests.

## Verification and completion record

Run host checks from `CONTRIBUTING.md`, relevant standalone native and graphical
checks only via `bash test/vm.sh ...`, and byte compilation/diff checks. Restart
Emacs after any native rebuild. Record actual versions/results and screenshots.
No live config changes. This task is independent of launcher.el implementation.
