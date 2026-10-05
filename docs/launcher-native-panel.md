# Dedicated launcher panel

`portal-launcher.el` owns one dedicated frame at a time; `native/Launcher.swift`
owns its NSPanel attachment. The C module converts arguments through the existing
`portal.h` platform interface. A launcher is not a Portal view kind and does not
start the app host, use a controller frame, or load a second native module.

```text
portal-launcher-show(buffer), or a session of portal-launcher-present
  validate build and native frame guard
  delete a frame made for the other presentation kind
  capture the previous application before frame creation/selection
  create hidden dedicated Emacs frame for the kind, if needed
  attach its EmacsView to a Swift NSPanel
  select the frame, place the panel, enable Emacs redisplay

portal-launcher-hide
  hide native panel and Emacs frame; retain buffer and windows
  restore the previously selected ordinary window

delete-frame / disable / unload / exit
  detach before deletion: return EmacsView and child windows to original window
  let Emacs delete its own frame
```

The original EmacsWindow retains its delegate throughout attachment. Its
`setAppearance` method reads that delegate's internal frame, so clearing it
caused the prototype's appearance crash. The Swift panel implements the bounded
NS compatibility methods for border width, appearance, accessibility value,
restacking and drag cancellation. There is no generic message forwarding,
runtime class swap, copied frame layout or Objective-C shim.

