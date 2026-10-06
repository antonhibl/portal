---
id: launcher-buffer-content-fit
status: done
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

### Refinements recorded at implementation

- Fitting is a presentation feature. `(WIDTH auto)` fits a buffer panel during
  `portal-launcher-present`; `portal-launcher-show` outside a presentation keeps
  the old error for an automatic size, since nothing would end the observation.
- The legal frame height now honors `window-min-height`
  (`frame-windows-min-size` with IGNORE nil instead of t). Emacs's
  `window--resize-mini-window` limits a minibuffer resize by the root window's
  height minus its `window-min-height` minimum; below that minimum every resize,
  even by zero, gives a negative minibuffer height and `args-out-of-range`.
  That is the prototype's failure, and Vertico resizes the minibuffer this way
  in every normal frame. Minibuffer-only panels are unchanged (one line either
  way). A buffer panel's least height is therefore four lines of window with
  Emacs's default; users can lower `window-min-height`. This changes the
  prerequisite's "IGNORE t" refinement for normal frames only.
- The minibuffer counts as its one line, or as an active prompt's displayed
  height (once, if the buffer window shows the same buffer).
  `resize_frame_windows` resets the minibuffer window to one line on every
  frame resize, so counting an echo-area message's height oscillated (grow,
  reset, shrink) on every redisplay in an instrumented VM run. Echo messages
  therefore never resize the panel; Emacs shows them as in any frame.
- Commands are fitted from `post-command-hook`, before redisplay, so a window
  never shows a command's change at the old size. Timers, processes and echo
  messages are fitted from `pre-redisplay-function` on every redisplay: its
  window list omits minibuffer windows, so filtering by it missed changes. When
  all of the buffer fits but the window scrolled while the panel was still
  short, the window start returns to `point-min` (NOFORCE; point never moves).
- A split panel requests its own height, so the bounded request still raises
  it to the split layout's legal height ("freeze at the current legal height").

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

- [x] Fixed/default ordinary buffer behavior and all minibuffer-only behavior
  remain unchanged; only `(WIDTH auto)` opts ordinary buffers into fitting.
- [x] Short→long→short content and switching between unrelated buffers refit with
  unchanged frame/native session, anchored top/left, width, monitor and focus.
- [x] Configured max and screen max cap growth; long content is readable with
  normal scrolling. Scrolling does not shrink the panel or move point unexpectedly.
- [x] Timed/process-like insertions refit without keypresses, stop growing at the
  cap, preserve selection/view position, and stop affecting geometry on exit.
- [x] Overlay content, wrapping, fonts, modes/headers, echo area and nested prompts
  are measured correctly; small legal frames do not trigger the prototype's
  negative minibuffer-height failure or a redisplay feedback loop.
- [x] Multiwindow layout pauses fitting without deleting caller windows; returning
  to one ordinary window resumes it. Explicit numeric resize is respected.
- [x] Limits/errors/dynamic bindings and cleanup are tested; core has no dependency
  on Launcher, Vertico, osx-dictionary, or gptel and no tool-specific state.
- [x] Generic rendering/scrolling and old-mode regression screenshots are captured
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

### Completion record, 2026-10-07

Implemented from base `865da69` on branch `task/launcher-buffer-content-fit`.
Host: macOS 27.0.1 on Apple Silicon, GNU Emacs NS 31.1 at
`a360712c9d272d950d8d8255ef74570f7e90b7d9`, Swift 6.4, Bun 1.3.14, CMake 4.0.3.
VM: macOS 27.0.1 guest, same Emacs build, one "Apple Virtual" display, usable
area `(0, 74, 1326, 742)`, scale 2. No native code changed.

Host checks, all passed: `./build.sh`; `ctest --test-dir build
--output-on-failure`, 34 of 34, including `launcher` (48 tests); `bun run --cwd
host check` and `typecheck`; `python3 -B -m unittest discover -s test -p
'test_*.py'`; `git diff --check`; byte compilation of `portal-launcher.el` and
both launcher test files without warnings. Fourteen mutants of
`portal-launcher.el` (legal height ignoring `window-min-height`, the minibuffer
at its own height, no final-newline line, a prompt counted twice, no least
window height, measuring from the window start, no measuring limit, no start
reset, no redisplay observer, `resize-mini-frames` bound for buffer panels, a
numeric resize that keeps fitting, `portal-launcher-show` fitting outside a
presentation, no `post-command-hook` refit for buffer panels, the observer left
installed) each failed a targeted batch test.

Review round 1: Codex reported that the redisplay observer could be installed
and removed on a buffer's own `pre-redisplay-function`. `add-function` already
turns a bare symbol into its default value, as its docstring says, and both
spellings expand alike; by the user's choice the calls now name
`(default-value 'pre-redisplay-function)` explicitly, and a batch test starts
and ends presentations from buffers with their own value. That test and the
existing ones failed for mutants installing or removing on the local value.

VM checks through the new `bash test/vm.sh sh test/launcher-gui.sh`, the whole
launcher graphical suite with its daily-use checks in one disposable `emacs -Q
--module-assertions`: 38 tests, 37 passed, 0 failed, 1 skipped in 131 s. The
skip, `portal-launcher-gui-minibuffer-panel-stays-on-its-display`, needs a
second display. The existing minibuffer, fixed-size, mode-line, persistent and
session tests passed unchanged, and their screenshots were captured as well.
Measured heights and the new screenshots are in `docs/launcher-native-panel.md`,
section "Content-fitted buffer panels", and its legal height section.

GNU ELPA was unreachable from host and VM again. The host build reused the main
checkout's extracted, hash-checked packages. For the VM runs only,
`CMakeLists.txt` temporarily copied those same packages from an untracked
directory; the edit and directory were removed before committing.

Not tested: a physical input method or keyboard, VoiceOver with a fitted buffer
panel, a second display or monitor disconnection, and real third-party result
UIs (gptel, a dictionary, launcher.el's buffer experience); streams and
overlays were synthetic. `vertico-buffer` was not run: it sizes its candidate
count from the window's height, so a fitted panel settles wherever that leads;
the double-display rule was tested with the prompt shown in the buffer window
directly.
