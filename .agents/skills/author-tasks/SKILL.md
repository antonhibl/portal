---
name: author-tasks
description: Author tasks for the Portal dashboard. Use when creating, updating, or completing this repository's project tasks.
---

# Author tasks

Use the repository's `tasks/` root. Save a regular file as `<id>.md`, or use
`<id>/content.md` with attachments beside it. Discovery is shallow; other files
in a task folder are supporting material.

Start with YAML front matter and an outcome heading:

```markdown
---
status: todo
---

# Fix search
```

- Use exactly `todo` or `done`. The first level-one heading supplies the title;
  optional YAML `title` overrides it and must be a nonempty string.
- Choose a unique kebab-case ID and keep it stable. Moving `<id>.md` to
  `<id>/content.md` preserves identity; keep only one form and update relative links.
- Describe the problem, outcome, scope, and verifiable acceptance criteria.
  Record unresolved decisions before implementation. Put dependency links under
  `Blocked by`; checklists, dependencies, and notes belong in the body.
- Link other tasks by their relative source paths. Keep other attachments within
  the document's directory: `tasks/` for a standalone task, its folder otherwise.
  The dashboard blocks escaping links; cite repository files outside that boundary
  as code paths for agents to read.
- After the work and checks pass, set YAML `status: done` and record the outcome
  and verification. Keep completed files in place. Save and reload the dashboard
  with `g`; use **Show completed** to verify finished tasks. The dashboard is the
  task index.

For detailed discovery and link behavior, read the repository's
[task format](../../../README.md#writing-tasks).
