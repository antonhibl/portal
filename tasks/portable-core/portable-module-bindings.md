---
id: portable-module-bindings
status: done
depends_on: []
---

# Move Emacs module bindings into C

## Context and problem

Portal is currently a macOS Emacs module. The agreed refactor prepares its
architecture for a possible Linux implementation later; it does not implement
Linux, run Linux feasibility experiments, add Linux CI, or target Windows.
Keep the working macOS behavior and existing Lisp interface throughout.

Today `native/Emacs/bootstrap.c` calls `portal_swift_init`, and
`native/Module.swift` registers all 19 Lisp functions, converts arguments and
results, and translates errors. Most of that code is independent of macOS but
requires Swift to compile. This task establishes the C interface that later
tasks can use to move shared behavior out of Swift incrementally.

## Outcome and scope

The real Emacs module bindings are implemented in C and call a small, typed C
interface implemented initially by the existing Swift code. Each subsequent
extraction can replace an implementation behind that interface without changing
the Lisp callers. This task must be independently buildable and mergeable.

- Move registration, argument/result conversion, and Lisp error signaling into
  C. Preserve the 19 exports, their arities, option semantics, return shapes,
  feature provision, and useful errors described in ADR 0002.
- Use opaque handles, owned UTF-8 data with explicit lengths, plain structs,
  enums, and explicit error results where needed. Keep the existing named
  operations; do not replace them with a generic verb/JSON dispatcher.
- Define memory ownership, callback lifetime, and thread requirements. No
  asynchronous callback may retain or invoke an `emacs_env` or an unprotected
  `emacs_value`. Copy arguments before native work outlives the module call.
- Keep current macOS main-thread checks/dispatch in the adapter. The common
  declarations must not depend on Swift actors, Foundation, or AppKit.
- Compile the same C sources into production and a test module with a fake
  backend. The fake substitutes native operations, not the Emacs bindings.
  Establish a documented command for these tests using a C compiler and Emacs,
  without invoking Swift, Apple frameworks, Bun, or Ghostty.
- Integrate the C sources with SwiftPM/CMake without maintaining duplicate
  implementations. Preserve the default macOS build, bundle layout, and load
  path. Separate the common test target from native build prerequisites rather
  than claiming the application now supports other platforms.
- Update the README's build and architecture descriptions to match this slice.

Registry, input, web, terminal, and toolbar implementations remain in Swift
until their respective tasks. Do not change user commands or implement a
runtime backend/plugin system.

## Starting points

Read `CONTEXT.md`, `docs/adr/0001-one-portal-view-per-buffer.md`, and
`docs/adr/0002-portal-view-native-seam.md`; then `native/Module.swift`,
`native/Emacs/bootstrap.c`, `native/Emacs/include/CEmacs.h`,
`native/Package.swift`, `CMakeLists.txt`, and `portal-view.el`.
`test/portal-fake-native.el` tests Lisp behavior but bypasses the real module;
it does not verify the new C binding implementation.

## Decisions to settle during implementation

Choose the smallest C source/header layout and ownership conventions that both
SwiftPM and the standalone C tests can use. Record the conventions beside the
interface. Decide how the fake backend is linked only into tests. These are
implementation choices; a new architecture-design task or user approval is not
required. Avoid speculative Linux declarations.

## Acceptance criteria and verification

- [x] The production module registers its Lisp interface through C; there is
  no second Swift registration/conversion implementation left behind.
- [x] Tests load the real C module with a fake backend and exercise successful
  calls, malformed strings/vectors/plists, optional arguments, backend errors,
  and pending Lisp non-local exits without crashing or invoking invalid work.
- [x] The common test command runs on macOS without Apple framework dependencies;
  common headers expose neither Emacs values to native callbacks nor native UI
  types to the shared implementation.
- [x] `./build.sh` and `ctest --test-dir build --output-on-failure` pass.
  Run the README's disposable graphical Emacs smoke checks for opening a web
  view and a terminal, placing/hiding them, focus, and cleanup through the real
  module; use `--module-assertions`.
- [x] Record commands and results, then mark this task done using the
  author-tasks skill. Follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

None; this is the first refactor task.

## Outcome

- `native/Core/emacs.c` is the Emacs module: `emacs_module_init`, the 19
  registrations with their arities and docstrings, argument and result
  conversion, and error signalling. `native/Module.swift` and `native/Emacs/`
  are gone.
- `native/Core/include/portal.h` declares one named operation per Lisp function
  and records the conventions: borrowed `portal_string` arguments (UTF-8,
  explicit length, valid only during the call), `malloc`ed results that the
  bindings free, `false` plus an owned message on failure, synchronous calls on
  the module call's thread, and no callbacks. No opaque handles were needed yet,
  since targets remain strings. The header includes no Emacs, Swift, Foundation
  or AppKit declarations.
- `native/Backend.swift` implements `portal.h` with the existing Swift code and
  keeps the main-thread check and `MainActor` dispatch.
- The bindings reject strings that are not valid UTF-8 with
  `wrong-type-argument`, because Emacs copies unibyte raw bytes and surrogates
  unchanged. `portal--input` now treats an explicit nil SERIAL as absent, like
  ENTER in `portal--terminal-paste`. A failed `portal_channel` closes the
  descriptor instead of leaking it.
- SwiftPM builds `native/Core` as the `PortalCore` target of the production
  module. `native/Core/CMakeLists.txt` compiles the same `emacs.c` with
  `test/portal-fake-backend.c` into `portal-test-module.so`, used only by
  `test/portal-module-tests.el`. The top-level CMake project includes it, and
  it now locates Emacs and `emacs-module.h` for the whole build. The bundle
  layout and load path are unchanged.

## Verification

Run on macOS 27.0 with Swift 6.4, Emacs 31.1, and CMake 4.4.3 on 2026-09-27:

- `cmake -S native/Core -B build/core && cmake --build build/core && ctest
  --test-dir build/core --output-on-failure` passed (11 ERT tests under
  `--module-assertions`). `otool -L` shows the test module links only
  `libSystem`. Disabling the UTF-8 check, or reading ENTER without checking
  NARGS, makes the suite fail.
- `./build.sh` built without warnings; `nm` shows all 19 `portal_*` operations
  defined in `portal.dylib`, and none undefined.
- `ctest --test-dir build --output-on-failure` passed 12 of 12, including
  `module`.
- The README's combined graphical suite, run through the real module with
  `--module-assertions`, passed 50 of 50 twice. It covers opening web views and
  terminals, placing, hiding, focus, and cleanup. A third run had one
  input-injection failure. The injected-key tests
  `portal-input-gui-native-escape-invalidates-unacknowledged-prefix`,
  `portal-integration-focus-and-cleanup-in-either-startup-order` and
  `portal-input-gui-prefix-key-inside-emacs-gateway-is-not-literal` fail
  intermittently with the same messages on both builds. In interleaved reruns,
  `main` was clean in 12 of 17 runs and this branch in 12 of 20.
