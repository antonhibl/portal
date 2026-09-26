# Tasks: Portal view lifecycle redesign

These tasks build the design recorded in [CONTEXT.md](../../CONTEXT.md), [ADR 0001](../adr/0001-one-portal-view-per-buffer.md) and [ADR 0002](../adr/0002-portal-view-native-seam.md). Each task is a thin vertical slice. It goes through Swift, Elisp and tests together, deletes the code it replaces, updates the docs it touches, and leaves Portal working.

| Task | Type | Blocked by |
|---|---|---|
| [01: Spike: a terminal view survives moving between frames and being parked](01-terminal-frame-spike.md) | AFK, escalate on failure | none |
| [02: Terminal views run on the shared Portal view lifecycle](02-terminal-views-shared-lifecycle.md) | AFK | none |
| [03: Portal views follow their buffer into any frame](03-views-follow-buffer-across-frames.md) | AFK | 01, 02 |
| [04: One notification pipe owned by portal-view.el](04-one-notification-pipe.md) | AFK | 02 |
| [05: Web views run on the shared Portal view lifecycle](05-web-views-shared-lifecycle.md) | AFK | 02 |
| [06: Hosted apps open immediately and load when the app host is ready](06-hosted-apps-open-immediately.md) | AFK | 05 |
| [07: Excalidraw talks to its buffer over the bridge](07-excalidraw-over-bridge.md) | AFK | 04, 06 |

Tasks 01 and 02 can start straight away. Once 02 is done, 04 and 05 can run in parallel, and so can 03 if 01 has also passed.

Out of scope: the input handoff redesign, the toolbar redesign, and the routing of hosted-app pages.
