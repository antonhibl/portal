# Anymacs: a native view in Emacs

A minimal macOS proof of concept: Emacs loads a Swift dynamic module that draws
an AppKit green rectangle in every pane displaying the demo buffer. The native
views share one content object and follow splits, resizing, and buffer visibility.

## Build and run

Requires graphical macOS Emacs with dynamic modules, its `emacs-module.h`, and
Apple's Swift 6/Clang toolchain. There are no third-party package dependencies.

```sh
./build.sh
emacs -Q -l "$PWD/anymacs.el" -f anymacs-show
```

Or load `anymacs.el` in graphical Emacs and run `M-x anymacs-show`. The command
opens `*anymacs-green*`. Press `q` or run `M-x anymacs-hide` to remove all its views.
The mode line and minibuffer remain available.

Build against the Emacs installation that will load the module. The script
locates its header relative to the chosen Emacs installation. Override `EMACS`
or `EMACS_INCLUDE` if needed:

```sh
EMACS_INCLUDE=/path/to/include ./build.sh
```

Restart Emacs after rebuilding a module it has already loaded. The build replaces
the library atomically, so rebuilding leaves the old loaded library intact; it
does not hot-reload that library.

## Behaviour

Buffers hold content; Emacs windows are the panes displaying that content and
have coordinates. Anymacs creates one native view per pane showing the green
buffer within the frame where `anymacs-show` was invoked.

- Splitting shows green in both panes. Each view follows its own pane's size and
  position, including when resizing the macOS window.
- Changing focus leaves all views in place. Switching one pane to another buffer,
  or closing it, removes only that pane's native view.
- Switching the buffer out of every pane releases all views while retaining the
  shared content. Showing the buffer again creates the required views automatically.
- `q`, `anymacs-hide`, killing the buffer, changing its major mode, or deleting the
  host frame releases all views and shared content, and stops tracking.
- Failed attachment or layout updates remove all views. Run `anymacs-show` to retry.

Moving the whole macOS window needs no extra positioning code because the native
views are already its children.

Splitting normally shows the same buffer in both panes, including with Evil's
`C-w v`. Both panes now render green. Switch either pane to another buffer to work
with text beside the remaining view.

## Implementation

| File | Responsibility |
| --- | --- |
| `anymacs.el` | Buffer mode, pane tracking, geometry, and lifecycle hooks |
| `native/Module.swift` | Emacs function registration, argument conversion, and errors |
| `native/NativeView.swift` | Shared content, AppKit views, and native inspection |
| `native/bootstrap.c` | Required C entry point and Emacs ABI size checks |

The Lisp `window-state-change-functions` hook measures `window-inside-pixel-edges`
during redisplay. Each pane receives a stable numeric ID. Lisp sends the complete
layout when geometry or pane membership changes; Swift validates the layout, then
creates, updates, or removes views on the main thread. An empty layout removes all
views without releasing the shared content. There is no polling timer, and Swift
never retains an Emacs value or environment pointer after a module call returns.

Each `GreenView` references the same `GreenContent` object, whose colour is fixed
to green for this demo. Views draw independently at their own dimensions; content
is shared rather than copied, and no screenshots or pixel mirroring are involved.

Initial attachment briefly assigns the requested frame a unique title so Swift
can find its native window, then immediately restores the title. The native host
stays bound until cleanup. This avoids relying on asynchronous window focus.

For diagnostics, `(anymacs--native-views)` reports the actual AppKit views as
plists containing `:visible`, `:edges`, and the native `:window` number.

## Verification

Tested with macOS 27.0, Swift 6.4, and Emacs 31.1 with `--module-assertions`.
C and Swift compile with warnings treated as errors; Lisp byte compilation also
passes without warnings. Rendering and both split directions were visually checked.

The graphical ERT tests inspect actual native bounds, visibility, and attachment
counts. They cover simultaneous views in splits, independent pane resizing, focus
navigation, removing only the views whose panes disappear, hidden buffers returning,
repeated show/stop/restart, buffer and frame cleanup, invalid layouts, and failure
recovery after multiple views have been attached.
They do not assert Lisp caches, hook names, or implementation call counts.

Run them in a disposable graphical Emacs. Batch Emacs has no native window and
cannot exercise these behaviours:

```sh
emacs -Q --module-assertions -l "$PWD/anymacs.el" \
  -l "$PWD/test/anymacs-tests.el" \
  --eval '(ert-run-tests-interactively "^anymacs-")'
```

The tests use only Emacs's built-in ERT, `cl-lib`, `seq`, and `windmove` libraries.

## Scope

One buffer with shared content and any number of pane views within one host frame.
Multiple native buffers and automatic presentation across frames are outside this
experiment.
To choose a different host frame, invoke `anymacs-show` from that frame again.

The buffer remains an ordinary Emacs buffer. This does not add native widgets to
Emacs's text rendering system. The module runs inside Emacs, so use a separate
`emacs -Q` process while experimenting.

Implementation files are licensed under [GPL-3.0-or-later](LICENSE).
