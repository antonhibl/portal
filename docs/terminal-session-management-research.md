# Terminal session management research

Researched 2026-09-28. This note explores terminal navigation and actions within
Emacs. Process persistence beyond Emacs and saved window layouts are outside the
proposed scope. The package behavior below is verified against upstream docs and
source; Portal commands and integrations described as proposals do not yet exist.

## Recommendation

Make existing terminal buffers easier to find and act on: add reliable metadata and project ownership in Portal, then optional Consult and Embark adapters. Preserve ordinary buffer lifetime and normal Emacs window navigation. The closest existing example is `consult-ghostel`; no new background service, layout manager, or completion UI is needed.

## What the completion stack already provides

| Package | Existing responsibility | Proposed Portal use |
| --- | --- | --- |
| Vertico | UI for ordinary Emacs completion, including groups and annotations | Reuse the user's minibuffer and navigation keys |
| Orderless | Match space-separated components in any order | Find a terminal by project, name, directory, or title |
| Consult | Sources, narrowing, preview, and project-scoped commands | All-session and project-session selection |
| Marginalia | Additional display annotations | Show terminal context consistently in existing buffer prompts |
| Embark | Actions and collection/export based on candidate type | Rename, close, inspect, and collect selected terminals |
| Cape / Corfu | Completion providers / UI for text edited in Emacs | A possible later command composer, rather than the session picker |

