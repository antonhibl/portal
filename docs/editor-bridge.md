# The bridge, and Excalidraw drawings over it

The bridge is the message channel between a hosted app and the buffer that
presents it (see [CONTEXT.md](../CONTEXT.md)). Only hosted web views get one.
Excalidraw is its first client: `portal-excalidraw.el` keeps a drawing buffer
and its Excalidraw page in sync over the bridge.

## Transport

A web view opened with `:hosted` gets a bridge when it opens (`WebBridge` in
`native/WebView.swift`). Other web views have none: `portal--web-send` and
`portal--web-receive` signal an error for them, and their pages have no
`window.webkit.messageHandlers.portal` to post to.

- **App to Emacs.** The page posts JSON objects to
  `window.webkit.messageHandlers.portal`. The bridge accepts a message only
  from the page's main frame, at the app-host URL that Emacs loaded last, and
  drops messages from frames and from other pages. Accepted messages wait in
  the bridge, outside the notification pipe, so large payloads such as images
  never cross it. A newer `change` message replaces one Emacs has not received
  yet; all other messages keep their order.
- **Notification.** The first waiting message sends one `bridge TARGET` record
  on the shared notification pipe that `portal-view.el` owns
  ([terminal input bridge](terminal-input-bridge.md#the-notification-pipe)).
  No other record goes out until Emacs has received the messages. If the pipe
  is full, the bridge retries the record, and keeps the messages.
- **Receiving.** `portal-web.el` handles `bridge` records. It calls
  `portal--web-receive TARGET`, which returns every waiting message as a JSON
  array and lets the next message send a new record. It then calls the
  buffer's `portal-web-bridge-function` with each message, as a plist, in
  order. The function runs inside the process filter, so it never prompts; it
  queues commands as Emacs input events.
- **Emacs to app.** `(portal-web-send PLIST)` calls `portal--web-send TARGET
  JSON`, which passes the object to `window.portalBridge.receive` in the page.
  If that call fails, the bridge queues an `error` message for Emacs.

A hosted page also reports to its bridge when a load fails or its web process
stops, as `error` messages. No asynchronous AppKit or WebKit callback
keeps an `emacs_env` or calls Lisp.

Hosted pages keep no cookies or storage between sessions, and never leave the
app host. The Excalidraw page's CSP allows its local scripts, fonts and
embedded images, and blocks external network requests. File inputs, such as
inserting an image, use the native file picker; opening and saving the drawing
stays in Emacs.

## Drawing sessions

`portal-excalidraw-mode` opens the drawing's view with
`(portal-web-open-hosted "/excalidraw/" "none")`, so the view appears at once
and loads the page once the app host is ready. The view follows the buffer's
selected pane like any Portal view; hiding it keeps the page's state and undo
history. Killing the buffer or changing its major mode closes the view.

The page reports `ready`, then Emacs sends `load` with the buffer's JSON.
`loaded` sets the normalized baseline. Later `dirty` and `change` messages
update the buffer and its modified flag. Selection, viewport and other state
outside the document do not modify it. Image data is included using
Excalidraw's `serializeAsJSON(..., "local")`.

## Saving and input

Before saving, Emacs sends `snapshot` with a request ID that only increases.
The page commits an active text editor and replies with the latest scene.
Only a reply with the matching ID completes the save barrier; errors or
timeouts abort the write. A `write-contents-functions` guard also covers
normal `save-buffer` and save-all operations; `before-save-hook` is unsuitable
because Emacs can catch its errors and carry on writing. Emacs writes through
its normal save machinery, and sends `saved` only from `after-save-hook`. A
failed write keeps the buffer modified.

The page's Save button and Command-S send `save`, which queues an Emacs save
for the drawing's buffer. The page still has the keyboard at that point, so the
save first returns focus to Emacs, which can then ask for a file name, and
focuses the page again afterwards. Keyboard input uses the shared Portal
prefix: `C-b C-x C-s` runs the normal Emacs save command, including the mode's
remapping, and returns focus after the save and any file name prompt finish.
`C-b d` and Command-Escape leave control with Emacs. Escape, Control-G and bare
Control-X belong to the page.

The buffer holds the latest synchronized JSON even if WebKit stops.
`portal-excalidraw-reopen` rebuilds the view from that buffer; it never
silently reloads a saved file over unsaved work. `revert-buffer` reads the
file, then reopens the view with it. Auto-save and backups follow Emacs
configuration. Changes are synchronized after 150 ms, so a web process crash
can lose edits that have not yet reached Emacs. App host restarts do not
reload drawings; reopen them if their old asset URLs are gone.

## Verification

`./build.sh` compiles the browser assets and fonts into the relocatable host
and builds the native module. `bun run --cwd host typecheck` builds the
Excalidraw assets and checks TypeScript.

`ctest --test-dir build --output-on-failure` runs the batch tests. With the
fake native module, `test/portal-web-tests.el` checks that a `bridge` record
reaches its buffer's bridge function with the messages in order, and
`test/portal-excalidraw-tests.el` checks that a drawing opens the Excalidraw
hosted app and loads over the bridge. The same file covers scene persistence,
save failures, stale replies and revert.

The standalone AppKit check in `test/native-focus.swift` (see the README)
checks the bridge in a real WebKit page: only the main frame's messages
arrive, in order, under one record until received, and a web view that is not
a hosted app has no bridge.

The graphical tests need a disposable graphical Emacs with the test event
module from the README loaded. Load `test/portal-excalidraw-gui-tests.el`, then
run `M-x ert` with selector `^portal-excalidraw-gui-`. They exercise the real
WKWebView, offline fonts, paste, image round trips, several drawings, revert,
hidden views keeping their state, and rapid shared-prefix handoff. The
test-only JavaScript evaluator is not part of the production module.
