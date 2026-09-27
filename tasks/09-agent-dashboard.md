---
status: todo
---

# Live agent dashboard in Emacs

Add `M-x portal-agents`: list tracked Portal terminals with agent, project/path,
working or idle status, attention, and existing job title. Refresh every second;
`RET` selects and focuses the terminal, including hidden and quick terminals.

## Design

- Use `tabulated-list-mode` in `portal-agents.el`. Provide track/untrack,
  refresh, and a cached snapshot callable from Elisp.
- Collect Ghostty progress, notification, title, and cwd callbacks in
  `native/Terminal.swift`; expose cached data through `portal--inspect`.
  Poll with one timer while the dashboard is visible; keep native collection
  active while hidden.
- Track terminals explicitly by buffer and native incarnation, never path/title.
  Ignore pre-registration status; remove closed terminals. Prefer reported cwd,
  falling back to launch directory, and resolve its project/worktree root.
- Choose one status source per terminal. Missing/stale evidence means unknown.
  Notifications indicate attention only; silence or progress-clear does not
  universally mean idle. Idle never means proven success.
- Start with an opt-in Pi extension loaded using `pi --extension PATH` in
  `INSIDE_EMACS=portal-ghostty`. Use `agent_start` and `agent_settled` plus
  `ctx.isIdle()`, not `agent_end`. Emit OSC `9;4;3` for working and
  `9;4;0` for idle, with one-second heartbeats and a five-second stale limit.
  Keep Pi's native progress writer off. Compute event age natively.
- Validate Claude/Codex progress/title behavior before enabling mappings.
  Unsupported cases stay unknown; heuristics must be labelled. OSC assumes one
  cooperating writer; use a structured adapter if stronger guarantees are needed.

## Acceptance

- [ ] Multiple agents, including two in one directory, remain distinct; `RET`
  reaches the correct terminal across frames.
- [ ] Refresh preserves selection, sorting, and focus; hiding/killing the
  dashboard stops its timer.
- [ ] Test working/idle, input waits, cancellation, retries, compaction, stale
  reports, retracking, and terminal replacement. Verify actual harness versions.
- [ ] Cover normalization/timer behavior with ERT, verify graphical focus, and
  document setup and supported harnesses.

Follow-up only: session naming, semantic summaries/LLM calls, automatic discovery,
remote/multiplexed terminals, and agent control.

References: [Ghostty progress](https://ghostty.org/docs/vt/osc/conemu),
[Herdr status sources](https://herdr.dev/docs/agents/#status-authority),
[Pi lifecycle](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/docs/extensions.md).
