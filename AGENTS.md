# Agent workflow

Tasks are tracked with the `task` CLI in a separate private repository, `portal-tasks`, cloned beside the main checkout: pass its path with `task -d`. Run `task help` before picking up, adding or claiming a task.

Any task that changes code runs in its own git worktree, on a new branch off `main`. The main checkout stays on whatever the user has there.

The task is done when its changes are committed on that branch and the project's checks pass. At that point, push the branch and open a PR against `main` with `gh pr create`.

Before changing code, read [Contributing](CONTRIBUTING.md) for build setup,
required checks and generated-file boundaries. After rebuilding a loaded native
module, restart Emacs; it does not hot-reload.
Before verifying work, read [Testing Portal](docs/testing.md#verifying-work)
and run every check it lists, graphical ones included. Start graphical Emacs
only through the test scripts: when the clone sets `git config portal.testVm`,
they run in that VM and keep windows off the desktop.

Before changing view ownership or platform interfaces, read
[the native boundaries](docs/architecture.md) and its linked ADRs. When editing
launcher examples, preserve the markers in [the launcher guide](docs/launcher.md):
tests execute those blocks directly.
