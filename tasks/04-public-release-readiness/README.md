# Prepare Portal for public release

Seven implementation tasks from the current-state readiness audit on 2026-10-11,
in the original priority order. All seven remain to do. The first task contains
the native compilation and Bun research, including primary sources and decisions
agreed during planning. This PR defines work; it does not implement fixes or
certify release readiness. Commit-history cleanup is outside scope.

## Tasks

1. [Fix use-package installation](01-fix-use-package-installation.md)
2. [Unblock native GUI acceptance](02-unblock-native-gui-acceptance.md)
3. [Define the supported platform matrix](03-define-the-supported-platform-matrix.md)
4. [Triage dependency security findings](04-triage-dependency-security-findings.md)
5. [Automate release and installation checks](05-automate-release-and-installation-checks.md)
6. [Package third-party licenses](06-package-third-party-licenses.md)
7. [Finish public onboarding and cleanup](07-finish-public-onboarding-and-cleanup.md)

Tasks 2, 3, 4 and 6 can begin independently. Tasks 5 and 7 depend on tasks 1 and 3;
those dependencies are encoded in their frontmatter. Task 3 consumes task 2's
GUI evidence before claiming final native support. Task 6 must refresh its
inventory after dependency changes from task 4. These are coordination points,
not permission to skip acceptance criteria.

## Working instructions for a fresh agent

- Read your task and this file, then [AGENTS.md](../../AGENTS.md),
  [Contributing](../../CONTRIBUTING.md) and
  [Testing Portal](../../docs/testing.md#verifying-work).
- Run `task help` before claiming. The CLI defaults to the main checkout's
  tasks directory; use `task -d tasks ...` for deliberate checkout-local edits.
  These tasks become claimable after this planning PR lands on main.
- Code changes use their own new branch/worktree off main. Follow repository
  workflow for committing, checks, pushing and opening a PR. Mark only the work
  actually completed as done. Leave unrelated user files/branches untouched.
- Read [domain vocabulary](../../CONTEXT.md) and
  [native boundaries](../../docs/architecture.md) before changing native interfaces
  or ownership. Preserve executable launcher example markers.
- Run all non-GUI checks on the host. GUI checks run only in a logged-in VM through
  `bash test/vm.sh <command>`. Restart disposable Emacs after rebuilding a loaded
  module. Missing VM access is an explicit verification gap, not a host fallback.

## Audit baseline and verification

A clean source snapshot passed `./build.sh`, all 26 then-registered CTest suites,
Biome, TypeScript checking, and 8 Python tests. The audit used macOS 27.0.1 arm64,
Emacs 31.1 development revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`,
Swift 6.4 and Bun 1.4.2. These are historical observations, not a support matrix
or evidence for later changes. Native GUI acceptance was inconclusive; see task 2.
The existing documentation's Bun 1.3.14 pin is separate from the audit's tool version.

For implementation PRs, run the currently required checks from Contributing:

```sh
./build.sh
ctest --test-dir build --output-on-failure
bun run --cwd host check
bun run --cwd host typecheck
python3 -B -m unittest discover -s test -p 'test_*.py'
git diff --check
```

Read the testing guide first for the Emacs native compiler library environment.
Use the registered test list as the current inventory; do not hardcode the old
counts as acceptance criteria. Each task adds targeted checks and states when
native acceptance is needed. Report exact commands, environment, results, skips
and limitations in its implementation PR. Keep tests isolated from real user
configuration and preserve failure logs. Do not rely on audit files in temporary
local directories being available to the next agent.
