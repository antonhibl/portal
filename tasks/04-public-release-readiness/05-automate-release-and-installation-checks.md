---
status: todo
blocked-by: [04-public-release-readiness/01-fix-use-package-installation, 04-public-release-readiness/03-define-the-supported-platform-matrix]
---
# Automate release and installation checks

## Goal and evidence

Make a green PR check mean that a fresh checkout builds and a consumer package
can install, rather than merely that source loading works. Read [shared
context](README.md). This task follows installation task 1 and matrix task 3 so
CI uses implemented recipes and support policy.

At audit time there were no checked-in `.github/workflows/` files. All 26 CTest
suites passed while package-vc installation still emitted byte-compilation errors
and omitted native artifacts. `test/portal-startup-tests.el` covers direct source
loading; it cannot stand in for a package-manager installation test.

## Start here

[Required checks](../../CONTRIBUTING.md#checks-before-a-pr),
[testing guide](../../docs/testing.md), [CMake tests](../../CMakeLists.txt),
[startup test](../../test/portal-startup-tests.el),
[VM runner](../../test/vm.sh), [host scripts](../../host/package.json),
[build script](../../build.sh), and task 1's new installation regression tests.
Create `.github/workflows/` as needed.

## Work

1. Add PR and main-branch workflows on macOS runners appropriate to the supported
   matrix. Provision graphical Emacs plus its matching header and pinned/recorded
   build tools. A hosted headless check need not open graphical Emacs.
2. Run a genuinely fresh configure/build, all registered CTest suites, Biome,
   TypeScript, Python and whitespace checks. Keep normal checks credential-free.
   Cache downloads using appropriate lockfile/tool/platform keys; include an
   uncached installation/build path so caches cannot hide missing inputs.
3. Run task 1's isolated package-manager installation and byte-compilation test
   plus an upgrade test. Assert expected files/resources and non-GUI readiness.
   Treat byte-compilation errors and failed native builds as failures even when
   package-vc returns success. Do not use direct source loading as a substitute.
4. Preserve build/compiler/install logs on failure, bound jobs, and avoid shared
   user configuration or mutable tool installations. Give workflows minimal
   permissions and keep untrusted PR code away from credentials or a privileged
   self-hosted desktop.
5. Make real GUI acceptance an explicit release gate with recorded commit,
   environment and results, executed through the documented VM runner. Hosted
   headless CI passing does not satisfy this gate. Automate it only on an
   appropriately isolated desktop environment; otherwise document a reproducible
   manual release checklist and required evidence.

## Acceptance and verification

- [x] Workflow syntax/configuration validates and a real run against this branch
      builds from source and passes the required host checks and install/upgrade
      tests. Report any check that cannot yet be run as pending.
- [x] Installation starts with isolated empty package/config directories and no
      prebuilt Portal artifacts; failure logs identify the failed stage.
- [x] A controlled failing-install fixture proves CI fails on compilation/build
      failure rather than trusting the package manager's success message.
- [x] Fresh/cached behavior and matching Emacs/header selection are covered.
- [x] The release checklist requires task 2's native acceptance and clearly
      distinguishes passes, skips and unavailable GUI evidence.
