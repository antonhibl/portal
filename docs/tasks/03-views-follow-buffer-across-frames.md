# 03: Portal views follow their buffer into any frame

Type: AFK · Status: done

## What to build

A Portal view appears wherever its buffer is shown, in any frame (CONTEXT.md, *Portal view*). This behaviour depends on task 01 passing.

- **Placement across frames.** The placement rule in `portal-view.el` considers windows in every frame. When `portal--place` is given a different frame's title, it moves the view to that frame within the same call: remove, add, and re-bind the host and the input host.
- **Parking.** Swift keeps hidden views in one offscreen parking window. New views start there, and a view whose frame is deleted moves there, so its session survives.
- **Frame deletion.** `delete-frame-functions` hides the frame's views. The next sync places each one wherever its buffer is shown.
- **Terminal features stop being per frame.**
  - `portal-terminal`, next/previous cycling and index selection cover every terminal.
  - Each project has one quick terminal. The bottom panel and its remembered height stay per frame, because they are window layout.
  - Delete `portal-terminal--frame`, `--frame-buffers`, the "This terminal belongs to another frame" error, and the code that kills terminals when their frame is deleted.
- **Test helper.** Add a batch helper that creates a second frame as a terminal-mode frame on a pseudo-terminal:
  - `make-process` with `:connection-type 'pty`;
  - `make-frame` with the `tty` and `tty-type` ("xterm") parameters;
  - `set-frame-size` to make it large enough to split.

  This was checked in Emacs 31.1: the frame can be created and split, and `delete-frame-functions` fires when it is deleted.

## Acceptance criteria

- [x] Showing a terminal buffer in another frame moves its view there; the shell keeps running and scrollback survives (GUI test)
- [x] Deleting a frame hides its views, they reappear when their buffer is shown elsewhere, and no shell ends
- [x] One quick terminal per project, which can be summoned from any frame
- [x] Batch tests using a second pseudo-terminal frame cover moving between frames and frame deletion
- [x] The README is updated wherever it describes frame ownership and quick terminals (around lines 175, 209, 248, 272 and 637-642)

## Blocked by

- [01: Spike: a terminal view survives moving between frames and being parked](01-terminal-frame-spike.md)
- [02: Terminal views run on the shared Portal view lifecycle](02-terminal-views-shared-lifecycle.md)
