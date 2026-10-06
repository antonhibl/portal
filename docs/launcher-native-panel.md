# Dedicated launcher panel

`portal-launcher.el` owns one dedicated frame at a time; `native/Launcher.swift`
owns its NSPanel attachment. The C module converts arguments through the
`portal.h` platform interface.
A launcher is not a Portal view kind: it neither starts the app host, uses a
controller frame nor loads a second native module.

```text
portal-launcher-show(buffer), or a session of portal-launcher-present
  validate build and native frame guard
  delete a frame made for the other presentation kind
  capture the previous application before frame creation/selection
  create hidden dedicated Emacs frame for the kind, if needed
  attach its EmacsView to a Swift NSPanel
  select the frame, place the panel, enable Emacs redisplay

automatic minibuffer height, during a session (layout only)
  redisplay of changed minibuffer content, via resize-mini-frames, and
  post-command-hook: measure the displayed minibuffer, then ask the panel
  for that height; it keeps its screen, left edge, width and top edge

portal-launcher-hide
  hide native panel and Emacs frame; retain buffer and windows
  restore the previously selected ordinary window

delete-frame / disable / unload / exit
  detach before deletion: return EmacsView and child windows to original window
  let Emacs delete its own frame
```

The original EmacsWindow retains its delegate throughout attachment:
`setAppearance` reads that delegate's internal frame, so clearing it crashed the
prototype. The Swift panel implements bounded NS compatibility methods for
border width, appearance, accessibility value, restacking and drag cancellation,
without generic message forwarding, runtime class swaps, copied frame layouts
or an Objective-C shim.

