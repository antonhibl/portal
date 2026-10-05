# Work with Org tasks

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Task view

`M-x portal-tasks` lists the actionable tasks in the current project's
`project.org`. It needs [org-ql](https://github.com/alphapapa/org-ql) from
MELPA, and is tested with org-ql 0.8.10 and MELPA's 20250421.133. The rest of
Portal works without it.

This Org view is separate from the [Markdown task browser](tasks.md#task-browser),
which reads this repository's authoritative `tasks/` directory.

In the Org view, tasks are headings with their own `:task:` tag. A task is
actionable when its keyword is `TODO`, every task its `DEPENDS_ON` property
names by `CUSTOM_ID` is `DONE`, and it is not scheduled after today. They are
listed by priority, where none counts as Org's default, then nearest deadline,
then file order. A deadline makes a task urgent, never eligible.

`v` switches to all tasks, grouped as Actionable, Blocked, Deferred and Closed.
After its title, a blocked or deferred task says why: each prerequisite it waits
for, with its state and a link to it; a prerequisite that does not exist or
whose `CUSTOM_ID` another task shares; a missing or shared `CUSTOM_ID` of its
own; a dependency cycle; a keyword other than `TODO`; or a date it is scheduled
for. A `CANCELLED` prerequisite blocks like any other that is not `DONE`.
Closed tasks have a done keyword. Prerequisites can also be in the file's Org
archives, such as `project.org_archive`, where `org-archive-subtree` moves
finished tasks; the view does not list archived tasks.

`RET` shows a task in its [detail](#task-detail). Each line is an Org agenda
line, so Org's other agenda keys act on its task: `t` changes its state and
`TAB` goes to it in its file, for example. `g` redraws the view, and `q`
leaves it.

With [evil-collection](https://github.com/emacs-evil/evil-collection), the view
is in Evil's normal state, where evil-collection's agenda keys come before the
view's. There `RET`, `v` and `q` work as above, and `gr` or `gR` redraws the
view. Its other agenda keys still act on a task, such as `t`, and `r`, which
refiles it. This is tested with Evil 1.15.0 and evil-collection 3.0.3, and
with MELPA's 20260728.1438 and 20260818.145.

The project is the one being edited, as for
[quick terminals](terminals.md#quick-project-terminal): in a terminal, the terminal's
own project; elsewhere, the project of the file or Dired buffer the frame
selected last. Each project has one view, such as `*tasks: ~/src/app*`, which
keeps its choice of actionable or all tasks. The view reads the buffers of
`project.org` and its archives, saved or not. It is redrawn when its pane is
selected, or shows it again, after a change or on a new day; when one of those
files is saved; and on `g`. Each pane stays on its task.

### Task detail

`RET` on a task shows it in the project's task detail, such as
`*task: ~/src/app*`, in the same pane. The detail is an Org indirect buffer of
the task's file, narrowed to the task and showing all of it, as `C-c C-x b`
shows a subtree. It has folds of its own, so the file's buffer stays folded as
it was. Everything else is Org: type into the task, fold it, follow and insert
links, tick checkboxes, schedule it, and change its state with `C-c C-t`. Any
state can be set by hand, whether or not the task is actionable. Saving and
undo act on the file's buffer, and edits not yet saved stay there when you
leave the detail.

A link to a task's `CUSTOM_ID`, such as `[[#search-index][the index]]`, shows
that task in the detail, from `project.org` or its archives. So does a blocker's
link in the view. Org follows every other link as usual. `M-,`, wherever
`xref-go-back` is bound, goes back: to the task whose link you followed, where
you were in it, and finally to the view, on the task you opened. The view is
redrawn on the way back, so its readiness reflects your edits. If you killed
the view meanwhile, Back makes it again, listing all tasks if it did. The project has
one detail, reused for each task. Tasks are found again by their file and
`CUSTOM_ID` each time, across `project.org` and its archives. A task without a
`CUSTOM_ID`, or one that shares it, opens in its file instead, as in Org's
agenda, and a link to a shared `CUSTOM_ID` says so rather than pick a task.

`DONE` and `CANCELLED` tasks stay in the view's Closed group. Reopen one by
setting it back to `TODO` in its detail or with `t`. Reopening or cancelling
changes only the keyword, so the task's sections stay. Cancelling a task does
not stop a terminal working on it.

### Starting Claude on a task

`M-x portal-tasks-implement` starts Claude on an actionable task: the one on
the view's line, or the one point is in, in the task detail or in
`project.org` itself. No key is bound to it; bind one if you like. Claude runs
in a new terminal, named after the task, such as
`*claude: search-index*`, at the project root. The program and its arguments
are `portal-tasks-claude-program` and `portal-tasks-claude-arguments`, read at
each start, then the initial prompt; [Implementing a task](tasks.md#implementing-a-task)
describes them and the shell that finds the program. The first time Claude runs in a
folder, it may ask whether you trust it.

Window placement follows Emacs's `pop-to-buffer` rules, for both new and
existing runs. Use `display-buffer-alist` or `display-buffer-base-action`
to choose your layout. For example, to show `*claude: ...*` terminals in the
entire frame, add this to your Emacs config:

```elisp
(add-to-list 'display-buffer-alist
             '("\\`\\*claude: " display-buffer-full-frame))
```

The task is judged again first, from `project.org` and its archives as they
are in Emacs. A task that is not actionable starts nothing, and the message
says why. If `project.org` has unsaved changes, Emacs offers to save it;
declining, or a failed save, starts nothing and keeps the edits. So does a
save hook that changes the buffer or the file again, and a `project.org`
changed on disk since Emacs read it: revert or save it, then try again.

The initial prompt has Claude read the task's brief first and implement the
task, following the repository's instructions. Once the work and its checks
pass, Claude is to mark the task `DONE` in `project.org`, found by its
`CUSTOM_ID`, and record its verification there, normally in the
implementation's pull request. Starting Claude changes no task. There is no
shared in-progress state: other checkouts see the task done through Git.

The brief is a new file in `temporary-file-directory` that only you can read
and no one can write, such as
`portal-task-search-index-AbC123.org`. It holds the task's subtree as saved,
with its child sections, and nothing else: no neighboring tasks or
prerequisites. Comments before it give the project, the path of
`project.org`, the task's `CUSTOM_ID`, the lines it was on and the SHA-256 of
the saved file. Links in the task stay relative to `project.org`, and the line
numbers only record where it was. The prompt names the brief with an `@`
mention, so Claude Code attaches it to the first message under its normal
permissions, with no tool call or permission prompt. The brief lasts as long
as its terminal. It is deleted when the buffer is killed, `C-c C-k` ends the
terminal, or Emacs exits; if Emacs itself is killed, it stays in the
temporary directory.

Running the command on a task whose terminal still exists shows that
terminal instead of starting another run. `C-u M-x portal-tasks-implement`
starts another.
