# Preview files and open web pages

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## HTML files and URLs

Run `M-x portal-render-html` in a `.html` or `.htm` buffer to preview saved
contents, including relative scripts, styles and images from its directory.
Other buffers prompt for a local path or URL. Relative paths use the buffer's
`default-directory`; `C-u M-x portal-render-html` always prompts. Unsaved edits
are excluded. Repreviewing a file reuses and reloads its buffer, such as
`*portal: index.html*`.

`M-x portal-open-url` opens any absolute URL in a new, page-named buffer each
time, such as `*portal: example.com*`.
Both commands accept HTTP, HTTPS, `file:`, `data:`, and `about:` URLs.
To open a local HTML file programmatically:

```elisp
(portal-render-html "/absolute/path/index.html")
```

In a web buffer, `g` reloads and `q` (`quit-window`) hides the still-running
page. Killing the buffer closes it.

### Going to another address

`G`, Command-L, or the toolbar's globe button (Go to address) runs
`M-x portal-web-goto`, which reads an address in the minibuffer, starting with
the one on screen, and loads it in the same page. It takes a URL; a host, with
or without a path, such as `example.com/docs`, which loads over HTTPS, or
`localhost:8080`, over HTTP; a local file starting with `/`, `~` or `.`; or
any other words, which it searches for at `portal-web-search-url` (DuckDuckGo
by default). From a preview, a hosted app or any other buffer, or with a
prefix argument, the address opens in a new buffer instead. `w` copies the
address on screen. Command-L works while the page has the keyboard, unless the
page uses that chord itself.

### Dialogs and windows a page opens

A page's JavaScript `alert`, `confirm` and `prompt` dialogs ask in the
minibuffer, naming the page's origin: an alert shows its message, a
confirmation asks `y-or-n-p`, and a prompt reads a line, starting with the
page's default. The page waits for the answer, and gets one however the
dialog ends: `C-g` cancels it. The view gets the keyboard back if it had it.

A window the page opens, with `window.open` or a link to a new tab, shows in a
web buffer of its own, in another pane, as `portal-web-popup-display-action`
says. It is the page WebKit made for that window, still related to the page
that opened it, so sign-in pop-ups that report back to their opener work. When
the window's page closes it, as a sign-in pop-up does when it is done, its
buffer and pane close too. Set `portal-web-popups` to `browser` to open such
windows in the default browser instead, or to nil to ignore them. A window
Emacs has not shown within a minute goes.

### Bookmarks and Org links

`C-x r m` (`bookmark-set`) in a web buffer bookmarks it: a page by its address,
named after its title, and a Markdown or Org preview by its file, since the app
host's address changes. Other hosted apps cannot be bookmarked. Jumping to the
bookmark opens the page or preview again.

Once Org's links load, a `portal:` link, such as
`[[portal:https://example.com/docs][Docs]]`, opens its URL in a web view; with
a prefix argument, `C-u C-c C-o` opens it in the default browser. In a web
buffer, `org-store-link` stores a `portal:` link named after the page's title,
or a file link for a preview. Exported, a `portal:` link is an ordinary link
to its URL.

## Markdown previews

Run `M-x portal-render-markdown` in a Markdown file buffer to preview it;
Markdown modes and common extensions are recognised. Other buffers prompt for
a saved local file. `C-u M-x
portal-render-markdown` explicitly chooses another file. Each file reuses one
preview buffer, such as `*portal: notes.md*`. The Bun server reads and renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
returning complete HTML with embedded light/dark CSS. Rendering is in memory:
no temporary HTML files or additional npm dependencies.

Previews follow system light/dark appearance, even when Emacs frames force a
title-bar appearance with `ns-appearance`. To fix preview appearance, set
`portal-web-appearance` or run `M-x portal-web-set-appearance`:

```elisp
(setopt portal-web-appearance 'light) ; or 'dark; nil follows the system
```

This affects every web view, including Excalidraw;
open previews change immediately without reloading.

Previews support headings, lists, fenced code, tables, strikethrough, task lists,
heading anchors and images. Local images, such as `![diagram](img/arch.png)`,
resolve like links below and show inline; HTTP(S) and `data:` images also work. Command-R rereads the displayed file from disk; from
Emacs, `g` (`portal-web-reload`) also starts a stopped host. Loaded previews
survive host stops or restarts. Missing or unreadable files show an error page.

The preview follows links like a browser:

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| A local Markdown file, such as `architecture.md` or `other.md#heading` | Opens in the same preview, at the heading if there is one |
| Any other local file, such as `src/server.ts#L42` | Opens in Emacs in another pane, at line 42 for `#L42` or `#L42-L50` |
| A local image or folder | Opens in Emacs, in `image-mode` or Dired |
| `https://…` and other sites | Opens in the default browser |

Relative links resolve from the displayed document's folder; local absolute
paths and `file:` URLs also work. Following a Markdown link renames the buffer
after that file: `g` rereads it, and `portal-render-markdown` on that file finds
this preview.
Toolbar Back/Forward, or `l` and `r` in the buffer, navigate previously shown
documents and restore reading positions. Following a new link after going back
discards forward pages, as in a browser; opening files in Emacs or websites does not.

