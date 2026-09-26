# Agent workflow

Any task that changes code runs in its own git worktree, on a new branch off `main`. The main checkout stays on whatever the user has there.

The task is done when its changes are committed on that branch and the project's checks pass. At that point, push the branch and open a PR against `main` with `gh pr create`.
