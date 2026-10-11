---
status: done
---
# Fix use-package installation

## Goal and evidence

Make a clean Emacs package installation produce usable Portal Lisp and provide
one reliable route to build its native module and host. Read the [shared release
context](README.md) first. This task includes the compilation and private Bun
bootstrap research below; no earlier chat is needed.

The 2026-10-11 audit installed the current source through `use-package :vc` in an
empty package directory. Installation reported success while both native outputs
were missing and 22 byte compilations failed. `portal.el` preferred the caller's
`load-file-name` over `byte-compile-current-file`, resolving siblings relative to
the installer. Optional Consult/Embark adapters required unavailable packages,
and package-vc recursively compiled development tests. Version, Package-Requires,
and maintainer metadata were missing. A manually built clone loaded through
`use-package :load-path` successfully. Reproduce against current files before
fixing; the old count is evidence, not a required future failure count.

## Start here

- [portal.el](../../portal.el), [portal-view.el](../../portal-view.el), and
  [portal-server.el](../../portal-server.el): entry point, lazy module loading,
  host discovery and compatibility.
- [Consult adapter](../../portal-terminal-consult.el) and
  [Embark adapter](../../portal-terminal-embark.el): optional integrations.
- [build.sh](../../build.sh), [CMakeLists.txt](../../CMakeLists.txt),
  [CMake presets](../../CMakePresets.json), [native package](../../native/Package.swift),
  and [startup tests](../../test/portal-startup-tests.el).
- [Contributing](../../CONTRIBUTING.md), [Bun distribution notes](../../docs/bun-distribution.md),
  and the upstream sources preserved below.

## Implementation scope

1. Correct package metadata and source-directory resolution for interpreted,
   byte-compiled, autoloaded and absolute-path loading. Determine a defensible
   initial minimum Emacs version; task 3 owns the final tested support matrix.
   Compile shipped Lisp cleanly with optional packages absent and present.
   Keep adapters optional and exclude development fixtures from consumer package
   compilation without omitting native sources/resources needed for a build.
2. Implement `M-x portal-build` as an asynchronous, observable entry point to the
   shared build script, using the Emacs executable and header that will load the
   result. User builds use `-DBUILD_TESTING=OFF`. Diagnose missing prerequisites,
   paths containing spaces, read-only destinations and unsuccessful subprocesses.
3. Offer setup on first interactive native use. Ordinary `require`, package
   installation/byte compilation and autoload generation must work without
   native artifacts and must not trigger a build/download or batch prompt.
   After success ask the user to retry their command. Prevent concurrent builds
   of the same outputs and keep failure logs available.
4. Implement the Bun resolution order agreed below: explicit override, compatible
   Bun from Emacs's search path, valid private cache, then pinned official download.
   Use a customizable Emacs-owned cache outside ELPA, shared resolution with CLI
   builds, checked-in archive digests, verification before execution and atomic
   cache population. Preserve the explicit `BUN` override and no-download mode.
   Explain any fallback from an incompatible discovered Bun; reject invalid
   explicit overrides. Do not modify global Bun or shell configuration.
5. Validate the full module bundle/resources and host as one usable installation.
   Record a build identity and compatible interface versions so upgrades detect
   stale or partially rebuilt artifacts. Preserve running artifacts during build;
   if an old module is loaded, require Emacs restart before incompatible new Lisp
   uses it. Perform native load probes only in a separate disposable process.
6. Document and exercise one small `use-package :vc` recipe plus manual clone and
   `:load-path` use. Keep package-manager build hooks optional. Retain externally
   supplied artifact support and resolve package-manager symlink layouts correctly.
   Prebuilt Portal releases and archive submission are separate future work.

## Acceptance and verification

- [ ] Isolated `user-emacs-directory`, package directory, `HOME` and source copy:
      install through the documented recipe with no prior build outputs or user
      configuration. Fail verification on compilation errors even if package-vc
      reports installation success. Do not mutate the user's real init/packages.
- [ ] Installation/autoloads/byte compilation work with no native outputs and no
      Consult/Embark; explicitly test optional integrations when installed.
- [ ] First interactive use offers setup, one requested build produces the complete
      artifacts, and a fresh graphical Emacs in the VM opens a terminal and web
      view. Batch loading never launches a GUI or prompts.
- [ ] Cover Bun already installed, incompatible/missing, cached, fresh download,
      offline/no-download, invalid override, checksum/network failure and concurrent
      requests with controlled fixtures. Exercise one actual official download
      separately; tests must not repeatedly fetch a compiler.
- [ ] Unchanged startup does not rebuild. An upgrade detects stale outputs, rebuilds
      as needed, and requires restart when an old module was already loaded.
      Failed builds never report Portal ready.
