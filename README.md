# Portal: native views in Emacs

<p align="center">
  <img src="assets/portal.png" alt="Portal Companion Buffer: a cube with Emacs and terminal emblems" width="320" height="320">
</p>

Portal puts native WebKit pages and Ghostty terminals inside macOS Emacs panes.
For Emacs users who want a real terminal or a local document preview alongside
editing, each buffer has one native view that follows it across splits, resizing
and frames. Hidden pages and terminal sessions keep running.

The bundled app host provides Markdown previews and an offline Excalidraw
editor. Optional launchers present your own Emacs commands in
a native panel, invoked by global shortcuts you configure.

## Scope

Portal requires **graphical macOS Emacs with dynamic modules**; it is not a
cross-platform package or a replacement for Emacs's text rendering. The native
module runs inside Emacs: a defect can crash that process. Start in a disposable
`emacs -Q`, and restart Emacs after rebuilding a module it has already loaded.

The opt-in launcher has a stricter compatibility gate: **GNU Emacs NS 31.1,
revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`**, with native subroutine
trampolines enabled. Other builds are rejected for this feature. Read
[launcher safety and setup](docs/launcher.md#set-up-safely) before enabling it.
Recorded environments and validation limits are in the
[testing guide](docs/testing.md).

## Build and run

You need graphical macOS Emacs and its matching `emacs-module.h`, Apple's
Swift 6.2 or newer and Clang (Xcode), CMake 3.29 or newer, Ninja, and Bun with
`Bun.markdown.html` (tested with Bun 1.3.14). Install CMake and Ninja with
`brew install cmake ninja` or your tool manager, and install Bun for building.
The first build downloads locked host/test dependencies and the pinned
GhosttyKit binary (about 77 MB) and Swift wrapper. No Zig installation is needed.

Use the graphical Emacs executable that matches the build's header. For a
non-default installation, select it using [build and editor setup](CONTRIBUTING.md#build-and-editor-setup)
before building. From a clone of this repository, run:

```sh
./build.sh
emacs -Q -l "$PWD/portal.el" --eval '(portal-hello)'
```

The build produces `build/portal.bundle` and the standalone `build/portal-host`.
The new Emacs should show **Hello World in a native web view**; its app host
starts automatically. Click the page or press `RET` to enter it, and press
Command-period (`⌘.`) to return to Emacs. Inactive content is subtly grayed out;
`RET` re-enters it. Customize `portal-input-escape-key` to change the escape chord.
`q` hides the view; killing its buffer closes it.

Try `M-x portal-terminal` for a shell, `M-x portal-preview-markdown` for a saved
Markdown file, or `M-x portal-excalidraw` for a local drawing. Loading Portal registers no global
shortcuts. Runtime use needs neither Bun nor Node nor adjacent web assets; see
[distribution layout](CONTRIBUTING.md#build-outputs-and-distribution).

## Documentation and contributing

Start with the [documentation index](docs/README.md) for user guides and design
notes. [Contributing](CONTRIBUTING.md) covers the worktree workflow,
editor setup, generated files and checks before a PR. [Testing Portal](docs/testing.md)
contains graphical procedures and detailed coverage; [AGENTS.md](AGENTS.md)
adds agent-specific working instructions.

For help or reproducible bug reports, use the repository's
[GitHub issues](https://github.com/xiaoxinghu/portal/issues). Include the Emacs
version/revision, macOS version, Portal commit and relevant diagnostics (for app
host failures, `*portal-server*`), removing credentials or private content.
Implementation files are licensed under [GPL-3.0-or-later](LICENSE). Builds
include third-party components under their own licenses; see
[Licenses and third-party notices](docs/licenses.md).
