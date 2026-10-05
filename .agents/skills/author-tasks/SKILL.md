---
name: author-tasks
description: Author Markdown tasks in tasks/. Use when creating, updating, or completing this repository's project tasks.
---

# Author tasks

Use the repository-root `tasks/` directory as the source of truth. Keep each
task's plan, decisions, acceptance criteria, and completion record in its
Markdown document. `project.org` and `project.org_archive` are historical
references, not a parallel task store to maintain. If a requested task exists
only in Org, move its relevant content into a Markdown task, preserving its
`CUSTOM_ID` as `id` and checking its prerequisite references.

## Locate and choose a layout

Find an existing task by its front matter `id` or source path and read its
whole document plus relevant prerequisites before editing. Use one of these
layouts for a new task:

```text
tasks/
  fix-search.md              # standalone task
  task-preview/              # task with supporting assets
    content.md               # the task's sole authoritative document
    mockup.png
    notes.md                 # supporting document, without status
```

Prefer `<name>.md` for a text-only task. Use `<name>/content.md` when mockups,
images, or other supporting files belong with it. Keep only one of
`<name>.md` and `<name>/content.md`. Discovery is recursive: folders can group
related tasks without having a `content.md` of their own. Every Markdown file
with a front matter `status` is a task, so supporting documents omit `status`.

For an agent handoff, identify the repository, task source path, and stable
`id`. Update that document, not a copied brief or an Org subtree.

## Author a task

Start with YAML front matter and an outcome heading:

```markdown
---
id: fix-search
status: todo
depends_on:
  - extract-search-index
---

# Make task search predictable

## Problem and outcome

Search should find a task by its stable ID or words in its title.

## Blocked by

[Search index](extract-search-index.md) supplies stable task identities.

## Plan

Use the shared index for exact-ID and title searches.

## Acceptance

- [ ] Searching by an exact task ID selects that task.
- [ ] Title search preserves the selected task when results refresh.
```

- Give new tasks a unique lowercase kebab-case `id` and preserve it through
  renames, moves, layout changes, and completion. Legacy tasks without `id`
  derive it from the root-relative path without `.md` or `/content.md`; before
  moving one, assign an explicit ID and update dependency references if it
  differs from the old derived ID.
- Use exactly `status: todo` or `status: done`. The first level-one heading
  supplies the title; optional YAML `title` overrides it and must be nonempty.
- Describe the problem, intended outcome, scope, concrete plan, and verifiable
  acceptance criteria. Record unresolved decisions before implementation.
  Use Markdown headings, checkboxes, inline code, and fenced code blocks.
- Link tasks by relative source paths, including `content.md` for folder tasks.
  Keep assets within the task document's directory and link them relatively,
  for example `![Preview mockup](mockup.png)`. Update relative links when moving
  a document, including inbound links. The browser permits task-to-task links
  but confines other local files to the document's directory; cite repository
  files outside that boundary as code paths for agents to read.

## Dependencies

`depends_on` is a YAML list of prerequisite task IDs, not file paths. Omit it
when there are none. Every target must resolve to a task, with no duplicate
edges, self-dependencies, or cycles. Explain each prerequisite under
`Blocked by` and link to its source document.

Only `depends_on` defines dependency edges; folders and prose links do not.
A parent task waits for child tasks only if it lists their IDs. A `todo` task
is ready when all its prerequisites are `done`; inspect those states before
starting dependent work.

## Complete and verify

After implementation and the required checks pass, set `status: done` and
record the outcome and verification in the same document. Update acceptance
checkboxes according to the evidence. Keep completed tasks and their IDs in
place. Reopening sets `status: todo` while retaining completion history.

Check that front matter is valid, IDs and task locations are unique,
dependencies resolve without cycles, and task and asset links reach their
intended targets. When using the Markdown task browser, reload it and check
**Problems**; use **Show completed** to verify finished tasks. Org task-view
commands still read Org and are not verification for this Markdown workflow.

For detailed discovery and link behavior, read the repository's
[task format](../../../README.md#writing-tasks).
