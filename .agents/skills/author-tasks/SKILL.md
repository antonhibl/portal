---
name: author-tasks
description: Author tasks for the Portal dashboard. Use when creating, updating, or completing this repository's project tasks.
---

# Author tasks

Use the repository's `tasks/` root. Save a regular file as `<name>.md`, or use
`<name>/content.md` with attachments beside it. Discovery is recursive: group
related tasks in a folder, which needs no metadata, or nest them under a parent
task's folder. Every `.md` file with a `status` is a task at any depth, so keep
`status` out of supporting documents.

Start with YAML front matter and an outcome heading:

```markdown
---
id: fix-search
status: todo
depends_on:
  - extract-search-index
---

# Fix search
```

- Use exactly `todo` or `done`. The first level-one heading supplies the title;
  optional YAML `title` overrides it and must be a nonempty string.
- Give new tasks an `id` (lowercase kebab-case, unique in the root) and keep it
  forever; the file can then move or be renamed freely, including between
  folders. Without `id`, the root-relative path without `.md` or `/content.md`
  is the ID, such as `big refactor/extract`. Keep only one of `<name>.md` and
  `<name>/content.md`.
- List prerequisites by ID in `depends_on`; the dashboard orders work and marks
  it ready or blocked from that list alone. Folders imply nothing: a parent
  does not wait for its tasks unless it lists their IDs, and a group cannot be
  a dependency. Before moving a task others depend on, give it an `id` equal to
  its current name when that fits the form. Explain why under `Blocked by`,
  linking the prerequisite files.
- Describe the problem, outcome, scope, and verifiable acceptance criteria.
  Record unresolved decisions before implementation. Checklists and notes
  belong in the body.
- Link other tasks by their relative source paths. Keep other attachments within
  the document's directory: the folder holding a standalone task, its own folder
  otherwise. Update relative links when moving a document.
  The dashboard blocks escaping links; cite repository files outside that boundary
  as code paths for agents to read.
- After the work and checks pass, set YAML `status: done` and record the outcome
  and verification. Keep completed files in place. Save and reload the dashboard
  with `g`; check **Problems** is empty and use **Show completed** to verify
  finished tasks. The dashboard is the task index: **Tree** browses folders,
  **Execution** gives the order to work in.

For detailed discovery and link behavior, read the repository's
[task format](../../../README.md#writing-tasks).
