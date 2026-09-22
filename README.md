# Portal: native views in Emacs

Native WebKit pages and Ghostty terminals inside macOS Emacs panes, backed by
one Swift dynamic module. A bundled Bun server hosts Hello World and local
Markdown previews and an offline Excalidraw editor. Native views follow splits, resizing, and buffer visibility;
hidden terminal sessions keep running. An AppKit green-square demo is also included.

## Build and run

Requires graphical macOS Emacs with dynamic modules, its `emacs-module.h`,
Apple's Swift 6/Clang toolchain (Xcode), CMake 3.29 or newer, Ninja, and Bun
(tested with Bun 1.3.14). Install CMake and Ninja with `brew install cmake ninja`
or your tool manager, and install Bun for building.
The build checks that Bun provides `Bun.markdown.html`.
The resulting host executable includes Bun and its page assets: users do not
need Bun, Node, npm packages, or server source files at runtime.
The native module uses SwiftPM to download a pinned GhosttyKit binary
(about 77 MB on the first build) and its native Swift wrapper. No Zig installation
is needed. The versions and binary checksum are pinned by
`native/Package.swift` and `native/Package.resolved`.

```sh
./build.sh
emacs -Q -l "$PWD/portal.el" \
  --eval '(portal-hello)'
```

The single build command produces `build/portal.bundle` and
`build/portal-host`. The bundle contains the one native Emacs module at
`Contents/MacOS/portal.dylib` and Ghostty's resources. CMake recompiles the host when its TypeScript entry point
or HTML changes. Set `-DBUN=/absolute/path/to/bun` through `./build.sh` or CMake
if Bun is not discoverable. Both binaries are built for the current Mac.

Or load `portal.el` in graphical Emacs and run `M-x portal-hello`.
Run `M-x portal-preview-markdown` to preview the current Markdown file or
select another local file.
To distribute this layout, include all `portal*.el` files at the package root,
`build/portal-host`, and the complete `build/portal.bundle`;
the host needs no adjacent web assets. Keep the bundle intact, including its terminfo
and shell integration resources. Restart Emacs when upgrading from the former
separate web and terminal modules, or after rebuilding a loaded native module.

Run `M-x portal-preview-html` in a `.html` or `.htm` file buffer to open its
saved contents in the embedded webview, including relative scripts, styles,
and images from its directory. From other buffers, it prompts for a local
path or URL. Relative paths use the current buffer's `default-directory`;
`C-u M-x portal-preview-html` always prompts. Unsaved edits are not included.

`M-x portal-open-url` still opens an arbitrary absolute URL in `*portal-web*`.
Both commands accept HTTP, HTTPS, `file:`, `data:`, and `about:` URLs.
To open a local HTML file programmatically:

```elisp
(portal-preview-html "/absolute/path/index.html")
```

Click inside a page to interact with it. Press Escape or `C-g` to return keyboard
focus to Emacs, then `q` or `M-x portal-hide` to remove the views. The mode line
and minibuffer remain available. Run `portal-open-url` again to open another URL.
`M-x portal-show` still opens the green-square demo in `*portal-green*`.

## Local Excalidraw drawings

Run `M-x portal-excalidraw` for a new drawing, then `C-x C-s` to choose its
filename and save. Open existing `.excalidraw` files normally with `C-x C-f`
or Dired; they enter `portal-excalidraw-mode` automatically. A prefix argument
to `portal-excalidraw` prompts for an existing or new file.

- Draw, type, paste text/images, and use the normal Excalidraw editing tools.
- `C-x C-s`, Command-S, and the editor's **Save** button all save through Emacs.
  `C-x` works while the webview has focus, including fast follow-up keys.
- Command-Escape returns keyboard focus to Emacs; `RET` re-enters the editor.
  Bare Escape remains available for drawing/text editing.
- Each drawing has one editor. Switching buffers hides it without losing its
  contents, selection, or undo history. In splits, the editor follows the selected
  window showing that buffer. Independent drawings can be displayed together.