- [ ] Exercise a manual clone and at least one symlink-based package manager in
      addition to package-vc. Record actual versions and any unverified recipes.
- [ ] Add repeatable non-GUI package-installation regression tests for task 5 to
      invoke in CI. Run the shared host checks and relevant GUI checks in the VM.

## Compilation and Bun research

Recorded: 2026-10-11. The research below motivates this task; none of the proposed installation APIs have been implemented yet.

### Recommendation

Give Portal a package-owned native build command and a first-use readiness check.
Keep `build.sh` as the underlying build entry point. Offer package-manager build
hooks as optional adapters. For the first public release, retain source builds;
consider prebuilt artifacts after defining the supported platform matrix.

The projects below establish a common pattern, not a formal ecosystem consensus:
the package handles its native component, while package managers install the
Lisp and source files. The exact trigger varies from library loading to mode
activation or an explicit setup command. This research concerns C/Swift modules
and helper executables, not Emacs's separate compilation of Lisp into `.eln` files.

### Established packages

| Package | Native component and trigger | Installation experience |
| --- | --- | --- |
| [vterm](https://github.com/akermu/emacs-libvterm/blob/6d715a93fa0e5182bc137d4db09f376e06938aa5/vterm.el#L61) | In-process module; loading the library attempts to load it, then prompts to compile if missing. | Synchronous CMake/Make build with a compilation buffer. `vterm-always-compile-module` skips confirmation; `vterm-module-compile` is available interactively. Its [README](https://github.com/akermu/emacs-libvterm#installation) documents ordinary `use-package :ensure t`. |
| [Jinx](https://github.com/minad/jinx/blob/bccb08062a3372629015bcd2c197490b7d005f37/jinx.el#L615) | In-process module; mode activation or language discovery loads it and compiles a missing binary automatically. | Checks module support and compiler availability; obtains Enchant flags through `pkg-config`, with fallback flags. A failed build opens its compilation buffer. Its [README](https://github.com/minad/jinx/blob/bccb08062a3372629015bcd2c197490b7d005f37/README.org#installation) gives package installation and configuration without user-written build logic. |
| [PDF Tools](https://github.com/vedang/pdf-tools/blob/365f88238f46f9b1425685562105881800f10386/lisp/pdf-tools.el#L370) | External `epdfinfo` helper; explicit `pdf-tools-install` checks availability and offers to rebuild. | Asynchronous compilation followed by activation. A working helper can be supplied separately. The [installation guide](https://github.com/vedang/pdf-tools#installing-pdf-tools) also offers deferred activation with `pdf-loader-install`. |
| [Rime](https://github.com/DogLooksGood/emacs-rime/blob/f927d26e471e7d63de65ffa92897944242f2fd92/rime.el#L1044) | In-process module; input-method activation builds a missing module with `make lib`. | Exposes `rime-compile-module`. Activation compares Lisp and native versions; a mismatch recompiles and explicitly requires restarting Emacs. |

The first three source snapshots were fetched at the linked revisions. Their
bootstrap logic should not be treated as comprehensive upgrade management:
vterm and Jinx primarily check whether the module is loaded or exists. PDF Tools
accepts an already running helper or performs a functional check, rather than
comparing source and binary versions. Its [upgrade instructions](https://github.com/vedang/pdf-tools#updating-pdf-tools)
recommend restarting and reinstalling, with `make distclean` for Git installs.
Rime provides the closest precedent here for an explicit version/restart check.

Archive packaging must retain the native build inputs. The MELPA recipes for
[vterm](https://github.com/melpa/melpa/blob/master/recipes/vterm),
[Jinx](https://github.com/melpa/melpa/blob/master/recipes/jinx), and
[PDF Tools](https://github.com/melpa/melpa/blob/master/recipes/pdf-tools)
explicitly include C sources, headers, or build directories. Portal's future
recipe needs its CMake files, native sources/resources, host sources and lockfiles,
as well as Lisp. A Lisp-only archive cannot build Portal.

### What package managers provide

Emacs 30's [`package-vc` implementation](https://github.com/emacs-mirror/emacs/blob/emacs-30/lisp/emacs-lisp/package-vc.el#L370)
supports `:shell-command` and `:make`. Commands run during installation and the
unpack step used by upgrades/rebuilds. They are disabled by default through
`package-vc-allow-build-commands`; allowlisting a package enables them. A failed
command produces a warning and does not necessarily fail installation.

A disposable local package tested through `use-package :vc` on this machine's
Emacs 31.1 reproduced all three cases:

| Probe | Result |
| --- | --- |
| Build command present; default policy | Package installed; command did not run. |
| Package allowlisted; successful command | Package installed; build marker created. |
| Package allowlisted; command exits 7 | Warning emitted; package still reported installed. |

These were isolated fixtures, not a successful end-to-end Portal installation.
The preceding Portal audit already found package metadata, byte-compilation,
and missing-artifact problems; a build hook alone does not fix those.

[`straight.el`](https://github.com/radian-software/straight.el#the-recipe-format)
has `:pre-build` and `:post-build` commands executed in the source repository;
its build directory contains selected symlinks. [Elpaca](https://github.com/progfolio/elpaca/blob/master/doc/manual.org#recipe-keyword-build)
has configurable ordered build steps and file selection. Both can invoke Portal's
build entry point, but recipes must expose the resulting complete bundle and host
where Portal looks for them. Test this explicitly instead of assuming the source
and runtime directories are identical.

### Proposed Portal behavior

The following names and behavior are a design proposal, not existing functions.

1. **Provide `M-x portal-build`.** Invoke the existing script in the actual source
   root. Interactive builds run asynchronously with a visible `*portal-build*`
   compilation buffer. Check tool availability and report actionable failures.
   Use the Emacs executable that will load the module. Document graphical Emacs's
   potentially different `PATH`, and retain explicit tool overrides. Resolve Bun
   using the private bootstrap described below. Diagnose missing Xcode and
   Homebrew-provided tools without installing or upgrading them automatically.
2. **Check readiness on the first interactive native command.** A normal `require`, autoload
   generation, and byte compilation must remain possible without native outputs.
   If outputs are absent, offer to run the build; explain that the first build
   downloads dependencies. After an asynchronous build, report success and ask
   the user to retry the original command. Keep an explicit command and an opt-in
   automatic-build setting for unattended setups; do not prompt in batch mode.
3. **Check compatibility, not just existence.** Record the built native revision
   or build identity, platform, and expected interface/protocol version. Detect
   stale binaries after an in-place source update and a partial module/host
   rebuild. Validate both artifacts before declaring the installation ready.
   Make any batch build/verification entry point return a nonzero exit status
   on failure. Verify files and metadata without loading a replacement into the
   current Emacs; any native load check must use a separate disposable process.
4. **Handle upgrades as a distinct state.** If Emacs has already loaded the old
   module, finish the build atomically, then clearly require a restart. Do not
   load a second module into that process or continue new Lisp against an
   incompatible old module. Reuse the existing server protocol checks for the
   helper side. Portal already documents [atomic replacement and restart](../../CONTRIBUTING.md#build-and-editor-setup),
   and [its view loader](../../portal-view.el) loads the module lazily.
5. **Use one build implementation.** The Lisp command, CI, manual instructions,
   and optional package-manager hooks should all call the same script. A user
   installation can use `./build.sh -DBUILD_TESTING=OFF`, which avoids Portal's
   CTest fixtures and ELPA test downloads; the full contributor build remains
   unchanged. This follows the [existing CMake testing guard](../../CMakeLists.txt).
6. **Support externally built artifacts.** Manual installations and distribution
   packages must be able to supply existing artifacts and disable compilation,
   including from read-only package directories. Diagnose an unwritable build
   destination instead of repeatedly offering a build that cannot succeed.
   Resolve symlinks deliberately and expose configurable artifact locations if
   needed. Native build output must not depend accidentally on an init file's
   directory or a package manager's staging layout.

For Portal, this combines PDF Tools' explicit asynchronous setup with vterm's
first-use assistance and Rime's version/restart handling. Choosing a prompt for
Portal is a recommendation based on its Swift/Bun build and downloads, not a
claim that all Emacs packages prompt.

### Private Bun bootstrap

Use a compatible existing Bun when available, otherwise obtain a private,
version-pinned executable as part of the requested build. Bun is distributed as a
single executable, with official archives for both Mac architectures; see its
[installation documentation](https://bun.com/docs/installation). The
[1.3.14 release assets](https://github.com/oven-sh/bun/releases/tag/bun-v1.3.14)
are approximately 22.5 MiB compressed for Apple Silicon and 25.3 MiB for Intel
(23,586,433 and 26,509,109 bytes respectively, from GitHub release metadata).
This is a practical one-time build download. Portal's compiled host already
contains its runtime; users do not need to keep a separate Bun running.

Proposed resolution order:

1. An explicit executable override, exposed through a Lisp customization and the
   existing CMake `BUN` option. An invalid explicit override produces an error
   rather than silently choosing something else.
2. Bun discovered through Emacs's `exec-path` (the command-line build uses its
   `PATH`). Validate that it runs and meets Portal's supported version/API
   requirements, including the existing `Bun.markdown.html` check. Record the
   chosen path and actual version in the build log. Presence alone is insufficient.
3. A previously cached copy of Portal's pinned Bun version for this platform.
4. Download and cache that pinned version from the official release assets.

Use a customizable tool cache rooted at
`(locate-user-emacs-file "portal/tools/")`, for example
`~/.emacs.d/portal/tools/bun/1.3.14/darwin-aarch64/`. Keep it outside versioned
ELPA directories so package upgrades and reinstalls can reuse the download.
The version shown here matches the currently documented tested runtime; the
implementation should select and test its pin deliberately. Maintain versions,
platform asset names, and SHA-256 digests together in one checked-in manifest.
Download to a temporary location, verify the expected digest before extraction
and execution, validate the executable, then install into the cache atomically.
Choose architecture and CPU requirements appropriate to the supported build
target, including translated Emacs processes where applicable.

Pass the selected executable's absolute path through `-DBUN=...`. Keep the
bootstrap resolver shared with `build.sh` so command-line and package-manager
builds follow the same selection rules; Emacs can supply its cache directory.
Use direct release archives, leaving shell configuration and global installations
untouched. Update the managed version through tested Portal changes rather than
running `bun upgrade` or following a floating latest-release URL.

The download belongs to explicit `portal-build` or an accepted first-use build,
with its progress shown in the build buffer. It should not need a separate prompt
after the user requests setup. Allow downloads to be disabled and a binary to be
supplied manually; a cached Bun avoids this download on later builds, although
other build dependencies also need caches for a fully offline build. Graphical
Emacs may have a different search path from a terminal: document the executable
override and respect the user's configured `exec-path` without automatically
sourcing shell startup files.

This refines the earlier [Bun distribution options](../../docs/bun-distribution.md) by
preferring an Emacs-owned persistent cache over a per-checkout build directory.

### Suggested user configuration

After implementing the readiness behavior and fixing package compilation, the
normal configuration can be small:

```elisp
;; Proposed source installation after the packaging work is complete.
(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal" :rev :newest)
  :commands (portal-terminal portal-hello portal-preview-markdown
             portal-excalidraw))
```

The first native command would offer setup. Users wanting to prepare Portal
before first use would run `M-x portal-build`. Once releases exist, document a
release-selection policy instead of requiring every user to track the newest
commit.

An optional Emacs 30+ installation-time adapter can use this shape:

```elisp
(require 'package-vc)
(unless (eq package-vc-allow-build-commands t)
  (add-to-list 'package-vc-allow-build-commands 'portal))

(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal"
       :rev :newest
       :shell-command "./build.sh -DBUILD_TESTING=OFF")
  :commands (portal-terminal portal-hello portal-preview-markdown
             portal-excalidraw))
```

This demonstrates the supported hook syntax, not an end-to-end verified Portal
recipe. It still needs correct tool discovery, packaging fixes and runtime
artifact validation. Its synchronous build can block installation or startup.
Keep it optional; avoid unconditional compilation in `:init` or `:config`, which
are configuration/loading hooks rather than an upgrade-aware native build API.

### Prebuilt artifacts

Prebuilt downloads are an established alternative. The separate [ELisp
Tree-sitter package](https://emacs-tree-sitter.github.io/installation/) tries a
GitHub binary first and Rust compilation second, with a setting that changes the
sources. This is a packaging precedent; its [current README](https://github.com/emacs-tree-sitter/elisp-tree-sitter)
recommends built-in Tree-sitter for Emacs 29+.

For Portal, prebuilt downloads would reduce the substantial toolchain burden, but
add architecture/macOS compatibility, complete bundle packaging, release pairing,
checksums, and distribution-notice work. Recommend source builds for the initial
release, then evaluate prebuilt releases using the existing [distribution
notes](../../docs/bun-distribution.md). Avoid making a general Emacs installation depend on
the launcher's single validated Emacs revision; that feature should retain its
separate compatibility gate.

### Acceptance criteria for implementation

- A clean package installation produces usable Lisp without loading native code
  or compiling developer tests. Optional adapters remain optional.
- First use diagnoses missing prerequisites and can start one visible build.
  Repeated requests do not launch competing builds.
- Bun resolution covers a compatible installed executable, an incompatible one,
  a valid cache, a fresh download, download/checksum failure, and an invalid
  explicit override. Package upgrades reuse the cache; disabled downloads remain
  disabled. Concurrent builds cannot expose a partially installed executable.
- Successful builds verify the module, complete resources and host. Failed builds
  preserve their logs and never report Portal ready.
- An unchanged installation does not rebuild on every Emacs startup.
- Updating the checkout detects stale outputs; updating with an already loaded
  module requires restart before using an incompatible interface.
- Test a clean `package-vc` install, an upgrade, a manual clone, and at least one
  package manager using symlinked build directories. Test missing tools and failed
  native builds as well as success.

These are research findings and acceptance targets, not evidence that Portal
already implements or passes the proposed installation behavior.
