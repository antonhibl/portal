# Anymacs: a native view in Emacs

A minimal macOS proof of concept: Emacs loads a Swift dynamic module that embeds
native WebKit (`WKWebView`) pages or an AppKit green square in its panes.
A bundled Bun server hosts Hello World and local Markdown previews. The native views follow splits,
resizing, and buffer visibility.

## Build and run

Requires graphical macOS Emacs with dynamic modules, its `emacs-module.h`,
Apple's Swift 6/Clang toolchain (Xcode), CMake 3.29 or newer, Ninja, and Bun
(tested with Bun 1.3.14). Install CMake and Ninja with `brew install cmake ninja`
or your tool manager, and install Bun for building.
The build checks that Bun provides `Bun.markdown.html`.
The resulting host executable includes Bun and its page assets: users do not
need Bun, Node, npm packages, or server source files at runtime.

```sh
./build.sh
emacs -Q -l "$PWD/anymacs.el" \
  --eval '(anymacs-hello)'
```

The single build command produces `build/anymacs.dylib` and
`build/anymacs-host`. CMake recompiles the host when its TypeScript entry point
or HTML changes. Set `-DBUN=/absolute/path/to/bun` through `./build.sh` or CMake
if Bun is not discoverable. Both binaries are built for the current Mac.

Or load `anymacs.el` in graphical Emacs and run `M-x anymacs-hello`.
Run `M-x anymacs-preview-markdown` to preview the current Markdown file or
select another local file.
To distribute this layout, include both Lisp files at the package root and both
binaries in `build/`; the host needs no adjacent web assets.

`M-x anymacs-open-url` still opens an arbitrary absolute URL in `*anymacs-web*`.
HTTP, HTTPS, `file:`, `data:`, and `about:` URLs are supported. To open a local
HTML file with its adjacent assets:

```elisp
(require 'browse-url)
(anymacs-open-url (browse-url-file-url "/absolute/path/index.html"))
```

Click inside a page to interact with it. Press Escape or `C-g` to return keyboard
focus to Emacs, then `q` or `M-x anymacs-hide` to remove the views. The mode line
and minibuffer remain available. Run `anymacs-open-url` again to open another URL.
`M-x anymacs-show` still opens the green-square demo in `*anymacs-green*`.

`./build.sh` runs the `dev` CMake configure and build presets. For development,
configure once before opening native source files; this generates editor metadata
without compiling the module:

```sh
cmake --preset dev
cmake --build --preset dev
```

CMake describes both C and Swift, including the Emacs bridging header, Swift 6,
and AppKit/WebKit linkage. Configuration generates `build/compile_commands.json`
and a symlink at the repository root. clangd uses its C command; SourceKit-LSP
uses its Swift commands. Both get the same settings used by the build. Generated
files stay out of Git. Reconfigure after changing sources, dependencies, or SDKs.

In Emacs, use Eglot with clangd for C and SourceKit-LSP for `swift-mode`. Xcode
provides both servers. If buffers were opened before configuration, run
`M-x eglot-reconnect` in a C buffer and a Swift buffer (or `M-x eglot` if not yet
connected). No project-specific header paths belong in your Emacs configuration.

For TypeScript editing, install the host's development dependencies and run its
type check:

```sh
bun install --cwd host --frozen-lockfile
bun run --cwd host typecheck
```

`host/tsconfig.json` supplies strict TypeScript settings and Bun/Node API types.
The asset declarations describe HTML and CSS imports loaded as strings.
Bun types match the tested 1.3.14 runtime; TypeScript 6 retains `tsserver`
support for editors using `typescript-language-server`, including Eglot.
If an existing TypeScript session still shows old diagnostics, run
`M-x eglot-reconnect`. These packages are development dependencies; CMake
continues to compile the standalone host directly with Bun.

Build against the Emacs installation that will load the module. Configuration
locates its header beside the app's resources or in system include directories.
Override the cached choices when needed:

```sh
cmake --preset dev -DEMACS=/path/to/emacs -DEMACS_INCLUDE=/path/to/include
```

`EMACS` and `EMACS_INCLUDE` environment overrides also work with `./build.sh`.
When changing Emacs installations, pass its include directory too, or run
`cmake --fresh --preset dev` to rediscover everything.

Restart Emacs after rebuilding a module it has already loaded. The build replaces
the library atomically, so rebuilding leaves the old loaded library intact; it
does not hot-reload that library.

