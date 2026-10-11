# Testing Portal

Tests define coverage. Do not duplicate their inventory here.

## Verifying work

1. Run all non-GUI checks on the host: CTest, Bun and Python tests, lint, and
   type checks. Follow [checks before a PR](../CONTRIBUTING.md#checks-before-a-pr).
   Do not send these checks to the VM.
2. Run only GUI checks in the VM through `bash test/vm.sh <command>`.
   This includes graphical Emacs tests and standalone AppKit checks.
   For native view, keyboard, toolbar or launcher changes, run the relevant
   checks below. Never run GUI checks on the host.
3. Report commands, results and skipped checks. If the VM is unavailable,
   report GUI checks as not run; do not fall back to the host.

For this Homebrew Emacs build, set its native compiler library path before host
CTest runs. CLI launches do not inherit the app's environment:

```sh
export LIBRARY_PATH="$(/usr/libexec/PlistBuddy -c Print:LSEnvironment:LIBRARY_PATH /Applications/Emacs.app/Contents/Info.plist)"
```

## Writing tests

- Test at the narrowest useful boundary. Use the real core with a fake platform
  for shared rules. Use native integration tests for behavior controlled by
  AppKit, WebKit or Emacs's command loop.
- Assert observable results, not incidental caches, hook names or call counts.
  Platform contracts include resource ownership and ordering.
- Drive input and focus tests through the event loop. Direct handler calls do
  not prove keyboard access.
- Mark web fixture fields that tests type into `spellcheck=false`. Otherwise
  macOS may show its correction panel, whose nested event loop holds Emacs's
  main thread until a key arrives, so the next injected key never comes.
- After giving a web view the keyboard, wait until its page has focus before
  typing. WebKit tells the page asynchronously; an earlier key reaches the page
  but not its field.
- Isolate fixtures. Clean up buffers, processes, files and registrations, even
  after failure. Leave user configuration and existing sessions untouched.
- Keep default checks headless and credential-free. Register them in the
  [CMake suite](../CMakeLists.txt) or [core suite](../native/Core/CMakeLists.txt).
  Keep special setup beside the test. Use
  [native failure helpers](../test/native-checks.swift) to avoid assertion
  failures that trigger macOS crash dialogs.

## Evidence and safety

Fake-backend tests cannot prove native window behavior. Injected AppKit or Carbon
events cannot prove physical-key delivery, Accessibility, Spaces or fullscreen
behavior. Verify those manually.

The VM's Emacs has no Accessibility grant, and nothing can grant one from a
shell, so a posted chord there only fails. The Accessibility alert can be
checked: TCC attributes an Emacs started from the runner's shell to sshd, a
platform binary it never prompts for, so start Emacs with `open -n -W -a` in
the runner's command, reset with `tccutil reset Accessibility org.gnu.Emacs`,
and read the alert's lifetime from `log show` (`universalAccessAuthWarn`
launches and WindowServer's `AppVisible` assertion on it).

Run GUI checks in disposable graphical Emacs or standalone processes inside the
VM; they can steal focus or crash. Keep launcher subroutine trampolines enabled.
Report skips and manual checks separately from passes. Record the native acceptance
environment; old results are not current evidence. Support claims follow the
[platform acceptance checks](platforms.md#acceptance-checks).

## GUI checks in a macOS VM

Use a logged-in macOS desktop VM for GUI checks only. GUI windows stay in the
guest, preserving host focus. Set up passwordless SSH as `portal-vm`.
Run from the checkout under test:

```sh
bash test/vm.sh
bash test/vm.sh sh test/launcher-daily-use.sh
```

Each run copies tracked and untracked non-ignored files, including uncommitted
changes, into a new `~/portal-test-runs/run.XXXXXXXX/repo` directory. It builds
there, then runs the command. Deleted files, Git metadata and ignored build
outputs stay out.
Pass `sh -c 'command…'` for compound commands.

Commands inherit the installed Emacs app's native compiler library path, which
direct SSH launches miss. Trampolines stay enabled. Set `PORTAL_TEST_VM` for
another SSH alias.
`PORTAL_TEST_TIMEOUT` sets a positive integer limit in seconds per build/test stage
(default: 1,200). Timing starts after acquiring the desktop lock.
Requires Bash, macOS's built-in `lockf`, SSH and rsync. No Python or extra npm
packages.

Runs have separate files but share the desktop and VM resources. One guest-wide
file lock queues builds and GUI commands. The guest build prepares the GUI test
artifacts; it does not replace host verification.
Always use the runner for GUI work; manual tests bypass its lock.
Keep commands in the foreground. The runner terminates their process group on
completion or timeout. SSH disconnects can leave runs active until timeout.
Reconnect to inspect saved logs.

Remote output goes to `build.log` and `test.log` beside the repo. Commands can
save more `*.log` files in `PORTAL_TEST_LOGS`, the run directory. Logs and
`exit-status` copy back to `.cache/vm/<run>/`. Command failure status reaches the
caller.
Successful runs delete the source/build tree and keep logs. Failed runs keep
everything for diagnosis; remove their directories when no longer needed.
Keep at least 5 GiB free per fresh guest build. Leave host disk space for VM
image growth.

Guest preparation:

- Use UTM Shared Network with a virtual display. Keep UTM running; background is
  fine. Closing its console may suspend or stop the VM.
- Enable Remote Login. Install the host's SSH public key, verify the guest host
  key, and configure an SSH alias. Keep private keys on the host.
  Use the same account for SSH and the guest desktop.
- Install Xcode with Swift 6.2 or newer. Select its developer directory and
  complete first-launch setup. Install Homebrew, then CMake, Ninja and Bun.
  Keep Homebrew tools under `/opt/homebrew/bin`.
- Match the host's Homebrew Emacs cask: `d12frosted/emacs-plus/emacs-plus-app`,
  build `31.1-349` here. Check the revision and native compilation against
  [launcher prerequisites](launcher.md). Do not use a terminal-only formula.
  This guest used tap commit `2d6afb2ec4869b8dc3098541696d0d9d362cc8f0` with
  `HOMEBREW_NO_AUTO_UPDATE=1`. Homebrew updates/upgrades can change the build;
  recheck the host/guest match before upgrading.
- Keep the guest desktop logged in and unlocked. Disable sleep, display sleep,
  screen saver and automatic logout. Keep display size and scale stable.
  The runner also holds a `caffeinate` assertion.
- Verify GUI tests with UTM in the background. SSH access alone does not prove
  AppKit, WebKit or Ghostty works.

Default: launcher daily-use acceptance check, not the full GUI suite.
Pass other graphical Emacs or standalone AppKit checks as needed.

## View graphical checks

For ordinary terminal and web views (WebKit loading, terminals, their
coexistence, Markdown previews and Excalidraw) in one fresh Emacs:

```sh
bash test/vm.sh sh test/views-gui.sh
```

Pass an ERT selector regexp to run part of it. It fails on any skip. The
[platform matrix](platforms.md) uses it as the view acceptance check.

## Terminal graphical checks

Graphical ERT suites run through [gui-ert.sh](../test/gui-ert.sh). It compiles
and loads the test-only event injector, adds `build/elpa` to Emacs's load path,
and runs the suite in one fresh Emacs. The injector needs no Accessibility
permission. Reuse it for other GUI suites, as
[input-gui.sh](../test/input-gui.sh) does; keep dependency versions in CMake.

For the shared input, terminal, toolbar and coexistence checks in a fresh
Emacs process:

```sh
bash test/vm.sh sh test/input-gui.sh
```

It passes only with every selected test as expected and none skipped. Give
`input-gui.sh` an ERT selector regexp to run part of it.

### Diagnosing a stalled GUI run

`gui-ert.sh` prints each test's start, result and duration to `test.log` as it
happens, and appends a start and end record to `gui-progress.log`. Watch a run
from the host with the path `bash test/vm.sh` prints:

```sh
ssh portal-vm tail -f '~/portal-test-runs/run.XXXXXXXX/test.log'
```

A stuck native call can stop every Lisp timer, including `with-timeout`, so a
shell watchdog bounds each test. When no test starts or ends for
`PORTAL_GUI_TEST_TIMEOUT` seconds (default: 60), it samples Emacs into
`emacs-sample.log`, kills Emacs and its subprocesses, reports which test did
not finish, and exits 124. Emacs gives each subprocess its own process group,
so the runner's cleanup alone would leave them holding the desktop lock. Both logs copy back with `test.log`. The runner's stage timeout still
bounds the whole command. To rerun only the stalled test:

```sh
bash test/vm.sh sh test/input-gui.sh '^portal-integration-focus-'
```

In the sample, read the main thread below the test's Lisp frames. A nested
AppKit event loop there, such as `NSCorrectionPanel _interceptEvents`, waits
for an event that the blocked test would have injected. Failed runs keep their
`repo/`; delete it once you have the logs.

On 2026-10-11, all 39 selected cases passed in each of two fresh Emacs
processes, with none skipped. The guest ran macOS 27.0.1 (26A434) arm64, with
macOS's default text correction on, and the `emacs-plus-app` cask's Emacs 31.1,
build `31.1-349`. A deliberately stalled test, blocked in a synchronous
`call-process`, exited 124 after 66 seconds and named itself; the next suite
then ran. These cases inject AppKit events into Emacs; they do not prove
physical-key delivery.

The standalone focus check below also verifies live escape rebinding and the
inactive content cue, including rendering and click-through without a toolbar.
Physical-key delivery on the affected macOS version still needs a manual check.

## Package installation checks

The `package` CTest suite installs a copy of the checkout through
[the installation guide](install.md)'s use-package examples in empty home
directories, with and without Consult and Embark. It fails on any compilation
error or warning, even when package-vc reports success. `test_resolve_bun.py`
covers Bun selection with stand-in executables and archives. Neither builds
native code nor downloads anything.

For first use in graphical Emacs (the offered build, then a terminal and a web
view in a fresh Emacs), run in the VM:

```sh
PORTAL_TEST_TIMEOUT=2400 bash test/vm.sh sh test/package-gui.sh
```

It builds Portal twice: the runner's build, then the installed package's own.

## Launcher graphical checks

For the launcher's whole graphical suite, daily-use checks included, in one
fresh Emacs:

```sh
bash test/vm.sh sh test/launcher-gui.sh
```

Pass an ERT selector regexp to run part of it. Tests that need a second display
skip. A successful run deletes `repo/`, so save the panel's drawings beside it,
then copy them back from the printed run directory:

```sh
bash test/vm.sh sh -c 'mkdir -p ../screenshots &&
  PORTAL_LAUNCHER_SCREENSHOTS="$(cd .. && pwd)/screenshots" sh test/launcher-gui.sh'
```

## Combined graphical suite

Test coexistence in one fresh graphical Emacs inside the VM. Load `portal.el`,
the injector, `test/portal-tests.el` and `test/portal-terminal-tests.el` before
`test/portal-integration-tests.el`. Add relevant `test/*-gui-tests.el` files.
Run `M-x ert` with selector `^portal-`. Batch Emacs cannot test native windows.

## Standalone AppKit checks

These checks isolate native integration from Emacs bindings and Ghostty.
No build target exists. From your checkout, use the VM runner to build Portal
and run these commands in the guest:

```sh
bash test/vm.sh sh -c '
set -eu
for core in channel views input terminals web toolbar shortcuts status; do
  xcrun clang -std=c11 -Wall -Wextra -Werror -I native/Core/include \
    -c native/Core/$core.c -o build/$core.o
done
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I native/Core/include -import-objc-header test/native-core.h \
  native/Backend.swift native/CoreCalls.swift native/NativeHost.swift native/NativeInput.swift \
  native/Launcher.swift native/Hotkeys.swift native/KeyPost.swift native/StatusPanel.swift \
  native/Views.swift native/Toolbar.swift native/WebToolbar.swift native/WebView.swift \
  test/native-checks.swift test/native-terminal-stub.swift test/native-views.swift \
  test/native-focus.swift build/channel.o build/views.o build/input.o build/terminals.o \
  build/web.o build/toolbar.o build/shortcuts.o build/status.o \
  -framework AppKit -framework WebKit -framework Carbon -o build/check-focus
build/check-focus
'
```

Swap `test/native-toolbar.swift`, `test/native-launcher.swift`,
`test/native-shortcuts.swift` or `test/native-status.swift` for
`test/native-focus.swift`. Rename the output to match. These checks open real
windows or register real hot keys.

Whether a bare Escape shortcut keeps Escape from the frontmost app takes key
events that macOS matches against hot keys, which only an Emacs with
Accessibility permission can post. Once a person has switched it on for the
guest's Emacs, run:

```sh
bash test/vm.sh sh test/escape-shortcut-leak.sh
```

## C core checks

Run this standalone build on the host for shared rules without the native backend.
It still needs macOS for `F_SETNOSIGPIPE`; a fake platform does not make the pipe
portable.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```
