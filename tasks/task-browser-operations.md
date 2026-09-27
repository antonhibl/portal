---
status: todo
---

# Complete and edit tasks from the task browser

## Context and problem

`portal-tasks` currently presents saved Markdown tasks as a read-only list and
detail pages. Completing or reopening a task requires finding its source file,
editing front matter, saving, and manually reloading the task view. The hosted
app already has task identity, Markdown rendering, and attachment handoff to
Emacs; these can support a small set of direct task operations.

Tasks remain plain-text documents versioned with the repository. Each task view
reads one task root in one checkout. An agent's worktree can contain a different
task state from main until its changes are incorporated. This task preserves
that behavior rather than reconciling statuses across checkouts.

## Outcome and scope

Keep the existing list, completed-task filter, and detail pages. Add accessible
controls for completing/reopening tasks and opening their source in Emacs, with
refresh after saves that preserves the user's navigation context.

### Complete and reopen

- Expose Complete for `todo` tasks and Reopen for `done` tasks in both the list
  and detail page. Support ordinary keyboard focus and activation as well as
  mouse use; activating an operation must not also follow the task's detail link.
- Keep exactly two persisted statuses: `todo` and `done`. Resolve the task ID to
  its current source in the viewed root, supporting both `ID.md` and
  `ID/content.md`. Status changes do not move, rename, or delete task files.
- Share one status operation between list and detail controls. Send an explicit
  target status so repeated delivery does not accidentally toggle back. Indicate
  pending work and report success only after the file has been saved; failures
  leave the displayed saved status unchanged and provide a useful explanation.
- Emacs owns file mutation and saving. Preserve the Markdown body, unrelated
  front matter, comments, and line-ending conventions in the status edit. The
  existing reader accepts quoted keys/values and flow-style YAML mappings; a
  line-based `status:` replacement alone is insufficient. Reject an ambiguous or
  unsupported edit explicitly rather than rewriting unrelated document text.
- Do not silently save or overwrite existing unsaved edits. If the source buffer
  is modified, leave it untouched and direct the user to save it in Emacs first.
  Detect external file changes and stale requests before applying a patch. A
  failed save must not be reported as successful or discard buffered changes.
- Completing a row respects the current Show completed filter and leaves
  predictable focus and visible feedback if the row disappears. A completed
  task's open detail remains accessible and can be reopened.
- Write only to the source in the viewed checkout. These actions do not create
  commits, switch branches, or write into another checkout.

### Edit in Emacs

- Provide an explicit Edit in Emacs action from list rows and task details.
  Open the task's current source as editable Markdown, reusing an existing
  visiting buffer and preserving any unsaved contents.
- Reuse the existing local-file handoff: display the source in another pane,
  transfer keyboard focus to Emacs, preserve the task page and its history, and
  support returning through `portal-preview-return`.
- Explicit editing must open source even if Markdown files later acquire a
  default preview association. No Markdown editor is added to the hosted app.

### Refresh after saving

- After a relevant task file is saved in Emacs, refresh affected open task views
  from saved files. Hidden views may defer their refresh until shown.
- Preserve the task root, completed-task filter, current detail, history, and
  reading position where the resulting content permits. Refresh must not create
  a new navigation entry or steal keyboard focus from the source buffer.
- Returning to the task view, including history navigation, should revalidate
  saved state so old pages do not undo the visible effect of an operation. Keep
  explicit reload as recovery and a way to pick up external file changes.
- Changes to title, body, status, or document validity should appear through the
  same refresh behavior. Deleted, invalid, or conflicting tasks retain useful
  diagnostics and a route back to the list.

## Implementation guidance

Reuse the existing hosted-app bridge, Emacs command-loop handoff, task discovery,
and Markdown rendering. Keep the task-command interface small so list/detail
controls do not each implement source resolution, patching, or save handling.
Keep metadata validation and patch planning consistent without duplicating YAML
semantics across the hosted app and Elisp.

Task pages currently inherit the script-blocking Markdown CSP. If interaction
needs a bundled script, give the task hosted app its own policy while preserving
non-executable task content, bounded file access, and existing bridge admission
rules. Use the bridge available when implementing; unrelated portability work
is not a prerequisite. Queue operations that may prompt into the Emacs command
loop, not its process filter.

Read `portal-tasks.el`, `portal-web.el`, `host/tasks.ts`, `host/tasks.css`,
`host/markdown.ts`, `host/server.ts`, `docs/task-browser-spec.md`, and
`docs/editor-bridge.md`. Existing coverage lives in `test/portal-server-tests.el`,
`test/portal-tasks-tests.el`, and `test/portal-tasks-gui-tests.el`.

## Decisions to settle before implementation

- Choose a format-preserving YAML patch strategy, including explicit behavior
  for valid structures that cannot be safely edited. Preserve the existing read
  format; do not quietly narrow discovery to accommodate the writer.
- Specify how command results, document freshness, and save notifications cross
  the existing bridge, and how refresh restores view context. Avoid adding a
  generic command framework or a background polling system for this scope.

## Out of scope

Kanban, `in-progress` or other statuses, task creation, new search/filter systems,
labels, priorities, bulk operations, a web Markdown editor, shared activity or
claim storage, and cross-branch state aggregation are excluded.

Worktree discovery and association are also deferred. A future deterministic
task-to-worktree association may display its name/path as a factual reference.
It must not imply activity, ownership, completion, or any automatic status change.

## Acceptance criteria and verification

- [ ] List and detail controls complete and reopen both task storage forms,
  persist only `todo`/`done`, and work by mouse and keyboard.
- [ ] Status edits preserve unrelated document text and metadata; malformed,
  duplicate, missing, stale, or unsafe targets produce explicit errors without
  unintended writes. Repeated requests do not reverse a successful operation.
- [ ] Tests cover modified source buffers, external changes, failed saves,
  quoted/flow YAML, comments, unknown fields, and BOM/CRLF documents.
- [ ] Edit in Emacs reuses the source buffer in another pane, preserves its
  contents, hands off keyboard focus, and supports returning to the task view.
- [ ] Saving a task updates list/detail content and completion filtering while
  preserving navigation and reading context; hidden views and Back/Forward
  do not silently retain an obsolete status after revalidation.
- [ ] Separate roots/checkouts remain independent. Changing a worktree's task
  does not mutate or derive a new status for the main checkout's copy.
- [ ] Existing discovery, duplicate diagnostics, attachments, local-file
  handoff, and app-host restart recovery continue to work.
- [ ] `./build.sh`, `ctest --test-dir build --output-on-failure`,
  `bun run --cwd host check`, and `bun run --cwd host typecheck` pass. Extend and
  run the affected graphical task tests for real WebKit controls, focus,
  refresh, and history behavior.
- [ ] Update README and relevant task-browser/bridge documentation for the new
  operations and save/refresh workflow, then record verification and mark this
  task done. Follow `AGENTS.md` for the implementation worktree and PR.
