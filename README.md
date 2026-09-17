# Anymacs: a native view in Emacs

A minimal macOS proof of concept: Emacs loads a Swift dynamic module that embeds
native WebKit (`WKWebView`) pages or an AppKit green square in its panes.
The native views follow splits, resizing, and buffer visibility.

## Build and run

Requires graphical macOS Emacs with dynamic modules, its `emacs-module.h`, and
Apple's Swift 6/Clang toolchain. There are no third-party package dependencies.

```sh
./build.sh
emacs -Q -l "$PWD/anymacs.el" \
  --eval '(anymacs-open-url "https://example.com")'
```

Or load `anymacs.el` in graphical Emacs and run `M-x anymacs-open-url`, then enter
an absolute URL. It opens `*anymacs-web*`. HTTP, HTTPS, `file:`, `data:`, and `about:`
URLs are supported. To open a local HTML file with its adjacent assets:

```elisp
(require 'browse-url)
(anymacs-open-url (browse-url-file-url "/absolute/path/index.html"))
```

Click inside a page to interact with it. Press Escape or `C-g` to return keyboard
focus to Emacs, then `q` or `M-x anymacs-hide` to remove the views. The mode line
and minibuffer remain available. Run `anymacs-open-url` again to open another URL.
`M-x anymacs-show` still opens the green-square demo in `*anymacs-green*`.

Build against the Emacs installation that will load the module. The script
locates its header relative to the chosen Emacs installation. Override `EMACS`
or `EMACS_INCLUDE` if needed:

```sh
EMACS_INCLUDE=/path/to/include ./build.sh
```

Restart Emacs after rebuilding a module it has already loaded. The build replaces
the library atomically, so rebuilding leaves the old loaded library intact; it
does not hot-reload that library.

## Webview behaviour

The existing native host accepts `WKWebView` directly. Remote pages use
[WebKit's URL request loading](https://developer.apple.com/documentation/webkit/wkwebview);
local pages use `loadFileURL` with read access to the containing directory so
relative scripts, styles, and images can load. JavaScript is enabled by default.

- Each pane displaying `*anymacs-web*` gets an independent webview starting at the
  requested URL. Cookies use WebKit's default data store, but navigation, DOM,
  scroll position, and form state are independent between panes.
- Resizing a pane preserves its webview. Hiding or closing a pane releases its
  webview; showing the buffer again loads the originally requested URL anew.
- Opening another URL replaces the current Anymacs content. There is one active
  native buffer and one host frame, as in the original demo.
- Escape and `C-g` are reserved for returning to Emacs while a page has focus.
  Clicking a webview does not change Emacs's selected pane; use Emacs window
  navigation after returning focus.
- This is a URL viewer, without browser chrome, history commands, downloads,
  popup windows, or JavaScript dialog UI. Failed loads can be inspected through
  `:error` in `(anymacs--native-views)`.

A shared, persistent browser session mirrored across splits would require a
separate design; this first version shares the requested URL only.

## Green demo behaviour

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
| `native/NativeView.swift` | AppKit/WebKit views, URL loading, focus return, and inspection |
| `native/bootstrap.c` | Required C entry point and Emacs ABI size checks |

The Lisp `window-state-change-functions` hook measures `window-inside-pixel-edges`
during redisplay. Each pane receives a stable numeric ID. Lisp sends the complete
layout when geometry or pane membership changes; Swift validates the layout, then
creates, updates, or removes views on the main thread. An empty layout removes all
views without releasing the shared content. There is no polling timer, and Swift
never retains an Emacs value or environment pointer after a module call returns.

Each `GreenView` references the same `NativeContent` object, whose colour is fixed
to green for this demo. Views draw independently at their own dimensions; content
is shared rather than copied, and no screenshots or pixel mirroring are involved.

Initial attachment briefly assigns the requested frame a unique title so Swift
can find its native window, then immediately restores the title. The native host
stays bound until cleanup. This avoids relying on asynchronous window focus.

For diagnostics, `(anymacs--native-views)` reports the actual AppKit views as
plists containing `:visible`, `:edges`, the native `:window` number, and WebKit's
`:url`, `:title`, `:loading`, and `:error` state. Native navigation callbacks only
update Swift state; they never call back into Lisp.

## Verification

Tested with macOS 27.0, Swift 6.4, and Emacs 31.1 with `--module-assertions`.
C and Swift compile with warnings treated as errors; Lisp byte compilation also
passes without warnings. The green demo and both split directions were previously visually checked.

The graphical ERT tests inspect actual native bounds, visibility, and attachment
counts. They cover simultaneous views in splits, independent pane resizing, focus
navigation, removing only the views whose panes disappear, hidden buffers returning,
repeated show/stop/restart, buffer and frame cleanup, invalid layouts, and failure
recovery after multiple views have been attached.
The webview tests also wait for real WebKit page loads, verify JavaScript execution
and relative local assets, and exercise splits, resizing, hidden-buffer reloads,
repeated navigation, input validation, and cleanup. All 15 graphical tests pass;
a separate HTTPS smoke check loaded `https://example.com` successfully.
They do not assert Lisp caches, hook names, or implementation call counts.

Run them in a disposable graphical Emacs. Batch Emacs has no native window and
cannot exercise these behaviours:

```sh
emacs -Q --module-assertions -l "$PWD/anymacs.el" \
  -l "$PWD/test/anymacs-tests.el" \
  --eval '(ert-run-tests-interactively "^anymacs-")'
```

The Lisp tests use only Emacs's built-in libraries. A standalone AppKit check
also verifies Escape, `C-g`, and focused-view removal return focus to the editor:

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors \
  native/NativeView.swift test/native-focus.swift \
  -framework AppKit -framework WebKit -o build/check-focus
build/check-focus
```

## Scope

One active native buffer and any number of pane views within one host frame.
Multiple native buffers and automatic presentation across frames are outside this
experiment.
To choose a different host frame, invoke `anymacs-open-url` (or `anymacs-show`
for the green demo) from that frame again.

The buffer remains an ordinary Emacs buffer. This does not add native widgets to
Emacs's text rendering system. The module runs inside Emacs, so use a separate
`emacs -Q` process while experimenting.

Implementation files are licensed under [GPL-3.0-or-later](LICENSE).
