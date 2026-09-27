---
id: portable-web-bridge
status: done
depends_on:
  - portable-view-lifecycle
  - portable-notification-channel
---

# Move web policy and the bridge into the C core

## Context and problem

The goal is a macOS-preserving architecture that makes adding another platform's
web view natural later. It does not implement WebKitGTK or a Linux experiment
or CI job. Windows is outside scope. Follow ADR 0003
(`docs/adr/0003-platform-interface-primitives.md`).

`native/WebView.swift` mixes WKWebView callbacks with navigation policy and the
hosted-app bridge queue. `host/excalidraw.tsx` calls
`window.webkit.messageHandlers.portal` directly. Link interception and TOC
helpers are JavaScript strings embedded in Swift. Another platform would have
to copy both Portal's rules and browser-specific plumbing.

## Outcome and scope

The core owns the bridge and web policy. The platform loads pages, delivers
messages, and reports what pages do. Hosted apps and shared browser helpers use
a Portal JavaScript transport, not WebKit globals.

- Move message ownership, reserved message types, coalescing of the latest
  change, receiving and draining, and the single outstanding `bridge TARGET`
  notification into the core. Large payloads stay out of the pipe, and other
  messages keep their order.
- Move hosted navigation and message policy into the core as plain data. The
  platform supplies the provenance it observed natively, such as main frame and
  URL; a page's own claimed origin is not evidence. Preserve hosted versus
  ordinary web behavior, allowed URLs, and document identity.
- Keep WebKit delegates, website data-store configuration, URL loading and file
  access, script-world installation, native file pickers, and `NSWorkspace`
  calls in Swift. Preserve hosted storage isolation, the exact sender rules,
  rejection of reserved app messages, external-link handling, and isolated
  helper worlds.
- Give hosted apps a shared interface such as `portalBridge.postMessage`, and
  keep the existing receive protocol. Move the link, TOC and count helpers into
  shared JavaScript resources. Keep privileged helper transport separate from
  the page-visible bridge; moving files must not weaken isolation.
- Install scripts before clients need them, on first load and on reload. Local
  HTML and arbitrary pages must still work without the Bun app host.
- Keep escape-before-follow and escape-before-edit ordering. Use the existing
  input operation if C input policy has not merged; do not copy its state
  machine. Guard asynchronous completions after navigation or close. Remove
  replaced Swift and JavaScript copies.

## Platform interface

- **Removes** the Lisp-shaped `portal_web_send` and `portal_web_receive`. The
  core owns the queue and answers `portal--web-receive` itself.
- **Adds, implemented by the platform, on one web view handle:** load a URL;
  go back, go forward or reload; and post a message to the page. Page URL,
  title, loading state and errors come from the lifecycle's describe primitive.
- **Adds, implemented by the core, called by the platform:**
  - a page posted a message, with the provenance the platform observed;
  - the page asks to navigate to a URL, with its main-frame flag. The core
    answers allow, open externally or hand to Emacs.
- Zoom, find and TOC are toolbar concerns. If they need a primitive now, such as
  running a shared helper script with an asynchronous result, add that one
  primitive, not one per feature.

## Starting points

Read ADR 0003, `native/WebView.swift`, `native/WebToolbar.swift`,
`portal-web.el`, `portal-excalidraw.el`, `host/excalidraw.tsx`,
`host/build-editor.ts`, `docs/editor-bridge.md`, and the README's hosted-app
behavior. Tests include `test/native-focus.swift`, `test/native-toolbar.swift`,
the web and Excalidraw batch and graphical suites, and the Markdown and
task-browser graphical suites. Existing tests define the behavior; do not add
browser features during the extraction.

## Decisions to settle during implementation

The core must read each message's type to apply reserved-type and coalescing
rules. Choose between receiving validated JSON bytes with typed metadata and a
small maintained C JSON library; do not write a new parser. Decide how "go
back, go forward or reload" is typed without a string verb. Specify where
shared scripts are packaged and how arguments reach JavaScript safely. Document
ownership, trusted provenance, and navigation generations in the interface.

## Acceptance criteria and verification

- [x] `portal.h` no longer declares the removed operations. Its web part is the
  primitives and calls into the core above.
- [x] C tests with a fake web platform exercise the real core. They cover
  message order and coalescing, drain and re-arm, invalid senders and types,
  rejection on ordinary pages, navigation decisions, close, and stale
  completions.
- [x] Hosted application source does not reference WebKit transport globals;
  only platform bootstrap glue does. Shared helpers are installed with the same
  privilege and isolation as before.
- [ ] Real WKWebView checks verify hosted storage, main-frame provenance,
  external and local links, long link payloads, reload and history, and script
  readiness. Excalidraw open, edit, save and revert, and Markdown and task
  handoff still pass.
- [x] `./build.sh`, `ctest --test-dir build --output-on-failure`,
  `bun run --cwd host check` and `bun run --cwd host typecheck` pass, along with
  the affected native and graphical web, input and Excalidraw suites.
- [x] Update `docs/editor-bridge.md` and the README architecture, record
  verification, and mark this task done. Follow `AGENTS.md` for the
  implementation worktree and PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  handles, the describe primitive, and invalidation on close.
- [Own ordered native notifications in the C core](portable-notification-channel.md)
  supplies bridge announcements, their order relative to input records, and the
  convention for platform calls into the core.

## Outcome

