# 02: Terminal views run on the shared Portal view lifecycle

Type: AFK · Status: done

## What to build

This is the first slice through the new architecture from end to end (see ADR 0001 and ADR 0002). Terminal views are opened, placed, hidden, focused and closed through `portal-view.el`, using the new native lifecycle calls addressed by target. They are tested in batch against a fake native adapter.

**Swift**
- Add one registry keyed by native target (`kind:id`), with a small protocol that each view kind implements. IDs are global and never reused. Register the terminal kind: today's `TerminalSession`, without `activeID` and without the optional-ID defaults.
- Add these exports:
  - `portal--open KIND OPTIONS`. Terminal options are `:directory`, `:theme` and `:quick`.
  - `portal--place TARGET EDGES TITLE`
  - `portal--hide TARGET`
  - `portal--close TARGET`
  - `portal--inspect TARGET`, which returns a plist, or nil for an unknown target.
- `portal--terminal-input` and `portal--terminal-text` become `portal--terminal-paste` and `portal--terminal-text`, and both require a target. The theme, themes and bindings exports stay as they are.
- Leave `NativeInput.inputs` and the view search in `NativeHost.toolbarAction` in place. Web views and Excalidraw editors still depend on them until task 07.

**Elisp: new `portal-view.el`**
- Interface:
  - functions: `portal-view-open KIND OPTIONS`, `portal-view-close`, `portal-view-target`, `portal-view-buffers`, `portal-view-sync`, `portal-view-focus`
  - variable: `portal-view-load-hook`
- It owns:
  - loading the native module;
  - the frame-title trick. Copy it from `portal-native.el`, which web views and Excalidraw keep using until task 07.
  - the placement rule. In order, it picks: the selected window, the view's current window, then another window showing the buffer. If none of those shows the buffer, the view is hidden.
  - the geometry cache;
  - the global hooks, which are installed only while at least one view exists;
  - closing the view from buffer-local `kill-buffer-hook` / `change-major-mode-hook` entries at depth 90.
- In this task a view stays in the frame it was opened in. Moving between frames is task 03.
- `portal-input` finds the target and focus function for terminal buffers through `portal-view-target` and `portal-view-focus`. Web and Excalidraw buffers keep their buffer-local functions until they move to the shared lifecycle.

**Elisp: `portal-terminal.el`**
- Open views with `portal-view-open`.
- Delete `--sync`, `--window`, `--geometry` and all the hook add/remove bookkeeping.

**Tests**
- Add `test/portal-fake-native.el`. It `provide`s `portal-native-module` and implements the lifecycle exports in memory, resolving TITLE by scanning `frame-list`.
- Add batch ERT tests that go through `portal-view.el`. Batch Emacs never runs window-change hooks, so tests call `portal-view-sync` themselves.
- Delete the `cl-letf` stubs of terminal natives in `test/portal-terminal-quick-tests.el`.
- Fix the references that have drifted: `test/portal-terminal-tests.el:205` (`portal-input--header`) and `test/portal-terminal-quick-tests.el:12` (`portal-terminal--channel`).

## Acceptance criteria

- [x] `M-x portal-terminal` opens a working terminal view
- [x] Split, selecting the other pane, `quit-window`, showing the buffer again and `kill-buffer` all follow ADR 0001: there is one view, it follows the selected pane, it is hidden rather than ended, and killing the buffer ends the shell
- [x] RET focuses the view, and the prefix and Command-Escape still work (the GUI terminal suite passes)
- [x] Batch tests through `portal-view.el` with the fake adapter cover:
  - [x] open
  - [x] split
  - [x] selection change
  - [x] `quit-window`
  - [x] showing the buffer in another pane
  - [x] `kill-buffer`
  - [x] no native call when nothing moved
  - [x] a failed open leaves nothing registered
- [x] The new batch suite runs under CTest
- [x] `portal--terminal-open/layout/focus/unfocus/close/state` and `Terminals.activeID` are deleted
- [x] No Elisp outside `portal-view.el` calls a native lifecycle function for terminals
- [x] The quick terminal still works (still per frame until task 03)
- [x] The README's terminal and architecture sections are updated

## Blocked by

None; can start immediately.
