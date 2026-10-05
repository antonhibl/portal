# Portal documentation

New to Portal? Start with [build and run](../README.md#build-and-run).
All shell examples in these guides run from the repository root, not `docs/`.

## Use Portal

| I want to… | Guide |
| --- | --- |
| Move between Emacs and a native view | [Keyboard ownership and toolbars](keyboard.md) |
| Open HTML, URLs or a saved Markdown preview | [Web views and previews](web-views.md) |
| Draw and save offline | [Local Excalidraw drawings](excalidraw.md) |
| Run shells, switch terminals or use a quick terminal | [Terminals and optional Consult/Embark adapters](terminals.md) |
| Find running agents and understand their activity | [Agent dashboard](agents.md) |
| Present my own command in a panel or set a global shortcut | [Launchers and global shortcuts](launcher.md) |
| Browse, author or complete Markdown tasks | [Markdown task browser and format](tasks.md) |
| Use the separate `project.org` integration | [Org task view](org-tasks.md) |
| Diagnose a blank hosted app or restart its process | [App host lifecycle and diagnostics](app-host.md) |

The repository's current task store is `tasks/`; `project.org` and its archive
are historical references. The Org integration remains available for projects
that use it, but is not a parallel task store to maintain here.

## Build and change Portal

- [Contributing](../CONTRIBUTING.md): build/editor setup, distribution, worktrees
  and checks before a PR.
- [Testing Portal](testing.md): batch coverage, graphical procedures, standalone
  native checks and opt-in smoke tests. Recorded results are not a new test run.
- [Domain vocabulary](../CONTEXT.md): view, terminal, hosted-app and Org task terms.
  For Markdown task identity and readiness, use the [task format](tasks.md#writing-tasks).
- [Implementation and native boundaries](architecture.md): state ownership,
  lifetimes, platform interfaces and failure invariants.
- [Input bridge](terminal-input-bridge.md): key routing and the notification pipe.
- [Hosted-app bridge](editor-bridge.md): message transport and Excalidraw persistence.
- [Hosted app actions](hosted-actions.md): instances, task operations and process
  protocol version 3.
- [Launcher native panel](launcher-native-panel.md): Emacs NS compatibility,
  frame guards, geometry and command sessions.
- [Launcher daily-use validation](launcher-daily-use.md): fresh-session setup,
  M-x.app migration/rollback, automated checks and dated manual acceptance.
- [Application launcher integration](launcher-applications.md): launcher.el
  follow-ups, optional smoke test and the removed built-in adapter's evidence.
- [Terminal benchmarks](terminal-benchmark.md): measuring and interpreting latency
  and frame timing, not a guarantee of parity with standalone Ghostty.

## Decisions, proposals and research

These documents preserve rationale and evidence. A proposal or historical
measurement is not a claim that every described feature ships today; use the
user guides above for current behavior.

### Architectural decisions

1. [One Portal view per buffer](adr/0001-one-portal-view-per-buffer.md)
2. [Shared view/native interface](adr/0002-portal-view-native-seam.md)
3. [Platform interface primitives](adr/0003-platform-interface-primitives.md)

### Design and research records

- [Initial native-view research](../RESEARCH.md): original feasibility and
  proposed architecture, not current setup instructions.
- [Input design proposal](input-design.md): superseded prefix/passthrough model;
  retained for its research.
- [Toolbar design](toolbar-design.md): implemented controls and later ownership
  updates, with historical alternatives and a dated [mockup](toolbar-mockup.html).
- [Markdown task browser specification](task-browser-spec.md): design contract
  and acceptance criteria; [the task guide](tasks.md) describes shipped usage.
- [Task dependency display research](task-dependency-display-research.md):
  alternatives and source comparisons behind the dependency display.
- [Terminal session management research](terminal-session-management-research.md):
  package integration options and the original navigation proposal.
- [Agent discovery research](agent-discovery-research.md): recorded agent
  lifecycles, status-source limitations, fixtures and prototype artifacts.
- [Agent dashboard refresh research](emacs-agent-dashboard-research.md):
  Emacs precedents, refresh policy and measurements.
- [Bun distribution options](bun-distribution.md): current packaging, size
  measurements and alternatives to revisit.
