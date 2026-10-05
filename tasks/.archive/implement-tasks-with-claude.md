---
id: implement-tasks-with-claude
status: done
---

# Launch Claude from task details through hosted app actions

## Outcome

Task details offer **Implement with Claude**. A normal HTML form submits to the
Bun app host, which resolves the current task source and asks Emacs to create a
native terminal. Claude starts at the project root with
`--dangerously-skip-permissions` and the initial prompt
`implement @tasks/path/to/task.md`, using a project-relative task path.

The app host and Emacs exchange correlated action requests over their existing
process pipes. Each hosted instance registers its context and supported native
operations. The task browser is the first user of this reusable interface.

## Acceptance

- [x] Standalone and folder tasks launch from their captured project root with
  the current relative source path, including after an ID-preserving move.
- [x] Scripts remain blocked in task content; same-origin form POSTs invoke
  actions, while GET, reload, and duplicate submission cannot relaunch a run.
- [x] Emacs executes only supported operations from live instances/current
  app-host processes, in the command loop, and returns results or useful errors.
- [x] Terminals receive their command at creation, retain literal arguments,
  appear in another pane, and keep running when the task page is hidden/closed.
- [x] App-host restart and stale/deleted/conflicting tasks have explicit recovery.
- [x] Build, batch checks, TypeScript checks, and a real WebKit/Ghostty launch
  test pass. The graphical probe captures cwd/argv without running Claude.

## Scope

No agent-status dashboard, task status mutation, worktree provisioning, persistent
sessions, or simulated keystroke automation. The task page continues using the
saved-file model. The form response redirects back to the detail; preserving
scroll without navigation can be a later frontend enhancement.

## Verification

Implemented with `portal-actions.el`, registered instance contexts, and correlated
requests over the app host's existing process pipes. `portal-terminal-start`
accepts a directory, executable, and literal arguments; Ghostty receives the
command when the terminal is created. See `docs/hosted-actions.md` for the API.

- `./build.sh`, `bun run --cwd host check`, and
  `bun run --cwd host typecheck` passed.
- CTest passed all 11 suites, including app-host POST tests and the real
  app-host-to-Emacs flow. This machine required its Homebrew GCC library path
  in `LIBRARY_PATH` for Emacs native compilation in an existing terminal test.
- All seven relevant graphical tests passed in a disposable Emacs: six task
  browser tests and terminal hiding/resizing. An existing attachment handoff
  test timed out once, then passed alone and in the full rerun.
- The real WebKit/Ghostty launch probe verified cwd, literal argv, PTY, focus,
  relative task references with spaces/quotes/Unicode, and reload without a
  second launch. No real Claude process or model request was used.
- Reloaded the repository dashboard in WebKit: Problems is empty, and Show
  completed includes this finished task with its Implement button.
