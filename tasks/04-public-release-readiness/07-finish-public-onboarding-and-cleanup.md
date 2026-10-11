---
status: todo
blocked-by: [04-public-release-readiness/01-fix-use-package-installation, 04-public-release-readiness/03-define-the-supported-platform-matrix]
---
# Finish public onboarding and cleanup

## Goal and evidence

Make the public repository understandable and usable without the maintainer's
local setup. Read [shared context](README.md). Preserve the substantial existing
user/architecture documentation; improve onboarding rather than rewrite it.
This task follows installation task 1 and support matrix task 3 so examples
describe implemented, verified behavior.

The audit found only a clone-based quickstart, no persistent `use-package` setup,
and personal dotfiles work in the public backlog. In particular, the dictation
configuration task targets `~/.local/share/obento/.../ai.el`, rather than Portal.
The checkout also had an untracked Emacs drawing autosave and lacked appropriate
ignore patterns. AGENTS.md requires a `task` CLI but contributor setup does not
explain where to obtain it.

## Start here

[README](../../README.md), [documentation index](../../docs/README.md),
[Contributing](../../CONTRIBUTING.md), [AGENTS.md](../../AGENTS.md),
[ignore rules](../../.gitignore), [testing guide](../../docs/testing.md),
[launcher guide](../../docs/launcher.md), and
the personal dictation task, `01-system-wide-dictation/02-dictation-command-in-the-emacs-config` (removed by this task).
Review the rest of `tasks/` for personal-only instructions and dependencies.

## Work

1. Add a concise persistent Emacs configuration using task 1's verified package
   installation path, with the manual-clone alternative. Explain first build,
   its downloads/private Bun cache, expected first result and how to find logs.
2. Document upgrades, rebuilds, the loaded-module restart requirement and common
   installation problems: graphical Emacs's PATH, mismatched header/Emacs,
   unavailable native tools, unsupported platform, failed downloads, permissions,
   stale outputs and app-host failures. Link detailed guides from the quickstart.
3. Explain task CLI installation and version/source from a verified upstream
   project or maintainer-provided distribution. Do not guess a package named
   `task` (several unrelated tools use that name). Explain checkout-local `-d`
   behavior, task/worktree workflow, and any actual contributor prerequisites.
4. Remove personal-only dotfiles tasks from the public backlog while preserving
   their content for the owner before removal. Retain/rewrite generic Portal
   feature tasks and repair dependent task references. Choose a private handoff
   location with the owner if none is established; do not modify their dotfiles
   repository or discard uncommitted work. Limit cleanup to current content,
   without rewriting Git history.
5. Add targeted ignore patterns for Emacs autosaves, lock files and backup files;
   test with representative names and ensure legitimate fixtures remain tracked.
   Do not delete the user's existing untracked files as a cleanup shortcut.
6. Add a clear screenshot showing terminal and preview use if feasible. Capture
   with a disposable VM session and non-private content. Explain what it shows;
   prioritize verified instructions over decorative assets. Coordinate with the
   existing [branding task](../03-use-companion-buffer-artwork-for-project.md)
   so this work does not replace or duplicate its artwork.

## Acceptance and verification

- [ ] A newcomer can follow the documented supported-platform setup in an isolated
      Emacs environment, reach the expected native result and find troubleshooting.
      GUI verification runs through the VM runner.
- [ ] Persistent configuration and upgrade examples match implemented behavior;
      no proposed API is described as already shipping.
- [ ] CLI setup has a verifiable installation source and task dependency links
      remain valid after personal backlog cleanup. Preserved personal work has an
      explicit owner/location without exposing it in the public release.
- [ ] `git check-ignore` confirms autosave/lock examples are ignored and legitimate
      source/test files are not. Local documentation links resolve.
- [ ] If launcher examples change, preserve their markers and run launcher CTest;
      run shared checks for code/configuration changes and report skipped GUI work.
