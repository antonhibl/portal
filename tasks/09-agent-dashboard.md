---
id: 09-agent-dashboard
status: todo
depends_on:
  - terminal-buffer-metadata
---

# Live agent dashboard in Emacs

Add `M-x portal-agents`: list tracked Portal terminals with agent, project/path,
working or idle status, attention, and existing job title. Refresh every second;
`RET` selects and focuses the terminal, including hidden and quick terminals.

## Blocked by

[Terminal metadata and project ownership](terminal-buffer-metadata.md) supplies
buffer identity, labels, title, current directory, process state, and assigned
project. Consume its shared Lisp interface; do not introduce a second metadata
store or project resolver. This task adds agent tracking, status, and attention
on top of that foundation.

## Design

- Use `tabulated-list-mode` in `portal-agents.el`. Provide track/untrack,
  refresh, and a cached snapshot callable from Elisp.
- Collect additional Ghostty progress and notification callbacks in
  `native/Terminal.swift`; expose cached agent data through `portal--inspect`.
  Reuse the prerequisite's title and directory updates. Poll with one timer
  while the dashboard is visible; keep native collection active while hidden.
- Track terminals explicitly by buffer and native incarnation, never path/title.
  Ignore pre-registration status; remove closed terminals. Read directory and
  assigned project from the shared metadata interface, including its launch
  directory fallback. Changing directory must not reassign the terminal's project.
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
- [ ] Labels, title, directory, process state, and project come from shared
  terminal metadata. Renames and directory changes appear without changing
  tracking identity or implicitly reassigning the project.
- [ ] Refresh preserves selection, sorting, and focus; hiding/killing the
  dashboard stops its timer.
- [ ] Test working/idle, input waits, cancellation, retries, compaction, stale
  reports, retracking, and terminal replacement. Verify actual harness versions.
- [ ] Cover normalization/timer behavior with ERT, verify graphical focus, and
  document setup and supported harnesses.

Follow-up only: semantic summaries/LLM calls, automatic discovery,
remote/multiplexed terminals, and agent control.

References: [Ghostty progress](https://ghostty.org/docs/vt/osc/conemu),
[Herdr status sources](https://herdr.dev/docs/agents/#status-authority),
[Pi lifecycle](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/docs/extensions.md).
