# Work with Org tasks

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Task view

`M-x portal-tasks` lists actionable tasks from the current project's
`project.org`. It requires MELPA's [org-ql](https://github.com/alphapapa/org-ql),
tested with org-ql 0.8.10 and MELPA's 20250421.133. Other Portal features work
without it.

This Org view is separate from the [Markdown task browser](tasks.md#task-browser),
which reads this repository's authoritative `tasks/` directory.

Tasks are headings with their own `:task:` tag. A task is actionable when its
keyword is `TODO`, every `DEPENDS_ON` prerequisite named by `CUSTOM_ID` is `DONE`,
and it is not scheduled after today. Tasks sort by priority (unset means Org's default), then
nearest deadline, then file order. Deadlines confer urgency, never eligibility.

`v` lists all tasks as Actionable, Blocked, Deferred and Closed. Blocked/deferred
titles are followed by reasons: waiting prerequisites with states and links;
missing prerequisites or shared prerequisite `CUSTOM_ID`; missing/shared own
`CUSTOM_ID`; dependency cycles; non-`TODO` keywords; or scheduled dates.
`CANCELLED` prerequisites block like anything not `DONE`. Closed tasks have done
keywords. Prerequisites may live in Org archives such as `project.org_archive`,
where `org-archive-subtree` moves finished tasks; archived tasks are not listed.

`RET` opens [task detail](#task-detail). Lines are Org agenda lines, supporting
other agenda keys: `t` changes state, `TAB` visits the task in its file. `g` redraws;
`q` leaves.

With [evil-collection](https://github.com/emacs-evil/evil-collection), the view
uses Evil's normal state; evil-collection's agenda keys take precedence. `RET`, `v` and `q`
work as above; `gr` or `gR` redraws. Other agenda keys still work, including
`t` and `r` (refile). Tested with Evil 1.15.0 and evil-collection 3.0.3, and
MELPA's 20260728.1438 and 20260818.145.

Project selection matches [quick terminals](terminals.md#quick-project-terminal):
the terminal's assigned project, or elsewhere, the frame's last selected file
or Dired buffer's project. Each project reuses one view, such as
`*tasks: ~/src/app*`, remembering actionable/all selection. It reads `project.org`
and archive buffers, including unsaved edits. Redraws occur on pane selection
or redisplay after changes or a new day, on saving those files, and on `g`.
Each pane stays on its task.

### Task detail

`RET` opens the project's task detail, such as `*task: ~/src/app*`, in the same
pane: an Org indirect buffer of the task's file, narrowed to the full task,
like `C-c C-x b` for
subtrees. Independent folds leave the file buffer's folds unchanged. Otherwise
it is Org: edit, fold, follow/insert links, tick checkboxes, schedule, and change
state with `C-c C-t`. Manual state changes need not respect actionability.
Saving and undo affect the file buffer; unsaved edits remain after leaving detail.

Task `CUSTOM_ID` links, such as `[[#search-index][the index]]`, open detail from
`project.org` or its archives, as do blocker links. Org handles other links
normally. `M-,`, wherever `xref-go-back` is bound, returns to the previous task
and position, and finally the view's originally opened task. Returning redraws
readiness from your edits. Back recreates a killed view, retaining all-tasks
selection if set. Each project reuses one detail, locating tasks anew by file
and `CUSTOM_ID` across `project.org` and archives. Tasks with missing or shared
`CUSTOM_ID` open in their files, as in Org agenda; links to shared `CUSTOM_ID`
report ambiguity rather than choosing a task.

`DONE` and `CANCELLED` tasks remain Closed. Reopen by setting `TODO` in detail
or with `t`. Reopening/cancelling changes only the keyword, preserving sections.
Cancellation does not stop a terminal working on the task.

### Starting Claude on a task

`M-x portal-tasks-implement` starts Claude on the actionable task at point in
the view, task detail or `project.org`. It has no key binding; add one if desired.
Claude starts at the project root in a new task-named terminal, such as
`*claude: search-index*`. Each launch reads `portal-tasks-claude-program` and
`portal-tasks-claude-arguments`, then appends the initial prompt;
[Implementing a task](tasks.md#implementing-a-task) describes these settings and
the shell resolving the program. Claude may ask about trust on first use in a folder.

New and existing runs follow `pop-to-buffer` placement rules. Configure
`display-buffer-alist` or `display-buffer-base-action`; for example, show
`*claude: ...*` terminals full-frame:

```elisp
(add-to-list 'display-buffer-alist
             '("\\`\\*claude: " display-buffer-full-frame))
```

Launch first rechecks actionability using Emacs's `project.org` and archives;
ineligible tasks start nothing and report why. Emacs offers to save unsaved
`project.org` changes. Declining, save failure, a save hook changing the buffer
or file again, or `project.org` changing on disk since read all prevent launch
and preserve edits. Revert or save, then retry.

The initial prompt tells Claude to read the brief first, implement following
repository instructions, then, once work and checks pass, mark the task `DONE`
in `project.org` by `CUSTOM_ID` and record verification there, normally in the
implementation PR. Launch changes no task. There is no shared in-progress
state; other checkouts receive completion through Git.

The brief is a new file in `temporary-file-directory`, readable only by you
and writable by nobody, such as `portal-task-search-index-AbC123.org`. It holds
only the saved task subtree and child sections, not neighbors or prerequisites.
Preceding comments give the project, `project.org` path, task `CUSTOM_ID`,
original lines and saved-file SHA-256. Links remain relative to `project.org`;
line numbers only record the original location. An `@` mention attaches the
brief to Claude Code's first message under normal permissions, without a tool
call or permission prompt. Its lifetime matches the terminal: buffer kill,
ending the terminal with `C-c C-k`, or Emacs exit deletes it; killing Emacs
itself leaves it in the
temporary directory.

Rerunning shows the task's existing terminal instead of launching again.
`C-u M-x portal-tasks-implement` starts another.