## Bun UI host

Loading the Lisp package or native module does not start a server. The first
`anymacs-hello` or `anymacs-preview-markdown` starts one shared child process
asynchronously, waits for its readiness message, then loads the requested page
in the native webview. Opening external
URLs does not require the server.

- The host binds to `127.0.0.1` on an OS-assigned port. Each Emacs process owns
  its own host; all its panes reuse that host.
- Each host generates a fresh access token and sends it through the readiness
  pipe. URLs have the form `http://127.0.0.1:PORT/TOKEN/hello` or
  `http://127.0.0.1:PORT/TOKEN/markdown?path=ENCODED_ABSOLUTE_PATH`. The host
  validates the token and Host header; responses suppress outgoing referrers.
- Closing or hiding a view keeps the server running. `M-x anymacs-start-server`
  can prewarm it explicitly; `M-x anymacs-stop-server` stops it, and
  `M-x anymacs-restart-server` starts a replacement and reloads active hosted views.
- Startup is bounded by `anymacs-server-start-timeout` (five seconds by default).
  Failures leave diagnostics in `*anymacs-server*`; run `anymacs-hello` to retry.
  There is no automatic restart loop.
- Emacs supervises the child through a pipe. stdout carries a versioned JSON
  readiness line; stderr carries diagnostics. Closing stdin requests shutdown,
  including when Emacs exits unexpectedly. Normal shutdown also handles OS
  termination signals and has a forced-termination fallback.
- `anymacs-server-program` selects the standalone executable. At runtime it is
  launched directly, without a shell or any lookup of Bun on PATH. Runtime
  loading of `.env` and `bunfig.toml` is disabled in the compiled binary.

Control protocol version 2 announces readiness, port, and access token; it is
not yet a general UI RPC API. Rebuilding publishes the host executable atomically. An already
running host keeps its old code until `anymacs-restart-server` is called.

## Markdown previews

Run `M-x anymacs-preview-markdown` in a Markdown file buffer to preview it
directly. Markdown modes and common file extensions are recognised. From other
buffers, the command prompts for a saved local file. Use `C-u M-x
anymacs-preview-markdown` to choose another file explicitly.
The Bun server reads the file, renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
and returns a complete HTML page with embedded light/dark CSS. Rendering happens
in memory, without temporary HTML files or additional npm dependencies.

Headings, lists, fenced code, tables, strikethrough, task lists, and heading
anchors are supported. Press Escape or `C-g` to return focus to Emacs, then
`g` (`anymacs-refresh`) to reread the file from disk. Refresh also restarts a
stopped host; the selected Markdown file is retained across host restarts.
Missing or unreadable files produce an error page.

This version previews saved contents only, with no automatic refresh. It does
not serve relative images or linked local files, or add syntax highlighting,
Mermaid, or math rendering. HTTP(S) images and links can use their absolute URLs.
Raw HTML is displayed as text, and a page-specific Content Security Policy
blocks scripts. Bun currently marks its Markdown API unstable; it is tested
here with the Bun version listed above.

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

- Splitting shows a green square in both panes. Each square stays 32×32 points
  and centered in its pane's text area as the panes or macOS window resize.
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
| `anymacs-server.el` | Lazy shared-process startup, readiness, logs, and shutdown |
| `host/server.ts` | Local HTTP server and parent-process lifetime |
| `host/hello.html` | Embedded Hello World page, styles, and JavaScript |
| `host/markdown.ts` | Local Markdown reads, HTML rendering, and error pages |
| `host/markdown.css` | Embedded Markdown typography and light/dark colours |
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
repeated navigation, input validation, and cleanup. The hosted-page tests also
exercise process reuse, restart, and cancellation while the server starts;
a separate HTTPS smoke check loaded `https://example.com` successfully.
The Markdown tests exercise file paths with Unicode and URL punctuation,
refresh after file deletion/restoration, split panes, host recovery, and
cancellation during startup.
All 19 graphical tests pass with the bundled UI host.
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

The compiled-host integration tests run without a graphical display:

```sh
./build.sh
ctest --test-dir build --output-on-failure
```

They exercise real HTTP requests, a relocated binary with no Bun on PATH,
shared startup, graceful shutdown, restart, crash recovery, startup timeout,
and partial or incompatible readiness messages.
They also check Markdown output, rereading saved changes, invalid paths,
access-token and Host validation, and non-executable raw HTML.

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
