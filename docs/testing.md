# Testing Portal

Tests are the coverage reference; do not maintain a parallel inventory here.
For routine commands, see [checks before a PR](../CONTRIBUTING.md#checks-before-a-pr).

## Writing tests

- Test at the narrowest boundary that can demonstrate the behavior. Use the real
  core with a fake platform for shared rules; use native integration tests when
  AppKit, WebKit or Emacs's command loop determines the outcome.
- Assert observable results, not incidental caches, hook names or call counts.
  At a platform boundary, resource ownership and ordering are part of the contract.
- For input and focus regressions, drive events through the event loop. Calling
  a handler directly cannot establish that a user can reach it with the keyboard.
- Keep fixtures isolated and clean up buffers, processes, files and registrations
  even after failure. Avoid user configuration and existing sessions.
- Keep default checks headless and credential-free; register them in the relevant
  [CMake suite](../CMakeLists.txt) or [core suite](../native/Core/CMakeLists.txt).
  Keep special setup details beside the test.
  Use [native failure helpers](../test/native-checks.swift) rather than assertions
  that turn ordinary test failures into macOS crash dialogs.

## Evidence and safety

A passing fake-backend test does not establish native window behavior. Injected
AppKit or Carbon events do not establish physical-key delivery, Accessibility,
Spaces or fullscreen behavior; those need explicit manual evidence.

Run native checks in disposable graphical Emacs or standalone processes: they
can steal focus or crash. Keep launcher subroutine trampolines enabled. Report
skipped tests and manual checks separately from passes; record the environment
for native acceptance rather than treating an old result as current evidence.

Live-agent checks are opt-in: they use trusted projects, credentials and real
requests. See their [test-local prerequisites](../test/portal-agent-discovery-gui-tests.el).
For the mixed Pi check, use a disposable agent directory with `portal-pi.ts`,
terminal progress disabled, and a `/portal-test-prompt` command calling
`ctx.ui.input("Portal smoke test", "Type PORTAL_OK")`. Do not alter user settings.

## Tests in a macOS VM

Run GUI or non-GUI checks in a logged-in macOS desktop VM. GUI tests stay on the
guest desktop, keeping them from taking the host's focus.
With passwordless SSH configured as `portal-vm`, run from the checkout to test:

```sh
bash test/vm.sh
bash test/vm.sh ctest --test-dir build --output-on-failure
```

The runner copies tracked and untracked, non-ignored files (including uncommitted
changes), builds inside a new `~/portal-test-runs/run.XXXXXXXX/repo` directory,
and executes the command there. Deleted files, Git metadata and ignored build
outputs are not copied. For compound commands, pass `sh -c 'command…'` explicitly.
The test command inherits the installed Emacs app's native compiler library
path, which direct SSH launches otherwise miss; trampolines remain enabled.
Set `PORTAL_TEST_VM` for another SSH alias. `PORTAL_TEST_TIMEOUT` sets the positive
integer limit in seconds for each build/test stage (default: 1,200), after the
runner acquires the desktop lock. The runner uses Bash and macOS's built-in
`lockf`, SSH and rsync; it needs no Python or additional npm packages.

Each invocation has its own files. Builds and test commands queue on one
guest-wide file lock because they share the desktop and the VM's resources.
Always use the runner for GUI work on that guest; a manually launched test
bypasses its lock. Commands must remain in the foreground. The runner terminates
their process group on completion or timeout. A lost SSH connection can leave
the guest run active until its timeout; reconnect to inspect the saved logs.

Build and test output goes to `build.log` and `test.log` beside the remote repo,
then is copied to `.cache/vm/<run>/` locally, along with `exit-status`.
The command's failure status propagates to the caller. Successful runs remove
their source/build tree and retain logs; failed runs retain everything for
diagnosis. Remove old failed run directories when no longer needed. The guest
needs at least 5 GiB free per fresh build; the host also needs physical space for
its VM disk image to grow.

Guest preparation:

- Use UTM Shared Network and keep a virtual display attached. Keep UTM running
  in the background; closing its console may suspend or stop the VM.
- Enable Remote Login for the test account, install the host's SSH public key,
  verify the guest host key, and configure an SSH alias. Private keys stay on
  the host. The desktop and SSH account must be the same user.
- Install Xcode with Swift 6.2 or newer, select its developer directory, and
  complete its first-launch setup. Install Homebrew, then CMake, Ninja and Bun.
  Homebrew tools must be available under `/opt/homebrew/bin`.
- Install the same Homebrew Emacs cask as the host. For this environment it is
  `d12frosted/emacs-plus/emacs-plus-app`, build `31.1-349`. Verify the installed
  Emacs revision against [the launcher prerequisites](launcher.md), including
  working native compilation; do not substitute a terminal-only formula.
  The prepared guest uses tap commit `2d6afb2ec4869b8dc3098541696d0d9d362cc8f0`
  with `HOMEBREW_NO_AUTO_UPDATE=1` to install that build. A later Homebrew
  update/upgrade can change it; recheck the host/guest match before upgrading.
- Leave that guest user logged into an unlocked desktop. Disable guest sleep,
  display sleep, screen saver and automatic logout. Use a stable display size
  and scale. The runner also holds a `caffeinate` assertion while working.
- Verify a GUI run while UTM is in the background. A successful SSH connection
  alone does not establish that AppKit, WebKit and Ghostty work in the guest.

The default command is the launcher daily-use acceptance check. Pass other
graphical, non-GUI or standalone commands as needed; this does not select a full
GUI suite. Non-GUI commands also acquire the shared VM lock.

## Terminal graphical checks

The setup in [launcher-daily-use.sh](../test/launcher-daily-use.sh) is the reference
for compiling/loading the test-only event injector and adding `build/elpa` to
Emacs's load path. The injector needs no Accessibility permission. Reuse that
setup for other GUI suites rather than copying dependency versions here.

## Combined graphical suite

Test coexistence in the same fresh graphical Emacs, not only features in
isolation. Load `portal.el`, the injector, `test/portal-tests.el` and
`test/portal-terminal-tests.el` before `test/portal-integration-tests.el`; add the
relevant `test/*-gui-tests.el` files and run `M-x ert` with selector `^portal-`.
Batch Emacs cannot substitute for native windows.

## Standalone AppKit checks

These checks isolate native integration from Emacs bindings and Ghostty. There
is no build target for them; after building Portal, run from the repository root:

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

Substitute `test/native-toolbar.swift`, `test/native-launcher.swift` or
`test/native-shortcuts.swift` for `test/native-focus.swift` and rename the output
for the corresponding check. These open real windows or register real hot keys.

## C core checks

Use the standalone build when changing shared rules without needing the native
backend. It still requires macOS for `F_SETNOSIGPIPE`; a fake platform does not
make the pipe portable.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```
