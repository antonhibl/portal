# The bridge, and Excalidraw drawings over it

The bridge is the message channel between a hosted app and the buffer that
presents it (see [CONTEXT.md](../CONTEXT.md)). Only hosted web views get one.
Excalidraw is its first client: `portal-excalidraw.el` keeps a drawing buffer
and its Excalidraw page in sync over the bridge.

## Transport

The C core owns the bridge (`native/Core/web.c`); the platform, WebKit on
macOS, only delivers messages and reports what it observed. A web view opened
with `:hosted` gets a bridge when it opens. Other web views have none:
`portal--web-send` and `portal--web-receive` signal an error for them, their
pages have no `window.portalBridge`, and the core drops anything they post.

- **The app's interface.** Before any of a hosted page's own scripts run, on
  every load and reload, Portal defines `window.portalBridge` in its main
  frame. The app posts JSON objects with `portalBridge.postMessage(object)`,
  and sets `portalBridge.receive` to an async function that takes Emacs's
  messages (`host/bridge.d.ts`). Hosted app source never names WebKit: only
  the platform's bootstrap glue, in `native/WebView.swift`, connects
  `postMessage` to `window.webkit.messageHandlers.portal`.
- **App to Emacs.** The platform checks that a posted message is a JSON
  object and passes it to the core as JSON text, with its `type` and what
  WebKit says about the frame that posted it: whether it is the main frame,
  and the URL of its document. The core accepts a message only from the main
  frame, at the app-host URL that Emacs loaded last; whatever the page claims
  about itself is not evidence. It drops messages from frames, from other
  pages, and with a type the core itself sends. Accepted messages wait in the
  core, outside the notification pipe, so large payloads such as images never
  cross it. A newer `change` message replaces one Emacs has not received yet;
  all other messages keep their order.
- **Notification.** The first waiting message sends one `bridge TARGET` record
  on the shared notification pipe that `portal-view.el` owns
  ([terminal input bridge](terminal-input-bridge.md#the-notification-pipe)).
  No other record goes out until Emacs has received the messages. The pipe
  delivers the record in order with every other record, waiting while the
  pipe is full.
- **Receiving.** `portal-web.el` handles `bridge` records. It calls
  `portal--web-receive TARGET`, which the core answers with every waiting
  message as a JSON array, letting the next message send a new record. It
  then calls the buffer's `portal-web-bridge-function` with each message, as
  a plist, in order. The function runs inside the process filter, so it
  never prompts; it queues commands as Emacs input events.
- **Emacs to app.** `(portal-web-send PLIST)` calls `portal--web-send TARGET
  JSON`. The core asks the platform to pass the object to the page's
  `portalBridge.receive`, as data rather than script text. If that fails,
  such as when the app has not set `receive`, the core queues an `error`
  message for Emacs, unless the page has changed since: each message carries
  the page it went to, and a late failure from an old page is dropped.

The core adds its own messages, which an app cannot post. It sends `page`
with the URL of each page a hosted view commits, including after Back and
Forward, and `error` when a load fails or the web process stops. A click on a
local `file:` link sends `follow` with its URL, and a Markdown preview's
**Open in Emacs** sends `edit`; both first give Emacs the keyboard, ending any
key sequence it is reading, so the `escape` record comes before the `bridge`
record.
`portal-web.el` handles `page`, `follow` and `edit` for every hosted app,
tracking the page on screen and visiting linked files, and never passes them
to the buffer's bridge function. URLs travel this way, not in records,
because a long path would not fit in one. No asynchronous AppKit or WebKit
callback keeps an `emacs_env` or calls Lisp, and a callback that finishes
after its view closed finds no target in the core and does nothing.

WebKit never lets a page on the app host load a local file, and does not ask
the navigation delegate either. The core's shared links script
(`native/Core/scripts/links.js`) catches such clicks in an isolated content
world, out of the page's reach, and the platform asks the core about each one
as about any navigation. The core answers every navigation a hosted page
asks for: stay on the app host's origin, open another site in the default
browser, or hand a local file to Emacs.

The task browser uses the bridge in one direction: after Emacs saves a file in
a task root, it sends `{"type": "refresh"}` to that root's view, and the page
refreshes itself in place. Its operations reach Emacs through
[hosted actions](hosted-actions.md#task-operations) instead, so they can wait
for Emacs's reply.

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
focuses the page again afterwards. The drawing does not use Control-X, so it
reaches Emacs like any chord a page does not use: `C-x C-s` runs the normal
Emacs save command, including the mode's remapping, and returns focus after the
save and any file name prompt finish. Command-Escape leaves control with
Emacs. Escape, and the chords the drawing uses, belong to the page.

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

`ctest --test-dir build -R web-core` runs `test/portal-web-tests.c`, the core's bridge and
web rules against the fake platform: message order and coalescing, draining
and re-arming, invalid senders and reserved types, ordinary pages, navigation
decisions, handoffs after an escape, closed views and stale deliveries.

The [standalone AppKit check](testing.md#standalone-appkit-checks) in `test/native-focus.swift`
checks the bridge in a real WebKit page: only the main frame's messages
arrive, in order, under one record until received; the bridge works again
after a reload; a failed delivery reaches Emacs; and a web view that is not a
hosted app has no bridge.

The graphical tests need a disposable graphical Emacs with the
[test event injector](testing.md#terminal-graphical-checks) loaded.
Load `test/portal-excalidraw-gui-tests.el`, then
run `M-x ert` with selector `^portal-excalidraw-gui-`. They exercise the real
WKWebView, offline fonts, paste, image round trips, several drawings, revert,
hidden views keeping their state, and a rapid `C-x C-s` reaching Emacs. The
test-only JavaScript evaluator is not part of the production module.
