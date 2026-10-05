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
