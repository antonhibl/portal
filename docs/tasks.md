# Browse and maintain Markdown tasks

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Task browser

`M-x portal-tasks-browser`, or Lisp's `(portal-tasks-browser)`, lists the current
project's saved Markdown tasks in a navigation-toolbar web view. It opens
immediately, starting the host if needed, and loads on host readiness. Click a
task to read it in the same view; **Tasks** returns to the list. Pages show saved files; Emacs
saves every edit. Nothing moves or deletes task files.

This repository maintains tasks in the default root, `tasks/`: `<name>.md` or
`<name>/content.md` with adjacent assets. `project.org` and `project.org_archive`
are historical references, not a parallel task store. See
[Writing tasks](#writing-tasks) for the format; agents use the
[author-tasks skill](../.agents/skills/author-tasks/SKILL.md).

### Completing and editing tasks

Each row and task page has **Complete** (or **Reopen** when completed) and
**Edit in Emacs**: ordinary buttons separate from task links. Click, or Tab
then Return/Space.

**Complete** and **Reopen** save `status: done` or `status: todo`, changing only
that value. Body, other front matter, comments, quoting, byte order mark and
CRLF endings remain unchanged. Other status forms, such as YAML tags, anchors
or duplicate entries, are left untouched with a request to edit in Emacs.
Unsaved Emacs edits (save first), read-only files, concurrent file changes and
save failures also leave files unchanged and report why: replacement is
whole-file. A final check precedes replacement; as with any editor save, a
concurrent save in that instant could still be overwritten. Unmodified visiting
buffers show the saved file.
Buttons set their named status, so repeated/double presses have the same result.
The page shows progress and reports success only after saving. Saves affect
only the viewed task folder, not commits, branches or other checkouts; worktree
tasks are independent of the main checkout's copies.

**Edit in Emacs** opens current source in another pane with Emacs focus, reusing
any visiting buffer, including unsaved edits. The task page and history remain;
`M-x portal-preview-return` returns.

Saving any file in a task folder through Emacs refreshes that folder's browser
pages from saved files, preserving address, history, view, filter, folds, reading
position and focus; Emacs keeps the keyboard. Hidden views refresh on redisplay;
Back/Forward pages get the same check. If completion filters out a row, focus
moves to its replacement. Deleted, invalid or conflicting tasks show the problem
and a list link. `g` reloads, also picking up changes outside Emacs.

### Implementing a task

**Implement with Claude** on task detail opens a dedicated native terminal
using Emacs display rules. Claude starts at the project root with
`--dangerously-skip-permissions` and a prompt such as `implement @tasks/fix-search.md`.
Folder tasks use their actual `content.md` path. The project is captured on
browser opening; later project selection does not change the launch directory.

The page submits a normal form to the host, which resolves current source by
task ID and requests a terminal through Emacs. Duplicate submissions share one
launch; result-page reloads do not relaunch. Errors appear on the detail page. Folders without
a known project remain browsable but cannot launch Claude.

Before opening the browser, configure `portal-tasks-claude-program` and
`portal-tasks-claude-arguments` to choose the executable and arguments. Defaults
are `claude` and `("--dangerously-skip-permissions")`. The terminal runs your
interactive login shell, loads startup files and resolves `claude` on its PATH.
Programs such as `gh` use shell setup even if GUI-launched Emacs cannot find
them; Portal terminals need no environment-import package. Lisp's `setenv` and
`exec-path` do not configure these programs: use shell dotfiles or an explicit
executable path. Missing-program errors appear in the terminal, as can Claude's
first-run login or setup. Hiding keeps it running; killing its buffer ends it.

See [hosted app actions](hosted-actions.md) for the reusable instance/action
interface and its process protocol. Restart Emacs after rebuilding the native
module, and use the matching app host (protocol 3).

### Choosing the task root

`portal-tasks-directory` defaults to `tasks/` relative to the `project.el` root;
absolute directories are used unchanged. Set it per project in `.dir-locals.el`:

```elisp
((nil . ((portal-tasks-directory . "backlog/"))))
```

The project is the one being edited. Terminals, web views and other auxiliary
buffers use the frame's last selected file/Dired buffer's project, as for
[quick terminals](terminals.md#quick-project-terminal), including its directory-local
settings. Outside projects, the command prompts for a task folder;
`C-u M-x portal-tasks-browser` chooses any local folder. Remote folders are
rejected; path symlinks are resolved.

Each task root reuses one buffer, such as `*portal: tasks ~/src/app/tasks*`,
at its current page; other projects get their own. Missing folders show creation
instructions without creating anything. Folders without tasks show "No tasks";
completed-only folders offer **Show completed**.

### Writing tasks

Tasks are Markdown files or folders containing documents and attachments.
Both work identically at any depth; folders group tasks:

```text
tasks/
  fix-search.md                 # a task
  markdown-navigation/          # a task with attachments
    content.md
    mockup.png
    implementation-notes.md     # a supporting document, not a task
  big refactor/                 # a group: a folder with no task of its own
    extract something in c.md   # a task in the group
    implement something/
      content.md                # a task in the group, with attachments
  assets/
    search.png                  # an attachment of fix-search.md
  README.md                     # a document, since it has no status
```

Any `.md` file under the root can be a task. Exactly `content.md` names its
folder's task, except directly under the root, where it names task `content`.
Other files are supporting material; symlinks are never followed. Documents
become tasks through YAML front matter `status`:

```markdown
---
status: todo
---

# Fix search

Searching with spaces returns no results.
```

`status` is exactly `todo` or `done`. Completed tasks are hidden until
**Show completed**, but their pages remain reachable. Documents without front
matter or `status` are unlisted. Unclosed/non-mapping front matter, invalid
status/title and unreadable files/folders appear under **Problems** with paths;
other tasks still show.

Supporting Markdown inside a task folder with `status` is also a task; it was
ignored before nested folder discovery. Remove `status` to keep it a document.

Titles use front matter `title`, then the first level-one heading outside code
fences, then ID. IDs use front matter `id` or the root-relative path:
`big refactor/extract something in c` for `big refactor/extract something in c.md`,
and `big refactor/implement something` for its `content.md`. Moving
`fix-search.md` to `fix-search/content.md` preserves ID and address. Otherwise,
without `id`, renaming/moving changes both; explicit IDs preserve both across
moves, including between folders. An `id` uses lowercase letters/digits in
single-hyphen-separated words, such as `extract-c-interface`. Before moving a
prerequisite task, assign an `id`; using its current name preserves references
if it fits that form.

IDs, explicit or path-derived, are unique within the root; each location holds
one task. Shared IDs, or coexisting `fix-search.md` and `fix-search/content.md`,
hide both tasks: **Problems** names the files and their pages show the conflict
until resolved. Matching filenames in different folders, such as `a/fix.md` and
`b/fix.md`, are separate tasks.

#### Folders

Folders without their own task are folder-named groups, with no status or ID,
and cannot be dependencies. A task `content.md` makes its folder a titled parent task,
which can hold more tasks/folders. A `content.md` without `status` is a document,
leaving a group; invalid/conflicting ones appear in **Problems**, also leaving
a group so children stay reachable. `a/fix.md` beside taskless `a/fix/` appears
as a task and separate group.

Folders only organize: a parent's `status` and `depends_on` are independent,
never inherited. Completing children completes nothing else; depending on a
parent waits for its own status. To make parents wait for children, list their
IDs in `depends_on`.

#### Dependencies and order

`depends_on` lists the IDs of the tasks that must be done first:

```markdown
---
id: implement-c-adapter
status: todo
depends_on:
  - extract-c-interface
---

# Implement the C adapter
```

Todo tasks are **Ready** when all prerequisites are done, otherwise **Blocked**.
Status remains as saved; nothing auto-completes. Only `depends_on` creates
dependencies; links and body `Blocked by` sections are for readers.
`depends_on` IDs compare exactly, never as paths.

Unfinished tasks are numbered across folders in completion order: prerequisites
first, otherwise by ID. Numbers indicate position, not permission to start.
Blocked tasks are dimmed and name awaited positions, nearest first, such as
`after 7, 6`; beyond three, a count such as `+2` appears. Full-strength tasks
can start now; done titles are dimmed and struck through. Completion renumbers
positions, which refer only to the displayed list. Done tasks satisfy dependents
regardless of their own dependencies. Unorderable tasks and unfinished dependents
have no number: `depends_on` is not an ID list; a task is missing, invalid or
conflicting; or unfinished tasks form a cycle. Rows name the problem, or awaited
task ID when it lacks a position. **Problems** names files and IDs in both views,
including completed tasks.

#### Tree and execution views

Switch views with **Tree** and **Execution** atop the list. Both show identical
numbers, blockers and problems.

- **Tree** (default) shows each task once in its folders. Press a group row or
  parent-task arrow to fold children; arrows are keyboard controls separate
  from task links. Siblings sort by earliest numbered task, then path. This
  browsing order can interleave work across folders. Completed tasks say **done**.
- **Execution** orders unfinished tasks across folders, showing each task's
  containing folders. Unorderable tasks follow under **Blocked
  by dependency problems**, sorted by ID.

Completed tasks are hidden until **Show completed**, except parents containing
unfinished work. Groups with nothing visible are hidden. **Show completed**
reveals the whole tree or adds a separate **Completed** execution section,
without renumbering. View/filter live in the page address and survive links,
Back/Forward, `g` and host restarts. `g` unfolds the tree.

Task pages show ID, readiness, prerequisites and blocked tasks with their
statuses. Completed-task links work with either filter. Folder links above
lead to the list or a parent task.

Press **Complete** on a row/page, or save `status: todo` as `status: done` in
Emacs. Both refresh the browser; `g` rereads the displayed page from saved files,
including after host restarts.

### Links and attachments

Relative links/images resolve from the attachment folder: the containing folder
for single-file tasks (the root for `fix-search.md`, or `big refactor/` for a
task in that group), otherwise the task's own folder. Moves can break relative
links/images even with stable IDs.

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| Another task's file anywhere in the task root, such as `../fix-search.md#notes` | That task's page in the same view, keeping the view and filter |
| An inline image, such as `![Search](assets/search.png)` | Shown in the page |
| Any other file in the attachment folder | Opens in Emacs in another pane, as from a Markdown preview; `#L42` goes to line 42 |
| A missing file, or one outside the attachment folder | Crossed out, with the reason as its tooltip |
| `https://…` and other sites | Opens in the default browser |

Mock-up HTML and code open as Emacs source, never run in the browser. Opening
files preserves the task page/history; `M-x portal-preview-return` returns.
Toolbar Back/Forward, or `l` and `r`, navigate list/task pages, preserving filter
and reading position. Raw HTML appears as text; the host serves only images
from the attachment folder.
