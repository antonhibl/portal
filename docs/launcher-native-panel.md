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

The [README](../README.md#native-launcher-panel-opt-in) documents commands,
customization and test invocation. Plain buffer presentation refuses to hide an
active launcher minibuffer; command sessions unwind it as described below.
Outbound system drag-and-drop is cancelled. Full
IME candidate windows, VoiceOver and extended use with the user's configuration
remain in the daily-use validation task.

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
another buffer. Cleanup, after hiding, deletes all but the first launcher
window and clears the parameter; `portal-launcher-show` clears it too.

The graphical tests captured these from the surface Emacs drew into, so they
lack the panel's corners and shadow; the text is test output. Vertico in a
720×420 minibuffer panel, after typing `al` and Down:

![Vertico in a minibuffer panel](evidence/launcher-minibuffer-vertico.png)

A buffer panel split during the call, with each window's mode line, then with
`:mode-line nil`:

![A split buffer panel with mode lines](evidence/launcher-buffer-mode-lines.png)

![The same split with :mode-line nil](evidence/launcher-buffer-no-mode-lines.png)