Vertico needs no Portal-specific UI integration when a command uses standard
completion tables. Orderless is a matching policy, not a terminal index: Portal
must supply the searchable candidate strings. Its default styles include literal
and regexp matching; arbitrary fuzzy subsequence matching depends on the user's
configured styles. [Vertico README](https://github.com/minad/vertico/blob/a9998a777f1d92348f84d091bb15b87df933a7a2/README.org),
[Orderless README](https://github.com/oantolin/orderless/blob/3d2c2e6468ddf51e69c78e8212e5fd9006d2ce8a/README.org).

Marginalia recommends that new commands provide ordinary completion annotations
or affixation metadata instead of depending on its internal functions. Its
category annotators are useful when enriching existing commands. Annotations
are display metadata, so putting a command title only in the right-hand
annotation does not make it searchable through ordinary Orderless matching.
[Marginalia extension guidance](https://github.com/minad/marginalia/blob/42eafcfddbe88d92ed96521a00a5a90a49bac4dd/README.org#adding-custom-annotators).

**Proposed candidate contract:** each terminal has a stable identity and an
optional user label. The picker searches a compact string containing label,
project, title, and directory; changing a title must not change identity. Extra
status details can remain annotations. For example, `portal server api` should
find a terminal labelled `server` in project `portal`, currently in `api/`.
Snapshot these strings while the picker is open so output does not continually
reorder candidates. Resolve the final choice to the live buffer and check that
it still exists.

## Consult: extend existing navigation

Consult documents custom sources in `consult-buffer-sources` and
`consult-project-buffer-sources`. Sources can provide items, a completion
category, a narrowing key, annotations, an action, a creation handler, and a
preview state. Items can be display-string/value pairs. Preview can be immediate,
debounced, manually triggered, or disabled. This supports a dedicated picker and
an optional terminal source in ordinary buffer selection without another
session-list UI. The documented extension surface still uses helpers such as
`consult--read` and `consult--buffer-state`; these are internal APIs whose changes
must be confined to an adapter. [Consult extension documentation](https://github.com/minad/consult/blob/3c64214db5cd61a8f8186e4dce89c0e04be1652c/README.org#multiple-sources).

The source implementation retains the underlying value in `multi-category`
metadata. A decorated searchable label paired with a buffer object can therefore
remain a genuine buffer target. Existing buffer preview restores window history
and uses `switch-to-buffer` with `norecord`. These are useful foundations, but
they do not by themselves account for a native view's attachment or keyboard
focus. [Consult source](https://github.com/minad/consult/blob/3c64214db5cd61a8f8186e4dce89c0e04be1652c/consult.el#L3116),
[buffer preview implementation](https://github.com/minad/consult/blob/3c64214db5cd61a8f8186e4dce89c0e04be1652c/consult.el#L4859).

**Proposed progression:** provide all-terminal and current-project-terminal
commands, with recently used sessions first. Add a hidden terminal source to
ordinary Consult selection so a narrowing key shows terminals without duplicating
them in the default buffer list. Start with manual preview if necessary; automatic
preview should preserve minibuffer focus, restore the prior terminal attachment
on cancellation, and never count merely highlighted candidates as recently used.
An explicit creation candidate avoids confusing a mistyped filter with a request
to launch a shell.

## Project identity needs a deliberate policy

Projectile includes non-file buffers by examining `default-directory`; this
makes directory tracking valuable beyond the dedicated terminal picker.
Its existing project commands include terminal launchers, project buffer
selection, and project-switch actions. Portal should participate in these
conventions rather than invent another project database.
[Projectile project-buffer documentation](https://docs.projectile.mx/projectile/projects.html#_project_buffers),
[project-buffer predicate](https://github.com/bbatsov/projectile/blob/f902073c1d10bb125875470c9dcbdcd7c9a1eefb/projectile.el#L4497),
[command reference](https://docs.projectile.mx/projectile/3.2/cheatsheet.html).

Consult's current project integration variable is `consult-project-function`.
Its documented Projectile adapter calls `projectile-project-root`. The separate
`consult-projectile` package combines project, buffer, and file choices, but is
not necessary merely to give Portal a project-scoped source.
[Consult configuration](https://github.com/minad/consult#use-package-example),
[consult-projectile README](https://gitlab.com/OlMon/consult-projectile/-/raw/master/README.org).

**Proposed model:** retain both the project assigned when a terminal is created
and its current working directory. A terminal created for a repository should
not unexpectedly disappear from that project's terminal list after `cd /tmp`.
Offer an explicit policy: assigned project, current directory, or their union.
Use full canonical roots as identities; basename labels alone collide between
worktrees. Update `default-directory` from reliable local directory events for
ordinary file commands. Do not turn an unqualified remote terminal path into a
local Emacs directory or perform remote filesystem probes on every keystroke.

## Embark makes a picker into a manager

Embark already supplies buffer actions and exports buffer candidates to Ibuffer.
Collect buffers support marking and acting on multiple candidates. Its source
understands Consult's buffer-valued `multi-category` metadata and converts it to
the buffer's current name. A Portal source using category `buffer` can retain
these facilities despite decorated display strings.
[Embark overview](https://github.com/oantolin/embark),
[candidate refinement](https://github.com/oantolin/embark/blob/87e53827cf6659dcc4ac4e54be9af34aeca44f6e/embark.el#L2210).

Two viable integration choices:

- **Buffer-first:** preserve category `buffer`, reuse Ibuffer export, and add a
  Portal-specific action dispatcher that checks the chosen buffer. Avoid adding
  terminal-only behavior indiscriminately to every buffer action.
- **Dedicated session category:** offer a focused action map and default action,
  with an explicit exporter that maps sessions to buffers. Unrecognized
  categories fall back to Embark Collect; they do not automatically acquire
  buffer semantics. [Embark exporter configuration](https://github.com/oantolin/embark/blob/87e53827cf6659dcc4ac4e54be9af34aeca44f6e/embark.el#L2732).

Proposed actions include rename the user label, open the working directory in
Dired, open project Magit, create a sibling shell, change assigned project, copy
the directory, and close selected sessions. “Create sibling” means another shell
in the same directory, not cloning a process. Distinguish switching/burying from
termination, and distinguish pasting text from executing it. These actions can
remain ordinary interactive Lisp commands, useful outside Embark too.

## Existing terminal packages validate the approach

`multi-vterm` provides multiple terminals, cycling, and a project terminal;
`vterm-toggle` supplies return-to-editor behavior and a project scoping option.
They demonstrate demand for navigation around long-lived terminal buffers, but
are coupled to vterm rather than directly reusable Portal backends.
[multi-vterm](https://github.com/suonlight/multi-vterm),
[vterm-toggle](https://github.com/jixiuf/vterm-toggle),
[scope option](https://github.com/jixiuf/vterm-toggle/blob/a0051a8b8eaa85f8df54ddb032f5710c1f62779d/vterm-toggle.el#L66).

The closest precedent is **consult-ghostel**. It offers all/project terminal
pickers with preview, recent-use ordering, creation, hidden sources in ordinary
Consult commands, and terminal-title annotations integrated with Marginalia.
Its sources use category `buffer`. This is a concrete example of the intended
scale: an optional completion adapter, not a multiplexer or layout manager.
Portal would still need its own native-focus handling and metadata bridge.
[consult-ghostel source](https://github.com/dakra/ghostel/blob/eb53ff37994d5e43851432a710468bc1445453fa/extensions/consult-ghostel/consult-ghostel.el).

Ghostel also separates creation-time project identity from the directory, with
current-directory, identity-only, and union policies. That distinction is worth
borrowing. Its bookmarks can reopen a live terminal or create a new one from
recorded context; bookmarking is not preservation of the old process.
[Ghostel project scope](https://github.com/dakra/ghostel/blob/eb53ff37994d5e43851432a710468bc1445453fa/lisp/ghostel.el#L360),
[Ghostel manual](https://dakra.github.io/ghostel/).

## Where native terminal rendering changes the answer

Cape provides completion-at-point functions and Corfu displays their candidates
for editable Emacs text. Cape's history completion understands Eshell, Comint,
and minibuffer histories; a native terminal's shell history is not automatically
one of those. Enabling Cape or Corfu in a Portal buffer therefore does not make
the shell's editable command line an Emacs completion region.
[Cape documentation](https://github.com/minad/cape),
[Corfu documentation](https://github.com/minad/corfu).

**Possible later enhancement:** compose a command or an agent prompt in a real
Emacs buffer, using normal editing and Cape/Corfu, then explicitly send it to a
chosen terminal. Use the terminal's directory for file completion. This needs
an intentional input bridge and paste/submit behavior, but no replacement
terminal emulator. Recovering or replacing the shell's existing partially typed
line is a separate, harder feature.

Likewise, searching session metadata is different from searching terminal
output. `consult-line`, Occur, and text-at-point Embark actions cannot read a
native renderer as ordinary buffer text. A read-only output snapshot would make
searching and copying possible later; returning to an exact live terminal row
requires another mapping mechanism. Session selection and management can ship
independently of that work.

## Portal's starting point

Inspected Portal `d691db30d1f137149ae1482d00d10fbb43bdd19a`. A terminal session here means an ordinary buffer-owned terminal, not a newly independent background object. There is no need to introduce a second registry that duplicates buffer lifetime.

- [`portal-terminal.el`](../portal-terminal.el) already provides `portal-terminal-choose`, rename, next/previous, last-terminal, numbered selection, and literal program/argument launch. The picker uses `completing-read` over buffer names; it has neither session annotations nor project filtering. Its cycle list is creation order, whereas a picker can use recent-use order.
- Ordinary terminal buffers receive their starting `default-directory`. They do not retain a separate owning project or synchronize their directory with the running shell. Quick terminals have an explicit project root and separate display behavior; they are excluded from the ordinary picker.
- [`native/Terminal.swift`](../native/Terminal.swift) retains terminal title and process-exited state, and exposes both through view inspection. Title updates currently stop on the native side rather than updating searchable Lisp metadata.
- The pinned Ghostty wrapper already offers delegates for title, working directory, command completion with exit code/duration, bell, and reported progress. Portal can adopt these and send small metadata events through the existing native notification channel. Shell integration or application support is required for some events; a title is not a trustworthy process-status API. [Pinned delegate definitions](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift), [callback dispatch](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/InMemory/TerminalCallbackBridge.swift).
- [`portal-project.el`](../portal-project.el) remembers the last file/Dired editing context per frame; the quick terminal resolves it with `project.el`. A project-aware session picker should resolve its scope before entering the minibuffer, use a terminal's assigned project when invoked there, and support Projectile without changing global project detection.
- [`portal-input.el`](../portal-input.el) already hands native keyboard ownership to an Emacs command, waits for minibuffer completion, and can resume the selected view. [`portal-terminal-bindings.el`](../portal-terminal-bindings.el) supports opt-in native shortcuts to arbitrary commands. The integration can reuse this for buffer/session navigation instead of introducing another key dispatcher.
- The actual screen and scrollback are not Lisp buffer text. [`TerminalSession.text`](../native/Terminal.swift) currently obtains text by selecting everything and leaves that selection active. This is unsuitable as the final background snapshot API for seamless search. A deliberate, bounded, non-destructive text-read operation would be needed.

## Workflow fit from local configuration inspection

The configuration uses Consult for global and project buffer selection, Projectile for finding projects/files, Orderless for matching, Vertico in the minibuffer, Marginalia for annotations, and Embark for actions/export. It also configures Bufler, recent-use histories, a project command menu, and a quick Portal terminal. These observations favor augmenting ordinary buffer selection plus a project-scoped terminal command. They do not imply a need for saved window layouts or a permanent dashboard. Personal configuration files are not reproduced in this note.

Version detail: the installed Consult uses `consult-project-function`, a function accepting `MAY-PROMPT`. An older configuration variable, `consult-project-root-function`, is not bound by that installed package. The integration should verify the installed API and adapt Projectile explicitly; merely setting an obsolete variable does not connect the two. This was checked in an isolated batch Emacs without loading or modifying the user's init. [Current Consult project interface](https://github.com/minad/consult/blob/main/consult.el).

## Proposed user experience

### 1. Search terminals by what they contain

The primary command would show the current project's terminals in recent-use order, with a way to widen to all projects. A dedicated all-terminal command would also be available. Ordinary buffer selection remains useful, with a terminal narrowing source rather than duplicated entries in its initial mixed list.

Illustrative candidates, not an implemented UI:

```text
Terminal in portal: api dev

dev       portal    packages/api/    npm run dev       open
tests     portal    ./               bun test          last exit 1 · 2m ago
shell     portal    native/          zsh               open
```

Search should match the label, project, current directory, reported title, and explicit status fields. The candidate resolves to a buffer object regardless of its displayed text. Keep the user-chosen label stable when commands change the terminal title. Add enough project-path detail to distinguish equally named repositories and Git worktrees. Do not derive identity by parsing the buffer name.

Some information belongs in searchable text, and some can remain annotations: elapsed time is useful to read but need not affect matching. Freeze candidate ordering during a selection and refresh cheaply from cached metadata; avoid querying a process tree or extracting every terminal's scrollback on each keystroke. Preview must not count as an intentional visit for recent-use ordering.

### 2. Separate project ownership from shell location

Record the owning project at creation and track the current shell directory separately. A terminal opened for a project should not disappear from its project picker after `cd /tmp`. Conversely, commands to open a file or Dired from that session can use its actual current directory. Provide an explicit reassign-project action if ownership needs to change.

The local directory can update `default-directory` and `list-buffers-directory` where appropriate, but then stock Consult's directory-based project filter no longer expresses fixed ownership. A Portal project source should filter using the assigned project. Remote/container directory reports must not silently be treated as host-local paths; Portal currently starts local terminals and leaves SSH to the shell.

Suggested behavior: select an existing session with Return; create a new one through an explicit action using the current project and an optional role name. A separate create command avoids turning a mistyped search into a new shell. Keep the existing quick terminal separate by default; an optional "include quick" filter should identify it and use its established display behavior. Switching out of a quick panel needs an intentional dismissal/selection path, since today's regular-terminal switch rejects that context.

### 3. Make terminal actions available where the candidate already is

Embark actions could select the session, rename its label, open Dired in its directory, open another shell there, copy its directory, search a snapshot, reassign its project, or end its terminal. On a file candidate, an optional action could choose a project terminal and paste the shell-quoted path; sending a path and executing a command should remain distinct actions.

Begin with the `buffer` completion category, preserving normal buffer actions and Ibuffer export. Add terminal-specific actions conditionally or in a clearly scoped map instead of replacing every buffer's actions. A separate `portal-terminal` category is an alternative if tailored actions become the main interaction, but it requires explicit target, default action, and export integration.

Ghostty's child is not a normal Emacs `get-buffer-process`, so generic process annotations and kill prompts cannot be assumed to work. Embark/Ibuffer termination needs to use the intended Portal buffer lifecycle, including any shared confirmation policy. An explicit "clean up exited terminals" action is easier to make predictable than heuristically guessing which running shells are expendable.

### 4. Reach all of this while typing in a terminal

Allow the same buffer/project/session shortcuts to be registered in Portal's native keymap. The existing input bridge can hand focus to Consult and resume the chosen terminal after confirmation. This may improve daily use as much as adding a new picker, because a global Emacs binding alone is not automatically intercepted while Ghostty owns the keyboard.

Preview should show a candidate without accepting keyboard input or changing its session identity. Abort should restore the prior buffer and Portal view placement. Since Portal moves one native view between windows and may resize the actual TUI, preview in another frame is not a free clone. Start with manual or debounced preview and verify the minibuffer retains input throughout; test from ordinary buffers and native-terminal focus.

### 5. Search terminal output through ordinary Emacs tools

On-demand read-only snapshots would let `consult-line`, `consult-line-multi`, isearch, copying, and Embark operate on terminal text. A project-wide search could capture a bounded amount from each session, group matches by terminal, and retain source-buffer identity. Refresh would be explicit; selecting a result could open its snapshot at the matching line or jump back to the live session.

This is an additional feature, not something achieved by adding a Consult buffer source. Snapshots represent retained screen/scrollback text, not a complete command transcript. Exact navigation back to a historical live Ghostty row needs more mapping. Do not promise `consult-ripgrep` over terminals without first defining an explicit log/export facility.

### 6. Use Cape and Corfu in an optional command editor

Cape/Corfu complement session navigation through an ordinary Emacs input buffer: compose a command with file/word/history completion and normal editing, choose a session, then paste it there. First keep execution separate from pasting. A project's current directory would give file completion useful context.

This would be a new input surface, not automatic Corfu completion inside Ghostty. It cannot assume that the foreground application is a shell, or that Cape's history is the shell's live history. A full shell-aware completion bridge is a separate investment and should not delay session discovery.

## Choices and recommendation

| Approach | Scope | Fit |
| --- | --- | --- |
| Better ordinary buffer citizens | Stable useful names, current-directory metadata, project membership, annotations | Smallest change; improves existing Consult, Ibuffer, and Bufler immediately |
| Optional Consult terminal extension | All/project picker, searchable metadata, recent-use order, narrowing, preview, actions | Recommended main enhancement; directly matches the user's workflow |
| Dedicated terminal manager view | Persistent table, groups, batch operations | Useful later if needed; begin with Embark export/Ibuffer or Bufler rather than another dashboard |

Implement the first two together in small increments. Core Portal owns metadata and terminal operations and retains a standard `completing-read` fallback. Optional Consult and Embark adapters present those operations; Vertico and Orderless continue to work through normal completion without package-specific core code. Keep `project.el` as a default provider and permit a Projectile resolver for this workflow. Cape/Corfu remain independent optional input enhancements.

Suggested priority:

1. Stable project/label identity, cached title/directory/exited metadata, and a project/all picker with recent-use ordering.
2. Consult sources and safe preview, same shortcuts from native focus, Embark actions, and export through existing buffer tools.
3. Shell-reported command completion/failure and bell/progress indicators. Report unknown states honestly; the exposed delegates do not by themselves prove a command-start or semantic agent-status implementation.
4. Non-destructive output snapshots and project-wide output search.
5. Optional composer, bookmarks of launch recipes, and richer batch management if use demonstrates a need.

Bookmarks or launch recipes would create/reuse an appropriate terminal, not resurrect an exited process. Process persistence remains delegated to tmux/Herdr inside the terminal; layout restoration is outside this design.

## Local verification

- Read the relevant local configuration and installed package sources without loading the user's init or changing its settings.
- A batch Emacs probe confirmed that the installed Consult defines `consult-project-function` and does not define `consult-project-root-function`.
- A second probe constructed a Consult `buffer` source using display-string/buffer pairs. Orderless matched `portal dev` against the metadata-bearing candidate and the candidate still resolved to the original buffer object. No terminal process or graphical preview was involved.
- Native metadata callbacks and current Portal behavior were checked in source at the pinned dependency revision. End-to-end native preview, shell-event delivery, and output snapshots remain implementation experiments; none was claimed as completed.
