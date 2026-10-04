# Portal

Portal shows native macOS views inside Emacs panes, so an Emacs buffer can present a web page or a terminal as if it were ordinary buffer content.

## Views

**Portal view**:
A native view that an Emacs buffer presents in a pane. A buffer has at most one Portal view, and it appears in the selected pane that shows the buffer, in any frame; while the minibuffer is selected, that is the pane it returns to. The view lives as long as its buffer and is hidden, not ended, while the buffer is not shown.
_Avoid_: native pane, surface (in Elisp), widget

**View kind**:
The native technology that renders a Portal view. There are two: **web** and **terminal**. Every view kind shares the same lifecycle and behaves the same way in panes and frames.
_Avoid_: using a feature name (Excalidraw, Markdown preview, quick terminal) as a view kind

**Web view**:
A Portal view of the web kind. It can show any web content, including a hosted app.
_Avoid_: editor view, preview view, browser

**Terminal view**:
A Portal view of the terminal kind. It runs a terminal session.
_Avoid_: shell view

**Terminal project**:
The project a terminal view's buffer belongs to, by its canonical root: the project it started in, until explicitly reassigned. The shell changing directory never changes it.
_Avoid_: inferring a terminal's project from its current directory or buffer name

**Quick terminal**:
A project's scratch terminal view, summoned into a panel at the bottom of the current frame. Each project has one.
_Avoid_: scratch shell, quick shell

**Agent dashboard**:
The one plain Emacs buffer, opened with `portal-agents`, that lists discovered agent sessions and manually tracked terminals. It has no Portal view, and refreshes itself only while shown.
_Avoid_: agent view, status panel

**Tracked terminal**:
A terminal session explicitly added to the agent dashboard, identified by its buffer and its view, never by its name, directory or title. Untracking leaves it running; closing or replacing the terminal ends tracking, and its program exiting does not.
_Avoid_: watched terminal, registered agent

**Agent session**:
An automatically discovered agent running in a terminal's foreground. A new run is a new session even when it uses the same terminal; hiding its row leaves it running.
_Avoid_: identifying an agent by its terminal title or project

**Agent activity**:
Whether an agent is working, idle or waiting for input, reported by a verified source or explicitly labelled as inferred, or unknown when evidence is unavailable. Idle does not mean successful task completion.
_Avoid_: treating inferred activity as reported fact, inferring activity from process liveness

## System-wide

**Global shortcut**:
A chord, named by a symbol, that calls a Lisp function when pressed in any application, from Emacs's command loop and without activating Emacs. Setting the name again replaces its chord and function; a press from before that, or from before its removal, is ignored. The launcher's chord is one of them.
_Avoid_: hotkey (the platform's primitive that registers a chord), launcher shortcut

## Web content

**Hosted app**:
Web content served by Portal's app host, such as Hello, the Markdown preview, the task browser, or Excalidraw.
_Avoid_: hosted page, editor, UI

**App host**:
Portal's own local server for hosted apps.
_Avoid_: UI host, Bun host, server, host (unqualified)

**Bridge**:
The message channel between a hosted app and the buffer that presents it. Only hosted apps get a bridge; other web content never does.
_Avoid_: editor channel, event pipe

## Tasks

**Task**:
A heading in a project's `project.org` with its own `task` tag, identified by its `CUSTOM_ID`. Its `DEPENDS_ON` property names its prerequisites.
_Avoid_: ticket, issue

**Actionable task**:
A `TODO` task whose prerequisites are all `DONE` and that is not scheduled after today.
_Avoid_: ready task, unblocked task

**Task view**:
The Org agenda buffer of a project's tasks that `portal-tasks` shows: the actionable ones, or all of them with why each is not actionable.
_Avoid_: task browser, which is the hosted app for Markdown tasks

**Task detail**:
A project's one indirect Org buffer, narrowed to the task it shows, where Org edits that task. `RET` in the task view and links to tasks show a task there; Back retraces them to the task view.
_Avoid_: task page, which is the task browser's

**Task brief**:
A read-only snapshot of one task's subtree as saved, with where it came from, that `portal-tasks-implement` has Claude read first. It lasts as long as the terminal Claude runs in; the task itself is updated in `project.org`, found by its `CUSTOM_ID`.
_Avoid_: task file, task copy
