---
id: terminal-buffer-metadata
status: todo
---

# Give terminal buffers useful metadata and project ownership

## Problem and outcome

Portal terminals can live for an entire Emacs session, but their generic buffer
names make them difficult to recognize. The current terminal picker searches
only names, and ordinary terminals have no explicit project association or
directory tracking after the shell starts.

Make each terminal an informative Emacs buffer with a stable label, assigned
project, current directory, terminal title, and known process state. Expose this
information through a small Lisp interface and ordinary completion so existing
buffer tools can use it. The follow-up [Consult and Embark integration](terminal-consult-embark.md)
uses this foundation for project-scoped selection and actions.

## Scope and decisions

- Keep the buffer as the session's identity and lifetime owner. Keep user labels
  stable when applications change the terminal title; never recover identity by
  parsing a display name. Choose useful default names, disambiguating projects
  and worktrees that share a basename, and respect explicit user renames.
- Record the assigned project at creation separately from the shell's current
  directory. `cd /tmp` must not remove the session from its assigned project.
  Provide an explicit operation to reassign the project. Use canonical local
  roots, with a configurable resolver that defaults to `project.el` and can
  accommodate Projectile without requiring it.
- Cache metadata in Lisp. Bridge the native title and process-exited state, and
  adopt the pinned Ghostty wrapper's working-directory callback. Initialize the
  directory from the launch context until a reliable shell report arrives.
  Synchronize valid local directory reports with `default-directory` and
  `list-buffers-directory` for ordinary file and buffer commands. Do not treat a
  remote or container path as a host-local directory without enough context.
- Expose session enumeration, metadata, and filtering by assigned project to
  consumers. Keep ordinary and quick terminals distinguishable; preserve the
  quick terminal's existing naming, project identity, and display behavior.
- Enhance ordinary terminal completion with useful context through standard
  completion metadata. Matching must cover the chosen label, project, title,
  and directory rather than leaving all context in non-searchable annotations.
  Preserve the underlying buffer target independently of displayed text.
- Do not depend on Consult, Vertico, Marginalia, or Embark in core Portal.
  Ordinary buffer listings should display useful names and directories, while
  project-aware consumers can explicitly use assigned ownership instead of
  inferring it from the mutable directory.
- Report only facts that are available. An open shell is not proof that it is
  idle or busy, and a terminal title is not an authoritative process name.
  Rich command-completion, activity, and agent-status indicators can follow.

Before implementation, record the default naming format, behavior outside a
project, and policy for accepting directory reports. Keep these choices within
the stable-label and assigned-project contracts above.

## Acceptance criteria

- [ ] Several terminals in one project have distinct, recognizable labels;
  identical project basenames and user renames do not confuse session lookup.
- [ ] Title changes update metadata without overwriting a user label, including
  while the terminal is hidden.
- [ ] Supported shell directory reports update file-command context; missing or
  unsupported reports retain a usable fallback. Assigned project remains stable
  across directory changes and changes only through explicit reassignment.
- [ ] Program exit is distinguishable from a live session and from a killed
  buffer. Closing a buffer removes its metadata without affecting other shells.
- [ ] Standard completion searches the specified fields and resolves the chosen
  candidate to the correct buffer. Core behavior works with no optional
  completion or project packages installed.
- [ ] Existing quick-terminal behavior and buffer-owned lifecycle remain intact.
- [ ] Focused tests cover metadata updates, identity, project filtering, and
  fallback behavior; a graphical smoke test verifies real title/directory/exit
  events through the native bridge. Project checks pass.

## Boundaries and starting points

Process persistence beyond Emacs, saved layouts, a separate session registry,
output search, command composition, and personal Emacs config changes are outside
scope. Users can run tmux or Herdr inside an ordinary terminal when needed.

Read `portal-terminal.el`, `portal-project.el`, `portal-terminal-quick.el`,
`portal-view.el`, `native/Terminal.swift`, `native/CoreCalls.swift`, and the pinned
Ghostty delegate definitions. The source-cited background is in
[research PR #42](https://github.com/xiaoxinghu/portal/pull/42), which introduces
`docs/terminal-session-management-research.md`.
