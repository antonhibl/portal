# Portal view native seam: per-target calls, named per-kind exports, frame title on every placement

Emacs drives every Portal view through a small set of lifecycle calls, each addressed by the view's native target (`web:3`, `terminal:2`): open, place, hide, close, inspect. Operations that only make sense for one view kind get their own named exports, such as `portal--web-send` and `portal--terminal-paste`. Each placement call resolves the frame again by temporarily renaming it to a unique title, and nothing about frames is cached across the seam. We chose these because they are the most straightforward options with two view kinds, and because nothing can go stale between Emacs and the native module.

The native module exports these 19 functions:

- **Lifecycle**, for every view kind: `portal--open`, `portal--place`, `portal--hide`, `portal--close`, `portal--inspect`, and `portal--channel` for the notification pipe.
- **Web:** `portal--web-load`, `portal--web-appearance`, and the bridge's `portal--web-send` and `portal--web-receive`.
- **Terminal:** `portal--terminal-paste`, `portal--terminal-text`, `portal--terminal-theme`, `portal--terminal-themes` and `portal--terminal-bindings`.
- **Input:** `portal--input`.
- **Toolbar:** `portal--toolbar`, `portal--toolbar-theme` and `portal--toolbar-action`.

## Considered Options

- **One declarative layout call carrying the placement of every view.** Rejected. Every open view would have to appear in every call, so one registry mismatch breaks all later syncs. The all-or-nothing validation only pays off when views depend on each other, and with one view per buffer they don't (ADR 0001).
- **A generic `portal--call TARGET VERB JSON` for kind operations.** Rejected. It would mean the native module never changes when a view kind is added, but verbs become strings that are only checked at runtime and can't be documented. That generality serves a third kind that doesn't exist yet.
- **Caching a native frame handle instead of renaming the frame on each call.** Rejected. A cached handle can go stale, for example when non-native fullscreen swaps the frame's window, which would need an invalidate-and-retry path. Renaming only happens when a view's geometry actually changes, so the cost is small. If Emacs ever exposes a reliable way to identify a frame's native window, only one function in `portal-view.el` changes.
