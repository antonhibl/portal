# Portal tasks

This is the project task root used by `M-x portal-tasks`. Save edits, then press
`g` in the task view to reload. Use **Show completed** to read finished work.
For task authoring, follow [AGENTS.md](../AGENTS.md#authoring-tasks).

## Portal view lifecycle redesign

These tasks build the design recorded in [CONTEXT.md](../CONTEXT.md), [ADR 0001](../docs/adr/0001-one-portal-view-per-buffer.md) and [ADR 0002](../docs/adr/0002-portal-view-native-seam.md). Each task is a thin vertical slice. It goes through Swift, Elisp and tests together, deletes the code it replaces, updates the docs it touches, and leaves Portal working.

| Task | Type | Blocked by |
|---|---|---|
| [01: Spike: a terminal view survives moving between frames and being parked](01-terminal-frame-spike.md) | AFK, escalate on failure | none |
| [02: Terminal views run on the shared Portal view lifecycle](02-terminal-views-shared-lifecycle.md) | AFK | none |
| [03: Portal views follow their buffer into any frame](03-views-follow-buffer-across-frames.md) | AFK | 01, 02 |
| [04: One notification pipe owned by portal-view.el](04-one-notification-pipe.md) | AFK | 02 |
| [05: Web views run on the shared Portal view lifecycle](05-web-views-shared-lifecycle.md) | AFK | 02 |
| [06: Hosted apps open immediately and load when the app host is ready](06-hosted-apps-open-immediately.md) | AFK | 05 |
| [07: Excalidraw talks to its buffer over the bridge](07-excalidraw-over-bridge.md) | AFK | 04, 06 |

The lifecycle tasks are complete; the table preserves their original dependency order.
Current task status is stored in each document's YAML front matter.

Out of scope: the input handoff redesign, the toolbar redesign, and the routing of hosted-app pages.

## Markdown navigation

- [08: Markdown preview follows links, with back and forward](08-markdown-preview-links.md)

## Ideas imported from tasks.org

These notes retain their original TODO status. The Markdown preview note overlaps
completed task 08; its remaining scope needs to be clarified before implementation.

- [Persistent terminal sessions](persistent-terminal-sessions.md)
- [Open Markdown files directly in the preview](markdown-default-viewer.md)
- [Better Markdown preview](better-markdown-preview.md)
