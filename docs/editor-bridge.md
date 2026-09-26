# Persistent web editors and the shared event bridge

`NativeHost.swift` already owns frame lookup, native view placement, focus
handoff, and event routing for both WebKit and Ghostty. It remains independent
of feature state and persistence. An editor does not need another host or a
second keyboard monitor.

`NativeEventChannel.swift` is the nonblocking pipe transport. Portal views
share one channel instance, the notification pipe owned by `portal-view.el`
([terminal input bridge](terminal-input-bridge.md)). Web editors still have their
own instance, with the same descriptor lifetime, atomic short writes, and SIGPIPE
protection. Editor notifications identify a session with queued messages. Lisp's
`portal-view--consume-lines` handles partial and batched reads for both pipes.

No asynchronous AppKit or WebKit callback keeps an `emacs_env` or calls Lisp.
Callbacks notify an Emacs pipe process, and interactive commands are queued as
normal Emacs input events. `NativeInput.swift` and `portal-input.el` share prefix capture and dispatch
across terminals, editors, and previews; Ghostty retains terminal input handling.

## Document sessions

`WebEditor.swift` owns one persistent WKWebView per document. It reuses
`NativeHost.place`, `hide`, and `remove`. The view can move between panes and
frames; hiding does not destroy its JS state or undo stack. Existing disposable
HTML/Markdown previews retain their original lifecycle.

Only a hosted editor receives the script bridge, with a nonpersistent WebKit data
store. Messages are accepted only from its main frame at the expected local URL.
Navigation away from that URL is blocked. The editor page's CSP allows its local
scripts/fonts and embedded images, while blocking external network dependencies.

Emacs sends JSON messages through `portal--editor-send`; WebKit delivers messages
through `window.webkit.messageHandlers.portal`. Native code holds the message
payloads, including image data, outside the notification pipe. Lisp drains them
with `portal--editor-events`. Undelivered scene changes are coalesced. A full pipe
causes the editor to retry its notification, without dropping the scene.

The JS document reports `ready`, then Emacs supplies `load` with the buffer's
JSON. `loaded` establishes the normalized baseline. Subsequent `dirty` and
`change` messages update the buffer and its modified flag. Selection, viewport,
and other nonexported app state do not modify the document. Image data is included
using Excalidraw's `serializeAsJSON(..., "local")`.

## Saving and input

Emacs requests a `snapshot` with a monotonically increasing request ID before
saving. The page commits an active text editor and replies with the latest scene.
Only a matching reply completes the save barrier. Errors or timeouts abort the
write. A `write-contents-functions` guard also covers normal `save-buffer` and
save-all operations; `before-save-hook` is unsuitable because Emacs can catch its
errors and continue writing. Emacs writes through its normal save machinery and
sends `saved` only from `after-save-hook`. A failed write retains modified state.

The in-page Save button and Command-S queue an Emacs save for their owning
buffer. Keyboard input uses the shared Portal bridge: `C-b C-x C-s` resolves the
normal Emacs save command, including the editor's remapping, and returns focus
after the save and any filename prompt finish. `C-b d` and Command-Escape leave
control with Emacs. Escape, Control-G, and bare Control-X belong to the page.
Native escape releases pending input capture without waiting for a JS snapshot.

The buffer holds the latest synchronized JSON even if WebKit terminates. Explicit
reopen rebuilds the editor from that buffer; it does not silently reload a saved
file over unsaved work. Auto-save and backups follow Emacs configuration. The
debounced synchronization window is 150 ms, so a process crash can lose edits
that have not yet reached Emacs. Host restarts do not forcibly navigate editors;
reopen when their old asset URLs are no longer available.

## Verification

`./build.sh` compiles the browser assets and fonts into the relocatable host and
builds the native module. `bun run --cwd host typecheck` builds editor assets and
checks TypeScript. `ctest --test-dir build --output-on-failure` includes scene
persistence, save failures, stale replies, event framing, and terminal regressions.

The graphical tests require a disposable graphical Emacs with the test event
module from the README loaded. Load `test/portal-excalidraw-gui-tests.el`, then
run `M-x ert` with selector `^portal-excalidraw-gui-`. They exercise the actual
WKWebView, offline fonts, paste, image round trips, multiple documents, retained
sessions, and rapid shared-prefix handoff. The test-only JS evaluator is not
part of the production module.
