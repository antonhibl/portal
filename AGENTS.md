# Agent workflow

Any task that changes code runs in its own git worktree, on a new branch off `main`. The main checkout stays on whatever the user has there.

The task is done when its changes are committed on that branch and the project's checks pass. At that point, push the branch and open a PR against `main` with `gh pr create`.

Before changing code, read [Contributing](CONTRIBUTING.md) for build setup,
required checks and generated-file boundaries. After rebuilding a loaded native
module, restart Emacs; it does not hot-reload.
Before verifying work, read [Testing Portal](docs/testing.md#verifying-work).
Run non-GUI checks on the host. Run only GUI checks in the VM through
`bash test/vm.sh <command>`.

Before changing view ownership or platform interfaces, read
[the native boundaries](docs/architecture.md) and its linked ADRs. When editing
launcher examples, preserve the markers in [the launcher guide](docs/launcher.md):
tests execute those blocks directly.

## Project tasks

Keep project tasks in `tasks/`, one Markdown document per task: either
`tasks/<name>.md` or `tasks/<name>/content.md` with assets beside it.
When creating, updating, or completing tasks, use the
[author-tasks skill](.agents/skills/author-tasks/SKILL.md).
