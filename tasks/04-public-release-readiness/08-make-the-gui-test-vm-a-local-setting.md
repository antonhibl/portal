---
status: todo
---
# Make the GUI test VM a local setting

## Goal

Make the public repository's test instructions work on any Mac, and keep the
maintainer's "GUI checks run in a VM" rule as a local setting rather than a
project rule. Read [shared context](README.md).

AGENTS.md, CONTRIBUTING.md, the testing guide and the platform matrix say GUI
checks run only in a VM through `test/vm.sh`. That suits one machine, where GUI
tests must not take focus from the maintainer's desktop. Contributors without
such a VM have no supported way to run the GUI checks.

## Work

1. Add a per-clone setting, `git config portal.testVm <ssh-alias>`, that every
   worktree sees. When it is set, the GUI test scripts run themselves through
   `test/vm.sh` with that alias. Without it they run on the local desktop.
   The VM copy has no Git metadata, so it runs the checks directly.
2. Rewrite AGENTS.md, CONTRIBUTING.md, the testing guide and the platform matrix
   so they list every check, including the GUI scripts, say that GUI checks open
   windows and take focus, and present the VM runner as optional.

## Acceptance

- [ ] With `portal.testVm` set, each GUI script runs in the VM; unset, it runs
      locally; inside the VM it never delegates again.
- [ ] Runner tests cover the delegation decision.
- [ ] Public docs no longer require a VM, and list how to run all checks.