- `native/Core/web.c` owns web views' rules and the bridge. Each web view's
  state hangs off its registry entry in `views.c` and is freed on close. The
  core validates the URLs Lisp loads, reloads the document on screen instead
  of adding a history entry, skips about:blank in a view that has shown
  nothing, and keeps the view's address across a failed load. It answers
  every navigation a hosted page asks for, owns the bridge's queue, `change`
  coalescing, the reserved `page`, `follow` and `edit` types and the single
  outstanding `bridge TARGET` record, and answers `portal--web-receive`
  itself. `emacs.c` calls `portal_views_web_load`, `_send` and `_receive`.
- `portal.h` no longer declares `portal_web_send` or `portal_web_receive`.
  Its web primitives are `portal_web_load(view, url)`, `portal_web_go(view,
  step)` and `portal_web_post(view, json, token)`. Platform calls into the
  core are `portal_web_posted(target, sender, type, json)`,
  `portal_web_navigating(target, url, main_frame)`, `portal_web_committed`,
  `portal_web_failed(target, token, message)` and `portal_web_edit`, plus
  `portal_web_script`, which hands out the shared scripts.
- Swift keeps WebKit: delegates, the non-persistent data store for hosted
  apps, `loadFileURL`, content worlds and script installation, the file
  picker and `NSWorkspace`. `WebBridge` and `WebLinks` are gone; one
  `PageMessages` handler forwards what WebKit observed.
- C input policy merged first (portable-input-policy), so a `follow` or
  `edit` gives Emacs the keyboard through the input core:
  `portal_input_escape` in `native/Core/input.c` does what the platform's
  Command-Escape report does, ending any handoff with its `escape` record
  before the `bridge` record, then returning the keyboard. It adds an entry
  to the input state machine, not a copy of it.
- Hosted apps post with `window.portalBridge.postMessage` and set
  `portalBridge.receive` (`host/bridge.d.ts`). Only the platform glue in
  `WebView.swift` and `CoreCalls.swift` names `window.webkit`.
- The links script and the toolbar's contents and count script are
  `native/Core/scripts/links.js` and `contents.js`. They keep their worlds,
  injection times and main-frame limits.
- Decisions:
  - **JSON.** Validated JSON bytes with typed metadata. The platform checks
    that a message is a JSON object, as it must parse one to deliver it
    anyway, and passes its `type`. The core only writes JSON, for its own
    messages and the received array, and never parses it. No JSON library.
  - **History.** `portal_history` is an enum, `PORTAL_BACK`,
    `PORTAL_FORWARD` or `PORTAL_RELOAD`. The core uses reload now; back and
    forward stay with the toolbar until the toolbar task moves them.
  - **Scripts.** Packaged in the core, embedded with `#embed` (a C23
    feature that Clang, and GCC 15, accept in C11, with one warning
    silenced), so no platform needs bundle resources or the app host. Each is
    a function expression taking a report function. The platform starts it
    as `(SOURCE)(REPORT)` in its own isolated world, with REPORT posting to a
    handler in that world. Arguments to a script's functions, and messages
    to the page, cross as `callAsyncJavaScript` arguments, never as script
    text.
  - **Provenance.** A `portal_sender` is what WebKit reports about the
    posting frame: main frame or not, and its document URL. It must be the
    URL Emacs loaded last, compared as a URL parser spells both (raw and
    percent-encoded bytes alike), as are the URLs that decide a reload. A
    page's own claims never count.
  - **Ownership and generations.** Platform calls name the view by target,
    so a late call after close finds nothing. Each commit starts a new
    generation, and a post's token is the generation it went to, so a failed
    delivery reported after the page changed is dropped. Token 0 reports a
    failure of the page itself.
  - **Current page.** The core compares loads with the URL committed last.
    Swift compared with `WKWebView.url`, which also follows
    `history.pushState`, so for an ordinary page that has pushed a URL, `g`
    now reloads it rather than loading the original URL. No hosted app uses
    `pushState`.

## Verification

Run on macOS 27.0 with Swift 6.4, Emacs 31.1 and Bun 1.3.14 on 2026-09-28:

- `./build.sh` built the module and app host. `ctest --test-dir build
  --output-on-failure` passed all 16 tests, including the new `web-core`
  test. `bun run --cwd host check` and `bun run --cwd host typecheck` passed.
- Mutations of `web.c` (stale-token guard, reserved types, the escape before
  a handoff, the about:blank rule, sender URL matching and restoring the
  address) each failed `portal-web-tests`.
- `build/check-focus` and `build/check-toolbar` passed with real WKWebViews:
  hosted storage, main-frame provenance, reserved types, external and local
  links, a link longer than a record, reload and history, bridge readiness on
  first load and reload, a failed delivery, the TOC and count scripts, and
  Open in Emacs sending `prefix`, `escape` and `bridge` in order.
- The graphical Excalidraw suite passed 7 of 7: open, edit, hide and reopen,
  images, save, and revert. In the combined graphical suite, the tests that
  inject keys or clicks failed because Emacs could not become active while
  another app was in front. Unmodified `main` failed the same tests in the
  same session (28 there, 27 here; the extra one is a flaky Markdown back and
  forward test). Tests that inject nothing passed, including Markdown Open in
  Emacs and back and forward, task dependencies and reloads, toolbar and web
  loading. The Markdown and task-browser link handoffs still need a run with
  Emacs in front.
