---
id: terminal-consult-embark
status: done
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

## Decisions

Recorded 2026-09-29, before implementation, after reading `consult-ghostel` at
the pinned revision and Consult 3.10 and Embark 1.2 source.

- **Commands.** `portal-terminal-choose` (all terminals, still `C-b w`) and
  `portal-terminal-choose-project` (the current project's). In either, `M-a`
  (`portal-terminal-choose-map`) switches between the project's terminals and
  all of them, keeping the input. `portal-terminal-select` selects a terminal
  buffer read by name; Embark uses it as the default action. Both pickers
  resolve the project first: a terminal's assigned project, otherwise the
  frame's editing context (`portal-project-context`) through
  `portal-project-function`. Projectile users set that to
  `projectile-project-root` and `consult-project-function` to
  `(lambda (_may-prompt) (projectile-project-root))`.
- **Candidates and order.** One compact string per terminal (label, project,
  directory, title), carrying its buffer; exited and quick are annotations.
  Order is Emacs's buffer list, most recently selected first, with the current
  buffer last; it is read once when the picker opens and not re-sorted. An
  accepted selection is recorded by `switch-to-buffer`; previews use
  `norecord`. Cycling keeps creation order. A "New" group offers
  "New terminal in PROJECT" and "New named terminal in PROJECT…", starting at
  the project root (or the context directory outside a project). Completion
  requires a match, so no input ever creates a terminal.
- **Adapters.** `portal-terminal-consult.el` defines
  `portal-terminal-consult-mode`: the pickers read through `consult--multi`,
  and hidden sources `portal-terminal-consult-source` and
  `portal-terminal-consult-project-source` join `consult-buffer` and
  `consult-project-buffer` under narrowing key `t`, so the default mixed list
  shows each terminal once, as an ordinary buffer. The picker's "New" group
  narrows with `n`. `consult-customize` changes either key. Without the mode,
  the pickers use `completing-read` with category `portal-terminal`.
- **Preview.** Consult only, and manual by default: `M-.` through the
  sources' `:preview-key`; `(consult-customize portal-terminal-consult-source
  :preview-key '(:debounce 0.3 any))` makes it debounced. The preview window is
  the window the picker started from, or the editing window behind a quick
  panel. Quick terminals are not previewed. While the minibuffer is selected,
  a Portal view follows the window the minibuffer returns to, so a terminal
  shown in another frame or window moves into the preview and back when it
  ends. Placing a view never takes the keyboard, so typing stays in the
  minibuffer; `portal-input` resumes a terminal only after the command ends.
- **Embark.** Consult candidates keep category `buffer` (Consult's
  `multi-category` holding the buffer object); the fallback's `portal-terminal`
  candidates get a transformer to the same buffer. `portal-terminal-embark-mode`
  puts a target finder first in `embark-target-finders`: when the current
  target is a buffer naming a live Portal terminal, it becomes a
  `portal-terminal` target. Its map, `portal-terminal-embark-map`, has
  `embark-buffer-map` as its parent, so every buffer action remains, and adds:
  `RET` select, `r` rename, `d` Dired in its directory, `c` another shell
  there, `W` copy its directory, `p` reassign its project, `k` end it. Other
  buffers stay `buffer` targets with the unchanged map. Export uses Embark's
  collectors, so terminal candidates export to Ibuffer; a list mixed with the
  "New" group exports to Embark Collect, as mixed Consult lists do.
- **Ending terminals.** `portal-terminal-confirm-kill` (default t) asks before
  killing a terminal buffer whose program has not exited, through
  `kill-buffer-query-functions`, however it is killed: `C-x k`, Ibuffer,
  Embark, `C-b x`. Quick-terminal reset and forget keep their own prompt.
- **Quick terminals.** Excluded unless `portal-terminal-choose-quick` is
  non-nil; a chosen one opens in the quick panel. From a quick panel, the
  pickers select in the editing window behind it, leaving the panel open;
  cancelling returns to the panel.
- **Versions.** Tested with GNU ELPA Consult 3.10, Embark 1.2, Vertico 2.15 and
  Orderless 1.8, which CMake downloads for the tests with pinned hashes, and
  with MELPA Consult 20260829.1558 and Embark 20260610.302.

## Acceptance criteria

- [x] Current-project selection returns assigned sessions even after their
  shells change directory; all-terminal selection spans projects. A query such
  as `portal api dev` matches context and selects the intended buffer.
- [x] Consult's ordinary and project buffer commands can narrow to terminals
  without duplicate default entries. Existing completion configuration remains
  in control, and Portal still works without the optional packages.
- [x] Recent-use order reflects accepted switches, stays stable while typing,
  and survives canceled previews. Closed candidates fail gracefully.
- [x] Preview/accept/cancel work from an ordinary buffer, a terminal owning
  native input, and a quick panel. Typing stays in the minibuffer until accepted;
  previews never send input to a shell, and cancellation restores placement.
- [x] Embark actions operate on the underlying session despite decorated labels
  or buffer renames. Exported buffer candidates work in Ibuffer, and terminal
  actions do not change behavior for unrelated buffers.
- [x] New-shell actions use the intended project/directory. End-session actions
  follow the shared lifecycle and confirmation policy and affect only the target.
- [x] Focused adapter tests and graphical input/preview smoke tests cover the
  contracts above; documented package versions and project checks pass.

## Outcome

Done 2026-09-30. `portal-terminal-choose` (`C-b w`) and
`portal-terminal-choose-project` pick terminals by recent use from compact,
searchable candidates, widen and narrow with `M-a`, and start terminals only
from their New group. They live in `portal-terminal-choose.el`, with
`portal-terminal-select`. `portal-terminal-consult-mode`
(`portal-terminal-consult.el`) reads them with Consult and adds hidden `t`
sources to `consult-buffer` and `consult-project-buffer`;
`portal-terminal-embark-mode` (`portal-terminal-embark.el`) adds the terminal
actions. Killing a running terminal asks through `kill-buffer-query-functions`
(`portal-terminal-confirm-kill`). The README documents setup, Projectile,
native bindings and the tested versions.

Found while implementing:

- Embark's `RET` and the terminal map's actions are functions that Embark
  calls with the target's name, `portal-terminal-embark-select` among them,
  not commands that read it. Injecting the name into a prompt was fragile, and
  a command that read the current terminal could take the name as its answer.
- A view only follows the selected pane, so a Consult preview left a terminal
  shown elsewhere in place. While the minibuffer is selected, `portal-view`
  now treats the window it returns to as the selected pane (ADR 0001 and
  `CONTEXT.md` say so). Consult's own buffer preview benefits too.
- Hiding a view ends its handoff, as the core's tests require, so a command
  that showed another terminal in the originating pane never resumed a
  terminal, though the prefix map promises to. `portal-input--run` now resumes
  the selected view unless the user ended the handoff, which already cleared
  `portal-input--resume` through its `escape` record, or an error or explicit
  unfocus did. `C-b n` and `C-b w` now resume the terminal they select.
- A terminal view closed but kept its buffer, and a quick terminal, are not
  previewed; Consult would otherwise show placeholder text.
- Consult 3.10 computes a hidden source's items only while it is narrowed to,
  and Vertico skips its update while input is pending. Stand-ins for
  `completing-read` cannot narrow, and the graphical tests must type as a
  person does. Batch Emacs opens a real minibuffer while it executes a keyboard
  macro, so the adapter suites type into one.
- With `portal-terminal-confirm-kill` off in the test suites, `C-b x`'s old
  confirming `y` leaked into the next test; that test now answers the real
  question with the option on.

## Verification

- `ctest --test-dir build`: all 23 suites pass, including the new
  `terminal-choose`, `terminal-consult` and `terminal-embark` suites and the
  view suite's minibuffer-origin test. The adapter suites also pass against the
  MELPA snapshots named above. Each of these fails under a matching mutation:
  showing the hidden source, dropping the target finder, never asking before a
  kill, choosing inside the quick panel, creation order, previewing quick
  terminals, ignoring `M-a`, and removing the minibuffer-origin rule.
- The graphical suite, with the new picker tests and `build/elpa`, after the
  last change to Lisp outside the tests: one full run passed 60 of 61 with the
  usual skip. Six other full runs each failed one to four key-injection tests,
  a different set each time (Excalidraw, Markdown, input, terminal and picker
  tests), while the desktop was in use by another app; `main` failed one such
  test in one of two runs then. The picker tests passed together in six of
  seven runs alone, and the cross-frame one's accept step timed out in three of
  the seven full runs, each time alongside other injection failures. After the
  screen locked, every native-binding injection failed, as it does on `main`.
  **Before merging:** rerun the graphical suites with Emacs in front and the
  screen unlocked. A stalled picker test now reports the minibuffer and focus
  state from before its timeout.
- Every Lisp file, the adapters and the new tests byte-compile without
  warnings.

## Boundaries and starting points

Persistent daemons, saved layouts, a dedicated management dashboard, terminal
output snapshots/search, Cape/Corfu command composition, and changes to a user's
personal configuration are outside scope. Embark export and existing Ibuffer or
Bufler workflows supply the initial list-management experience.

Read `portal-terminal.el`, `portal-input.el`, `portal-terminal-bindings.el`,
`portal-view.el`, and the metadata interface from the prerequisite. Background:
[research PR #42](https://github.com/xiaoxinghu/portal/pull/42) and
[consult-ghostel](https://github.com/dakra/ghostel/tree/eb53ff37994d5e43851432a710468bc1445453fa/extensions/consult-ghostel).
