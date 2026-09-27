---
id: portable-web-bridge
status: todo
depends_on:
  - portable-view-lifecycle
  - portable-notification-channel
---

# Separate shared web behavior from WKWebView

## Context and problem

The goal is a macOS-preserving architecture suitable for adding a Linux web
adapter later, not an implementation of WebKitGTK or a Linux experiment/CI job.
Windows is outside scope. The C registry and notification channel are available
after the prerequisites; input policy may still be Swift.

`native/WebView.swift` mixes WKWebView callbacks with navigation policy and the
hosted-app bridge queue. `host/excalidraw.tsx` calls
`window.webkit.messageHandlers.portal` directly. Link interception and TOC
helpers are JavaScript strings embedded in Swift. A future adapter would have
to copy both Portal behavior and browser-specific plumbing.

## Outcome and scope

The production web kind uses typed web operations/events and shared C bridge
policy. WKWebView is a macOS implementation. Hosted apps and reusable browser
helpers use a Portal JavaScript transport interface.

- Describe only current operations: navigation/reload/history, bridge send and
  receive, relevant state/events, zoom/find, and helper-script installation.
  Keep native initialization and JavaScript completions asynchronous where
  needed; never block the UI loop waiting for a page. The toolbar's state model
  moves separately, but its web operations must remain usable through this seam.
- Move message ownership, reserved message-type rules, latest-change coalescing,
  receive/drain behavior, and the single outstanding `bridge TARGET` notification
  into C. Large payloads remain outside the pipe, and other messages retain order.
- Express hosted navigation/message policy with platform-neutral data. The
  adapter must supply native-observed main-frame/URL provenance; a page's own
  claimed origin is not evidence. Preserve current hosted versus ordinary web
  behavior, allowed URLs, and navigation/document identity semantics.
- Keep WK delegates, website data-store configuration, URL loading/file access,
  script-world installation, native file pickers, and NSWorkspace calls in Swift.
  Preserve hosted storage isolation, exact admitted bridge sender rules, rejection
  of reserved app messages, external-link handling, and isolated helper worlds.
- Give hosted apps a shared interface such as `portalBridge.postMessage` while
  preserving the existing receive protocol. Move the link/TOC/count helper
  sources into shared JavaScript resources. Separate privileged helper transport
  from the page-visible bridge; changing file location must not weaken isolation.
- Bundle/install scripts before clients need them, for initial loads and reloads.
  Local HTML and arbitrary pages must still work without the Bun app host.
- Keep escape-before-follow/edit notification ordering. Use the existing native
  input operation if C input policy has not merged; do not copy its state machine
  or add that task as an implicit dependency. Guard asynchronous completions
  after navigation or close. Remove replaced Swift/shared-JS copies.

## Starting points

Read `native/WebView.swift`, `native/WebToolbar.swift`, `portal-web.el`,
`portal-excalidraw.el`, `host/excalidraw.tsx`, `host/build-editor.ts`,
`docs/editor-bridge.md`, and the README's hosted-app behavior. Tests include
`test/native-focus.swift`, `test/native-toolbar.swift`, the web and Excalidraw
batch/GUI suites, and Markdown/task-browser GUI suites. Follow the prerequisite
C files for lifecycle and notifications. Existing tests define actual behavior;
do not expand the browser feature set during extraction.

## Decisions to settle during implementation

Choose whether the core receives validated JSON bytes plus typed metadata or
uses a small maintained C JSON library; do not build a new parser. Specify the
shared script packaging location and safe argument transport to JavaScript.
Document ownership, trusted provenance, and navigation-generation handling in
the interface. A universal browser framework is unnecessary.

## Acceptance criteria and verification

- [ ] C tests cover message ordering/coalescing, drain and re-arm, invalid
  senders/types, ordinary-page rejection, close, and stale completions using
  the real bridge with a fake web adapter.
- [ ] Hosted application source does not reference WebKit transport globals;
  platform-specific bootstrap glue does. Shared helper sources are installed
  with the same privilege/isolation guarantees as before.
- [ ] Real WKWebView checks verify hosted storage, main-frame provenance,
  external/local links, long link payloads, reload/history, and script readiness.
  Excalidraw open/edit/save/revert behavior and Markdown/task handoff still pass.
- [ ] `./build.sh`, `ctest --test-dir build --output-on-failure`,
  `bun run --cwd host check`, and `bun run --cwd host typecheck` pass, along with
  affected native and graphical web/input/Excalidraw suites.
- [ ] Update `docs/editor-bridge.md` and README architecture, record verification,
  and mark this task done. Follow `AGENTS.md` for the implementation worktree/PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  view identity, native-handle ownership, and close invalidation.
- [Share ordered native notifications](portable-notification-channel.md)
  supplies bridge announcements and ordering with input notifications.
