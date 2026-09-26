# 04: One notification pipe owned by portal-view.el

Type: AFK · Status: todo

## What to build

Every notification from the native module to Emacs travels on one pipe, which `portal-view.el` owns.

**Swift**
- One `NativeEventChannel`, owned by the registry.
- `portal--channel PROCESS` replaces `portal--input-channel`; passing nil disconnects.
- Record format: `TYPE TARGET FIELD…\n`, ASCII, space-separated, at most `PIPE_BUF` bytes, so every write is atomic.

**Elisp: `portal-view.el`**
- Creates the pipe process together with the first view.
- Splits incoming text into lines. `portal-native--consume-lines` moves here.
- Dispatches each record through `portal-view-record-handlers`, an alist of `("TYPE" . FUNCTION)`. Each handler:
  - is called with the target's buffer current;
  - runs inside the process filter, so it must never prompt; it queues commands through `unread-command-events`;
  - never sees records for unknown targets, which are dropped.

**Elisp: `portal-input`**
- Registers handlers for `prefix`, `binding`, `literal`, `cancel` and `escape`.
- Deletes its own pipe process, `portal-input--channel`, `--receive`, and the pipe part of `--connect`.
- Web views and Excalidraw editors also use `NativeInput`, so they must keep working on the shared pipe. `NativeInput.inputs` stays until task 07.

## Acceptance criteria

- [ ] Prefix handoff works in terminal views, web views and Excalidraw (the GUI input suites pass)
- [ ] A batch test shows that:
  - [ ] a record split across two reads is dispatched exactly once;
  - [ ] records batched into one read are each dispatched once, to the right handler, with the right buffer current;
  - [ ] a record for an unknown target is dropped
- [ ] The `portal--input-channel` export and `portal-input`'s pipe code are deleted
- [ ] `docs/terminal-input-bridge.md` is updated

## Blocked by

- [02: Terminal views run on the shared Portal view lifecycle](02-terminal-views-shared-lifecycle.md)
