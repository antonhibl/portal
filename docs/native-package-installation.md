# Native package installation research

Recorded: 2026-10-11. Status: recommendation, not an implemented installation API.

## Recommendation

Give Portal a package-owned native build command and a first-use readiness check.
Keep `build.sh` as the underlying build entry point. Offer package-manager build
hooks as optional adapters. For the first public release, retain source builds;
consider prebuilt artifacts after defining the supported platform matrix.

The projects below establish a common pattern, not a formal ecosystem consensus:
the package handles its native component, while package managers install the
Lisp and source files. The exact trigger varies from library loading to mode
activation or an explicit setup command. This research concerns C/Swift modules
and helper executables, not Emacs's separate compilation of Lisp into `.eln` files.

## Established packages

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

## What package managers provide

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

## Proposed Portal behavior

The following names and behavior are a design proposal, not existing functions.

1. **Provide `M-x portal-build`.** Invoke the existing script in the actual source
   root. Interactive builds run asynchronously with a visible `*portal-build*`
   compilation buffer. Check tool availability and report actionable failures.
   Use the Emacs executable that will load the module. Document graphical Emacs's
   potentially different `PATH`, and retain explicit tool overrides. Avoid
   automatically installing or upgrading Xcode, Homebrew packages, or Bun.
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
   helper side. Portal already documents [atomic replacement and restart](../CONTRIBUTING.md#build-and-editor-setup),
   and [its view loader](../portal-view.el) loads the module lazily.
5. **Use one build implementation.** The Lisp command, CI, manual instructions,
   and optional package-manager hooks should all call the same script. A user
   installation can use `./build.sh -DBUILD_TESTING=OFF`, which avoids Portal's
   CTest fixtures and ELPA test downloads; the full contributor build remains
   unchanged. This follows the [existing CMake testing guard](../CMakeLists.txt).
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

## Suggested user configuration

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

## Prebuilt artifacts

Prebuilt downloads are an established alternative. The separate [ELisp
Tree-sitter package](https://emacs-tree-sitter.github.io/installation/) tries a
GitHub binary first and Rust compilation second, with a setting that changes the
sources. This is a packaging precedent; its [current README](https://github.com/emacs-tree-sitter/elisp-tree-sitter)
recommends built-in Tree-sitter for Emacs 29+.

For Portal, prebuilt downloads would reduce the substantial toolchain burden, but
add architecture/macOS compatibility, complete bundle packaging, release pairing,
checksums, and distribution-notice work. Recommend source builds for the initial
release, then evaluate prebuilt releases using the existing [distribution
notes](bun-distribution.md). Avoid making a general Emacs installation depend on
the launcher's single validated Emacs revision; that feature should retain its
separate compatibility gate.

## Acceptance criteria for implementation

- A clean package installation produces usable Lisp without loading native code
  or compiling developer tests. Optional adapters remain optional.
- First use diagnoses missing prerequisites and can start one visible build.
  Repeated requests do not launch competing builds.
- Successful builds verify the module, complete resources and host. Failed builds
  preserve their logs and never report Portal ready.
- An unchanged installation does not rebuild on every Emacs startup.
- Updating the checkout detects stale outputs; updating with an already loaded
  module requires restart before using an incompatible interface.
- Test a clean `package-vc` install, an upgrade, a manual clone, and at least one
  package manager using symlinked build directories. Test missing tools and failed
  native builds as well as success.

This research changes documentation only. It does not implement these behaviors
or assert that the proposed Portal recipes already pass those acceptance checks.
