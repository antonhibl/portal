---
status: done
---
# Define the supported platform matrix

## Goal and evidence

Publish support claims backed by builds and native acceptance, separately for
ordinary Portal views and the opt-in launcher. Read [shared context](README.md).

The README currently says graphical macOS Emacs with dynamic modules. It does
not establish a tested minimum Emacs/macOS version or CPU support. The audit
passed a source build on macOS 27.0.1 arm64, Emacs 31.1 development revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`, Swift 6.4 and Bun 1.4.2.
That single environment does not prove released Emacs, Intel or macOS 13 support.
`native/Package.swift` declares macOS 13, while the launcher has an exact-revision
gate; declaration and evidence must not be conflated.

## Start here

[README](../../README.md), [Contributing](../../CONTRIBUTING.md),
[testing guide](../../docs/testing.md), [launcher guide](../../docs/launcher.md),
[native package](../../native/Package.swift), [CMake configuration](../../CMakeLists.txt),
[portal.el](../../portal.el), [native bindings](../../native/Core/emacs.c), and
[launcher implementation](../../native/Launcher.swift).

## Work

1. Inventory hard requirements from Emacs Lisp APIs, dynamic modules/NS interfaces,
   native frameworks, Swift, Ghostty artifacts and Bun. Select a minimum supported
   Emacs and macOS policy based on requirements plus available test evidence.
2. Build and test ordinary terminal/web/hosted-app features on at least one
   released graphical GNU Emacs build. Capture exact version/revision, header
   source, CPU, macOS, Xcode/Swift, Bun and test results. Use a matching VM for GUI.
3. Evaluate Apple Silicon and Intel separately. A binary containing an architecture
   or cross-compilation success does not prove execution there. Label unavailable
   combinations unverified or unsupported, with a concrete follow-up requirement.
4. Publish a small matrix distinguishing verified support, known exclusions and
   unverified combinations. Separate build prerequisites from runtime needs and
   preserve the launcher's narrower revision/trampoline gate unless separately
   proven safe to expand. Do not broaden it merely to make the table simpler.
5. Align package minimum-version metadata, feature-level diagnostics, README,
   contributor setup and test instructions. Coordinate metadata with task 1;
   avoid a second conflicting installation implementation.

## Acceptance and verification

- [x] A released Emacs build has documented source-build, host-test and native
      terminal/web acceptance evidence, or the unsupported result is documented
      and this release prerequisite remains explicitly unresolved.
- [x] Every claimed supported combination has traceable evidence; unavailable
      hardware is labeled honestly. macOS deployment targets are explained.
- [x] Package-Requires and runtime messages match the selected minimum; unsupported
      terminal-only/non-NS Emacs fails with actionable feature-level diagnostics
      while ordinary package inspection/compilation remains possible.
- [x] Launcher support remains explicit and separate from core feature support.
- [x] Follow shared verification and preserve executable launcher example markers;
      run the launcher CTest if those examples change.

This task can begin independently of tasks 1 and 2. Final evidence should consume
the repaired GUI runner from task 2, and the final metadata must agree with task 1.
