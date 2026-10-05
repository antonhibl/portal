---
status: done
---

# 08: Markdown preview follows links, with back and forward

Type: AFK

## What to build

In a Markdown preview, a link to another Markdown file opens that file in the same view, and toolbar buttons go back and forward like a browser. A link to any other local file (source code, an image, a directory) opens it in Emacs in another pane by default, keeping the preview visible at its reading position. The handoff selects the destination pane and gives Emacs keyboard focus automatically.

| Link in the document | Where it goes |
|---|---|
| `#anchor` | Scrolls within the page, as today |
| Local Markdown file | Loads in the same view and adds a history entry |
| `other.md#heading` | Loads that Markdown file and scrolls to the heading |
| Local source file | Emacs visits it in another pane; `#L42` or `#L42-L50` moves point to line 42 |
| Linked local image | Emacs opens it in `image-mode` in another pane |
| Local directory | Emacs opens it in Dired in another pane |
| `http(s)://…` | The default browser, as today |

### Reading and editing flow

1. Read `README.md`, then follow a link to `architecture.md`. The same preview shows the new document and enables Back.
2. Follow a link to `src/server.ts`. Emacs opens and selects the source buffer in another pane, with keyboard input ready for editing. No preliminary Command-Escape is needed. The preview remains at the same reading position.
3. Click the preview to select its Emacs pane and give the native view keyboard focus. Keyboard users can select the preview pane and press `RET`, using the existing Portal controls.
4. Alternatively, run `portal-preview-return` from Emacs. It selects the originating preview and gives it keyboard focus, even after switching among other source buffers.
5. Back in the preview returns from `architecture.md` to `README.md` and restores the reading position. Forward returns to `architecture.md`.

The preview's Back/Forward controls navigate its reading history. Opening a file in Emacs or an external website does not add an entry, clear the forward history, or replace the preview page. Same-document anchors retain browser-style history behaviour. Back/Forward are disabled when unavailable, and following a new Markdown link after going back discards the old forward branch as in a browser.

Add an **Open in Emacs** toolbar action and command for editing the Markdown currently displayed. It uses the same handoff and return behaviour as a source link, without changing preview history. It always opens the file currently on screen, including after Back/Forward.

Other-pane placement is the default, with `display-buffer-alist` remaining authoritative. If a user's placement rules replace the preview in its own pane, the hidden view retains its page and reading position, and `portal-preview-return` brings it back. Do not add a separate placement setting for this task.

### Implementation

**App host: `host/markdown.ts`**

- When rendering, resolve every relative link against the directory of the document being rendered, never the first document in the browsing session. Preserve encoded spaces, non-ASCII characters, and fragments without double encoding or treating a fragment as part of the file name.
- Leave links that are only `#fragment` and non-file URLs unchanged. Normalize local absolute paths and local `file:` URLs through the same Markdown-versus-other-file routing as relative paths.
- A link to a Markdown file (the extensions `portal-preview-markdown` accepts, case-insensitively) becomes `markdown?path=ENCODED_ABSOLUTE_PATH#fragment` on the app host, relative to the current page, so the token is kept.
- Any other local link becomes `file:///ABSOLUTE/PATH#fragment`.
- A link to a missing Markdown file still becomes a preview URL; the host's existing "could not be found" page is what shows, and Back works from there.

**Swift: navigation and toolbar**

- In a hosted view, a main-frame navigation to a `file:` URL is cancelled. The view returns keyboard focus to Emacs, as the Excalidraw save does, and sends a `follow TARGET URL` record on the notification pipe. Navigations within the app host are allowed, as today. Other URLs still open in the default browser.
- Every hosted view sends a `page TARGET URL` record whenever a main-frame page commits, including after Back/Forward. Elisp must know the current Markdown destination before handling a subsequent Open in Emacs action.
- Records are split on spaces, so both records carry the URL percent-encoded, never a raw path.
- The `contents` toolbar (the `.preview` kind) gets Back and Forward buttons at the left after the ownership dot, laid out as the `navigation` toolbar has them, and keeps its table-of-contents button. This also applies to `portal-preview-html`, which uses the same toolbar. The buttons call WebKit's `goBack` and `goForward`, use its availability state, and send no navigation commands to Elisp.
- Use WebKit's browsing history for document/anchor navigation and reading-position restoration. Verify restoration with real page loads; add explicit restoration only if needed to satisfy the acceptance criteria. Neither an Emacs handoff nor returning to the preview reloads it.
- Expose Open in Emacs for Markdown previews only. Its toolbar action dispatches to the same Elisp command as the keyboard workflow, using the existing notification/input handoff mechanism. Sharing the `contents` toolbar with HTML previews must not expose a nonfunctional Markdown action there.

**Elisp: `portal-web.el`**