This code is restricted to GNU Emacs NS 31.1, revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`. The matching
[window declarations](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.h#L383)
and [window implementation](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.m)
are internal interfaces. Future builds need explicit compatibility validation.
A native defect can crash Emacs; opt-in does not isolate the process.

## Native-role guard

Lisp guards `modify-frame-parameters` before applying any requested parameters,
rejecting role changes and dropping unchanged role entries: even setting
`parent-frame` to its existing nil invokes an EmacsWindow-only method.
Other frames pass through unchanged. The dedicated frame's decorations,
fullscreen, parent, bars, minibuffer and focus policy are fixed.

Native-compiled Emacs functions can call primitive setters directly. With
`native-comp-enable-subr-trampolines` disabled, native-compiled
`set-frame-parameter` bypassed the initial Lisp advice in the graphical test.
Enabling now adds advice, then checks the validated build's installed trampoline
registry, including the session's `delete-frame` trampoline. If a required
trampoline is missing, it removes hooks and refuses frame creation without
changing native compilation settings. Emacs normally installs or compiles trampolines when adding advice.

The C attachment binding independently checks Emacs's version and revision.
Before moving anything, the platform checks donor classes, hidden state,
decorations, parent/child state and toolbar. A failed first-responder handoff
restores the donor and its content layer settings before returning an error.
Disabling and detaching are idempotent. Deletion validation precedes the
pre-deletion hook, preserving the attachment and guard if deletion is refused.

## Coordinates and measurements

Geometry uses AppKit logical points with a global bottom-left origin.
Offsets are right/down from the chosen screen's `visibleFrame` center.
The origin is floored to whole points, matching Emacs's integer coordinates;
size and position are then clamped to the usable area. There is no
backing-scale conversion or character-cell rounding.

The default screen is under the pointer. Each show resolves an explicit screen
index, falling back to the pointer if missing. While visible, the panel
reapplies placement on AppKit's display-arrangement notification without
requesting focus. Detaching removes that observer. Fitting a minibuffer panel's
content keeps the screen of its placement; see
[content-fitted minibuffer panels](#content-fitted-minibuffer-panels).

Measured in a disposable Emacs on 2026-10-03, with both displays at scale 2:

| Display | Global frame | Usable frame |
| --- | --- | --- |
| Gigabyte M32U | `(0, 0, 2560, 1440)` | `(0, 0, 2560, 1410)` |
| LG ULTRAFINE | `(2560, -483, 1440, 2560)` | `(2560, -483, 1440, 2530)` |

Requested and actual rectangles were identical; Emacs's frame pixel dimensions
also matched each requested point size.

| Size | Offset right/down | M32U actual x/y | LG actual x/y |
| --- | --- | --- | --- |
| 640×320 | 0 / 0 | 960 / 545 | 2960 / 622 |
| 640×320 | −137 / 81 | 823 / 464 | 2823 / 541 |
| 720×420 | 0 / 0 | 920 / 495 | 2920 / 572 |
| 720×420 | −137 / 81 | 783 / 414 | 2783 / 491 |
| 860×520 | 0 / 0 | 850 / 445 | 2850 / 522 |
| 860×520 | −137 / 81 | 713 / 364 | 2713 / 441 |
| 713×407 | 0 / 0 | 923 / 501 | 2923 / 578 |
| 713×407 | −137 / 81 | 786 / 420 | 2786 / 497 |

Tests also request 100000×100000 points with an offscreen offset and verify the
rectangle equals the usable screen. Standalone native checks cover a synthetic
negative-X-origin screen and deterministic display-change notifications.
Physical monitor disconnect/reconnect was not performed.

The graphical suite tests fonts Menlo 13/18/15 with dark/light/system appearance,
100 show/hide cycles, 20 frame deletion/recreation cycles, deletion with a live
child frame, disable/re-enable and ordinary-frame mutations. Native checks
independently exercise rollback and verify that closed panels leave AppKit's
window list after autoreleased objects drain.

The [launcher guide](launcher.md) documents setup and customization; the
[testing guide](testing.md#combined-graphical-suite) documents test invocation.
Plain buffer presentation refuses to hide an active launcher minibuffer; command sessions unwind it as described below.
Outbound system drag-and-drop is cancelled. These geometry checks did not
establish full IME, VoiceOver or normal-configuration behavior; the later
[daily-use record](launcher-daily-use.md#manual-acceptance-on-2026-10-04)
contains the user's manual acceptance.

## User-configured launchers

Panel and global shortcuts are separate. Portal chooses no command or chord:
`portal-launcher-present` requires a function, and the launcher module neither
loads `portal-global-shortcut.el` nor sets a shortcut. A user's command calls
`portal-launcher-present` with options and runs from M-x, an Emacs key or
`portal-global-shortcut-set`. Batch and graphical tests evaluate the launcher
guide's examples directly from `docs/launcher.md`.

`portal-launcher-mode` tracks panel state. Presenting or showing enables it,
validating the build and installing frame guards and lifecycle hooks. Disabling
cancels the session, deletes the frame and removes them. Neither touches
shortcuts: dismissal, hiding, deletion and disable preserve every registration;
re-evaluating configuration replaces each name's registration. Pressing any
launcher's chord during a session runs its command there; the second invocation
cancels the session and unwinds that command too, toggling the panel. If enabling
fails with a live panel frame, guards remain: it must still detach before deletion.

Application discovery, search and input rules belong to the separate
launcher.el package, configured as in the launcher guide's recipe; the
[application notes](launcher-applications.md) record its upstream follow-ups.

## Command sessions

`portal-launcher-present` synchronously calls one interactive command or
zero-argument function inside a unique catch tag. Escape, C-g, hide, another
invocation and native focus loss throw to that tag, unwinding all nested prompts
before cleanup. Ordinary errors propagate through the same cleanup. Selection
returns to the original Emacs window (its frame if deleted) without requesting
application activation; if the launcher was selected, this means its originating
window. Minibuffer ownership, display rules and the emulation keymap are
dynamically bound; completion package settings are untouched.

Deletion advice catches requests before Emacs's active-minibuffer validation.
Delete and disable run once, after command unwind and ownership clearance.
Normal deletion still restores the donor window in `delete-frame-functions`.
Commands deliberately selecting other frames or intercepting arbitrary throws
are outside this bounded interface.

Native `prepare` captures the previous `NSRunningApplication` before
`make-frame` or selection can activate Emacs; re-presenting a visible panel
retains it. Cancellation/errors request restoration only while the panel owns
the keyboard and the captured app or Emacs is frontmost. Success and focus-loss
cleanup never request activation. AppKit activation is asynchronous and
system-controlled; see
[Apple's activation API](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)).

Panel `didResignKeyNotification`, workspace app activation and a mouse-only
global event monitor emit `launcher-blur SESSION` through the existing pipe.
The latter two cover nonactivating panels retaining AppKit key status while
another app receives input, including the already-frontmost app. App and mouse
observers exist only during presentation, without an Accessibility event tap.
Native focus loss is coalesced once per presentation and suppresses cancellation
activation even if AppKit still reports the panel as key. The process filter
validates and queues the ID; a special command-loop event unwinds the matching
session, even with an overriding completion keymap. Queuing and dispatching
both reject stale IDs. Hide/detach suppress their own notifications and remove
app and mouse observers; detach also removes the panel observer. No polling
timer or extra process is used.

The event alone can be lost: Emacs treats it as special only if it arrives
while waiting for input. Events queued while Lisp runs, such as during a
process wait, are later read as ordinary keys and fail. Error reporting in
buffers or minibuffers discards all queued input. The session therefore also
records the ID. A `post-command-hook`, run at each command loop's start and after
every command, including failures, dismisses sessions that lost focus. Cleanup
removes the session's queued events.

## Presentation kinds

`portal-launcher-present` takes `:kind` and `:mode-line`. A `buffer`
presentation uses the frame above with its own minibuffer. A `minibuffer`
presentation uses `(minibuffer . only)`: the root window is the minibuffer, as
in M-x's [present.el](https://github.com/xiaoxinghu/m-x/blob/main/elisp/present.el).
Merely hiding a mode line would leave an empty buffer window. The native-role
guard compares requests against the frame kind's role.

A frame's `minibuffer` parameter is immutable. Changing kind therefore deletes
the dedicated frame normally, detaching in `delete-frame-functions`, then
creates its replacement. Deletion precedes capturing the previous application,
since detaching forgets it. No minibuffer is active: sessions refuse to start
inside one and defer their own deletions until unwound. In graphical tests on
2026-10-04, showing took 18–37 ms with frame creation (every kind change) and
4–9 ms with reuse. The native panel does not know the kind; attachment,
placement and focus handling are identical.

A minibuffer fills its frame's text area from the top. Vertico does not resize
a root minibuffer window, so at a fixed size unused lines stay blank below its
candidates. By default the panel fits that content instead, as described next;
every session binds `resize-mini-frames`, so a user's setting never resizes the
natively placed frame.

Minibuffer sessions bind `display-buffer-overriding-action` to
`display-buffer-no-window` with `allow-no-window`; otherwise Emacs displays
buffers such as `*Completions*` in the last ordinary frame. The function runs
with `*Portal Launcher*` current, rather than the inactive minibuffer buffer
that selecting a minibuffer-only frame would make current.

Before showing, `:mode-line nil` sets each launcher window's `mode-line-format`
parameter to `none`, preserving buffers' `mode-line-format` elsewhere. A
session-only `window-buffer-change-functions` hook does the same for windows
redisplay finds new or showing another buffer. Each window's previous parameter
is recorded before changing it. After hiding, cleanup deletes call-created windows, preserves
pre-existing ones (such as an explicitly shown panel's split) and restores
recorded parameters. With mode lines, or in `portal-launcher-show`, window
parameters remain untouched.

Graphical tests captured Emacs's drawing surface, excluding panel corners and
shadow; the text is test output. Vertico in a 720×420 minibuffer panel after
`al` and Down:

![Vertico in a minibuffer panel](evidence/launcher-minibuffer-vertico.png)

A buffer panel split during the call, with each window's mode line, then with
`:mode-line nil`:

![A split buffer panel with mode lines](evidence/launcher-buffer-mode-lines.png)

![The same split with :mode-line nil](evidence/launcher-buffer-no-mode-lines.png)

## Content-fitted minibuffer panels

`portal-launcher-size` resolves per presentation, before anything is shown or
an active session is cancelled: nil gives a minibuffer panel `(720 auto)` and a
buffer panel `(720 420)`; `(WIDTH auto)` is rejected for buffer panels, which do
not fit arbitrary buffers; numeric pairs stay fixed for both kinds. Only an
automatic minibuffer presentation fits. Its session binds `resize-mini-frames`
to `portal-launcher--fit` and adds `portal-launcher--refit` to
`post-command-hook`; fixed presentations bind it to nil. The binding unwinds
and cleanup removes the hook on every exit path, and the option keeps its value:
no measured height replaces it. There is no timer or polling.

Emacs calls `resize-mini-frames`' function from `resize_mini_window` while it
redisplays a selected, active minibuffer window whose buffer changed, after
the commands, timers and completion UI that changed it (pinned
[xdisp.c](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/xdisp.c),
`redisplay_internal`). That covers typing, Vertico's `post-command-hook`
updates and timer-driven changes without a key press. It can miss a nested
prompt starting or ending: `set_window_buffer` keeps the window's record of the
previous buffer's change count, which can exceed the next buffer's. A command
loop runs `post-command-hook` as each prompt starts, and the command that read
an inner prompt ends with it in the outer one, so the session refits there too.
A GUI regression whose outer prompt changed less than its inner one fails
without that hook.

Measurement uses `window-text-pixel-size` on the panel's minibuffer window at
its current width, with no positions or line options, capped at the display's
height. It follows the display iterator: wrapped input, faces of other heights,
line spacing and end-of-buffer overlay strings count, both Vertico's
before-string and an after-string, and a final newline in either adds no row.
The frame's height minus the window's body height adds internal borders and any
header line once. On NS, Emacs's frame pixels are AppKit points. [Height
limits](#height-limits-and-legal-frame-heights) then bound the measurement, by
default to at least 100 points. An echo-area message temporarily puts its own
buffer in the minibuffer window; fitting skips it, keeping the input's height,
so a long message neither flickers the panel nor leaves it the wrong size.
Messages Emacs shows inline in an active minibuffer are minibuffer content and
fit.

The fit function passes the measured height to the session's bounded request,
described below, which asks the native panel only for a height that differs
from the last one it asked, through `portal_launcher_fit` with the session's
native presentation ID. The platform ignores a stale ID, a hidden panel or an
unchanged rectangle. Otherwise it keeps the placement's screen, left edge, width
and top edge, clamps the bottom edge to that screen's usable area and sets the
panel frame without drawing. It never resolves the pointer's screen, starts a
session, resets recorded focus loss, captures the previous application or
requests key or first-responder status, so IME marked text stays in the same
view. Emacs NS's `resizeWithOldSuperviewSize:` only queues the frame size change
and marks the frame for redisplay: no nested redisplay, which Emacs would
answer by throwing to top level
([nsterm.m](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.m)).
The next redisplay draws the same content at the new size, measuring the same
height, so fitting cannot loop. AppKit keeps the layer's contents top-left
while the frame catches up.

The first placement uses the content's height at presentation, before the
function's prompt, which is normally the minimum, centered by the offset and
screen settings; it never opens taller than its content. That rectangle's top
edge is the anchor; later fits move only the bottom edge. A display-arrangement
change places the current height again, possibly on the pointer's screen, and
later fits keep that new top edge. The next presentation resolves screen and
offset afresh.

Graphical tests in a disposable Emacs on 2026-10-05, with Menlo 24 (28-point
lines) and 16-point internal borders, on the displays measured above:

| Content | Native and Emacs frame height |
| --- | --- |
| Prompt and five after-string rows (also five Vertico rows) | 200 |
| Two rows | 116 |
| No rows, or a nested one-line prompt | 100 (minimum) |
| Five rows, line spacing 6 | 236 |
| Five rows, one at face height 1.5 | 213 |
| Vertico with a group title and two candidates | 144 |
| Input wrapped to five lines, no rows | 172 |
| 300 rows, top edge 632 on the LG display | 1115, bottom edge at the usable area's −483 |

Each step kept the native session ID, key status, left and top edges, and the
Emacs frame matched the native height. Vertico gave the same heights with
`vertico-resize` set to `grow-only`, t and nil, and its settings and the
minibuffer resize options were unchanged afterwards. Moving the pointer to the
other display while typing left the panel on its display. A fixed `(720 240)`
control stayed 240 points. Standalone native checks cover the anchored
geometry on negative-origin and offset placements, clamping, stale sessions,
hidden panels, unchanged sessions, responder and focus-loss state, and
display-change reanchoring. Marked text set through Emacs's NS text-input
client stayed through a resize from 200 to 116 points and then committed;
a physical input method and display disconnection were not tested.

Vertico in a fitted panel with five rows, then after typing `alp`, then with no
matches at the minimum:

![Five Vertico rows with group titles](evidence/launcher-minibuffer-fitted-rows.png)

![Two candidates under one group title](evidence/launcher-minibuffer-fitted-filtered.png)

![No matches at the minimum height](evidence/launcher-minibuffer-fitted-minimum.png)

### Height limits and legal frame heights

`portal-launcher-height-limits`, `(MIN MAX)`, is validated with the size before
anything is shown or cancelled: MIN is `content` or a positive fixnum, MAX nil
or a positive fixnum, and a numeric MIN at most MAX. An automatic session keeps
the value it started with, so later bindings and fitting leave both the session
and the option unchanged; a fixed session has no limits.

`portal-launcher--request-height SESSION HEIGHT` is the one resizing path. The
minibuffer fitter calls it, and so will fitters of other content. It takes the
session object, never a raw native ID, and does nothing unless that session is
still current, automatic and visible, so a timer from a finished presentation
cannot resize a newer one. It bounds HEIGHT to the larger of the legal height,
a numeric MIN and HEIGHT capped at MAX, skips a height equal to the last one it
asked and calls `portal_launcher_fit`. The first placement bounds its measured
height the same way. Every limit error is therefore found by the static
validation above, before a session is cancelled or a frame replaced.

The legal height is `frame-windows-min-size` with IGNORE t, in pixels, plus the
frame's pixel height minus its inner height (internal borders and any tab bar),
or the frame's `min-height` parameter in lines when that is larger. IGNORE t is
the minimum that `resize_frame_windows` falls back to as a frame shrinks: one
line of each window's text with its tab, header and mode lines, ignoring
`window-min-height` and rounded up to whole lines unless
`window-resize-pixelwise`; the minibuffer window adds its line. Native resizes
reach Emacs through `change_frame_size`, whose `adjust_frame_size` keeps the
frame at least `frame-windows-min-size` with IGNORE `safe` plus borders, which
is never larger
([frame.c](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/frame.c),
[window.c](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/window.c)).
A shorter panel would leave Emacs's frame taller than its view, cutting off the
minibuffer, and could give a window less than a line. Portal changes neither
`window-min-height` nor the safe minima. The C bindings and the platform accept
any positive height: the floor is Lisp policy from Emacs's own window rules,
not a native constant, and numeric `portal-launcher-size` heights still start
at 100.

A MAX below the legal height is not an error: the legal height wins over it,
including when it grows later in a presentation, as with a larger font.
Checking it as an error would need the frame, with its font, which a
presentation may first create or replace, and a second invocation cancels the
active session before presenting anything; failing there would already have
dismissed or replaced the existing panel. The monitor wins over all: the
platform clamps the bottom edge to the usable area, even below MIN or the legal
height.

Graphical tests in a disposable Emacs in the macOS test VM on 2026-10-06, on its
"Apple Virtual" display (usable area `(0, 74, 1326, 742)`, scale 2), with Menlo
24 (28-point lines) and 16-point internal borders. Steps go from five rows of a
minibuffer panel to two, none and five again:

| Limits | First placement | Five rows | Two rows | No rows | Five rows again |
| --- | --- | --- | --- | --- | --- |
| `(100 nil)`, the default | 100 | 200 | 116 | 100 | 200 |
| `(80 nil)` | 80 | 200 | 116 | 80 | 200 |
| `(content nil)` | 60 | 200 | 116 | 60 | 200 |
| `(content 144)` | 60 | 144, clipped | 116 | 60 | 144, clipped |
| `(content 1)` | 60 | 60, clipped | 60, clipped | 60 | 60, clipped |

The legal height of that minibuffer frame was 60 points: one line and both
borders, which also overrode the 1-point maximum. At 144 points the text measured 168 points in a 112-point body, the
prompt staying at the top. Each step kept the native session ID, key status,
left and top edges and width, and Emacs's frame matched the native height.
Marked text stayed through a resize from 200 to 116 points at `(content nil)`
and committed; the committed text's fallback font then fitted 65 points.

A normal frame, with a buffer window above its own minibuffer, in place of the
buffer fitting that a later task adds: with Menlo 13 (15-point lines), a
request for 1 point gave its legal height, 77 points with the mode line (a text
line, the mode line, the minibuffer's line and both borders) and 62 without.
Emacs's frame matched, one text line showed, and the minibuffer read input.
A maximum of 300 points capped a request for 100000. Standalone native checks
cover placing and fitting heights below 100 points, including on offset and
negative-origin placements, after display changes, and rejecting zero and
negative heights.

A minibuffer panel at `(content 144)`, five rows capped at 144 points, then at
its 60-point legal height with no matches:

![Five rows capped at the maximum](evidence/launcher-minibuffer-limited-maximum.png)

![The legal minimum: the prompt alone](evidence/launcher-minibuffer-legal-minimum.png)

A normal frame at its legal height, with and without the mode line, reading a
name in its minibuffer:

![A normal frame at its legal height](evidence/launcher-buffer-legal-minimum.png)

![The same without the mode line](evidence/launcher-buffer-legal-minimum-no-mode-line.png)

## Persistent buffer panels

With `:keep-open t`, `portal-launcher-present` enters a recursive edit inside
the same catch tag after its function returns. Panel commands retain the
session's emulation keymap, display rules, minibuffer ownership and focus-loss
handling. Their prompts use the panel's minibuffer; cancellation unwinds both
prompts and recursive edit. Every dismissal belongs to the session:
Escape, C-g, `portal-launcher-hide`, `portal-launcher-cancel`, another invocation,
deletion and disable throw to the tag and cancel; focus loss throws `blur`.
`exit-recursive-edit` and `abort-recursive-edit` also cancel. The call returns nil,
discarding the function's value. `top-level` cancels and hides the panel while
also unwinding the caller. Since a minibuffer panel would have nothing left to
use, `:keep-open t` with `:kind 'minibuffer` is rejected before showing.

The recursive command loop reports later command errors and keeps reading,
leaving the panel usable. Reporting exits batch Emacs, so batch tests replace
`command-error-function`. Cleanup still hides the panel, deletes call-created
windows and kills no buffers. Pre-existing windows retain their last buffers
until the next presentation shows `*Portal Launcher*` in the selected window.

While a persistent panel is open, `%[` in the default `mode-line-modes` brackets
the mode name in every frame, reflecting the recursive edit. Ending a keyboard
macro also ends a recursive edit; batch tests rely on this to avoid waiting for
input.

A persistent hello-world panel with `:mode-line nil`, after its local `n`
command read a name from the panel's minibuffer:

![A persistent hello-world panel](evidence/launcher-persistent-hello.png)
