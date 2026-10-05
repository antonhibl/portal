# Testing Portal

Tests define coverage. Do not duplicate their inventory here.
Routine commands: [checks before a PR](../CONTRIBUTING.md#checks-before-a-pr).

## Writing tests

- Test at the narrowest useful boundary. Use the real core with a fake platform
  for shared rules. Use native integration tests for behavior controlled by
  AppKit, WebKit or Emacs's command loop.
- Assert observable results, not incidental caches, hook names or call counts.
  Platform contracts include resource ownership and ordering.
- Drive input and focus tests through the event loop. Direct handler calls do
  not prove keyboard access.
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

Run native checks in disposable graphical Emacs or standalone processes; they can
steal focus or crash. Keep launcher subroutine trampolines enabled. Report skips
and manual checks separately from passes. Record the native acceptance
environment; old results are not current evidence.

Live-agent checks are opt-in and use trusted projects, credentials and real
requests.
See [prerequisites](../test/portal-agent-discovery-gui-tests.el).
Mixed Pi check: use a disposable agent directory with `portal-pi.ts`. Disable
terminal progress. Define `/portal-test-prompt` to call
`ctx.ui.input("Portal smoke test", "Type PORTAL_OK")`. Leave user settings untouched.

## Tests in a macOS VM

Run GUI or non-GUI checks in a logged-in macOS desktop VM. GUI windows stay in
the guest, preserving host focus. Set up passwordless SSH as `portal-vm`.
Run from the checkout under test:

```sh
bash test/vm.sh
bash test/vm.sh ctest --test-dir build --output-on-failure
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
file lock queues all builds and commands, including non-GUI checks.
Always use the runner for GUI work; manual tests bypass its lock.
Keep commands in the foreground. The runner terminates their process group on
completion or timeout. SSH disconnects can leave runs active until timeout.
Reconnect to inspect saved logs.

Remote output goes to `build.log` and `test.log` beside the repo. Logs and
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
Pass other graphical, non-GUI or standalone commands as needed.

## Terminal graphical checks

Use [launcher-daily-use.sh](../test/launcher-daily-use.sh) to compile/load the
test-only event injector and add `build/elpa` to Emacs's load path.
The injector needs no Accessibility permission. Reuse this setup for other GUI
suites; keep dependency versions there.

## Combined graphical suite

Test coexistence in one fresh graphical Emacs. Load `portal.el`, the injector,
`test/portal-tests.el` and `test/portal-terminal-tests.el` before
`test/portal-integration-tests.el`. Add relevant `test/*-gui-tests.el` files.
Run `M-x ert` with selector `^portal-`. Batch Emacs cannot test native windows.

## Standalone AppKit checks

These checks isolate native integration from Emacs bindings and Ghostty.
No build target exists. Build Portal, then run from the repository root:

```sh
for core in channel views input terminals web toolbar shortcuts; do
  xcrun clang -std=c11 -Wall -Wextra -Werror -I native/Core/include \
    -c native/Core/$core.c -o build/$core.o
done
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I native/Core/include -import-objc-header test/native-core.h \
  native/Backend.swift native/CoreCalls.swift native/NativeHost.swift native/NativeInput.swift \
  native/Launcher.swift native/Hotkeys.swift \
  native/Views.swift native/Toolbar.swift native/WebToolbar.swift native/WebView.swift \
  test/native-checks.swift test/native-terminal-stub.swift test/native-views.swift \
  test/native-focus.swift build/channel.o build/views.o build/input.o build/terminals.o \
  build/web.o build/toolbar.o build/shortcuts.o \
  -framework AppKit -framework WebKit -framework Carbon -o build/check-focus
build/check-focus
```

Swap `test/native-toolbar.swift`, `test/native-launcher.swift` or
`test/native-shortcuts.swift` for `test/native-focus.swift`. Rename the output to
match. These checks open real windows or register real hot keys.

## C core checks

Use the standalone build for shared rules without the native backend.
It still needs macOS for `F_SETNOSIGPIPE`; a fake platform does not make the pipe
portable.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```