This code is restricted to GNU Emacs NS 31.1, revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`. The matching
[window declarations](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.h#L383)
and [window implementation](https://github.com/emacs-mirror/emacs/blob/a360712c9d272d950d8d8255ef74570f7e90b7d9/src/nsterm.m)
are internal interfaces. Future builds need explicit compatibility validation.
A native defect can crash Emacs; opt-in does not isolate the process.

## Native-role guard

Lisp guards `modify-frame-parameters` before any parameters in the request are
applied. It rejects role changes and drops unchanged role entries: even setting
`parent-frame` to its existing nil invokes an EmacsWindow-only method.
Other frames pass through unchanged. The dedicated frame's decorations,
fullscreen, parent, bars, minibuffer and focus policy cannot be repurposed.

Native-compiled Emacs functions can call primitive setters directly. With
`native-comp-enable-subr-trampolines` disabled, the native-compiled
`set-frame-parameter` bypassed the initial Lisp advice in the graphical test.
Enabling now verifies the validated build's installed trampoline registry after
adding advice, including the `delete-frame` trampoline used by sessions.
If a required trampoline is absent, it removes the hooks and refuses
to create a frame. It does not change the user's native compilation settings.
Emacs normally installs or compiles the trampoline when adding the advice.

The C attachment binding independently checks Emacs's version and revision.
The platform checks the donor classes, hidden state, decorations, parent/child
state and toolbar before moving anything. A failed first-responder handoff
restores the donor, including its content layer settings, before returning an
error. Disabling and detaching are idempotent. Deletion validation runs before
the pre-deletion hook so a refused deletion keeps the attachment and guard.

## Coordinates and measurements

All geometry uses AppKit logical points with a global bottom-left origin.
Offsets are right/down from the chosen screen's `visibleFrame` center. The
origin is floored to whole points to agree with Emacs's integer coordinates,
then size and position are clamped into the usable area. No backing-scale
conversion or character-cell rounding is applied.

The default screen is under the pointer. An explicit screen index is resolved
on every show; a missing index falls back to the pointer. While visible, the
panel reapplies placement on AppKit's display-arrangement notification, without
requesting focus again. Detaching removes that observer.

Measured in a disposable Emacs on 2026-10-03, with both displays at scale 2:

| Display | Global frame | Usable frame |
| --- | --- | --- |
| Gigabyte M32U | `(0, 0, 2560, 1440)` | `(0, 0, 2560, 1410)` |
| LG ULTRAFINE | `(2560, -483, 1440, 2560)` | `(2560, -483, 1440, 2530)` |

The following requested and actual rectangles were identical. Emacs's frame
pixel dimensions also matched each requested point size.

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

The tests also request 100000×100000 points with an offscreen offset and check
that the actual rectangle equals the usable screen. Standalone native checks
cover a synthetic screen with a negative X origin and deterministic display
change notification delivery. Physical monitor disconnect/reconnect was not
performed.

The graphical suite tests fonts Menlo 13/18/15 with dark/light/system appearance,
100 show/hide cycles, 20 frame deletion/recreation cycles, deletion with a live
child frame, disable/re-enable and ordinary-frame mutations. Native checks
independently exercise rollback and verify that closed panels leave AppKit's
window list after autoreleased objects drain.

The [README](../README.md#native-launcher-panel-opt-in) documents setup,
customization and test invocation. Plain buffer presentation refuses to hide an
active launcher minibuffer; command sessions unwind it as described below.
Outbound system drag-and-drop is cancelled. Full
IME candidate windows, VoiceOver and extended use with the user's configuration
remain in the daily-use validation task.

## User-configured launchers

The panel and global shortcuts are separate infrastructure. Portal chooses no
command and registers no chord: `portal-launcher-present` takes its function
as a required argument, and the launcher module neither loads
`portal-global-shortcut.el` nor sets a shortcut. A user's command calls
`portal-launcher-present` with its options and runs from M-x, an Emacs key or
`portal-global-shortcut-set`; the README's examples are the test fixtures, and
the batch and graphical tests evaluate them from the README itself.

`portal-launcher-mode` remains the panel's own state. Presenting or showing
enables it, which validates the build and installs the frame guards and
lifecycle hooks; disabling cancels a session, deletes the frame and removes
them. Neither touches a shortcut, so dismissal, hiding, deletion and disable
leave every registration, and evaluating the configuration again replaces each
name's registration rather than adding one. A press of any launcher's chord
during a session runs its command inside that session, whose second
invocation cancels the session and unwinds that command too: the chord
toggles the panel. If enabling fails while a panel frame is live, the guards
stay, since that frame must still detach before deletion.

Application discovery, search and input rules belong to the separate
launcher.el package, configured as in the README's recipe; the
[application notes](launcher-applications.md) record its upstream follow-ups.

## Command sessions

`portal-launcher-present` calls one interactive command, or function of no
arguments, synchronously inside a unique catch tag. Escape, C-g, hide, another
invocation and native focus loss throw to that tag, unwinding every nested
prompt before cleanup. Ordinary errors propagate through the same cleanup. The
original Emacs window (or its frame if that window was deleted) is selected
without an application activation request; when the launcher itself was
selected, that is the window it was shown from. Minibuffer ownership, display
rules and the emulation keymap are dynamically bound; no completion package
settings are rewritten.

Deletion advice catches requests before Emacs's active-minibuffer validation.
Delete and disable requests are performed once, after the command has unwound
and ownership is cleared. Normal deletion still restores the donor window in
`delete-frame-functions`. Commands that deliberately select other frames or
intercept arbitrary throws are outside this bounded interface.

The native `prepare` operation captures the previous `NSRunningApplication`
before `make-frame` or selection can activate Emacs. Re-presenting an already
visible panel retains it. Only cancellation/errors request restoration, and
only if the panel still owns the keyboard and the frontmost application is
the captured app or Emacs. Success and focus-loss cleanup never request app
activation. AppKit activation is asynchronous and system-controlled; see
[Apple's activation API](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)).

Panel `didResignKeyNotification`, workspace app activation, and a mouse-only
global event monitor emit `launcher-blur SESSION` through the existing pipe.
The latter two are needed because a nonactivating panel can retain AppKit key
status when another app receives input, including the already-frontmost app.
The app and mouse observers exist only while the panel is presented; they
require no Accessibility event tap. Native focus loss is coalesced once per
presentation and suppresses cancellation activation even if AppKit still
reports the panel as key. The process filter validates
and queues the ID; a special command-loop event unwinds the matching session,
including prompts with an overriding completion keymap. Stale IDs are rejected
both when queuing and dispatching. Hide/detach suppress their own notifications
and remove the app and mouse observers; detach also removes the panel observer.
There is no polling timer or extra process.

The event alone can be lost. Emacs reads an event as special only when it
arrives while Emacs waits for input. One queued while Lisp runs, such as a
command waiting for a process, is read later as an ordinary key, which fails,
and Emacs's error report, in a buffer or a minibuffer, discards all queued
input. So the session also records the ID, and a `post-command-hook`, which
each command loop runs as it starts and after every command, including one
that failed, dismisses a session that lost focus. Cleanup removes the
session's queued events.

## Presentation kinds

`portal-launcher-present` takes `:kind` and `:mode-line`. A `buffer`
presentation uses the frame described above, which has its own minibuffer. A
`minibuffer` presentation uses a minibuffer-only frame, `(minibuffer . only)`,
whose root window is the minibuffer, as M-x's
[present.el](https://github.com/xiaoxinghu/m-x/blob/main/elisp/present.el)
does; hiding a mode line would still leave the empty buffer window. The
native-role guard compares requests with the role of the frame's kind.

A frame's `minibuffer` parameter cannot change, so a request for the other kind
deletes the dedicated frame through the usual path, detaching it in
`delete-frame-functions`, and then creates one of that kind. The deletion comes
before the previous application is captured, since detaching forgets it. No
minibuffer is active then: a session refuses to start inside one and defers its
own deletions until it has unwound. In the graphical tests on 2026-10-04, a
session's show took 18–37 ms when it created a frame, as every change of kind
does, and 4–9 ms when it reused one. The native panel does not know the kind: attachment, placement and
focus handling are the same.

Both kinds have `portal-launcher-size`. In a minibuffer frame, the minibuffer
starts at the top of the text area and fills it; Vertico does not resize a root
minibuffer window, and unused lines stay blank below the candidates. The
session binds `resize-mini-frames` to nil, so a user setting cannot make Emacs
resize the frame under its native placement.

In a minibuffer session, `display-buffer-overriding-action` is
`display-buffer-no-window` with `allow-no-window`. Without it, Emacs puts a
buffer that a minibuffer-only frame displays, such as `*Completions*`, in the
last ordinary frame. The function runs with `*Portal Launcher*` current:
selecting a minibuffer-only frame would otherwise make the inactive
minibuffer's buffer current.

`:mode-line nil` sets the `mode-line-format` window parameter of each launcher
window to `none` before the panel shows, so buffers keep their own
`mode-line-format` elsewhere. A `window-buffer-change-functions` hook, added
for the session only, sets it on windows that redisplay finds new or showing
another buffer. Each window's earlier parameter is recorded first. Cleanup,
after hiding, deletes the windows the call created, keeping those from before
it, such as a split made in an explicitly shown panel, and restores the
recorded parameters. With mode lines, and in `portal-launcher-show`, window
parameters are left alone.

The graphical tests captured these from the surface Emacs drew into, so they
lack the panel's corners and shadow; the text is test output. Vertico in a
720×420 minibuffer panel, after typing `al` and Down:

![Vertico in a minibuffer panel](evidence/launcher-minibuffer-vertico.png)

A buffer panel split during the call, with each window's mode line, then with
`:mode-line nil`:

![A split buffer panel with mode lines](evidence/launcher-buffer-mode-lines.png)

![The same split with :mode-line nil](evidence/launcher-buffer-no-mode-lines.png)

## Persistent buffer panels

With `:keep-open t`, the session continues after its function returns:
`portal-launcher-present` enters a recursive edit inside the same catch tag,
so the panel's commands run with the session's emulation keymap, display
rules, minibuffer ownership and focus-loss handling still bound. Their prompts
open in the panel's minibuffer, and the panel's cancellation unwinds them
with the recursive edit. Every dismissal is one of the session's own:
Escape, C-g, `portal-launcher-hide` or `portal-launcher-cancel`, another
invocation, deletion and disable throw to the tag and cancel, and focus loss
throws `blur`. Leaving the recursive edit with `exit-recursive-edit` or
`abort-recursive-edit` cancels as well. The call then returns nil; the
function's value is discarded. `top-level` also hides the panel as a
cancellation, while unwinding the caller too. A minibuffer panel would have
nothing left to use, so `:keep-open t` with `:kind 'minibuffer` is rejected
before anything is shown.

The command loop of the recursive edit reports a later command's error and
keeps reading, so the panel stays usable. In batch Emacs, that report exits
Emacs, so the batch tests replace `command-error-function`. Cleanup is
unchanged: it hides the panel, deletes the windows the call created and kills
no buffer. Windows from before the call keep their last buffers until the
next presentation shows `*Portal Launcher*` in the selected one.

Emacs counts the recursive edit in mode lines: `%[` in the default
`mode-line-modes` shows brackets around the mode name while a persistent panel
is open, in every frame. A keyboard macro's end also ends a recursive edit;
the batch tests rely on it so that a test cannot wait for input.

A persistent hello-world panel with `:mode-line nil`, after its local `n`
command read a name from the panel's minibuffer:

![A persistent hello-world panel](evidence/launcher-persistent-hello.png)
