# Agent workflow

Any task that changes code runs in its own git worktree, on a new branch off `main`. The main checkout stays on whatever the user has there.

The task is done when its changes are committed on that branch and the project's checks pass. At that point, push the branch and open a PR against `main` with `gh pr create`.

## Authoring tasks

When creating or updating project tasks, use the dashboard's default `tasks/`
root. Read [the task format](README.md#writing-tasks) for discovery and link rules.

- Save a standalone task as `tasks/<id>.md`. For a task with attachments, use
  `tasks/<id>/content.md` and keep its supporting files in that folder. Discovery
  is shallow; only these two layouts are tasks. Use regular files.
- Start the file with YAML front matter containing `status: todo`, then a `#`
  heading naming the outcome. The only statuses are lowercase `todo` and `done`.
  The heading supplies the title; use a nonempty YAML `title` only to override it.
- Choose a unique, descriptive kebab-case ID. Keep it stable when editing the
  title or status. To add attachments later, move `<id>.md` to `<id>/content.md`,
  update relative links, and retain only one form of that ID.
- Describe the problem, intended outcome, scope, and verifiable acceptance
  criteria. Link dependencies to their task source files under a `Blocked by`
  heading. Record unresolved decisions explicitly; clarify them before building.
  Dependencies, checklists, and notes belong in the body, not invented metadata.
- Resolve links relative to the task document. Link other tasks by their `.md`
  or `content.md` source path. Keep other attachments within the task's folder
  (or within `tasks/` for standalone tasks); the dashboard blocks escaping links.
  Refer to repository files outside that boundary as code paths for agents to read.
- Keep YAML `status` as the task's status source of truth. After completing the
  work and its checks, set it to `done` and record the outcome and verification
  in the body. Keep completed tasks in place; the dashboard hides them by default.
  Save files and reload with `g` to verify discovery, links, and status filtering.

`tasks/README.md` is an ordinary index without status front matter. Supporting
Markdown inside a task folder is documentation unless it is `content.md`.