- Drawings use standard Excalidraw JSON, including embedded image data. Emacs owns
  file saving, modified indicators, backup settings, auto-save, and overwrite
  checks. Untitled modified drawings also participate in save/close prompts.
- `M-x revert-buffer` reloads the file from disk. `C-c C-r` recreates a failed
  editor using the buffered drawing, preserving unsaved buffered changes but
  resetting undo history. Use it after restarting the Bun host if more editor
  assets need loading. A stopped host does not unload an already open drawing.

Excalidraw 0.18.1, React, CSS, lazy modules and fonts are bundled into
`portal-host`. The build installs pinned npm dependencies with Bun; runtime use
needs no npm packages or internet connection. The editor blocks external asset
requests, CDN font fallbacks and remote embeds. Document persistence uses neither
localStorage nor IndexedDB. The current integration focuses on local documents;
cloud collaboration, online library installation, persistent personal libraries,
and image export are not integrated.

Restart Emacs after rebuilding the native module. See the
[shared editor bridge](docs/editor-bridge.md) for implementation and tests.

## Quick project terminal

Run `M-x portal-terminal-toggle` to summon a scratch terminal in the bottom half
of the frame. Run it again to dismiss the panel and return to your editing
window, even if the terminal no longer has keyboard focus. No global shortcut
is installed. Call `(portal-terminal-toggle)` from Lisp or bind the command to
whatever Emacs key sequence you prefer. For example, in your own configuration:

