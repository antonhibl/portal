# 01: Spike: a terminal view survives moving between frames and being parked

Type: AFK (escalate on failure) · Status: done

## What to build

This is a throwaway check that verifies, in a GUI, the assumption behind making Portal views follow their buffer into any frame (CONTEXT.md, *Portal view*). None of this code gets merged. Record the findings in this file so task 03 can build on them.

Check each of the following:

1. **Moving between frames.** Move a Ghostty terminal view from one Emacs frame's content view into another's inside a single native call. Remove it from the old frame and add it to the new one, then re-bind both `NativeHost` and `NativeInput.host`, the same way `native/WebEditor.swift` `layout(title:edges:)` does today. The shell must keep running and scrollback must survive.
2. **Parking.** Create a terminal view inside an offscreen parking `NSWindow` that is never shown. Its Ghostty surface must exist, and the shell must keep draining output while parked. For example, `yes | head -c 10000000` must finish.
3. **Leaving parking.** Move a parked view back into a visible frame. It must render and accept input.
4. **Frame deletion.** Deleting an Emacs frame must close its `NSWindow`, and that close must be observable (for example through `willClose`), so parking can react to it.

What reading the code suggests (not run):
- `build/swift/checkouts/libghostty-spm/Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView+Lifecycle.swift`:
  - lines 64-68: the surface is kept and resynced when the view enters a window;
  - lines 107-110: leaving a window only stops the display link;
  - lines 139-142: the view can move directly between windows.
- Caveat: while the view has no window, the Ghostty surface coordinator (`TerminalSurfaceCoordinator.swift`, around lines 213-222) processes no wakeups. So the remove and the add must happen in the same call.

## Acceptance criteria

- [x] Each of the four checks has a recorded pass or fail, and says how it was verified
- [x] Findings are recorded under a `## Findings` heading in this file
- [x] If any check fails, stop and ask the user to choose between fixing it and falling back to views pinned to their frame. If they choose the fallback, update ADR 0001 and CONTEXT.md, and keep task 03 blocked. (No check failed.)
- [x] No spike code is merged

## Blocked by

None; can start immediately.

## Findings

All four checks pass. Views can follow their buffer into any frame, so task 03 can go ahead.

Run on 2026-09-26 with Emacs 31.1 (NS), macOS 27.0, and libghostty-spm 1.6.20260909 (pinned in `native/Package.resolved`). The full run was done twice, with the same results both times.

### How it was verified

- **Spike code.** Temporary native exports were added in a worktree: move, park, detach, watch `willClose`, and inspect the view's window and Ghostty's rendered pixels. The code was then reverted.
- **Driver.** A scripted `emacs -Q` session drove real shells through those exports, across two frames plus a third that check 4 deletes.
- **Evidence.** Each check relied on:
  - `portal--terminal-text` for scrollback;
  - the shell writing `$$` to a file, to compare PIDs;
  - commands that write a marker file when they finish, to show the shell drained its output;
  - real AppKit key events from `test/terminal-input.m`.
- **Rendering.** Screen capture is not permitted in this environment. Rendering was checked instead by sampling the IOSurface behind Ghostty's `IOSurfaceLayer`.

### 1. Moving between frames: pass

The move worked the same way as `WebEditorSession.layout(title:edges:)`, all in one native call:
1. `host.remove(terminal)`;
2. `session.host = next` and `input.host = next`. This needs `TerminalSession.host` to become a `var`;
3. `next.place(terminal, rectangle:)`, then `setSurfaceVisible(true)` and `fitToSize()`.

Results:
- **Placement.** The view ended up in frame B's window and was visible. The grid resized from 73x19 to 81x22 to fit B's pane.
- **Shell.** The shell PID was the same before and after the move.
- **Output during the move.** A loop was printing `tick-1`…`tick-60` when the move happened. It finished, and every line is in the text.
- **Scrollback.** 3000 lines printed before the move are all still there, from the first to the last.
- **Keyboard.** `echo keyed` typed as AppKit key events into frame B reached the shell. The new host routes keys to the view.
- **Stress.** The view made 40 moves between A and B while `yes | head -c 20000000` ran. The stream finished, and the PID did not change.

### 2. Parking: pass

The parking window is a borderless `NSWindow` placed offscreen, with `isReleasedWhenClosed = false`. It is never ordered in. The spike bound its `NativeHost` by window reference, through a `bind(window:)` split out of `bind(title:)`. Parked views were also hidden (`host.hide`) and occluded (`setSurfaceVisible(false)`).

Results:
- **Creation.** A terminal created in the parking window had a Ghostty surface right after it was placed. The 960x640 parking frame gave a 112x32 grid.
- **Draining output.** `yes | head -c 10000000` finished while parked, in 8.5 to 9.7 s.
- **Mailbox.** 2000 OSC title changes finished while parked, and the title delegate saw the last title. So the app mailbox is drained too, not just the PTY.
- **Visible to parked.** A view that was visible in a frame kept draining after moving into parking, with the same PID.
- **Speed.** Draining 10 MB in the same terminal took:

  | State | Seconds |
  |---|---|
  | Visible | 12.6 |
  | Hidden in its frame (today's hiding) | 10.5 |
  | Parked | 10.8 |
  | Visible again | 12.9 |

  Parking costs nothing compared with today's hiding.

A negative control confirmed the caveat above. A view removed from its window and not added anywhere stalls: the title loop was still unfinished after 5 s. Once the view was added back, the loop finished within 0.03 s. Hiding and the occluded flag do not stop draining. Having no window does. So a view must always be in a frame window or the parking window, and every move must happen inside one call.

### 3. Leaving parking: pass

A terminal that had been parked since it was created was moved into frame A.

Results:
- **Placement.** It sat in A's window, visible, with a 73x19 grid for its pane. The shell PID had not changed.
- **Rendering.** The IOSurface was 1260x728 pixels, which is the 630x392 point pane, less the 28 point toolbar, at 2x scale. After `clear`, about 2,500 sampled pixels differed from the background. After printing 15 rows of `#`, about 74,000 to 96,000 did, and the surface seed moved on. So Ghostty draws into its new frame.
- **Keyboard.** `echo typed`, typed as AppKit key events, reached the shell.

### 4. Frame deletion: pass

- **Close.** `delete-frame` closes the frame's `NSWindow`. `NSWindow.willCloseNotification` fired for that window, and afterwards the window was no longer visible.
- **Order.** `delete-frame-functions` runs first. When the hook ran, the window was still visible and `willClose` had not fired yet. So Elisp can hide a frame's views in `delete-frame-functions`, as task 03 plans, and `willClose` can act as a backstop in Swift.
- **Rescue.** When `willClose` fired, the terminal was still inside the closing window. Moving it to parking from the handler kept the shell alive (same PID). Later, the terminal showed in frame A with its scrollback intact.
