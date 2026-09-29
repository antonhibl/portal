---
id: terminal-consult-embark
status: todo
depends_on:
  - terminal-buffer-metadata
---

# Manage project terminals through Consult and Embark

## Problem and outcome

Terminal sessions should be as easy to find and act on as project files and
buffers. Provide an optional Consult and Embark integration over Portal's
ordinary terminal buffers: project/all-session selection, searchable context,
recent-use ordering, previews, and contextual actions. Use existing Emacs
completion and window navigation, without adding a layout manager or dashboard.

## Blocked by

[Terminal metadata and project ownership](terminal-buffer-metadata.md) supplies
stable buffer identity, cached context, and project filtering. This integration
must consume that interface rather than introduce another metadata store or
infer project ownership from candidate names.

## Scope and decisions

- Provide current-project and all-terminal commands. Allow widening a project
  selection to all projects. Resolve the project before opening the minibuffer;
  when invoked from a terminal, use its assigned project. Offer a documented
  Projectile adapter and retain a `project.el` default.
- Add optional terminal sources to `consult-buffer` and
  `consult-project-buffer`, with a configurable narrowing key. Avoid duplicate
  terminal entries in the ordinary mixed list. Retain the standard completion
  fallback when Consult is absent.
- Search compact candidates containing label, project, reported title, and
  current directory, preserving the underlying buffer identity. Display extra
  facts as annotations. Vertico and Orderless should work through the normal
  completion interfaces; they need no Portal-specific UI or hard dependency.
- Order the picker by recent intentional use. Freeze its ordering during a
  selection, do not count previews as visits, and handle buffers disappearing
  before confirmation. Keep cycle commands' ordering independent.
- Select into the current window by default. Support optional manual or
  debounced preview while preserving minibuffer keyboard ownership. Cancellation
  restores the previous buffer and native view placement. Portal has one native
  view per buffer, so preview must account for moving/resizing a live terminal,
  including one already displayed in another frame.
- Offer explicit new-terminal and named-terminal actions in the chosen project;
  a mistyped filter should not silently launch a shell. Exclude quick terminals
  by default and preserve their established display behavior if included.
- Supply Embark actions to select, rename, open Dired in the session directory,
  create another shell there, copy the directory, reassign the project, and end
  the terminal. Creating another shell does not clone a running process.
  Use the `buffer` candidate category to retain normal buffer actions and
  Ibuffer export; scope terminal-only actions to Portal targets.
- Keep termination consistent across picker actions and buffer-list tools.
  Ghostty's subprocess is not an Emacs `get-buffer-process`; do not rely on that
  API for state or termination confirmation. Keep switching/burying distinct
  from ending a session.
- Make the commands available through Portal's existing native input bridge.
  Document opt-in native bindings for the same buffer/project shortcuts users
  employ in Emacs, and resume the selected terminal only after completion ends.
  Handle selection from a quick-terminal panel deliberately.
- Isolate Consult-specific helpers in the optional adapter and document the
  supported package versions. The current project hook is
  `consult-project-function`, accepting `MAY-PROMPT`; do not copy obsolete config
  using `consult-project-root-function`.

Before implementation, record the command names, default preview policy,
narrowing key, and how the scoped Embark action map extends buffer actions.
Study `consult-ghostel` as a precedent, accounting for Portal's native views and
focus ownership rather than assuming its preview implementation transfers.

## Acceptance criteria

- [ ] Current-project selection returns assigned sessions even after their
  shells change directory; all-terminal selection spans projects. A query such
  as `portal api dev` matches context and selects the intended buffer.
- [ ] Consult's ordinary and project buffer commands can narrow to terminals
  without duplicate default entries. Existing completion configuration remains
  in control, and Portal still works without the optional packages.
- [ ] Recent-use order reflects accepted switches, stays stable while typing,
  and survives canceled previews. Closed candidates fail gracefully.
- [ ] Preview/accept/cancel work from an ordinary buffer, a terminal owning
  native input, and a quick panel. Typing stays in the minibuffer until accepted;
  previews never send input to a shell, and cancellation restores placement.
- [ ] Embark actions operate on the underlying session despite decorated labels
  or buffer renames. Exported buffer candidates work in Ibuffer, and terminal
  actions do not change behavior for unrelated buffers.
- [ ] New-shell actions use the intended project/directory. End-session actions
  follow the shared lifecycle and confirmation policy and affect only the target.
- [ ] Focused adapter tests and graphical input/preview smoke tests cover the
  contracts above; documented package versions and project checks pass.

## Boundaries and starting points

Persistent daemons, saved layouts, a dedicated management dashboard, terminal
output snapshots/search, Cape/Corfu command composition, and changes to a user's
personal configuration are outside scope. Embark export and existing Ibuffer or
Bufler workflows supply the initial list-management experience.

Read `portal-terminal.el`, `portal-input.el`, `portal-terminal-bindings.el`,
`portal-view.el`, and the metadata interface from the prerequisite. Background:
[research PR #42](https://github.com/xiaoxinghu/portal/pull/42) and
[consult-ghostel](https://github.com/dakra/ghostel/tree/eb53ff37994d5e43851432a710468bc1445453fa/extensions/consult-ghostel).
