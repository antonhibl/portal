---
id: terminal-buffer-metadata
status: done
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

## Decisions

Recorded 2026-09-29, before implementation.

- **Label and naming.** A terminal's label is its buffer name: the name buffer
  lists, Consult and Ibuffer already show. Portal names an ordinary terminal
  once, when it starts, as `*LABEL: PROJECT*`: LABEL is `terminal` for a shell
  and the program's file name for `portal-terminal-start`, such as
  `*claude: portal*`; an explicit name is used as given. PROJECT is the root's
  last directory component, extended with parent components while another live
  terminal's root ends the same way, so worktrees named alike read
  `research/portal` and `portal`. Emacs adds `<2>` to repeat names. Portal
  never renames a terminal afterwards: titles, directory changes and project
  reassignment leave the name alone, so renames with `portal-terminal-rename`
  or `rename-buffer` stay. Lookups use buffer objects and roots, never names.
  Quick terminals keep `*portal-quick:ROOT*`.
- **Outside a project.** An ordinary terminal started outside a project has no
  assigned project, and PROJECT in its name is its abbreviated start
  directory. It appears only in all-terminal listings until reassigned. Quick
  terminals keep their start directory as their root there, as before.
- **Project resolution.** `portal-project-function` maps a local directory to a
  project root (default: `project.el` without prompting;
  `projectile-project-root` also fits). Portal stores its `file-truename` as a
  directory name, and quick terminals use the same function. A new terminal is
  assigned the project of its start directory, which is the current buffer's
  `default-directory`, so a terminal started from another terminal starts in
  that shell's reported directory. `portal-terminal-set-project` reassigns.
- **Directory reports.** Ghostty passes on OSC 7 reports only from this host,
  and its shell integration for zsh and bash sends one at each prompt. Portal
  accepts a report that is an absolute path, not remote syntax, and an existing
  directory, checked with file name handlers disabled so a report never starts
  TRAMP. It then sets the cached directory, `default-directory` and
  `list-buffers-directory`. Anything else is ignored and the last accepted
  directory, initially the start directory, stays.
- **Native changes.** The platform tells the core a terminal changed (title,
  directory or exit); the core sends one `terminal TARGET` record and sends no
  other for that view until Emacs inspects it, so a program retitling itself
  constantly cannot flood the pipe. Lisp reads the new facts with
  `portal--inspect`, which carries text of any length.

## Acceptance criteria

- [x] Several terminals in one project have distinct, recognizable labels;
  identical project basenames and user renames do not confuse session lookup.
- [x] Title changes update metadata without overwriting a user label, including
  while the terminal is hidden.
- [x] Supported shell directory reports update file-command context; missing or
  unsupported reports retain a usable fallback. Assigned project remains stable
  across directory changes and changes only through explicit reassignment.
- [x] Program exit is distinguishable from a live session and from a killed
  buffer. Closing a buffer removes its metadata without affecting other shells.
- [x] Standard completion searches the specified fields and resolves the chosen
  candidate to the correct buffer. Core behavior works with no optional
  completion or project packages installed.
- [x] Existing quick-terminal behavior and buffer-owned lifecycle remain intact.
- [x] Focused tests cover metadata updates, identity, project filtering, and
  fallback behavior; a graphical smoke test verifies real title/directory/exit
  events through the native bridge. Project checks pass.

## Outcome

Done 2026-09-29. Each ordinary terminal is named `*LABEL: PROJECT*` once, owns
an assigned project root, and caches its directory, title and exit in its
buffer. `portal-terminal-buffers`, `portal-terminal-metadata`,
`portal-terminal-set-project` and `portal-project-function` are the interface
for [Consult and Embark integration](terminal-consult-embark.md).
`portal-terminal-choose` searches name, project, directory and title.

Found while implementing:

- The native fact is `pwd`, not `directory`, which already names the start
  directory among a terminal's options.
- Ghostty with `wait-after-command` reported an exit only at the next key
  press, so `exited` stayed false while the dead shell sat there. Portal now
  turns that option off and sets `abnormal-command-exit-runtime` to 0, so
  Ghostty reports every exit at once as a close request. Portal still keeps the
  view and its output, and the next key returns the keyboard to Emacs.
- Emacs's default completion styles match only from a candidate's start, so
  the `portal-terminal` category adds `basic` and `substring` to
  `completion-category-defaults`, as Emacs does for buffers. Users' styles
  still follow them, and overrides win.

## Verification

- `ctest --test-dir build`: all 20 suites pass, including the new
  `terminal-metadata` batch suite and the `terminals` core suite's record
  checks. Each metadata test fails under a matching mutation: trusting any
  directory, dropping context from candidates, renaming on title changes,
  deriving the project from the directory, or removing the category default.
- The full graphical suite: 57 of 58 pass, and the one skipped test passes
  under `sh test/terminal-shell-startup.sh`. It includes the new smoke test: a
  percent-encoded OSC 7 report and zsh integration's `cd` report, a title
  while hidden, and an exit reported at once that keeps the keyboard until the
  next key.
- `build/check-focus` and `build/check-toolbar` pass; C and Swift build with
  warnings as errors, and every Lisp file byte-compiles without warnings.

## Boundaries and starting points

Process persistence beyond Emacs, saved layouts, a separate session registry,
output search, command composition, and personal Emacs config changes are outside
scope. Users can run tmux or Herdr inside an ordinary terminal when needed.

Read `portal-terminal.el`, `portal-project.el`, `portal-terminal-quick.el`,
`portal-view.el`, `native/Terminal.swift`, `native/CoreCalls.swift`, and the pinned
Ghostty delegate definitions. The source-cited background is in
[research PR #42](https://github.com/xiaoxinghu/portal/pull/42), which introduces
`docs/terminal-session-management-research.md`.
