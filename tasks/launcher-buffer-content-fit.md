---
id: launcher-buffer-content-fit
status: todo
depends_on:
  - launcher-panel-height-bounds
---

# Fit ordinary buffer panels to rendered content within height bounds

## Problem and outcome

Allow Portal to fit the ordinary Emacs window it already hosts, without knowing
what application produced its content. A short buffer should produce a compact
panel; a long or asynchronously growing buffer should stop at the configured
maximum and remain scrollable by Emacs. Launcher will own all picker/query/result
rendering in a separate repository.

## Blocked by

[Bounded height requests](launcher-panel-height-bounds.md) supplies legal floors,
configured limits, stable anchored geometry and stale-session protection.
No dependency on launcher.el, Vertico, dictionary, gptel, or any specific UI.

## Proposed contract

Extend existing `portal-launcher-size` semantics narrowly:

| Value | Minibuffer-only | Ordinary buffer panel |
| --- | --- | --- |
| nil | unchanged: width720, existing automatic fitting | unchanged: fixed720×420 |
| `(WIDTH HEIGHT)` | unchanged fixed size | unchanged fixed size |
| `(WIDTH auto)` | unchanged minibuffer fitting | NEW: explicit opt-in rendered-content fitting |

Use `portal-launcher-height-limits` from the prerequisite, default `(100 nil)`.
For example, `(content 480)` requests a legal content-dependent minimum and a
480-point maximum. With no opt-in, ordinary buffer sizing must not change.

Support a single ordinary content window plus its frame minibuffer. If the caller
creates additional ordinary windows, freeze at the current legal height rather
than deleting/rearranging their splits or guessing a preferred content window;
resume fitting when a single ordinary window is restored. Document this scope.
Normal buffer switching updates the measured content without changing sessions.

## Plan

1. Extend size validation/resolution, documentation and tests to allow explicit
   buffer-auto. This intentionally replaces the old error for that formerly
   unsupported input; all previously valid default/fixed calls remain unchanged.
2. Measure rendered window content in generic Elisp, including before/after-string
   overlays, wrapping, font/line-height differences, text properties, header/mode
   lines, borders, and the actual minibuffer/echo area. Do not infer candidate
   counts, buffer types, major modes, or tool states.
3. Define measurement independently of scroll position: the desired bounded size
   should not shrink just because the user scrolled toward the end of a long
   document. Bound work at the effective maximum instead of scanning unbounded
   chat/log buffers on every streamed chunk. Cache/coalesce redundant requests.
4. Install session-scoped window/buffer/redisplay observation so text inserted by
   processes/timers and buffer switches refit without another keypress. No permanent
   polling. Keep measurement safe during redisplay; no recursive redisplay or
   frame presentation from measurement callbacks.
5. Show the initial legal compact size without flashing a tall empty panel, then
   use the prerequisite's anchored layout-only operation. Reuse the same frame,
   panel, session and focus across buffer switches. No native view swapping.
6. Measure active/nested ordinary minibuffer prompts without double-counting a
   buffer shown twice. Ensure echo messages do not displace/resize content wildly.
   Pause safely for unsupported multiwindow layouts, transitions, or teardown.
7. At the configured/screen maximum, keep frame/window dimensions bounded and let
   normal Emacs scrolling handle overflow. Never move point, force scroll-to-end,
   select another frame, or truncate the buffer. Result UIs decide follow-output
   behavior; Portal does not know whether content is chat or a dictionary.
8. Remove observers on success/quit/error/blur/hide/delete/disable. Delayed work from
   an old buffer/session must not resize, focus, or reopen a newer panel. Explicit
   manual numeric resize stops automatic fitting rather than being overwritten.
9. Update public docstrings, Custom documentation, executable launcher examples
   and relevant graphical tests. Use generic ordinary buffers and synthetic
   overlay/stream fixtures, not mandatory third-party packages.

## Acceptance

- [ ] Fixed/default ordinary buffer behavior and all minibuffer-only behavior
  remain unchanged; only `(WIDTH auto)` opts ordinary buffers into fitting.
- [ ] Short→long→short content and switching between unrelated buffers refit with
  unchanged frame/native session, anchored top/left, width, monitor and focus.
- [ ] Configured max and screen max cap growth; long content is readable with
  normal scrolling. Scrolling does not shrink the panel or move point unexpectedly.
- [ ] Timed/process-like insertions refit without keypresses, stop growing at the
  cap, preserve selection/view position, and stop affecting geometry on exit.
- [ ] Overlay content, wrapping, fonts, modes/headers, echo area and nested prompts
  are measured correctly; small legal frames do not trigger the prototype's
  negative minibuffer-height failure or a redisplay feedback loop.
- [ ] Multiwindow layout pauses fitting without deleting caller windows; returning
  to one ordinary window resumes it. Explicit numeric resize is respected.
- [ ] Limits/errors/dynamic bindings and cleanup are tested; core has no dependency
  on Launcher, Vertico, osx-dictionary, or gptel and no tool-specific state.
- [ ] Generic rendering/scrolling and old-mode regression screenshots are captured
  in the VM. Physical keyboard/IME/accessibility checks are accurately reported.

## Ownership correction

This replaces the abandoned plan to add `:completion 'vertico-buffer`,
`portal-launcher-vertico.el`, or `portal-launcher-continue-in-buffer` to Portal.
None belongs in this implementation. The application can own its entire interactive
command and return when finished; existing `portal-launcher-present` is the host.
Prototype commit `9005099` / PR #91 remains historical feasibility evidence only.

The caller-side implementation/configuration tasks are in the sibling launcher.el
repository: `tasks/full-buffer-experience.md`, `tasks/configurable-tool-routing.md`,
`tasks/apple-dictionary-example.md`, and `tasks/configuration-and-acceptance.md`.
They are not local task dependency IDs.

## Verification and completion record

Run host build/CTest/Bun/Python/byte-compilation/diff checks per `CONTRIBUTING.md`.
Run GUI checks only with `bash test/vm.sh ...`, retaining existing minibuffer and
persistent-buffer coverage. Measure actual Emacs/native dimensions and capture
short, capped-long, scrolled and shrunk-again states. No full user init/credentials
in the VM; no live configuration changes.
