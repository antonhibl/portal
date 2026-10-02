---
name: author-tasks
description: Author tasks in project.org. Use when creating, updating, or completing this repository's project tasks.
---

# Author tasks

Use the repository-root [project.org](../../../project.org) as the source of
truth for task authoring. Keep each task's plan, decisions, acceptance criteria,
and completion record together in its subtree. The retained Markdown files in
`tasks/` serve the existing Portal task browser; it does not read Org, and the
two representations are not synchronized. New tasks and subsequent task edits
belong in `project.org`.

## Locate and scope

Read the file preamble and outline, then find an existing task by `CUSTOM_ID`.
Read its subtree through the next heading of the same or a shallower level,
plus any relevant prerequisites. Resolve the boundaries again before editing;
line numbers can move as other tasks change. Preserve unrelated subtrees.

For an agent handoff, identify the repository, `project.org`, and `CUSTOM_ID`.
Supply the selected subtree and relevant file-level settings or prerequisite
context instead of loading the entire file. A line range is a snapshot; the ID
is the durable locator.

`M-x portal-tasks-implement` starts an agent on a task with a brief: a
read-only snapshot of the task's subtree, with comments naming its project,
`project.org`, `CUSTOM_ID`, line range and source digest. Links in the brief
are relative to that `project.org`. Never edit the brief; update the task in
`project.org` by its `CUSTOM_ID`.

## Author a task

Use level-one headings for areas and level-two headings for tasks. Each task
has a keyword from the file's `#+TODO: TODO(t) | DONE(d) CANCELLED(c)`, an
outcome title, and a local `:task:` tag. Use deeper headings for the task's
sections. For example:

```org
* Task management :tasks:
** TODO Make task search predictable :task:
:PROPERTIES:
:CUSTOM_ID: predictable-task-search
:ID: <fresh-uuid>
:DEPENDS_ON: task-dependencies
:END:

Search finds a task by its stable ID or words in its title.

*** Blocked by
[[#task-dependencies][Task dependencies]] supplies stable task identities.

*** Acceptance
- [ ] Searching by an exact task ID selects that task.
- [ ] Title search preserves the selected task when results refresh.
```

- Give a new task a unique lowercase kebab-case `CUSTOM_ID` and a fresh UUID
  `ID`, generated with `org-id-new` or `uuidgen`. Replace the example placeholder.
  Preserve both identifiers when renaming, moving, or completing a task.
- Preserve migrated `SOURCE` properties as provenance. New tasks need no
  Markdown source or `SOURCE` property.
- Describe the problem, intended outcome, scope, concrete plan, and verifiable
  acceptance criteria. Record unresolved decisions before implementation. Use
  Org headings, `- [ ]` checkboxes, `=inline code=`, and `#+begin_src` blocks.
- Link tasks with `[[#custom-id][Description]]`. Use repository-relative
  `[[file:path][Description]]` links for supporting files; paths are relative
  to `project.org` at the repository root.
- When dates are specified, use native `SCHEDULED:` or `DEADLINE:` timestamps
  immediately below the task heading, before its property drawer. Record only
  known dates.

## Dependencies

`DEPENDS_ON` contains space-separated prerequisite `CUSTOM_ID` values from this
file or its archive, `project.org_archive`, where archived tasks keep their IDs.
Omit the property when there are none. Every target must be a task, with
no duplicate edges, self-dependencies, or cycles. Explain each prerequisite
under `Blocked by` and link to its heading.

Only `DEPENDS_ON` defines dependency edges; area membership and prose links do
not. A TODO task is actionable when all its prerequisites are DONE, not
CANCELLED, and it is not scheduled after today. `M-x portal-tasks` lists the
actionable tasks; its All tasks view says why each other task is not. Org itself
does not enforce `DEPENDS_ON`: inspect prerequisite states before starting
dependent work.

## Complete and verify

After implementation and the required checks pass, change the task keyword to
`DONE` and record the outcome and verification in its subtree. Update acceptance
checkboxes according to the evidence; existing DONE tasks may contain historical
unchecked boxes. Keep completed tasks and their IDs in place. Reopening a task
sets it to `TODO` while retaining its completion history.

To drop a task, set it to `CANCELLED` and record why in its subtree; keep its
sections and IDs. Its dependents stay blocked until their `DEPENDS_ON` changes.
Cancelling changes only the keyword: it does not stop an agent or terminal
working on the task. Any keyword can be set by hand, whatever the task's
readiness.

Check that IDs remain unique, dependencies resolve without cycles, and internal
links reach their intended tasks. Use `org-lint` to check Org structure. Scope
org-ql queries to this project's `project.org` buffer or filename; select actual
tasks with `(tags-local "task")`, combining it with `(todo "TODO")` or `(done)`
as needed. This workflow needs no global agenda configuration.
