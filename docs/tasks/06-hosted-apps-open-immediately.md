# 06: Hosted apps open immediately and load when the app host is ready

Type: AFK · Status: done

## What to build

Every hosted app (CONTEXT.md) opens the same way. `portal-web-open-hosted PATH TOOLBAR` opens a hosted web view at `about:blank` immediately, then loads PATH from the app host as soon as the host is ready.

**Swift**
- The `:hosted` option is fixed when the view opens, and does two things:
  - the view gets a non-persistent data store;
  - if the main frame tries to navigate anywhere outside the app host, that navigation is cancelled and the URL opens in the default browser.

**Elisp: `portal-web.el`**
- Add `portal-web-open-hosted`.
- On `portal-server-ready-hook`, load every hosted web view that is still on `about:blank`.
- When the app host stops, leave hosted apps that have already loaded alone. Delete today's "server stopped" `data:` page.
- `g` reloads from the app host, starting it first if needed.
- Hello and the Markdown preview use `portal-web-open-hosted`. The Markdown preview reuses the buffer for its file.

## Acceptance criteria

- [x] A Markdown preview opened while the app host is not running shows its view immediately and loads once the host is ready. Test this in batch with the real app host and the fake native adapter.
- [x] Stopping or restarting the app host leaves a loaded preview unchanged, and `g` reloads it
- [x] An external `https://` link in a Markdown preview opens in the default browser, and the preview stays
- [x] Previewing the same Markdown file again reuses its buffer
- [x] Hosted views don't keep cookies or storage across Emacs sessions
- [x] The README's sections on Hello and the Markdown preview are updated

## Blocked by

- [05: Web views run on the shared Portal view lifecycle](05-web-views-shared-lifecycle.md)
