# Install Portal

Portal is an Emacs package with a native part: a module that Emacs loads and a
standalone app host. Package managers install the Lisp and the sources; Portal
builds its native part from those sources the first time you need it.

The use-package examples marked `<!-- example: NAME -->` are test fixtures: the
package installation test runs them. Keep their markers when editing them.

## Prerequisites

- Graphical macOS Emacs 30.1 or newer, built with module support.
- Xcode with Swift 6.2 or newer, CMake 3.29 or newer and Ninja. Install CMake
  and Ninja with `brew install cmake ninja` or your tool manager.
- Bun is optional. A build uses a compatible Bun on `exec-path`; otherwise it
  downloads Portal's pinned Bun once (see [Bun](#bun)).

Graphical Emacs started from the Dock may not see your shell's `PATH`. The build
searches Emacs's `exec-path`, so make sure that includes CMake, Ninja and Xcode's
`xcrun`, for example through `exec-path-from-shell` or by setting `exec-path`.
Portal does not read your shell's startup files.

The first build downloads locked host dependencies and the pinned GhosttyKit
binary (about 77 MB) and takes several minutes. Later builds are incremental.

## With use-package and package-vc

Emacs 30 can install Portal straight from its Git repository:

<!-- example: use-package-vc -->
```elisp
(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal" :rev :newest))
```

Installing compiles Portal's Lisp only. The first native command, such as
`M-x portal-terminal` or `M-x portal-hello`, offers to build the native part and
shows the build in `*portal-build*`. When it finishes, run the command again.
To prepare Portal ahead of time, run `M-x portal-build` yourself.

`:rev :newest` follows the newest commit. Portal has no releases yet.

## From a clone

Clone the repository anywhere and load it from there:

```sh
git clone https://github.com/xiaoxinghu/portal ~/src/portal
```

<!-- example: use-package-load-path -->
```elisp
(use-package portal
  :load-path "~/src/portal")
```

Without use-package, `(add-to-list 'load-path "~/src/portal")` and
`(require 'portal)` do the same. Build from Emacs with `M-x portal-build`, or
from the clone with `./build.sh -DBUILD_TESTING=OFF`; the
[contributor build](../CONTRIBUTING.md#build-and-editor-setup) also builds tests.
Both use the same script and the same [Bun selection](#bun).

## With straight.el or Elpaca

Both link the Lisp files into a separate build directory. Portal follows those
links back to the cloned repository, where it builds and keeps its native part.
With straight.el:

```elisp
(straight-use-package '(portal :host github :repo "xiaoxinghu/portal"))
```

The equivalent Elpaca recipe, `(elpaca (portal :host github :repo
"xiaoxinghu/portal"))`, follows the same layout but has not been tested.

## Building when the package installs

Building on first use needs no package-manager configuration. A package manager
can also run the build as it installs or upgrades Portal, for example with
package-vc in Emacs 30:

```elisp
(require 'package-vc)
(unless (eq package-vc-allow-build-commands t)
  (add-to-list 'package-vc-allow-build-commands 'portal))

(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal"
       :rev :newest
       :shell-command "./build.sh -DBUILD_TESTING=OFF"))
```

This build blocks Emacs while it runs, and package-vc reports a failed build only
as a warning. Portal still checks the result on first use. straight.el's
`:pre-build` and Elpaca's `:build` steps can run the same command in the cloned
repository. Do not build from `:init` or `:config`: they run on every startup.

## What Portal checks

Each successful build loads the new module and starts the new app host in a
separate batch Emacs. It then records a hash of the native sources it was built
from in `build/portal-build.eld`. A build removes that record before replacing
anything, and records nothing if its sources changed while it ran, so a failed,
interrupted or overtaken build is never taken as ready.

Before loading its module, Portal compares the record with its sources once per
Emacs session. Startup never rebuilds. After an upgrade that changes the native
sources, the first native command offers to rebuild. Lisp-only changes need no
rebuild. Emacs cannot unload a module: when the module that Emacs already loaded
came from another build, or from a Portal too old to record its build, Portal
asks you to restart Emacs before using the new one. Building never touches a module or host that is running.

Only one build of a checkout runs at a time; another one stops immediately.
`*portal-build*` shows the current build, and `build/portal-build.log` keeps the
last one started from Emacs.

## Bun

Bun compiles the app host; the built host includes its own runtime. A build
uses, in order:

1. The Bun you name: `portal-build-bun` in Emacs, or `BUN` for `./build.sh`.
   The build fails if this Bun is missing or incompatible.
2. A compatible `bun` on `exec-path` (the shell's `PATH` for `./build.sh`).
   An incompatible one is reported and skipped.
3. Portal's pinned Bun, cached in `portal-build-tools-directory`
   (`~/.emacs.d/portal/tools/` by default; `PORTAL_TOOLS_DIR` or `build/tools/`
   for `./build.sh`). The cache is outside the package, so upgrades reuse it.
4. Portal's pinned Bun, downloaded from Bun's official release. Its SHA-256
   digest is checked against [tools/bun.manifest](../tools/bun.manifest)
   before it runs, and it reaches the cache in one atomic step.

A compatible Bun has `Bun.markdown.html` and is at least the pinned version.
Set `portal-build-download-bun` to nil, or `PORTAL_BUN_DOWNLOAD=0`, to never
download. Portal never changes your shell configuration or installed Bun.

## Supplied builds and read-only installations

Portal looks for its native part in `build/` beside its sources. To use one
built elsewhere, for example by a distribution, set `portal-build-directory` to
the directory holding `portal.bundle`, `portal-host` and `portal-build.eld`.
Portal then reports a missing or stale build instead of offering to build. It
also reports a build directory that is not writable instead of starting a build
that cannot succeed.

| Option | Effect |
| --- | --- |
| `portal-build-on-first-use` | `ask` (default), `always` for unattended setups, or `never` |
| `portal-build-directory` | Use a build supplied elsewhere |
| `portal-build-bun` | Use this Bun executable |
| `portal-build-download-bun` | Allow downloading Portal's pinned Bun |
| `portal-build-tools-directory` | Where downloaded tools are cached |
