# Dedicated launcher panel

`portal-launcher.el` owns one dedicated frame; `native/Launcher.swift` owns its
NSPanel attachment. The C module converts arguments through the existing
`portal.h` platform interface. A launcher is not a Portal view kind and does not
start the app host, use a controller frame, or load a second native module.

```text
portal-launcher-show(buffer)
  validate build and native frame guard
  create hidden dedicated Emacs frame, if needed
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
adding advice. If that trampoline is absent, it removes the hooks and refuses
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
customization and test invocation. The later command-session task owns automatic
dismissal and active-minibuffer cancellation; this feature refuses to hide an
active launcher minibuffer. Outbound system drag-and-drop is cancelled. Full
IME candidate windows, VoiceOver and extended use with the user's configuration
remain in the daily-use validation task.