```elisp
(keymap-global-set "s-`" #'portal-terminal-toggle)
(portal-terminal-bind-key portal-terminal-quick-native-map
                          "s-`" #'portal-terminal-toggle)
```

The second binding handles Command-backtick while Ghostty has keyboard focus.
It applies immediately, including to hidden quick terminals. Both bindings are
optional user configuration. You can instead use the existing terminal prefix:

```elisp
(keymap-set portal-terminal-quick-prefix-map "t" #'portal-terminal-toggle)
```

That example runs the command after your terminal prefix followed by `t`.
See [the input bridge](docs/terminal-input-bridge.md) for runtime binding APIs
and how native events reach Elisp.

Each project has one quick shell per Emacs frame. A new shell starts at the
`project.el` root of the current file or Dired buffer. Help and other auxiliary
buffers use the most recently selected file/Dired directory in that frame.
Outside a project, the file's directory is used; with no editing context,
`portal-terminal-quick-directory` defaults to home. Remote contexts are rejected.

Dismissal only hides the panel: the shell, current directory, environment,
partially typed input, scrollback, and foreground programs remain intact.
Reopening never sends `cd` or starts a replacement shell. A command such as
`npm run dev` keeps running while hidden; reopen and use `C-c` to interrupt it.
Switching files or projects does not automatically change an already visible
panel. Dismiss it, then summon again to select the new project's quick shell.

Quick terminals have a restricted native prefix map (`C-b` by default):

| Key | Action |
| --- | --- |
| `q` | Dismiss without ending the shell |
| `d` | Return keyboard control to Emacs, leaving the panel visible |
| `r` | Confirm and reset to a fresh shell at this project's root |
| `k` | Confirm and forget this project's quick shell |
| `:` | Run an Emacs command with `M-x` |
| `?` | Show quick-terminal bindings |

The corresponding commands are `portal-terminal-quick-dismiss`,
`portal-terminal-quick-reset`, and `portal-terminal-quick-forget`. Reset/forget
target the visible panel when there is one, otherwise the current editing
project. Bare Escape, `q`, and `C-g` remain terminal input. Clicking into the
editor leaves the panel visible. Its initial height is controlled by
`portal-terminal-quick-height` (default `0.5`); dismissal remembers manual resizing.

Quick terminals are excluded from ordinary Portal terminal selection, numbering,
and cycling. They have no naming or multiple-instance workflow. A busy quick
shell remains busy until its command finishes or you interrupt/reset it.
Deleting its owning frame or quitting Emacs ends the session; this does not
provide persistence across Emacs restarts. A shell that exits is not silently
restarted: use reset when you want a new one.

Run the buffer/window/project tests with `ctest --test-dir build -R quick-terminal`.
The graphical terminal suite also tests a user-configured native prefix binding and a real
foreground process continuing while the quick panel is hidden.

## Native Ghostty terminal

To compare terminal performance, run `./benchmark.sh --label portal` inside the
embedded shell and `./benchmark.sh --label ghostty` in standalone Ghostty.
See [benchmark methodology and FPS research](docs/terminal-benchmark.md) for
latency, frame timing, optional Instruments captures and interpretation limits.

After `./build.sh`, load `portal.el` and run `M-x portal-terminal`, or launch a
fresh graphical Emacs:

```sh
emacs -Q -l "$PWD/portal.el" --eval '(portal-terminal)'
```

This embeds a real Ghostty Metal terminal surface inside the pane. Ghostty owns
the PTY, shell, terminal state, fonts, rendering, selection and scrollback.
It starts your normal shell in the current local `default-directory`; interactive
commands, Vim and other TUIs use the real terminal protocol engine. It does not
convert output to Emacs text or use WebKit or the Bun server.

- Click the terminal or press `RET` in its buffer to give it keyboard focus.
- Press **`C-b`**, then a command from the table below. A prompt in the echo
  area shows that Emacs is reading a command. There is no prefix timeout.
- **`C-b d`**, `Command-Escape`, or clicking **Return to Emacs** leaves keyboard
  control with Emacs. Use normal Emacs bindings, then `RET` to re-enter Ghostty.
- **`C-b C-b`** sends a literal Control-B. `C-g` cancels a pending prefix;
  ordinary Escape, `C-g`, `C-c`, and other terminal keys otherwise go to the shell.
- Select with the mouse and use `Command-C` / `Command-V` for the macOS clipboard.
  Scroll with the trackpad or mouse wheel. Non-Latin IME composition has not
  been manually verified.
- Hidden buffers keep their shells running. Killing a terminal buffer, running
  `portal-terminal-close` in it, or deleting its frame ends that shell.
  `portal-terminal-close-all` ends all embedded shells.

Defaults follow [tmux's key bindings](https://man.openbsd.org/tmux#DEFAULT_KEY_BINDINGS)
where an Emacs counterpart exists. Every row follows the prefix (`C-b` by default):

| Key | Action |
| --- | --- |
| `c` | New independent terminal buffer |
| `"` / `%` | Split below / right with a new shell |
| `o` / arrow keys | Next / directional Emacs pane |
| `n` / `p` / `l` | Next / previous / last terminal buffer |
| `0`–`9` | Select a terminal by its current creation-order index |
| `w` | Choose a terminal with Emacs completion |
| `,` | Rename the terminal buffer |
| `z` | Zoom the pane; repeat to restore the layout |
| `x` | Confirm, end the shell, and close its pane |
| `d` | Stay in Emacs; keep the shell running |
| `:` | Run `M-x` and stay in Emacs afterward |
| `?` | Show the current bindings, including customizations |
| repeated prefix | Send the actual prefix keystroke to the shell |

These are Emacs operations: terminal buffers stand in for tmux windows and Emacs
windows stand in for panes. There are no tmux session servers, saved per-terminal
pane layouts, or tmux copy mode. Each terminal belongs to its creating frame and
has one native view; displaying the same buffer twice moves that view to the
selected pane. Different terminal buffers can display and run simultaneously.

Configure in Lisp after loading `portal.el` (changes apply to running terminals):

```elisp
(setq portal-terminal-prefix "C-a") ; default: "C-b"
(setq portal-terminal-theme "Dracula") ; nil follows system light/dark appearance
(keymap-set portal-terminal-prefix-map "v" #'portal-terminal-split-right)
(keymap-set portal-terminal-prefix-map "b" #'switch-to-buffer)
(keymap-set portal-terminal-prefix-map "e" #'portal-terminal-unfocus)
```

`portal-terminal-theme` accepts an exact, case-sensitive name from
`(portal-terminal-themes)`. Set it with `setq` or Customize, including in your
init file before loading Portal. Changes recolor all running terminals, including
hidden ones, and apply to new terminals without restarting existing shells.
Set it to `nil` to restore Alabaster in light mode and Afterglow in dark mode.
Named themes stay fixed across system appearance changes.

The prefix accepts one modified ASCII key in `kbd` notation; Meta means Option
and Super means Command. Customize the map or add nested prefix maps with normal
Emacs keymap functions. Commands finish their minibuffer interaction before focus
returns to the selected terminal. Switching to an ordinary buffer keeps Emacs in
control. A custom command can call `portal-terminal-unfocus` to stay in Emacs even
when a terminal is selected. Errors also leave focus in Emacs.

`portal-terminal-native-map` adds opt-in standalone or nested shortcuts to all
terminals; `portal-terminal-quick-native-map` overlays it for quick terminals.
Use `portal-terminal-bind-key` / `portal-terminal-unbind-key` for live changes,
or call `portal-terminal-refresh-bindings` after direct keymap edits. These maps
start empty and do not install global shortcuts. First chords use the same
modified ASCII syntax as the leader; prefix tails use normal Emacs keys.

Native code catches registered first chords and notifies Emacs through an event
pipe. It holds fast follow-up keys until Lisp is ready, and Lisp reads the keymap and runs the
command. Ordinary terminal input and output stay native; there is no polling timer
or terminal redraw through Lisp.

The terminal uses the pinned [GhosttyTerminal Swift wrapper](https://github.com/Lakr233/libghostty-spm/tree/1.6.20260909)
and its Ghostty build. Themes come from the wrapper's bundled catalog; standalone
Ghostty preferences are not loaded. Ghostty's
app-level window/tab commands are not implemented here. The Emacs buffer contains
instructions, not live terminal text, so ordinary Emacs search and movement do not
operate on the terminal. The native view still shares Emacs's main thread for
input and presentation; this is not a guarantee of latency parity during Emacs GC
or long-running Lisp.

`(portal--terminal-state)` (optionally with a native session ID) reports the actual native surface, grid, bounds, focus
and title. `(portal--terminal-text)` selects all native scrollback and returns its
text for inspection; it leaves that selection active. Neither is polled during
normal use. Restart Emacs after rebuilding a module it has already loaded.

The graphical terminal tests exercise a real shell, alternate-screen output,
native keyboard and clipboard input, focus return, resizing, hidden-session
continuity, shell termination, and editing/saving a file in Vim. They also exercise
rapid native prefix sequences, multiple sessions and splits, live prefix/map
customization, runtime binding registration/unbinding, quick-only shortcuts,
shifted characters, literal prefix bytes, cancellation, and minibuffer focus.
Batch binding tests run with `ctest --test-dir build -R terminal-bindings`.
Build the test-only AppKit event injector (no Accessibility permission required):

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
  -I "$(cat build/emacs-include.txt)" test/terminal-input.m \
  -framework AppKit -framework WebKit \
  -o build/test-terminal-input.dylib
emacs -Q --module-assertions -l "$PWD/portal.el" \
  --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"))' \
  -l "$PWD/test/portal-terminal-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-terminal-")'
```

`./build.sh` runs the `dev` CMake configure and build presets. For development,
configure once before opening native source files; this generates editor metadata
without compiling the module:

```sh
cmake --preset dev
cmake --build --preset dev
```

CMake locates Emacs, builds the Bun host, and invokes the native Swift package.
`native/Package.swift` defines one Swift target containing the host, web, terminal,
and Emacs bridge code, plus the small required C entry point. There are no separate
feature libraries or plugin builds. Configuration writes the discovered header
path to `build/emacs-include.txt`, which the package also reads for editor support.

Use SourceKit-LSP with Eglot for Swift and the C bridge, with `native/` as its
SwiftPM project root. Xcode provides the server. Reconnect Eglot after switching
from the former CMake compilation database. No project-specific header paths
belong in your Emacs configuration. Reconfigure after changing Emacs or SDKs.

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
`M-x eglot-reconnect`. The type check also generates the browser assets.
CMake installs the locked dependencies, bundles the editor and fonts, and
compiles the standalone host. Runtime users need no npm packages.

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
`portal-hello`, `portal-preview-markdown`, or drawing buffer starts one shared child process
asynchronously, waits for its readiness message, then loads the requested page
in the native webview. Opening external
URLs does not require the server.

- The host binds to `127.0.0.1` on an OS-assigned port. Each Emacs process owns
  its own host; all its panes reuse that host.
- Each host generates a fresh access token and sends it through the readiness
  pipe. URLs have the form `http://127.0.0.1:PORT/TOKEN/hello` or
  `http://127.0.0.1:PORT/TOKEN/markdown?path=ENCODED_ABSOLUTE_PATH`. The host
  validates the token and Host header; responses suppress outgoing referrers.
- Closing or hiding a view keeps the server running. `M-x portal-start-server`
  can prewarm it explicitly; `M-x portal-stop-server` stops it, and
  `M-x portal-restart-server` starts a replacement and reloads active hosted views.
- Startup is bounded by `portal-server-start-timeout` (five seconds by default).
  Failures leave diagnostics in `*portal-server*`; run `portal-hello` to retry.
  There is no automatic restart loop.
- Emacs supervises the child through a pipe. stdout carries a versioned JSON
  readiness line; stderr carries diagnostics. Closing stdin requests shutdown,
  including when Emacs exits unexpectedly. Normal shutdown also handles OS
  termination signals and has a forced-termination fallback.
- `portal-server-program` selects the standalone executable. At runtime it is
  launched directly, without a shell or any lookup of Bun on PATH. Runtime
  loading of `.env` and `bunfig.toml` is disabled in the compiled binary.

Control protocol version 2 announces readiness, port, and access token; it is
not yet a general UI RPC API. Rebuilding publishes the host executable atomically. An already
running host keeps its old code until `portal-restart-server` is called.

## Markdown previews

Run `M-x portal-preview-markdown` in a Markdown file buffer to preview it
directly. Markdown modes and common file extensions are recognised. From other
buffers, the command prompts for a saved local file. Use `C-u M-x
portal-preview-markdown` to choose another file explicitly.
The Bun server reads the file, renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
and returns a complete HTML page with embedded light/dark CSS. Rendering happens
in memory, without temporary HTML files or additional npm dependencies.

Headings, lists, fenced code, tables, strikethrough, task lists, and heading
anchors are supported. Press Escape or `C-g` to return focus to Emacs, then
`g` (`portal-refresh`) to reread the file from disk. Refresh also restarts a
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

- Each pane displaying `*portal-web*` gets an independent webview starting at the
  requested URL. Cookies use WebKit's default data store, but navigation, DOM,
  scroll position, and form state are independent between panes.
- Resizing a pane preserves its webview. Hiding or closing a pane releases its
  webview; showing the buffer again loads the originally requested URL anew.
- Opening another URL replaces the current Portal content. There is one active
  native buffer and one host frame, as in the original demo.
- Escape and `C-g` are reserved for returning to Emacs while a page has focus.
  Clicking a webview does not change Emacs's selected pane; use Emacs window
  navigation after returning focus.
- This is a URL viewer, without browser chrome, history commands, downloads,
  popup windows, or JavaScript dialog UI. Failed loads can be inspected through
  `:error` in `(portal--native-views)`.

A shared, persistent browser session mirrored across splits would require a
separate design; this first version shares the requested URL only.

## Green demo behaviour

Buffers hold content; Emacs windows are the panes displaying that content and
have coordinates. Portal creates one native view per pane showing the green
buffer within the frame where `portal-show` was invoked.

- Splitting shows a green square in both panes. Each square stays 32×32 points
  and centered in its pane's text area as the panes or macOS window resize.
- Changing focus leaves all views in place. Switching one pane to another buffer,
  or closing it, removes only that pane's native view.
- Switching the buffer out of every pane releases all views while retaining the
  shared content. Showing the buffer again creates the required views automatically.
- `q`, `portal-hide`, killing the buffer, changing its major mode, or deleting the
  host frame releases all views and shared content, and stops tracking.
- Failed attachment or layout updates remove all views. Run `portal-show` to retry.

Moving the whole macOS window needs no extra positioning code because the native
views are already its children.

Splitting normally shows the same buffer in both panes, including with Evil's
`C-w v`. Both panes now render green. Switch either pane to another buffer to work
with text beside the remaining view.

## Implementation

| File | Responsibility |
| --- | --- |
| `portal-native.el` | Shared module loading and native frame identification |
| `portal.el` | Web/demo buffers, pane tracking, geometry, and lifecycle hooks |
| `portal-terminal.el` | Terminal buffers, configurable prefix commands, geometry, and lifecycle |
| `portal-terminal-bindings.el` | Runtime native keymaps, validation, and registration |
| `portal-terminal-quick.el` | Project scratch terminals, bottom panel, and callable toggle command |
| `portal-server.el` | Lazy shared-process startup, readiness, logs, and shutdown |
| `host/server.ts` | Local HTTP server and parent-process lifetime |
| `host/hello.html` | Embedded Hello World page, styles, and JavaScript |
| `host/markdown.ts` | Local Markdown reads, HTML rendering, and error pages |
| `host/markdown.css` | Embedded Markdown typography and light/dark colours |
| `native/Module.swift` | Emacs function registration, argument conversion, and errors |
| `native/NativeHost.swift` | Shared frame attachment, geometry, focus return, and keyboard routing |
| `native/WebView.swift` | WebKit/demo views, navigation, and inspection |
| `native/Terminal.swift` | Ghostty sessions, terminal input policy, and prefix buffering |
| `native/Emacs/` | Required C entry point, Emacs header import, and ABI size checks |
| `native/Package.swift` | One native library and pinned Ghostty dependency |

These are ordinary source boundaries within one native module. A small
`NativeSurface` protocol lets each feature expose its view and keyboard handler.
`NativeHost` knows neither WebKit nor Ghostty: it attaches views to the correct
frame, remembers the original Emacs responder, and uses one event monitor to
route keys to the focused surface or a pending terminal prefix. A key released
after focus changes is not delivered to the newly focused feature.

Features own their state and cleanup. Removing a web view does not destroy a
terminal, and closing a terminal does not remove web views. Hidden web views are
released and recreated when shown; hidden terminals stay attached so their PTYs
continue running. The Emacs bridge converts arguments and registers both APIs.

For web/demo views, the Lisp `window-state-change-functions` hook measures `window-inside-pixel-edges`
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

For diagnostics, `(portal--native-views)` reports the actual AppKit views as
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
All 32 tests in the combined graphical suite pass. They include the web/demo and terminal tests, plus
coexistence checks for both startup orders, real keyboard handoff, WebKit key-up
delivery alongside terminals, independent cleanup, and shared-frame deletion.
They do not assert Lisp caches, hook names, or implementation call counts.

Build the test-only event injector shown above, then run the suite in a disposable
graphical Emacs. Batch Emacs has no native window and
cannot exercise these behaviours:

```sh
emacs -Q --module-assertions -l "$PWD/portal.el" \
  --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"))' \
  -l "$PWD/test/portal-tests.el" \
  -l "$PWD/test/portal-terminal-tests.el" \
  -l "$PWD/test/portal-integration-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-")'
```

The Lisp tests use only Emacs's built-in libraries. A standalone AppKit check
also verifies Escape, `C-g`, and focused-view removal return focus to the editor:

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors \
  native/NativeHost.swift native/WebView.swift test/native-focus.swift \
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

The web/demo feature supports one active buffer and any number of pane views
within one host frame. Terminals support multiple independent buffers and frames,
with each terminal bound to its creating frame. Automatic migration of a terminal
to another frame is not implemented.
To choose a different host frame, invoke `portal-open-url` (or `portal-show`
for the green demo) from that frame again.

The buffer remains an ordinary Emacs buffer. This does not add native widgets to
Emacs's text rendering system. The module runs inside Emacs, so use a separate
`emacs -Q` process while experimenting.

Implementation files are licensed under [GPL-3.0-or-later](LICENSE).
