# Preview files and open web pages

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## HTML files and URLs

Run `M-x portal-preview-html` in a `.html` or `.htm` file buffer to open its
saved contents in a web view, including relative scripts, styles,
and images from its directory. From other buffers, it prompts for a local
path or URL. Relative paths use the current buffer's `default-directory`;
`C-u M-x portal-preview-html` always prompts. Unsaved edits are not included.
Previewing the same file again reuses its buffer, such as `*portal: index.html*`,
and reloads it.

`M-x portal-open-url` opens an arbitrary absolute URL in a new buffer each time,
named after the page, such as `*portal: example.com*`.
Both commands accept HTTP, HTTPS, `file:`, `data:`, and `about:` URLs.
To open a local HTML file programmatically:

```elisp
(portal-preview-html "/absolute/path/index.html")
```

In a web buffer, `g` loads the page again and `q` (`quit-window`) hides the
view while the page keeps running. Killing the buffer closes the page.

## Markdown previews

Run `M-x portal-preview-markdown` in a Markdown file buffer to preview it
directly. Markdown modes and common file extensions are recognised. From other
buffers, the command prompts for a saved local file. Use `C-u M-x
portal-preview-markdown` to choose another file explicitly. Each file has one
preview buffer, such as `*portal: notes.md*`; previewing it again reuses it.
The Bun server reads the file, renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
and returns a complete HTML page with embedded light/dark CSS. Rendering happens
in memory, without temporary HTML files or additional npm dependencies.

The preview is light or dark with the system's appearance, and switches when
the system does, even if your Emacs frames force a dark or light title bar with
`ns-appearance`. To keep previews one way, set `portal-web-appearance`, or run
`M-x portal-web-set-appearance`:

```elisp
(setopt portal-web-appearance 'light) ; or 'dark; nil follows the system
```

This applies to every web view, including the task browser and Excalidraw.
Open previews change at once, without reloading.

Headings, lists, fenced code, tables, strikethrough, task lists, and heading
anchors are supported. Press Command-R to reread the file on screen from disk, or
from Emacs, `g` (`portal-web-reload`), which also starts a
stopped host. A loaded preview stays as it is while the host stops or restarts.
Missing or unreadable files produce an error page.

The preview follows links like a browser:

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| A local Markdown file, such as `architecture.md` or `other.md#heading` | Opens in the same preview, at the heading if there is one |
| Any other local file, such as `src/server.ts#L42` | Opens in Emacs in another pane, at line 42 for `#L42` or `#L42-L50` |
| A local image or folder | Opens in Emacs, in `image-mode` or Dired |
| `https://…` and other sites | Opens in the default browser |

Relative links resolve from the folder of the document on screen, and local
absolute paths and `file:` URLs work the same way. After following a Markdown
link, the buffer is renamed after the new file, `g` rereads it, and
`portal-preview-markdown` on that file finds this preview. Back and Forward in
the toolbar, or `l` and `r` in the preview buffer, move through the documents
this preview has shown and restore their reading positions. Following a new
link after going back discards the old forward pages, as in a browser; opening
a file in Emacs or a website does not.

Opening a file in Emacs is one click, with no need to leave the preview first.
Emacs selects the file's pane and takes the keyboard, ready for editing, while
the preview stays in its own pane at the same reading position. The file goes
to another pane, reusing one or splitting the frame. Rules in
`display-buffer-alist` still decide: if one puts the file in the preview's own
pane, the hidden preview keeps its page. **Open in Emacs** in the toolbar, or
`M-x portal-preview-open-in-emacs`, does the same for the Markdown file on
screen, including after Back or Forward.

To go back to reading, click the preview, which selects its pane and gives it
the keyboard, or select its pane and press `RET`. From anywhere else,
`M-x portal-preview-return` selects the preview that the frame last opened a
file from, showing it again if it was hidden, and gives it the keyboard. The
page is not reloaded. There is no global key for it; bind one if you like.

This version previews saved contents only, with no automatic refresh. It does
not show relative inline images, or add syntax highlighting, Mermaid, or math
rendering. HTTP(S) images and links can use their absolute URLs. Going back past
an app host restart shows a "Not found" page; `g` reloads from the running host.
Raw HTML is displayed as text, and a page-specific Content Security Policy
blocks scripts. Bun currently marks its Markdown API unstable; it is tested
here with the Bun version in the [build prerequisites](../README.md#build-and-run).

## Web view behaviour

A web view is a Portal view of the web kind. Remote pages use
[WebKit's URL request loading](https://developer.apple.com/documentation/webkit/wkwebview);
local pages use `loadFileURL` with read access to the containing directory so
relative scripts, styles, and images can load. JavaScript is enabled by default.

- Each web buffer has one web view, which appears in the selected pane showing
  the buffer ([ADR 0001](adr/0001-one-portal-view-per-buffer.md)). Other
  panes showing the same buffer display only its text. To see two pages side by
  side, open two buffers.
- Web views belong to no frame: show the buffer in another frame and its page
  moves there. Deleting a frame only hides its web views.
- Hiding the view, with `q` or by showing another buffer, keeps the page loaded,
  including its navigation, DOM, scroll position, and form state. Cookies use
  WebKit's default data store, except in hosted apps, which keep no cookies or
  storage between Emacs sessions.
- A hosted app's page never leaves the app host. When it would navigate
  anywhere else, the navigation is cancelled and the URL opens in the default
  browser. Clicking a link to a local `file:` URL gives Emacs the keyboard and
  sends a `follow` message with the URL over the [bridge](editor-bridge.md)
  instead: WebKit never lets an app host page load a local file, so a script
  in its own content world, out of the page's reach, catches such clicks. Each
  page a hosted app commits, including after Back and Forward, sends a `page`
  message. URLs go over the bridge because a long path would not fit in a
  notification record.
- Pages see the system's light or dark appearance as CSS's
  `prefers-color-scheme`, not the appearance an Emacs frame forces with
  `ns-appearance`. `portal-web-appearance` set to `light` or `dark` overrides it
  for every web view, open or new.
- A chord the page does not use reaches Emacs, and Command-Escape works, while a
  page has focus.
  Clicking a view to enter it sends a `select TARGET` record, and Emacs selects
  the pane showing it.
- This is a URL viewer, without an address bar, downloads, popup windows, or
  JavaScript dialog UI. Failed loads can be inspected through `:error` in
  `(portal--inspect (portal-view-target))`.

Lisp can give any buffer a web view: `(portal-web-open URL TOOLBAR)` opens one
for the current buffer and loads URL. TOOLBAR is `"navigation"` (back, forward,
find, zoom and reload), `"contents"` (those and a table of contents),
`"markdown"` (those, a table of contents and, for a hosted app, Open in Emacs)
or `"none"`.
Loading the page a view shows again, ignoring its fragment, reloads it without
a new history entry.
`(portal-web-open-hosted PATH TOOLBAR)` opens a hosted app instead: the view
opens at once, at `about:blank`, and loads PATH, such as `"/hello"`, from the
app host as soon as the host is ready, starting the host if needed.
A hosted app and its buffer exchange JSON objects over the
[bridge](editor-bridge.md): `(portal-web-send PLIST)` sends one to the
app, and the buffer-local `portal-web-bridge-function` is called with each one
the app sends, in order. Other web views have no bridge.
