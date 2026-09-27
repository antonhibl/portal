---
id: portable-web-bridge
status: todo
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

- [ ] `portal.h` no longer declares the removed operations. Its web part is the
  primitives and calls into the core above.
- [ ] C tests with a fake web platform exercise the real core. They cover
  message order and coalescing, drain and re-arm, invalid senders and types,
  rejection on ordinary pages, navigation decisions, close, and stale
  completions.
- [ ] Hosted application source does not reference WebKit transport globals;
  only platform bootstrap glue does. Shared helpers are installed with the same
  privilege and isolation as before.
- [ ] Real WKWebView checks verify hosted storage, main-frame provenance,
  external and local links, long link payloads, reload and history, and script
  readiness. Excalidraw open, edit, save and revert, and Markdown and task
  handoff still pass.
- [ ] `./build.sh`, `ctest --test-dir build --output-on-failure`,
  `bun run --cwd host check` and `bun run --cwd host typecheck` pass, along with
  the affected native and graphical web, input and Excalidraw suites.
- [ ] Update `docs/editor-bridge.md` and the README architecture, record
  verification, and mark this task done. Follow `AGENTS.md` for the
  implementation worktree and PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  handles, the describe primitive, and invalidation on close.
- [Own ordered native notifications in the C core](portable-notification-channel.md)
  supplies bridge announcements, their order relative to input records, and the
  convention for platform calls into the core.
