---
id: 09-agent-dashboard
status: done
depends_on:
  - terminal-buffer-metadata
---

# Live agent dashboard in Emacs

## Outcome

`M-x portal-agents` provides an ordinary `tabulated-list-mode` buffer with
terminal label, agent, assigned project, process state, activity, directory and
title. `RET` visits and focuses the exact ordinary or quick terminal, including
hidden terminals and terminals in another frame. Tracking is keyed by buffer
and native incarnation, not directory, title or label.

The dashboard consumes cached terminal metadata. It preserves selection,
sorting and window positions, avoids rewriting unchanged rows, and uses one
configurable two-second timer only while visible. Manual refresh remains
available; hiding or killing the dashboard stops its timer.

## Blocked by

[Terminal metadata and project ownership](terminal-buffer-metadata.md) supplies
buffer identity, labels, title, current directory, process state and assigned
project. Directory changes do not reassign project ownership.

## Scope decisions recovered from Org

The original Markdown plan required one-second polling, native status polling
and a Pi heartbeat. During the Org period that plan was explicitly superseded
by a cached Emacs list, completed in
[PR #59](https://github.com/xiaoxinghu/portal/pull/59). The historical record is
`project.org_archive`, `CUSTOM_ID: 09-agent-dashboard` (done 2026-10-02).
This document now records that delivered scope rather than presenting the old
proposal as unfinished work.

Automatic discovery and verified activity were subsequently implemented in
separate completed Org tasks: `agent-discovery-spike`,
`agent-discovery-claude`, `agent-discovery-codex` and `agent-discovery-pi`, all in
`project.org_archive`. They are not outstanding dashboard prerequisites:

- Plain Claude, Codex and Pi launches are discovered through the shared
  foreground-process collector and terminal incarnation marker.
- Claude activity comes from `claude agents --json`; Codex activity is inferred
  from its title and labelled accordingly.
- Pi discovery needs no setup. Pi activity requires the opt-in
  `extensions/portal-pi.ts` source and documented configuration. It uses
  lifecycle events, not the earlier proposed heartbeat.
- Missing or unsupported evidence stays unknown; idle does not prove success.
  Codex title inference and Pi's unauthenticated progress source have documented
  limits. Some retry/compaction paths have only synthetic replay evidence.

Remote/multiplexed terminals, agent control and generated summaries remain
out of scope, not newly commissioned TODOs.

## Acceptance

- [x] The dashboard is an ordinary Emacs text buffer, with no dashboard native
  view, web page or app-host request; movement, isearch, sorting, `g` and `q` work.
- [x] Sessions in the same directory remain distinct; `RET` reaches the correct
  ordinary, hidden, quick or other-frame terminal.
- [x] Labels, title, directory, process state and project use shared metadata.
  Renames preserve tracking; closing/replacing a terminal drops old tracking;
  untracking does not kill the terminal.
- [x] Refresh preserves selection, sorting, window positions and focus;
  unchanged snapshots do not redraw and manual-only operation works.
- [x] Visibility, multiple windows/frames and live-update toggling leave exactly
  one timer when needed and none otherwise.
- [x] ERT, graphical focus/visibility checks, performance comparison and
  documentation were completed for the delivered scope.

## Completion evidence

Reconciled against the matching Org `CUSTOM_ID`, completion record and merged
implementation. These are historical verification results, not new GUI runs:

- PR #59 records all 25 CTest suites passing, nine dashboard ERT tests,
  mutation checks and two new graphical dashboard tests. The combined graphical
  run passed 66 tests with one shell-startup-specific skip.
- An unchanged refresh at 10 / 50 / 100 tracked terminals took
  0.01 / 0.07 / 0.18 ms in the recorded batch benchmark and did not redraw.
  See `docs/emacs-agent-dashboard-research.md` for measurements and limits.
- The later discovery records document real Claude/Codex/Pi smoke tests,
  lifecycle/source-loss coverage and version-specific limitations. The Pi
  completion record reports 31 passing CTest suites and five extension tests.
- Current implementation and regression coverage are in `portal-agents.el`,
  `portal-agent-discovery.el`, `test/portal-agents-tests.el` and the
  `test/portal-agent-discovery-*` suites.