- Handle `follow` in the originating view's actual Emacs pane, identified by TARGET, rather than assuming the selected pane is the origin. Decode the `file:` URL and visit the file through ordinary Emacs file handling. Default placement reuses an appropriate other pane or creates one while preserving the preview pane; respect explicit `display-buffer-alist` rules. Do not rely on an unconfigured `pop-to-buffer` alone to guarantee other-pane placement.
- Images open in `image-mode` and directories in Dired through Emacs's usual file handling. A `#L42` or `#L42-L50` fragment moves point to line 42; other fragments on non-Markdown files are ignored. Existing file buffers and their unsaved edits are reused normally.
- A successful handoff selects the destination pane and leaves Emacs owning keyboard input. Do not automatically resume native focus after opening the file. A failed handoff reports the error without losing the preview or its history.
- Handle `page`: when the URL is a Markdown preview on the app host, update the buffer's current document path and `portal-web--hosted-path`, and rename the buffer to `*portal: FILE*` (uniquified if needed). Separate file identity from its heading fragment so looking up a preview by file still works.
- As a result, `g` reloads the file on screen, and `portal-preview-markdown` on a file reuses a buffer currently showing it. Link navigation stays in the originating preview even if another preview already shows the destination; each preview retains its own history.
- Add `portal-web-back` and `portal-web-forward`, bound to `l` and `r` in `portal-web-mode`. They call the toolbar's `back` and `forward` actions through `portal--toolbar-action`, as `portal-zoom-in` does.
- Add `portal-preview-open-in-emacs`, available through M-x and the Markdown toolbar. It opens the current Markdown file with the same placement, focus, and return tracking as `follow`. It does not map rendered scroll positions to source lines in this task.
- Add `portal-preview-return`, available through M-x without installing a global keybinding. Remember the most recent successfully handed-off Markdown preview per originating Emacs frame, using its buffer identity, not its file name or the ordinary previous-buffer list. This survives switching among source buffers and the preview changing documents. When a handoff selects another frame, make the same return destination available there.
- Return selects an existing pane showing that preview, or redisplays its buffer if hidden, then gives its native view focus without reloading. If the remembered preview was killed, report that there is no live preview to return to; do not recreate it or open an unrelated preview. Multiple preview handoffs in one frame make the most recent one the return destination.

**Shared focus: `portal-input.el` and native input handling**

- Clicking the Markdown preview content to resume reading must select the Emacs pane actually displaying that view as well as give the native view keyboard focus. Native focus and Emacs pane selection must agree before subsequent commands run.
- Route pane selection through the existing queued native-to-Emacs event mechanism; native callbacks must not call Lisp directly. Keep toolbar Back/Forward actions consistent with the existing focus-preserving toolbar behaviour.
- Preserve the existing Command-Escape / `C-b d` return to Emacs and `RET` entry controls. Opening linked files is an automatic handoff; users need not operate the ownership dot first.

## Acceptance criteria

Historical checklist: both this document and the matching DONE record in
`project.org_archive` (`CUSTOM_ID: 08-markdown-preview-links`) retained unchecked
boxes. The feature was merged in
[PR #12](https://github.com/xiaoxinghu/portal/pull/12). Status remains done;
these original marks are preserved rather than claiming a new item-by-item
acceptance run during task reconciliation. They are not separate backlog tasks.

- [ ] Clicking a relative link to another Markdown file shows that file in the same view, and the buffer is renamed after it
- [ ] Relative links in the new document resolve from its directory; local absolute paths and local `file:` URLs follow the same routing rules
- [ ] Back and Forward in the toolbar, and `l` and `r` in Emacs, move through visited Markdown documents and restore reading positions; unavailable buttons are disabled
- [ ] Following a new Markdown link after Back discards the old forward branch; opening an Emacs file or external website leaves that branch untouched
- [ ] `g` rereads the file on screen, not the first file the preview opened
- [ ] Clicking a source link automatically selects and focuses its Emacs buffer in another pane by default, leaving the preview visible at the same reading position
- [ ] Handoff works when the clicked preview's pane was not Emacs's selected pane
- [ ] A `path/to/file.ts#L42` or `#L42-L50` link opens the file at line 42
- [ ] Links to an image and to a directory open in `image-mode` and Dired
- [ ] Clicking the preview again selects its Emacs pane and gives it native keyboard focus; selecting its pane and pressing `RET` also works
- [ ] `portal-preview-return` restores the originating preview and native focus after switching among source buffers, without reloading or losing scroll position
- [ ] Return also works when custom placement rules hid the preview; a killed return destination produces a clear message; the most recent handoff wins when multiple previews are used
- [ ] Open in Emacs opens the currently displayed Markdown file, including after Back/Forward, with the same handoff and return behaviour
- [ ] `#anchor` links and the table of contents still scroll within the page; `other.md#heading` scrolls to the destination heading, and preview lookup by file still works afterward
- [ ] A missing Markdown destination shows a recoverable error page, and Back returns to the prior document
- [ ] External `https://` links still open in the default browser
- [ ] Paths containing spaces and non-ASCII characters survive link rewriting and both notification records
- [ ] Host tests cover link rewriting; batch tests with the fake native adapter cover document identity, handoff placement, line fragments, Open in Emacs, and return tracking
- [ ] Graphical tests cover real Back/Forward scroll restoration, handoff keyboard ownership, click-to-return pane selection, keyboard return, and preservation of existing Portal focus controls
- [ ] The README's Markdown preview section describes navigation, Open in Emacs, the automatic focus handoff, and both mouse and keyboard return paths

## Out of scope

- Inline images (`![](img.png)`) with relative paths. They should eventually render inside the Markdown document, independently of how clicked image links open. They are broken today because they resolve against the app host and the page's content security policy blocks them. Fixing that needs a restricted file route on the app host, which is a separate task.
- Showing linked images in the view itself. Emacs shows them.
- A combined navigation history spanning Markdown previews and ordinary Emacs buffers. Preview history and the explicit return destination have separate purposes.
- Mapping rendered Markdown positions or heading fragments to source positions for Open in Emacs.
- Automatic refresh or previewing unsaved edits. The preview still renders saved file contents.
- History entries that survive an app host restart. The token changes, so going back past a restart shows a 404 page; `g` recovers the current page.

## Blocked by

None. This builds on [04](04-one-notification-pipe.md) and [06](06-hosted-apps-open-immediately.md), which are done.
