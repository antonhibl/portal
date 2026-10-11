# Portal documentation

Start with [build and run](../README.md#build-and-run).
Run shell examples from the repository root, not `docs/`.

## Use Portal

| I want to… | Guide |
| --- | --- |
| Move between Emacs and a native view | [Keyboard ownership and toolbars](keyboard.md) |
| Open HTML, URLs or a saved Markdown preview | [Web views and previews](web-views.md) |
| Draw and save offline | [Local Excalidraw drawings](excalidraw.md) |
| Run shells, switch terminals or use a quick terminal | [Terminals and optional Consult/Embark adapters](terminals.md) |
| Present a command in a panel or set a global shortcut | [Launchers and global shortcuts](launcher.md) |
| Diagnose a blank hosted app or restart its process | [App host lifecycle and diagnostics](app-host.md) |

## Build and change Portal

- [Contributing](../CONTRIBUTING.md): build/editor setup, distribution, worktrees
  and checks before a PR.
- [Testing Portal](testing.md): batch coverage, graphical procedures, standalone
  native checks and opt-in smoke tests. Recorded results are not a new test run.
- [Domain vocabulary](../CONTEXT.md): view, terminal and hosted-app terms.
- [Implementation and native boundaries](architecture.md): state ownership,
  lifetimes, platform interfaces and failure invariants.
- [Input bridge](terminal-input-bridge.md): key routing and the notification pipe.
- [Hosted-app bridge](editor-bridge.md): message transport and Excalidraw persistence.
- [Launcher native panel](launcher-native-panel.md): Emacs NS compatibility,
  frame guards, geometry and command sessions.
- [Application launcher integration](launcher-applications.md): launcher.el
  follow-ups and an optional smoke test.
- [Terminal benchmarks](terminal-benchmark.md): latency/frame timing measurement
  and interpretation, not guaranteed parity with standalone Ghostty.

## Decisions and design records

These records preserve rationale. Design records do not claim every described
feature ships today; see the user guides for current behavior.

### Architectural decisions

1. [One Portal view per buffer](adr/0001-one-portal-view-per-buffer.md)
2. [Shared view/native interface](adr/0002-portal-view-native-seam.md)
3. [Platform interface primitives](adr/0003-platform-interface-primitives.md)

### Design records

- [Toolbar design](toolbar-design.md): implemented controls and later ownership
  updates, with historical alternatives.
- [Bun distribution options](bun-distribution.md): current packaging, size
  measurements and alternatives to revisit.
- [Native package installation research](native-package-installation.md): upstream
  build conventions and proposed Portal setup and upgrade behavior.