One click opens a file in Emacs and selects its pane with editing focus. The
preview keeps its pane and reading position; the file reuses another pane or
splits the frame. `display-buffer-alist` still decides: if it uses the preview's
pane, the hidden preview keeps its page. Toolbar **Open in Emacs**, or
`M-x portal-render-open-in-emacs`, does the same for the displayed Markdown
file, including after Back/Forward.

To resume reading, click the preview to select and focus it, or select its pane
and press `RET`. From elsewhere, `M-x portal-render-return` shows, selects and
focuses the preview this frame last opened a file from, without reloading.
It has no global key; bind one if desired.

This version shows saved contents only, without automatic refresh, syntax
highlighting, Mermaid or math rendering. Going back past a host restart shows "Not found";
`g` reloads from the running host. Raw HTML appears as text; a page-specific
Content Security Policy blocks scripts. Bun currently marks its Markdown API unstable;
Portal tests it with the Bun version in the [build prerequisites](../README.md#build-and-run).

## Org previews

Run `M-x portal-render-org` in an Org buffer, or a buffer visiting a `.org`
file, to preview it; other buffers prompt for a file, as `C-u M-x
portal-render-org` always does. Emacs exports the file to HTML, so a buffer
visiting it shows its text, saved or not, and the app host shows the result
with the Markdown preview's styles, in a buffer such as `*portal: notes.org*`.
Code blocks never run for a preview: they show as code. A link Org cannot
resolve shows as a broken link rather than stopping the export. Previewing the
same file again reuses its buffer, and `g` exports the file on screen again.
The HTML lives in `portal-org-preview-directory`, one file per Org file.

Links work as in Markdown previews, except that only Emacs can export Org: a
link to another Org file opens it in the same preview, keeping the keyboard in
the page, where `l` and `r` go back and forward; a link to any other local
file opens it in Emacs, in another pane. ID links, including Org-roam's, go to
their file and the heading with that ID, which Org-roam's database resolves
when it is loaded. Images show from disk, and web links open in the default
browser. Toolbar **Open in Emacs**, or `M-x portal-render-open-in-emacs`,
visits the Org file on screen.

## Web view behaviour

Web views are Portal views of the web kind. Remote pages use
[WebKit URL request loading](https://developer.apple.com/documentation/webkit/wkwebview);
local pages use `loadFileURL` with containing-directory read access for relative
scripts, styles and images. JavaScript is enabled by default.

- Each web buffer has one view in its selected pane
  ([ADR 0001](adr/0001-one-portal-view-per-buffer.md)); other panes showing
  that buffer show only text. Use two buffers for side-by-side pages.
- Views belong to no frame: showing the buffer elsewhere moves its page.
  Deleting a frame only hides its views.
- Hiding with `q` or another buffer preserves the page's navigation, DOM, scroll
  position and form state. Cookies use WebKit's default store, except hosted
  apps keep no cookies or storage between Emacs sessions.
- Hosted pages never leave the app host: other navigation is cancelled and
  opened in the default browser. Local `file:` links instead give Emacs focus
  and send the URL in a `follow` message over the [bridge](editor-bridge.md).
  WebKit forbids hosted pages from loading local files, so a script in its own
  content world, beyond the page's reach, catches these clicks. Every hosted
  page commit, including Back/Forward, sends a `page` message. URLs use the
  bridge because long paths would not fit in notification records.
- CSS's `prefers-color-scheme` reflects system appearance, not a frame's forced
  `ns-appearance`. Setting `portal-web-appearance` to `light` or `dark`
  overrides every web view, open or new.
- With page focus, unused chords reach Emacs and the configured escape
  (Command-period by default) returns control to Emacs. Clicking
  to enter sends `select TARGET`; Emacs selects the view's pane.
- Pages ask Emacs for addresses, dialogs and new windows, as
[above](#dialogs-and-windows-a-page-opens). These requests wait outside the
record pipe, as bridge messages do, so their text can be any length. There are
no downloads.
  Inspect failed loads through `:error` in
  `(portal--inspect (portal-view-target))`.

Lisp can give any buffer a web view: `(portal-web-open URL TOOLBAR)` opens and
loads URL in the current buffer. TOOLBAR is `"navigation"` (back, forward,
find, zoom and reload), `"contents"` (those plus a table of contents),
`"markdown"` (those plus a table of contents and, for hosted apps, Open in Emacs)
or `"none"`. Loading the current page, ignoring its fragment, reloads without
adding history.
`(portal-web-open-hosted PATH TOOLBAR)` instead opens immediately at `about:blank`
and loads hosted PATH, such as `"/hello"`, when the host is ready, starting it
if needed. Hosted apps exchange JSON objects with their buffers over the
[bridge](editor-bridge.md): `(portal-web-send PLIST)` sends to the app;
buffer-local `portal-web-bridge-function` receives app messages in order.
Other web views have no bridge.
