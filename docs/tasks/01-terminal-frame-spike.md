# 01: Spike: a terminal view survives moving between frames and being parked

Type: AFK (escalate on failure) · Status: todo

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

- [ ] Each of the four checks has a recorded pass or fail, and says how it was verified
- [ ] Findings are recorded under a `## Findings` heading in this file
- [ ] If any check fails, stop and ask the user to choose between fixing it and falling back to views pinned to their frame. If they choose the fallback, update ADR 0001 and CONTEXT.md, and keep task 03 blocked.
- [ ] No spike code is merged

## Blocked by

None; can start immediately.
