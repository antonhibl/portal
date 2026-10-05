# Browse and maintain Markdown tasks

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Task browser

`M-x portal-tasks-browser`, or `(portal-tasks-browser)` from Lisp, lists the
current project's saved Markdown tasks in a web view with the navigation
toolbar. The view opens
at once and loads the list when the app host is ready, starting the host first
if needed. Click a task to read it in the same view; the **Tasks** link returns
to the list. Emacs stays the editor: the page shows saved files, and every
change to a task is saved by Emacs. Nothing moves or deletes task files.

This repository authors and maintains tasks in `tasks/`, the default root:
either `<name>.md` or `<name>/content.md` with supporting assets beside it.
`project.org` and `project.org_archive` are historical references, not a
parallel task store to maintain. See [Writing tasks](#writing-tasks) for the
format. Agents use the
[author-tasks skill](../.agents/skills/author-tasks/SKILL.md).

### Completing and editing tasks

Each list row and task page has **Complete**, or **Reopen** for a completed
task, and **Edit in Emacs**. They are ordinary buttons, apart from the task
link: click one, or Tab to it and press Return or Space.

**Complete** and **Reopen** save the task with `status: done` or
`status: todo`. They change only that value: the body, other front matter,
comments, quoting, a byte order mark and CRLF line ends all stay as they were.
A status written some other way, such as with a YAML tag, an anchor or in more
than one place, is left alone, and the page asks you to edit it in Emacs. So
are a task with unsaved changes in an Emacs buffer (save it first), a
read-only file, a file that changes while the action runs, and a failed save;
each reports why and changes nothing, since the file is replaced whole. The
file is checked once more just before it is replaced; like any editor's save,
only a save elsewhere in that instant could still be overwritten. An
unmodified buffer visiting the task shows the saved file.
Each button sets the status it names, so pressing it again, or twice, leaves
the task as it asked. The page shows what is happening, and reports success
only once the file is saved. The file is saved in the viewed task folder
alone: no commit, branch or other checkout changes, and a worktree's copy of
a task is independent of the main checkout's.

**Edit in Emacs** opens the task's current source in another pane, reusing a
buffer that visits it, unsaved changes and all, and gives Emacs the keyboard.
The task page and its history stay; `M-x portal-preview-return` comes back.

Saving any file in the task folder in Emacs refreshes the task browser pages
of that folder in place, from the saved files: the address, history, view, filter,
folds, reading position and keyboard focus stay, and Emacs keeps the keyboard.
A hidden view refreshes once it is shown again, and a page that Back or Forward
shows again is checked the same way. Completing a row that the filter hides
moves focus to the row that takes its place. A deleted, invalid or conflicting
task shows its problem, with a link back to the list. `g` still reloads the
page, which picks up changes made outside Emacs.

### Implementing a task

Click **Implement with Claude** on a task detail to open a dedicated native
terminal using Emacs's display rules. Claude starts in the project root with
`--dangerously-skip-permissions` and an initial prompt such as
`implement @tasks/fix-search.md`. Folder tasks use their actual `content.md`
path. The project is captured when the task browser opens; selecting another
project later does not change the launch directory.

The task page submits a normal form to the app host, which resolves the current
source by task ID and requests the terminal through Emacs. Duplicate submissions
share one launch. Reloading the result page does not start another session.
Errors appear on the detail page. A task folder with no known project remains
browsable but cannot launch Claude.

Configure `portal-tasks-claude-program` and `portal-tasks-claude-arguments` before
opening a task browser to choose the executable or adjust its arguments. The
program defaults to `claude`; arguments default to
`("--dangerously-skip-permissions")`. The terminal starts your interactive login
shell, loads its startup files, and resolves `claude` on that shell's PATH.
Programs such as `gh` therefore use your shell setup even when GUI-launched
Emacs cannot find them. No Emacs environment-import package is required for
Portal terminals. Lisp-side `setenv` and `exec-path` changes do not configure
these programs; use your shell dotfiles or an explicit executable path.
A missing program's error appears inside the terminal. Claude's first-run login
or setup can still appear there. The view keeps running when hidden, and
killing its terminal buffer ends it.

See [hosted app actions](hosted-actions.md) for the reusable instance/action
interface and its process protocol. Restart Emacs after rebuilding the native
module, and use the matching app host (protocol 3).

### Choosing the task root

`portal-tasks-directory` names the task root. It defaults to `tasks/`, which is
relative to the `project.el` root; an absolute directory is used as it is. Set
it for one project in that project's `.dir-locals.el`:

```elisp
((nil . ((portal-tasks-directory . "backlog/"))))
```

The project is the one being edited. From a terminal, a web view or another
auxiliary buffer, it is the project of the file or Dired buffer the frame
selected last, as for [quick terminals](terminals.md#quick-project-terminal), and that
project's directory-local settings apply. Outside a project, the command asks
for a task folder, and `C-u M-x portal-tasks-browser` chooses any local folder. Remote
folders are rejected, and symbolic links in the path are resolved.

Each task root has one buffer, such as `*portal: tasks ~/src/app/tasks*`.
Running the command again shows it at its current page; another project gets
its own. A missing task folder shows how to start one, without creating it. A
folder with no tasks shows "No tasks", and one with only completed tasks offers
**Show completed**.

### Writing tasks

A task is a single Markdown file, or a folder holding its document and
attachments. Both work the same, at any depth, and folders group tasks:

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

Every `.md` file under the task root, at any depth, can be a task. A file named
exactly `content.md` is its folder's own task, except directly in the root,
where it is a task named `content`. Other files are supporting material, and
symbolic links are never followed. A document is a task when its YAML front
matter has a `status`:

```markdown
---
status: todo
---

# Fix search

Searching with spaces returns no results.
```

`status` is `todo` or `done`, exactly. Completed tasks leave the list until you
turn on **Show completed**, and their pages stay reachable. Documents without
front matter, or without a `status`, are not listed. Front matter that is not
closed or not a YAML mapping, an invalid status or title, and unreadable files
and folders are listed under **Problems** with their paths, and the other tasks
still show.

Supporting Markdown inside a task folder is a task too once it has a `status`:
before nested folders were discovered, it was ignored. Remove `status` from a
supporting document that should stay a document.

A task's title is its front matter `title`, or else its first level-one
heading outside code fences, or else its ID. The ID is the front matter `id`
or, without one, the task's path in the root: `big refactor/extract something in c`
for `big refactor/extract something in c.md`, and `big refactor/implement something`
for its `content.md`. Moving `fix-search.md` to `fix-search/content.md` keeps
the task's ID and address. Without an `id`, renaming or moving the file changes
both; with one, the task keeps its ID and address wherever it moves, including
into another folder. An `id` is lowercase letters and digits in words joined by
single hyphens, such as `extract-c-interface`. Before moving a task that others
depend on, give it an `id`; its current name keeps their references working
when it fits that form.

IDs are unique in the task root, whether written or taken from a path, and one
location holds one task. If two tasks share an ID, or `fix-search.md` and
`fix-search/content.md` both exist, neither is listed: **Problems** names the
files, and each task's page shows the conflict until it is resolved. The same
file name in two folders, such as `a/fix.md` and `b/fix.md`, is two tasks.

#### Folders

A folder without a task of its own is a group, named after the folder. It has
no status or ID, and it cannot be a dependency. A folder with a task
`content.md` is a parent task, shown with its title, and it can hold more tasks
and folders. When a folder's `content.md` has no `status`, it is a document and
the folder is a group; when it is invalid or conflicting, **Problems** shows it
and the folder is a group, so its tasks stay reachable. `a/fix.md` beside a
folder `a/fix/` with no task of its own shows as a task and a separate group.

Folders only organize work. A parent's `status` and `depends_on` are its own:
nothing is inherited, completing the tasks in a folder completes nothing else,
and depending on a parent waits for that parent's own status. To make a parent
wait for its tasks, list their IDs in its `depends_on`.

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

A todo task is **Ready** when every task it depends on is done, and otherwise
**Blocked** by them. Status stays exactly what you saved: nothing is marked
done for you. Only `depends_on` makes a dependency; links and a `Blocked by`
section in the body are for readers. IDs in `depends_on` are compared exactly
and never read as paths.

Unfinished tasks are numbered in an order they could be completed: each
after what it depends on, and otherwise by ID, across every folder. A number
is a position in that order, not permission to start. A blocked task is dimmed
and names the positions it waits for, nearest first, such as `after 7, 6`; past
three it adds a count, such as `+2`. Everything shown at full strength can
start now. A done task's title is dimmed and struck through. Positions are renumbered as work is done, so they refer only to the
list on screen. A done task satisfies the tasks that depend on it, whatever its
own dependencies. Tasks that cannot be ordered, and the unfinished tasks
waiting on them, have no number: a `depends_on` that is not a list of IDs, a
missing, invalid, or conflicting task, or a cycle among unfinished tasks. Their
rows name the problem, or the task they wait for by ID when it has no position.
**Problems** names each file and ID, including for completed tasks, in either
view.

#### Tree and execution views

The list has two views, switched with **Tree** and **Execution** at its top.
Both show the same numbers, what blocked tasks wait for, and problems.

- **Tree**, the default, shows each task once in its folders. Press a group's
  row, or the arrow beside a parent task, to fold what it holds; the arrows
  are keyboard controls, apart from the task links. Folders and tasks at one
  level follow their earliest numbered task, then their paths. This is for
  browsing: a folder's tasks can be interleaved with other folders' work.
  Completed tasks are marked **done**.
- **Execution** lists unfinished tasks in order across all folders, each with
  the folders holding it. Tasks that cannot be ordered follow under **Blocked
  by dependency problems**, by ID.

Completed tasks are hidden until **Show completed**, except a completed parent
task whose folder still holds unfinished work. A group with nothing to show is
hidden. **Show completed** shows the whole tree, or in the execution view adds
a separate **Completed** section; it changes no number. The view and filter
are part of the page address, so links, Back and Forward, `g`, and an app host
restart keep them. `g` unfolds the tree again.

A task's page shows its ID, the tasks it depends on and the tasks it blocks,
each with its status, and whether it is ready. Links to completed tasks work
with either filter. Its folders, above the page, lead back to the list or to
a parent task's page.

To complete a task, press **Complete** on its row or page, or edit
`status: todo` to `status: done` in Emacs and save. Either way the task browser
refreshes; `g` rereads the page on screen from the saved files, including
after an app host restart.

### Links and attachments

Relative links and images in a task resolve from its attachment folder: the
folder holding a single-file task, such as the task root for `fix-search.md`
or `big refactor/` for a task file in that group, or the task's own folder.
Moving a task can break its relative links and images, even when its ID stays.

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| Another task's file anywhere in the task root, such as `../fix-search.md#notes` | That task's page in the same view, keeping the view and filter |
| An inline image, such as `![Search](assets/search.png)` | Shown in the page |
| Any other file in the attachment folder | Opens in Emacs in another pane, as from a Markdown preview; `#L42` goes to line 42 |
| A missing file, or one outside the attachment folder | Crossed out, with the reason as its tooltip |
| `https://…` and other sites | Opens in the default browser |

Mock-up HTML and code open in Emacs as source; the task browser never runs them.
Opening a file keeps the task page and its history, and
`M-x portal-preview-return` comes back to it. Back and Forward in the toolbar,
or `l` and `r`, move between list and task pages, keeping the filter and reading
position. Raw HTML in a task is shown as text, and the host serves only image
files from the attachment folder.
