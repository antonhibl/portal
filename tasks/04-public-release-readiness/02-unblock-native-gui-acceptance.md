---
status: done
---
# Unblock native GUI acceptance

## Goal and evidence

Get bounded, diagnosable native input acceptance that passes before public
release. Read the [shared release context](README.md).

The audit ran `bash test/vm.sh sh test/input-gui.sh`. The VM build succeeded,
but graphical Emacs remained in `read-key-sequence`; it was manually stopped
after 3 minutes 32 seconds with no per-test progress. This was an inconclusive
run, not a demonstrated product defect or a timeout failure: the runner's outer
limit was longer. Reproduce and distinguish fixture, environment and product
causes before changing native behavior.

## Start here

- [Input GUI runner](../../test/input-gui.sh): runs ERT inside a graphical Emacs
  timer and prints `*Messages*` only after the suite returns.
- [Input cases](../../test/portal-input-gui-tests.el),
  [terminal cases](../../test/portal-terminal-tests.el),
  [integration cases](../../test/portal-integration-tests.el),
  [toolbar cases](../../test/portal-toolbar-gui-tests.el), and
  [native injector](../../test/terminal-input.m).
- [VM runner](../../test/vm.sh), [runner tests](../../test/vm.test.ts),
  [testing guide](../../docs/testing.md), and
  [input architecture](../../docs/terminal-input-bridge.md).

## Work

1. Reproduce in a disposable logged-in macOS VM using the documented runner.
   Capture environment, selected tests, progress, the active test at stall, and
   a process sample/backtrace. Preserve useful evidence in the run logs, not only
   ephemeral local paths in the PR.
2. Emit and flush test start, finish, failure and elapsed-time records while the
   suite runs. Add focused selection if needed to isolate the stalled test.
3. Bound individual cases, including blocked key reads and event-loop stalls.
   A Lisp timer alone may not interrupt a stuck native call; use an independent
   watchdog or process isolation where needed. Keep the outer stage timeout and
   reliable child-process cleanup. Timeout must name the active test and exit
   nonzero, with logs copied back by the VM runner.
4. Fix the proven cause at its proper boundary. Preserve tests that exercise real
   event delivery, native focus and command-loop behavior. Do not turn failures
   into skips, replace event delivery with direct handler calls, or merely extend
   timeouts to obtain green results.
5. Update the testing guide with diagnosis commands and the verified environment.
   Keep physical-key/manual checks distinguished from injected-event coverage.

## Acceptance and verification

- [x] `bash test/vm.sh sh test/input-gui.sh` completes with the intended cases
      passing and no unexpected skips in a fresh VM Emacs process; repeat in a
      second fresh process to check cleanup and reproducibility.
- [x] A controlled deliberately stalled case exits nonzero within the documented
      per-case budget, identifies its test, preserves logs, and leaves no process
      or desktop lock that blocks a subsequent run. Remove the temporary fault.
- [x] Progress is visible before suite completion, including on failure.
- [x] If a native fix affects launcher, toolbar or ownership, read the architecture
      ADRs and run the corresponding extra GUI suites through the VM runner.
- [x] Run shared host checks. Record commands, environment, counts and skips;
      unavailable VM access is a remaining verification gap, never a pass.
