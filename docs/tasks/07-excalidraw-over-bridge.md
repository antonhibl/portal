# 07: Excalidraw talks to its buffer over the bridge

Type: AFK · Status: done

## What to build

Excalidraw becomes a hosted-app client that talks to its buffer over the bridge (CONTEXT.md, *Bridge*). Only hosted web views get a bridge. This task also finishes moving every view into the registry.

**Swift**
- The web kind gains the bridge, moved over from `WebEditorSession`.
  - Messages are accepted only from the main frame of a hosted view, at the app-host URL it loaded.
  - `portal--web-send TARGET JSON`
  - `portal--web-receive TARGET` returns all queued messages and re-arms the notification.
  - A `bridge TARGET` record goes out on the shared pipe once, and is not sent again until the queue is drained.
  - Using the bridge on a view that isn't hosted is an error.
- Delete:
  - `WebEditors` and `native/WebEditor.swift`;
  - the `portal--editor-*` exports;
  - `WebEditors.channel`;
  - the hard-coded `/excalidraw` URL check.
- Every view is now in the registry, so replace `NativeInput.inputs` and the view search in `NativeHost.toolbarAction` with registry lookups.

**Elisp: `portal-web.el`**
- Add `portal-web-send PLIST` and the buffer-local `portal-web-bridge-function`.
- Register the `bridge` record handler in `portal-view-record-handlers`.

**Elisp: `portal-excalidraw.el`**
- Open immediately with `(portal-web-open-hosted "/excalidraw/" "none")`, and sync the document through `portal-web-send` and the bridge function.
- Delete:
  - `--sync`, `--frame-deleted`, `--open`, `--channel`, `--receive`, `--receive-line`, `--buffers`, `--id` and `--close-all`;
  - the wait-until-ready before focusing.

**Elisp: other files**
- Delete `portal-native.el`, whose remaining helpers now live in `portal-view.el`.
- Remove the remaining buffer-local target and focus functions in `portal-input`.

## Acceptance criteria

- [x] Opening, editing, saving (`C-b C-x C-s`), reverting, and killing a buffer with unsaved changes all behave as today. Both the GUI Excalidraw suite and the batch persistence tests pass.
- [x] A web view that isn't hosted can't use the bridge: `portal--web-send` signals an error, and messages from its page are ignored
- [x] A batch test with the fake adapter shows a `bridge` record reaching the handler, and the bridge function receiving the messages in order
- [x] The native module exports exactly the 19 functions listed in ADR 0002, and nothing refers to the editor exports any more
- [x] `docs/editor-bridge.md` and the README are updated

## Blocked by

- [04: One notification pipe owned by portal-view.el](04-one-notification-pipe.md)
- [06: Hosted apps open immediately and load when the app host is ready](06-hosted-apps-open-immediately.md)
