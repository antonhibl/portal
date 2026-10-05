# Terminal session management research

Researched 2026-09-28. This note explores terminal navigation and actions in
Emacs, excluding process persistence beyond Emacs and saved window layouts.
Package behavior was verified against upstream docs and source; proposed Portal
commands and integrations do not yet exist.

## Recommendation

Make existing terminal buffers easier to find and manage: add reliable metadata
and project ownership, then optional Consult and Embark adapters. Preserve
ordinary buffer lifetime and Emacs window navigation. Follow `consult-ghostel`;
no new background service, layout manager, or completion UI is needed.

## What the completion stack already provides

| Package | Existing responsibility | Proposed Portal use |
| --- | --- | --- |
| Vertico | Ordinary Emacs completion UI, including groups and annotations | Reuse minibuffer and navigation keys |
| Orderless | Match space-separated components in any order | Find terminals by project, name, directory, or title |
| Consult | Sources, narrowing, preview, and project-scoped commands | All-session and project-session selection |
| Marginalia | Additional display annotations | Add terminal context to existing buffer prompts |
| Embark | Actions and collection/export by candidate type | Rename, close, inspect, and collect selected terminals |
| Cape / Corfu | Completion providers / UI for editable Emacs text | Possible later command composer, not the session picker |

Standard completion tables need no Portal-specific Vertico integration.
Orderless is a matching policy, not a terminal index: Portal supplies searchable
candidate strings. Default styles include literal and regexp matching; arbitrary
fuzzy subsequence matching depends on user-configured styles.
[Vertico README](https://github.com/minad/vertico/blob/a9998a777f1d92348f84d091bb15b87df933a7a2/README.org),
[Orderless README](https://github.com/oantolin/orderless/blob/3d2c2e6468ddf51e69c78e8212e5fd9006d2ce8a/README.org).

Marginalia recommends ordinary completion annotations or affixation metadata for
new commands, not its internal functions. Category annotators can enrich existing
commands. Annotations are display-only: a title shown only there is not searchable
with ordinary Orderless matching.
[Marginalia extension guidance](https://github.com/minad/marginalia/blob/42eafcfddbe88d92ed96521a00a5a90a49bac4dd/README.org#adding-custom-annotators).

**Proposed candidate contract:** each terminal has stable identity and an optional
user label. Search a compact label/project/title/directory string; title changes
must not change identity. Extra status details can remain annotations. For example,
`portal server api` should find label `server`, project `portal`, directory `api/`.
Snapshot strings while the picker is open to prevent output from reordering
candidates. Resolve the choice to a live buffer and check it still exists.

## Consult: extend existing navigation

Consult documents sources in `consult-buffer-sources` and
`consult-project-buffer-sources`. Sources can supply items, completion category,
narrowing key, annotations, action, creation handler, and preview state. Items
can pair display strings with values; preview can be immediate, debounced,
manual, or disabled. This supports a dedicated picker and optional terminal
source in ordinary buffer selection without another session-list UI. Documented
helpers such as `consult--read` and `consult--buffer-state` remain internal APIs;
isolate changes to these APIs in an adapter.
[Consult extension documentation](https://github.com/minad/consult/blob/3c64214db5cd61a8f8186e4dce89c0e04be1652c/README.org#multiple-sources).

Sources retain underlying values in `multi-category` metadata, so decorated
searchable labels paired with buffer objects remain genuine buffer targets.
Buffer preview restores window history and uses `switch-to-buffer` with
`norecord`, but does not itself handle native view attachment or keyboard focus.
[Consult source](https://github.com/minad/consult/blob/3c64214db5cd61a8f8186e4dce89c0e04be1652c/consult.el#L3116),
[buffer preview implementation](https://github.com/minad/consult/blob/3c64214db5cd61a8f8186e4dce89c0e04be1652c/consult.el#L4859).

**Proposed progression:** add all-terminal and current-project-terminal commands,
recently used first. A hidden source in ordinary Consult selection can offer
terminal narrowing without duplicating default buffer entries. Start with manual
preview if necessary. Automatic preview should preserve minibuffer focus,
restore terminal attachment on cancellation, and never count highlighted
candidates as recently used. An explicit creation candidate distinguishes shell
launches from mistyped filters.

## Project identity needs a deliberate policy

Projectile includes non-file buffers by `default-directory`, making directory
tracking useful beyond the terminal picker. Its project commands include
terminal launchers, buffer selection, and project-switch actions. Portal should
follow these conventions, not invent another project database.
[Projectile project-buffer documentation](https://docs.projectile.mx/projectile/projects.html#_project_buffers),
[project-buffer predicate](https://github.com/bbatsov/projectile/blob/f902073c1d10bb125875470c9dcbdcd7c9a1eefb/projectile.el#L4497),
[command reference](https://docs.projectile.mx/projectile/3.2/cheatsheet.html).

Consult's current project variable is `consult-project-function`; its documented
Projectile adapter calls `projectile-project-root`. The separate
`consult-projectile` combines project, buffer, and file choices but is unnecessary
for a Portal project-scoped source.
[Consult configuration](https://github.com/minad/consult#use-package-example),
[consult-projectile README](https://gitlab.com/OlMon/consult-projectile/-/raw/master/README.org).

**Proposed model:** retain creation-time project assignment and current working
directory separately. A repository terminal should not unexpectedly leave its
project's list after `cd /tmp`. Offer explicit assigned-project, current-directory,
or union policies. Use full canonical roots as identities; basenames collide
between worktrees. Update `default-directory` from reliable local directory
events for ordinary file commands. Never treat unqualified remote paths as local
Emacs directories or probe remote filesystems on every keystroke.

## Embark makes a picker into a manager

Embark supplies buffer actions and Ibuffer export. Collect buffers support
multi-candidate marking and actions. Embark converts Consult's buffer-valued
`multi-category` metadata to current buffer names, so category `buffer` retains
these facilities despite decorated display strings.
[Embark overview](https://github.com/oantolin/embark),
[candidate refinement](https://github.com/oantolin/embark/blob/87e53827cf6659dcc4ac4e54be9af34aeca44f6e/embark.el#L2210).

Two viable integrations:

- **Buffer-first:** preserve category `buffer` and Ibuffer export. Add a Portal
  action dispatcher that checks the chosen buffer; do not add terminal-only
  behavior indiscriminately to every buffer action.
- **Dedicated session category:** provide a focused action map, default action,
  and explicit session-to-buffer exporter. Unrecognized categories fall back to
  Embark Collect, not buffer semantics. [Embark exporter configuration](https://github.com/oantolin/embark/blob/87e53827cf6659dcc4ac4e54be9af34aeca44f6e/embark.el#L2732).

Proposed actions: rename the user label, open the directory in Dired or project
in Magit, create a sibling shell, reassign project, copy directory, and close
selected sessions. “Create sibling” opens another shell in the same directory;
it does not clone a process. Distinguish switching/burying from termination and
pasting from execution. Ordinary interactive Lisp commands remain useful
outside Embark.

## Existing terminal packages validate the approach

`multi-vterm` provides multiple terminals, cycling, and a project terminal;
`vterm-toggle` offers return-to-editor behavior and optional project scoping.
They demonstrate demand for navigating long-lived terminal buffers but are
vterm-coupled, not directly reusable Portal backends.
[multi-vterm](https://github.com/suonlight/multi-vterm),
[vterm-toggle](https://github.com/jixiuf/vterm-toggle),
[scope option](https://github.com/jixiuf/vterm-toggle/blob/a0051a8b8eaa85f8df54ddb032f5710c1f62779d/vterm-toggle.el#L66).

**consult-ghostel** is the closest precedent: all/project pickers, preview,
recent-use ordering, creation, hidden Consult sources, and Marginalia-integrated
title annotations. Its sources use category `buffer`. This is the intended
scale—an optional completion adapter, not a multiplexer or layout manager.
Portal still needs native-focus handling and a metadata bridge.
[consult-ghostel source](https://github.com/dakra/ghostel/blob/eb53ff37994d5e43851432a710468bc1445453fa/extensions/consult-ghostel/consult-ghostel.el).

Borrow Ghostel's separation of creation-time project identity from directory,
with current-directory, identity-only, and union policies. Its bookmarks reopen
live terminals or create new ones from recorded context; they do not preserve
old processes.
[Ghostel project scope](https://github.com/dakra/ghostel/blob/eb53ff37994d5e43851432a710468bc1445453fa/lisp/ghostel.el#L360),
[Ghostel manual](https://dakra.github.io/ghostel/).

## Where native terminal rendering changes the answer

Cape supplies completion-at-point functions; Corfu displays candidates for
editable Emacs text. Cape history completion understands Eshell, Comint, and
minibuffer histories, not automatically a native shell's history. Enabling
Cape/Corfu in Portal does not make the shell command line an Emacs completion
region.
[Cape documentation](https://github.com/minad/cape),
[Corfu documentation](https://github.com/minad/corfu).

**Possible later enhancement:** compose commands or agent prompts in an Emacs
buffer with normal editing and Cape/Corfu, then explicitly send them to a chosen
terminal. Use its directory for file completion. This requires an intentional
input bridge and paste/submit behavior, not a replacement emulator. Recovering
or replacing a partially typed shell line is a separate, harder feature.

Metadata search is distinct from output search. `consult-line`, Occur, and
text-at-point Embark actions cannot read native rendering as buffer text.
Read-only snapshots could enable searching and copying; returning to exact live
terminal rows needs another mapping mechanism. Session selection and management
can ship independently.

## Portal's starting point

Inspected Portal `d691db30d1f137149ae1482d00d10fbb43bdd19a`. Sessions here are
ordinary buffer-owned terminals, not independent background objects. No second
registry is needed to duplicate buffer lifetime.

- [`portal-terminal.el`](../portal-terminal.el) provides `portal-terminal-choose`, rename, next/previous, last-terminal, numbered selection, and literal program/argument launch. Its `completing-read` picker uses buffer names without annotations or project filtering. Cycling follows creation order; a picker can use recent-use order.
- Ordinary terminals receive starting `default-directory` but retain no owning project or shell-directory synchronization. Quick terminals have explicit project roots and separate display behavior; the ordinary picker excludes them.
- [`native/Terminal.swift`](../native/Terminal.swift) retains title and process-exited state for view inspection. Title updates stop natively rather than updating searchable Lisp metadata.
- The pinned Ghostty wrapper offers title, working-directory, command-completion (exit code/duration), bell, and progress delegates. Portal can send these as small metadata events through its native notification channel. Some require shell integration or application support; titles are not trustworthy process-status APIs. [Pinned delegate definitions](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift), [callback dispatch](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/InMemory/TerminalCallbackBridge.swift).
- [`portal-project.el`](../portal-project.el) remembers each frame's last file/Dired editing context; quick terminals resolve it with `project.el`. Resolve picker scope before entering the minibuffer, use a terminal's assigned project when invoked there, and support Projectile without changing global project detection.
- [`portal-input.el`](../portal-input.el) transfers native keyboard ownership to Emacs commands, waits for minibuffer completion, and can resume the selected view. [`portal-terminal-bindings.el`](../portal-terminal-bindings.el) offers opt-in native shortcuts to arbitrary commands. Reuse this for buffer/session navigation, not another key dispatcher.
- Screen and scrollback are not Lisp buffer text. [`TerminalSession.text`](../native/Terminal.swift) selects everything and leaves that selection active: unsuitable for seamless background search. A deliberate, bounded, non-destructive text-read operation is needed.

## Workflow fit from local configuration inspection

The configuration uses Consult for global/project buffer selection, Projectile
for projects/files, Orderless matching, Vertico's minibuffer, Marginalia
annotations, and Embark actions/export. Bufler, recent-use histories, a project
command menu, and a quick Portal terminal are also configured. This favors
augmenting ordinary buffer selection and adding a project-scoped terminal
command, not necessarily saved layouts or a permanent dashboard. Personal
configuration files are not reproduced here.

The installed Consult defines `consult-project-function`, a function accepting
`MAY-PROMPT`, but does not bind the older `consult-project-root-function`. Verify the installed
API and adapt Projectile explicitly; setting an obsolete variable cannot connect
them. This was checked in isolated batch Emacs without loading or modifying the
user's init. [Current Consult project interface](https://github.com/minad/consult/blob/main/consult.el).

## Proposed user experience

### 1. Search terminals by what they contain

The primary command would list current-project terminals, recently used first,
with an option to widen to all projects. Also offer a dedicated all-terminal
command. Ordinary buffer selection remains useful: a terminal narrowing source
avoids duplicate entries in its initial mixed list.

Illustrative candidates, not an implemented UI:

```text
Terminal in portal: api dev

dev       portal    packages/api/    npm run dev       open
tests     portal    ./               bun test          last exit 1 · 2m ago
shell     portal    native/          zsh               open
```

Search label, project, current directory, reported title, and explicit status
fields. Resolve candidates to buffer objects regardless of display text. Keep
user labels stable across title changes and include enough project-path detail
to distinguish equally named repositories and Git worktrees. Never derive
identity from buffer names.

Some details, such as elapsed time, can remain annotations without affecting
matching. Freeze ordering during selection and refresh cheaply from cached
metadata, not per-keystroke process-tree queries or full-scrollback extraction.
Preview must not count as a recent-use visit.

### 2. Separate project ownership from shell location

Record creation-time project ownership separately from current shell directory.
Keep terminals in their project picker after `cd /tmp`; file/Dired commands can
use the actual directory. Provide explicit project reassignment.

Local directories can update `default-directory` and `list-buffers-directory`
where appropriate, but stock Consult's directory-based filter then cannot
express fixed ownership. Filter Portal's project source by assigned project.
Never silently treat remote/container reports as host-local paths; Portal
currently starts local terminals and leaves SSH to the shell.

Suggested behavior: Return selects an existing session; an explicit action
creates one using the current project and optional role name. A separate create
command prevents mistyped searches from launching shells. Exclude quick
terminals by default; an optional "include quick" filter should identify them
and use their established display behavior. Leaving a quick panel needs an
intentional dismissal/selection path: today's regular-terminal switch rejects
that context.

### 3. Make terminal actions available where the candidate already is

Embark could select sessions, rename labels, open Dired or another shell in the
directory, copy it, search snapshots, reassign projects, or end terminals. An
optional file-candidate action could choose a project terminal and paste the
shell-quoted path. Keep sending paths separate from executing commands.

Start with category `buffer` to preserve normal actions and Ibuffer export.
Add terminal actions conditionally or in a scoped map, not by replacing every
buffer's actions. Alternatively, use `portal-terminal` if tailored actions
become primary; it requires explicit target, default action, and export
integration.

Ghostty's child is not a normal Emacs `get-buffer-process`: generic process
annotations and kill prompts may not work. Embark/Ibuffer termination must
follow Portal's buffer lifecycle and any shared confirmation policy. Prefer
explicit "clean up exited terminals" over guessing which running shells are
expendable.

### 4. Reach all of this while typing in a terminal

Allow buffer/project/session shortcuts in Portal's native keymap. The input
bridge can hand focus to Consult and resume the chosen terminal on confirmation.
This may help as much as a new picker: global Emacs bindings are not automatically
intercepted while Ghostty owns the keyboard.

Preview candidates without accepting keyboard input or changing session identity.
Abort must restore the prior buffer and view placement. Portal moves one native
view between windows and may resize the actual TUI; another-frame preview is not
a free clone. Start with manual or debounced preview; verify the minibuffer
retains input throughout, from both ordinary buffers and native-terminal focus.

### 5. Search terminal output through ordinary Emacs tools

On-demand read-only snapshots would support `consult-line`, `consult-line-multi`,
isearch, copying, and Embark on terminal text. Project-wide search could capture
bounded text per session, group matches by terminal, and retain source-buffer
identity. Refresh explicitly; selecting a result could visit its snapshot line
or return to the live session.

This is separate work, not a consequence of adding a Consult buffer source.
Snapshots represent retained screen/scrollback, not complete command transcripts.
Exact navigation to historical live Ghostty rows needs more mapping. Do not promise
`consult-ripgrep` over terminals without an explicit log/export facility.

### 6. Use Cape and Corfu in an optional command editor

An ordinary Emacs input buffer could complement navigation: compose commands
with Cape/Corfu file/word/history completion and normal editing, choose a session,
then paste. Initially keep execution separate. A project's current directory
would provide file-completion context.

This would be a new input surface, not automatic Corfu completion inside Ghostty.
Neither a foreground shell nor shared Cape/shell live history can be assumed.
A full shell-aware completion bridge is separate work and should not delay
session discovery.

## Choices and recommendation

| Approach | Scope | Fit |
| --- | --- | --- |
| Better ordinary buffer citizens | Stable useful names, current-directory metadata, project membership, annotations | Smallest change; immediately improves Consult, Ibuffer, and Bufler |
| Optional Consult terminal extension | All/project picker, searchable metadata, recent-use order, narrowing, preview, actions | Recommended main enhancement; matches the user's workflow |
| Dedicated terminal manager view | Persistent table, groups, batch operations | Possible later; start with Embark export/Ibuffer or Bufler, not another dashboard |

Implement the first two together in small increments. Core Portal owns metadata
and operations, retaining a standard `completing-read` fallback. Optional Consult/Embark adapters
present them; Vertico/Orderless use normal completion without package-specific
core code. Default to `project.el`, permitting a Projectile resolver. Cape/Corfu
remain independent optional input enhancements.

Suggested priority:

1. Stable project/label identity, cached title/directory/exited metadata, and a project/all picker with recent-use ordering.
2. Consult sources, safe preview, the same shortcuts from native focus, Embark actions, and export through existing buffer tools.
3. Shell-reported command completion/failure and bell/progress indicators. Preserve unknown states: exposed delegates alone do not prove command-start or semantic agent-status implementation.
4. Non-destructive output snapshots and project-wide search.
5. Optional composer, launch-recipe bookmarks, and richer batch management if needed in use.

Bookmarks/launch recipes would create or reuse appropriate terminals, not
resurrect exited processes. Delegate process persistence to tmux/Herdr inside the
terminal; layout restoration remains outside this design.

## Local verification

- Read relevant local configuration and installed package sources without loading or changing the user's init/settings.
- Batch Emacs confirmed installed Consult defines `consult-project-function`, not `consult-project-root-function`.
- A second probe built a Consult `buffer` source from display-string/buffer pairs. Orderless matched `portal dev` against the metadata-bearing candidate, still resolving to the original buffer. No terminal process or graphical preview was involved.
- Checked native metadata callbacks and Portal behavior in source at the pinned dependency revision. End-to-end native preview, shell-event delivery, and output snapshots remain implementation experiments, not completed work.
