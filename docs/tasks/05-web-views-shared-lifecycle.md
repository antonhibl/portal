# 05: Web views run on the shared Portal view lifecycle

Type: AFK · Status: todo

## What to build

One Swift web kind replaces the per-pane `WebViews`, and web content opens in web views that each have their own buffer (ADR 0001).

**Swift**
- Register the web kind. Its `:toolbar` option is `navigation`, `contents` or `none`. Its `:hosted` option is accepted but has no effect until task 06.
- `portal--web-load TARGET URL` accepts http, https, file, data and about URLs.
- Delete:
  - the `WebViews` exports: bind, set-layout, release-pane, destroy and native-views;
  - `GreenView`, `NativeContent` and `PaneLayout`.

**Elisp: new `portal-web.el`**
- `portal-web-mode`: turns on `portal-input-mode`. `q` runs `quit-window`; `g` reloads.
- `portal-web-open URL TOOLBAR` opens a web view in the current buffer.
- `portal-open-url` opens a new buffer every time, named after the page, for example `*portal: example.com*`.
- `portal-preview-html` reuses the buffer for its file.
- Hello and the Markdown preview must keep working on the new web views. They keep today's behaviour: open `about:blank`, then load the page once the app host is ready. Task 06 turns this into the shared hosted-app path.

**Elisp: other files**
- `portal.el` becomes the package root: requires and autoloads only. Delete `portal-mode`, `portal-show`, `portal-hide` and the single-buffer globals (`portal--buffer`, `portal--frame`, `portal--panes`, and so on).
- The zoom, find and table-of-contents commands in `portal-toolbar.el` find the selected web view through `portal-view-target`.

**Tests**
- Delete the per-pane tests in `test/portal-tests.el`.
- Add batch tests for web buffers that use the fake adapter.
- The GUI suites keep only the WebKit loading checks, using `data:` URLs.

## Acceptance criteria

- [ ] Running `portal-open-url` twice gives two buffers, each with its own web view
- [ ] After a split, the view appears only in the selected pane
- [ ] `portal-preview-html` on the same file reuses its buffer, and `g` reloads it
- [ ] URL views have the navigation toolbar with zoom and find; the HTML preview has the table-of-contents toolbar
- [ ] `q` hides the view and keeps it alive; killing the buffer releases it
- [ ] The old web exports, `GreenView`, `portal-show` and `portal-hide` are deleted
- [ ] `portal.el` contains no view code
- [ ] Hello and the Markdown preview still work
- [ ] The README's web sections are updated

## Blocked by

- [02: Terminal views run on the shared Portal view lifecycle](02-terminal-views-shared-lifecycle.md)
