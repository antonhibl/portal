# Portal: native views in Emacs

Native WebKit pages and Ghostty terminals inside macOS Emacs panes, backed by
one Swift dynamic module. A bundled Bun server hosts Hello World, local
Markdown previews, a task browser and an offline Excalidraw editor. Each buffer has one native view,
which follows its buffer across splits, resizing and frames; hidden pages and
terminal sessions keep running.

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
select another local file, and `M-x portal-tasks` to browse the project's
[tasks](#task-browser).
To distribute this layout, include all `portal*.el` files at the package root,
`build/portal-host`, and the complete `build/portal.bundle`;
the host needs no adjacent web assets. Keep the bundle intact, including its terminfo
and shell integration resources. Restart Emacs when upgrading from the former
separate web and terminal modules, or after rebuilding a loaded native module.

Run `M-x portal-preview-html` in a `.html` or `.htm` file buffer to open its
saved contents in a web view, including relative scripts, styles,
and images from its directory. From other buffers, it prompts for a local
path or URL. Relative paths use the current buffer's `default-directory`;
`C-u M-x portal-preview-html` always prompts. Unsaved edits are not included.
Previewing the same file again reuses its buffer, such as `*portal: index.html*`,
and reloads it.

`M-x portal-open-url` opens an arbitrary absolute URL in a new buffer each time,
named after the page, such as `*portal: example.com*`.
Both commands accept HTTP, HTTPS, `file:`, `data:`, and `about:` URLs.
To open a local HTML file programmatically:

```elisp
(portal-preview-html "/absolute/path/index.html")
```

In a web buffer, `g` loads the page again and `q` (`quit-window`) hides the
view while the page keeps running. Killing the buffer closes the page.

## Shared keyboard controls

Terminal, Excalidraw, and HTML/Markdown views use `portal-input-prefix`
(default `C-b`). The app receives ordinary keys, including Escape and `C-g`.
The prefix temporarily gives a command to Emacs:

| Keys | Action |
| --- | --- |
| `C-b ?` | Show shared and feature bindings |
| `C-b d` or Command-Escape | Return to Emacs and stay there |
| `C-b o` | Select the next Emacs pane |
| `C-b :` or `C-b M-x` | Run an Emacs command |
| `C-b C-x …`, `C-b C-c …`, `C-b C-h …` | Use your existing Emacs bindings |
| `C-b m …` | Feature commands; existing terminal shortcuts also work directly |
| `C-b C-b` | Send a literal Control-B to the app |
| `C-g` after the prefix | Cancel the prefix |
| `RET` while Emacs owns a Portal buffer | Enter the app |

The prefix has no timeout. Commands finish their minibuffer interaction before
returning to the selected native view; explicit unfocus, errors, and selecting
an ordinary buffer leave Emacs in control. The native toolbar's ownership dot
is hollow when Emacs owns the keyboard, green when the view owns it, blue while
an Emacs prefix is pending, and amber in passthrough. Click the dot to enter or
return to Emacs. No global physical keybinding is installed in ordinary buffers.

The 28 pixel toolbar reserves space above the content. Web pages have back,
forward, find, zoom, and reload; Markdown and HTML previews also have a table of
contents, and Markdown previews an **Open in Emacs** button. Terminals have text
size controls. Excalidraw and quick
terminals have no toolbar. The command that opens a web view chooses its toolbar.
`(setq portal-toolbar nil)` hides toolbars live, and `t` restores them. Colors
follow Emacs faces and update after theme changes.

`portal-zoom-in`, `portal-zoom-out`, `portal-zoom-reset`, `portal-toggle-toc`,
`portal-find`, `portal-web-back` (`l`), and `portal-web-forward` (`r`) use the
same native state as the buttons. Terminal equivalents are
`portal-terminal-text-size-increase`, `portal-terminal-text-size-decrease`, and
`portal-terminal-text-size-reset`. Find opens a field inside the strip; Return
and Shift-Return navigate matches, and Escape closes it. State survives hiding
and redisplaying a pane; reload preserves zoom and the TOC. Killing the buffer
releases it.

Use `M-x portal-input-passthrough` to release even the prefix and optional
native shortcuts to an app. Command-Escape leaves passthrough and returns to
Emacs; the next entry uses the normal prefix again. This does not bypass
macOS shortcuts or the embedded app's own input handling.

Set `(setq portal-input-prefix "C-a")` to change the prefix for all views.
`portal-terminal-prefix` remains an alias, so existing configuration works.
Customize shared operations in `portal-command-map`; they take precedence over
feature shortcuts. The native first chord accepts modified ASCII, with Meta =
Option and Super = Command. The rest of a sequence uses normal Emacs keys.

Click inside a page or press `RET` to interact. A click that enters a view also
selects the Emacs pane showing it, so the selected pane and the keyboard always
agree. After returning to Emacs, `q` hides the web view and `g` loads its page
again. The mode line and minibuffer remain available.

Restart Emacs after rebuilding the native module to try these controls.

## Local Excalidraw drawings

Run `M-x portal-excalidraw` for a new drawing, then `C-b C-x C-s` to choose its
filename and save. Open existing `.excalidraw` files normally with `C-x C-f`
or Dired; they enter `portal-excalidraw-mode` automatically. A prefix argument
to `portal-excalidraw` prompts for an existing or new file.

- Draw, type, paste text/images, and use the normal Excalidraw editing tools.
- `C-b C-x C-s`, Command-S, and the drawing's **Save** button save through Emacs.
  Bare `C-x` belongs to the app while the webview has focus. In Emacs input,
  the usual `C-x C-s` still works. `C-b m s` also saves; `C-b m r` reopens.
- Command-Escape returns keyboard focus to Emacs; `RET` re-enters the drawing.
  Bare Escape remains available for drawing/text editing.
- Each drawing buffer has one web view running the Excalidraw hosted app. It
  opens at once and loads the drawing when the app host is ready. Switching
  buffers hides it without losing its contents, selection, or undo history. In
  splits, the view follows the selected window showing that buffer. Independent
  drawings can be displayed together.
- Drawings use standard Excalidraw JSON, including embedded image data. Emacs owns
  file saving, modified indicators, backup settings, auto-save, and overwrite
  checks. Untitled modified drawings also participate in save/close prompts.
- `M-x revert-buffer` reloads the file from disk. `C-c C-r` reopens a failed
  view using the buffered drawing, preserving unsaved buffered changes but
  resetting undo history. Use it after restarting the app host if more
  Excalidraw assets need loading. A stopped host does not unload an already
  open drawing.

Excalidraw 0.18.1, React, CSS, lazy modules and fonts are bundled into
`portal-host`. The build installs pinned npm dependencies with Bun; runtime use
needs no npm packages or internet connection. The page blocks external asset
requests, CDN font fallbacks and remote embeds. Document persistence uses neither
localStorage nor IndexedDB. The current integration focuses on local documents;
cloud collaboration, online library installation, persistent personal libraries,
and image export are not integrated.

Restart Emacs after rebuilding the native module. See
[the bridge](docs/editor-bridge.md) for implementation and tests.

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

Each project has one quick shell, which you can summon from any Emacs frame.
The panel and its remembered height belong to each frame, but summoning the
shell in another frame brings the same shell into that frame's panel. A new
shell starts at the `project.el` root of the current file or Dired buffer. Help
and other auxiliary buffers use the most recently selected file/Dired directory
in that frame.
Outside a project, the file's directory is used; with no editing context,
`portal-terminal-quick-directory` defaults to home. Remote contexts are rejected.

Dismissal only hides the panel: the shell, current directory, environment,
partially typed input, scrollback, and foreground programs remain intact.
Reopening never sends `cd` or starts a replacement shell. A command such as
`npm run dev` keeps running while hidden; reopen and use `C-c` to interrupt it.
Switching files or projects does not automatically change an already visible
panel. Dismiss it, then summon again to select the new project's quick shell.

Quick terminals inherit the shared controls and add these feature shortcuts:

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
Deleting a frame only hides its panel's shell. Quitting Emacs ends the session;
this does not provide persistence across Emacs restarts. A shell that exits is
not silently restarted: use reset when you want a new one.

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
emacs -Q -L "$PWD" -l "$PWD/portal.el" --eval '(portal-terminal)'
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
- Hidden buffers keep their shells running: `quit-window` or switching buffers
  hides the terminal, and showing the buffer again brings the same shell back.
  Deleting the frame showing a terminal also only hides it. Killing a terminal
  buffer or running `portal-terminal-close` in it ends that shell.
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
| `:` | Run `M-x`, then resume the selected app |
| `?` | Show the current bindings, including customizations |
| repeated prefix | Send the actual prefix keystroke to the shell |

These are Emacs operations: terminal buffers stand in for tmux windows and Emacs
windows stand in for panes. There are no tmux session servers, saved per-terminal
pane layouts, or tmux copy mode. Each terminal buffer has one Portal view,
which appears in the selected pane showing the buffer; other panes showing the
same buffer display only its text ([ADR 0001](docs/adr/0001-one-portal-view-per-buffer.md)).
Terminals belong to no frame: show a terminal buffer in another frame and its
view moves there, with the same shell and scrollback. Selection, numbering and
cycling cover every terminal. Different terminal buffers can display and run
simultaneously.

Configure in Lisp after loading `portal.el` (changes apply to running terminals):

```elisp
(setq portal-input-prefix "C-a") ; default: "C-b"; applies to every Portal view
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

Native code catches registered first chords and notifies Emacs through the
notification pipe that every Portal view shares
([details](docs/terminal-input-bridge.md#the-notification-pipe)). It holds fast follow-up keys until Lisp is ready, and Lisp reads the keymap and runs the
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

`(portal--inspect (portal-view-target))` reports the selected terminal's actual
native surface, grid, bounds, focus and title. `(portal--terminal-text TARGET)`
selects all native scrollback and returns its text for inspection; it leaves
that selection active. Neither is polled during normal use. Restart Emacs after
rebuilding a module it has already loaded.

The graphical terminal tests exercise a real shell, alternate-screen output,
native keyboard and clipboard input, focus return, resizing, hidden-session
continuity, shell termination, and editing/saving a file in Vim. They also exercise
rapid native prefix sequences, multiple sessions and splits, live prefix/map
customization, runtime binding registration/unbinding, quick-only shortcuts,
shifted characters, literal prefix bytes, cancellation, and minibuffer focus.
Batch binding tests run with `ctest --test-dir build -R terminal-bindings`, and
batch tests of the view lifecycle (opening, splits, selection, `quit-window`,
showing the buffer elsewhere, moving between frames, deleting a frame and
killing the buffer) run with `ctest --test-dir build -R view`. Batch Emacs has
one frame, so these tests open a second, suspended terminal frame on a
pseudo-terminal.
Build the test-only AppKit event injector (no Accessibility permission required):

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
  -I "$(cat build/emacs-include.txt)" test/terminal-input.m \
  -framework AppKit -framework WebKit \
  -o build/test-terminal-input.dylib
emacs -Q --module-assertions -L "$PWD" -l "$PWD/portal.el" \
  --eval "(module-load \"$PWD/build/test-terminal-input.dylib\")" \
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
checks:

```sh
bun install --cwd host --frozen-lockfile
bun run --cwd host check
bun run --cwd host typecheck
```

Biome checks host formatting, imports, and lint rules using `biome.json`.
Indentation uses tabs. Run `bun run --cwd host format` to format the host sources.
Generated assets and dependencies are excluded through Git's ignore rules.

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
`portal-hello`, `portal-preview-markdown`, `portal-tasks`, or drawing buffer starts one shared
child process asynchronously. Hello, the Markdown preview and the task browser are hosted apps: each opens its
web view at once, at `about:blank`, and loads its page as soon as the host sends
its readiness message. Opening external URLs does not require the server.

- The host binds to `127.0.0.1` on an OS-assigned port. Each Emacs process owns
  its own host; all its web views reuse that host.
- Each host generates a fresh access token and sends it through the readiness
  pipe. URLs have the form `http://127.0.0.1:PORT/TOKEN/hello` or
  `http://127.0.0.1:PORT/TOKEN/markdown?path=ENCODED_ABSOLUTE_PATH`, and task
  pages `http://127.0.0.1:PORT/TOKEN/tasks?root=ENCODED_ABSOLUTE_PATH`. The host
  validates the token and Host header; responses suppress outgoing referrers.
- Closing or hiding a view keeps the server running. `M-x portal-start-server`
  can prewarm it explicitly; `M-x portal-stop-server` stops it, and
  `M-x portal-restart-server` starts a replacement. Hosted apps that have
  already loaded keep their page while the host stops or restarts; press `g` in
  one's buffer to reload it from the host, starting the host first if needed.
- Startup is bounded by `portal-server-start-timeout` (five seconds by default).
  Failures leave diagnostics in `*portal-server*`, and a hosted app that was
  waiting stays at `about:blank`; press `g` in its buffer, or run
  `portal-hello`, to retry.
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
portal-preview-markdown` to choose another file explicitly. Each file has one
preview buffer, such as `*portal: notes.md*`; previewing it again reuses it.
The Bun server reads the file, renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
and returns a complete HTML page with embedded light/dark CSS. Rendering happens
in memory, without temporary HTML files or additional npm dependencies.

Headings, lists, fenced code, tables, strikethrough, task lists, and heading
anchors are supported. Press `C-b d` or Command-Escape to return to Emacs, then
`g` (`portal-web-reload`) to reread the file on screen from disk. `g` also starts a
stopped host. A loaded preview stays as it is while the host stops or restarts.
Missing or unreadable files produce an error page.

The preview follows links like a browser:

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| A local Markdown file, such as `architecture.md` or `other.md#heading` | Opens in the same preview, at the heading if there is one |
| Any other local file, such as `src/server.ts#L42` | Opens in Emacs in another pane, at line 42 for `#L42` or `#L42-L50` |
| A local image or folder | Opens in Emacs, in `image-mode` or Dired |
| `https://…` and other sites | Opens in the default browser |

Relative links resolve from the folder of the document on screen, and local
absolute paths and `file:` URLs work the same way. After following a Markdown
link, the buffer is renamed after the new file, `g` rereads it, and
`portal-preview-markdown` on that file finds this preview. Back and Forward in
the toolbar, or `l` and `r` in the preview buffer, move through the documents
this preview has shown and restore their reading positions. Following a new
link after going back discards the old forward pages, as in a browser; opening
a file in Emacs or a website does not.

Opening a file in Emacs is one click, with no need to leave the preview first.
Emacs selects the file's pane and takes the keyboard, ready for editing, while
the preview stays in its own pane at the same reading position. The file goes
to another pane, reusing one or splitting the frame. Rules in
`display-buffer-alist` still decide: if one puts the file in the preview's own
pane, the hidden preview keeps its page. **Open in Emacs** in the toolbar, or
`M-x portal-preview-open-in-emacs`, does the same for the Markdown file on
screen, including after Back or Forward.

To go back to reading, click the preview, which selects its pane and gives it
the keyboard, or select its pane and press `RET`. From anywhere else,
`M-x portal-preview-return` selects the preview that the frame last opened a
file from, showing it again if it was hidden, and gives it the keyboard. The
page is not reloaded. There is no global key for it; bind one if you like.

This version previews saved contents only, with no automatic refresh. It does
not show relative inline images, or add syntax highlighting, Mermaid, or math
rendering. HTTP(S) images and links can use their absolute URLs. Going back past
an app host restart shows a "Not found" page; `g` reloads from the running host.
Raw HTML is displayed as text, and a page-specific Content Security Policy
blocks scripts. Bun currently marks its Markdown API unstable; it is tested
here with the Bun version listed above.

## Task browser

`M-x portal-tasks`, or `(portal-tasks)` from Lisp, lists the current project's
saved Markdown tasks in a web view with the navigation toolbar. The view opens
at once and loads the list when the app host is ready, starting the host first
if needed. Click a task to read it in the same view; the **Tasks** link returns
to the list. Emacs stays the editor: the task browser reads files and never
writes, moves or deletes them.

### Choosing the task root

`portal-tasks-directory` names the task root. It defaults to `tasks/`, which is
relative to the `project.el` root; an absolute directory is used as it is. Set
it for one project in that project's `.dir-locals.el`:

```elisp
((nil . ((portal-tasks-directory . "docs/tasks/"))))
```

The project is the one being edited. From a terminal, a web view or another
auxiliary buffer, it is the project of the file or Dired buffer the frame
selected last, as for [quick terminals](#quick-project-terminal), and that
project's directory-local settings apply. Outside a project, the command asks
for a task folder, and `C-u M-x portal-tasks` chooses any local folder. Remote
folders are rejected, and symbolic links in the path are resolved.

Each task root has one buffer, such as `*portal: tasks ~/src/app/tasks*`.
Running the command again shows it at its current page; another project gets
its own. A missing task folder shows how to start one, without creating it. A
folder with no tasks shows "No tasks", and one with only completed tasks offers
**Show completed**.

### Writing tasks

A task is a single Markdown file, or a folder holding its document and
attachments. Both work the same:

```text
tasks/
  fix-search.md                 # a task
  markdown-navigation/          # a task with attachments
    content.md
    mockup.png
    implementation-notes.md     # a supporting document, not a task
  assets/
    search.png                  # an attachment of fix-search.md
  README.md                     # a document, since it has no status
```

Only `.md` files directly in the task root, and a file named exactly
`content.md` directly in one of its folders, can be tasks. Deeper folders,
other files and symbolic links are supporting material. A document is a task
when its YAML front matter has a `status`:

```markdown
---
status: todo
---

# Fix search

Searching with spaces returns no results.
```

`status` is `todo` or `done`, exactly. Completed tasks leave the list until you
turn on **Show completed**, and their pages stay reachable. Documents without
front matter, or without a `status`, are not listed. Front matter that is not
closed or not a YAML mapping, an invalid status or title, and unreadable files
are listed under **Problems** with their paths, and the other tasks still show.

A task's title is its front matter `title`, or else its first level-one
heading outside code fences, or else its ID. The ID is the file name without
`.md`, or the folder name, so moving `fix-search.md` to
`fix-search/content.md` keeps the task's ID and address. Renaming it changes
both. If both forms exist, neither is listed: **Problems** names both files,
and the task's page shows the conflict until one is removed. The list is
ordered by ID.

To complete a task, edit `status: todo` to `status: done` in Emacs, save, and
press `g` in the task view. `g` rereads the page on screen from the saved files,
including after an app host restart. There is no automatic refresh.

### Links and attachments

Relative links and images in a task resolve from its attachment folder: the
task root for a single-file task, or the task's own folder.

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| Another task's file, such as `../fix-search.md#notes` | That task's page in the same view, keeping the filter |
| An inline image, such as `![Search](assets/search.png)` | Shown in the page |
| Any other file in the attachment folder | Opens in Emacs in another pane, as from a Markdown preview; `#L42` goes to line 42 |
| A missing file, or one outside the attachment folder | Crossed out, with the reason as its tooltip |
| `https://…` and other sites | Opens in the default browser |

Mock-up HTML and code open in Emacs as source; the task browser never runs them.
Opening a file keeps the task page and its history, and
`M-x portal-preview-return` comes back to it. Back and Forward in the toolbar,
or `l` and `r`, move between list and task pages, keeping the filter and reading
position. Raw HTML in a task is shown as text, and the host serves only image
files from the attachment folder.

## Web view behaviour

A web view is a Portal view of the web kind. Remote pages use
[WebKit's URL request loading](https://developer.apple.com/documentation/webkit/wkwebview);
local pages use `loadFileURL` with read access to the containing directory so
relative scripts, styles, and images can load. JavaScript is enabled by default.

- Each web buffer has one web view, which appears in the selected pane showing
  the buffer ([ADR 0001](docs/adr/0001-one-portal-view-per-buffer.md)). Other
  panes showing the same buffer display only its text. To see two pages side by
  side, open two buffers.
- Web views belong to no frame: show the buffer in another frame and its page
  moves there. Deleting a frame only hides its web views.
- Hiding the view, with `q` or by showing another buffer, keeps the page loaded,
  including its navigation, DOM, scroll position, and form state. Cookies use
  WebKit's default data store, except in hosted apps, which keep no cookies or
  storage between Emacs sessions.
- A hosted app's page never leaves the app host. When it would navigate
  anywhere else, the navigation is cancelled and the URL opens in the default
  browser. Clicking a link to a local `file:` URL gives Emacs the keyboard and
  sends a `follow` message with the URL over the [bridge](docs/editor-bridge.md)
  instead: WebKit never lets an app host page load a local file, so a script
  in its own content world, out of the page's reach, catches such clicks. Each
  page a hosted app commits, including after Back and Forward, sends a `page`
  message. URLs go over the bridge because a long path would not fit in a
  notification record.
- The shared Portal prefix and Command-Escape work while a page has focus.
  Clicking a view to enter it sends a `select TARGET` record, and Emacs selects
  the pane showing it.
- This is a URL viewer, without an address bar, downloads, popup windows, or
  JavaScript dialog UI. Failed loads can be inspected through `:error` in
  `(portal--inspect (portal-view-target))`.

Lisp can give any buffer a web view: `(portal-web-open URL TOOLBAR)` opens one
for the current buffer and loads URL. TOOLBAR is `"navigation"` (back, forward,
find, zoom and reload), `"contents"` (those and a table of contents),
`"markdown"` (those, a table of contents and, for a hosted app, Open in Emacs)
or `"none"`.
Loading the page a view shows again, ignoring its fragment, reloads it without
a new history entry.
`(portal-web-open-hosted PATH TOOLBAR)` opens a hosted app instead: the view
opens at once, at `about:blank`, and loads PATH, such as `"/hello"`, from the
app host as soon as the host is ready, starting the host if needed.
A hosted app and its buffer exchange JSON objects over the
[bridge](docs/editor-bridge.md): `(portal-web-send PLIST)` sends one to the
app, and the buffer-local `portal-web-bridge-function` is called with each one
the app sends, in order. Other web views have no bridge.

## Implementation

| File | Responsibility |
| --- | --- |
| `portal.el` | The package root: loads every feature |
| `portal-view.el` | Module loading, the shared Portal view lifecycle (open, placement, hiding and closing), and the notification pipe |
| `portal-web.el` | Web buffers, URL and HTML previews, Hello and Markdown previews on the app host, and the bridge |
| `portal-excalidraw.el` | Excalidraw drawing buffers, a hosted-app client of the bridge |
| `portal-input.el` | Shared prefix commands, Emacs gateways, focus policy, and input notifications |
| `portal-terminal.el` | Terminal buffers and tmux shortcuts |
| `portal-terminal-bindings.el` | Runtime native keymaps, validation, and registration |
| `portal-terminal-quick.el` | Project scratch terminals, bottom panel, and callable toggle command |
| `portal-server.el` | Lazy shared-process startup, readiness, logs, and shutdown |
| `host/server.ts` | Local HTTP server and parent-process lifetime |
| `host/hello.html` | Embedded Hello World page, styles, and JavaScript |
| `host/markdown.ts` | Local Markdown reads, HTML rendering, and error pages |
| `host/markdown.css` | Embedded Markdown typography and light/dark colours |
| `native/Module.swift` | Emacs function registration, argument conversion, and errors |
| `native/NativeHost.swift` | Shared frame attachment, geometry, focus return, and keyboard routing |
| `native/WebView.swift` | The web view kind: WebKit pages, navigation, inspection, and hosted apps' bridge |
| `native/NativeInput.swift` | Shared native prefix capture, passthrough, and literal input |
| `native/Views.swift` | The view registry, keyed by native target, and the view kind protocol |
| `native/Terminal.swift` | The terminal view kind: Ghostty sessions and terminal input |
| `portal-toolbar.el` | Toolbar option, face colors, and commands reading native state |
| `native/Toolbar.swift` | Native strip, controls, ownership dot, and view container |
| `native/WebToolbar.swift` | Web zoom, find, navigation, and isolated page TOC support |
| `native/Emacs/` | Required C entry point, Emacs header import, and ABI size checks |
| `native/Package.swift` | One native library and pinned Ghostty dependency |

These are ordinary source boundaries within one native module. A small
`NativeSurface` protocol lets each feature expose its view and keyboard handler.
`NativeHost` knows neither WebKit nor Ghostty: it attaches views to the correct
frame, remembers the original Emacs responder, and uses one event monitor to
route keys to the focused surface or a pending Portal command. A key released
after focus changes is not delivered to the newly focused feature.

Features own their state and cleanup. Closing a web view does not destroy a
terminal, and closing a terminal does not remove web views. The Emacs bridge
converts arguments and registers every API.

Terminal and web views run on the shared Portal view lifecycle
([ADR 0002](docs/adr/0002-portal-view-native-seam.md)). `portal-view.el` makes
every native lifecycle call: `portal--open KIND OPTIONS` returns a target such as
`terminal:3` or `web:4`, and `portal--place`, `portal--hide`, `portal--close` and
`portal--inspect` take that target. In Swift, `Views` keeps one registry keyed by
target; each view kind implements the small `PortalView` protocol, and IDs are
never reused. On each window change, `portal-view.el` picks one window per view,
in any frame: the selected window if it shows the buffer, then the view's current
window, then any other window showing the buffer. With none, the view is hidden.
A geometry cache means nothing crosses the seam when nothing moved. Each placement
renames the frame briefly so Swift can find its native window; nothing about
frames is cached. Placing a view in another frame moves it there within the one
call. Swift keeps hidden views in an offscreen parking window that is never
shown. New views start there, so a view is always in some window and its session
or page keeps running. Deleting a frame hides its views, and the next sync places each
one wherever its buffer is still shown. Killing the buffer or changing its major
mode closes the view. Operations that belong to one kind have their own exports,
such as `portal--web-load TARGET URL`. Batch
tests replace the native module with `test/portal-fake-native.el`.

The frame-title trick and the geometry cache mean there is no polling timer, and
Swift never retains an Emacs value or environment pointer after a module call
returns. Native navigation callbacks only update Swift state; they never call
back into Lisp.

## Verification

Tested with macOS 27.0, Swift 6.4, and Emacs 31.1 with `--module-assertions`.
C and Swift compile with warnings treated as errors; Lisp byte compilation also
passes without warnings.

Batch tests of web buffers run with `ctest --test-dir build -R web`. They cover
`portal-open-url` opening a new buffer each time, the view following the selected
pane after a split, `portal-preview-html` reusing its buffer, `g`, `q` and
killing the buffer, the toolbar each command chooses, and Hello and the Markdown
preview opening at once and loading once a simulated app host is ready. Markdown
tests feed the fake native adapter `page`, `follow` and `edit` bridge messages
and `select` records. They check document identity, handoff placement with and without
`display-buffer-alist` rules, line fragments, images and folders, failed
handoffs, paths longer than a record, Open in Emacs, and return tracking across
buffers, previews and frames. One test
opens a Markdown preview with the real app host, which `ctest` passes through
`PORTAL_TEST_HOST`. It checks that the preview loads once the host is ready,
stays as it is while the host stops and restarts, and that `g` reloads it.
Batch task browser tests run with `ctest --test-dir build -R tasks`. They cover
project-relative, absolute and directory-local task roots, auxiliary buffers,
explicit and prompted roots, remote roots, one buffer per root, `g` and restart
recovery of the page on screen, and attachment handoff. One test runs the real
app host.

The graphical web tests wait for real WebKit page loads. They verify JavaScript
execution, relative local assets, a page staying loaded while hidden, repeated
loading and native URL validation.
The Markdown graphical tests use the real app host and real mouse clicks. They
check that Back and Forward restore reading positions, that a source link hands
the keyboard to Emacs in one click, that clicking the preview selects its pane,
that `portal-preview-return` and `RET` return without reloading, and that
Command-Escape and `C-b d` still return to Emacs.
The task browser graphical tests check real list and task pages: Back and
Forward restore the filter and reading positions, `g` rereads the saved file,
and `g` loads the page on screen after an app host restart. They also check
task links, inline images in both layouts, and one-click handoff of
attachments, with mock-up HTML opening as source.
The combined graphical suite includes web, terminal, Excalidraw, Markdown, and
shared input tests, plus
coexistence checks for both startup orders, real keyboard handoff, WebKit key-up
delivery alongside terminals, independent cleanup, and shared-frame deletion.
They do not assert Lisp caches, hook names, or implementation call counts.

Build the test-only event injector shown above, then run the suite in a disposable
graphical Emacs. Batch Emacs has no native window and
cannot exercise these behaviours:

```sh
emacs -Q --module-assertions -L "$PWD" -l "$PWD/portal.el" \
  --eval "(module-load \"$PWD/build/test-terminal-input.dylib\")" \
  -l "$PWD/test/portal-tests.el" \
  -l "$PWD/test/portal-terminal-tests.el" \
  -l "$PWD/test/portal-integration-tests.el" \
  -l "$PWD/test/portal-excalidraw-gui-tests.el" \
  -l "$PWD/test/portal-input-gui-tests.el" \
  -l "$PWD/test/portal-toolbar-gui-tests.el" \
  -l "$PWD/test/portal-markdown-gui-tests.el" \
  -l "$PWD/test/portal-tasks-gui-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-")'
```

The Lisp tests use only Emacs's built-in libraries. A standalone AppKit check
also verifies guest Escape/`C-g` retain focus, while Command-Escape and
focused-view removal return focus to the editor:

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors \
  native/NativeHost.swift native/NativeInput.swift native/NativeEventChannel.swift \
  native/Views.swift native/Toolbar.swift native/WebToolbar.swift native/WebView.swift \
  test/native-terminal-stub.swift test/native-focus.swift \
  -framework AppKit -framework WebKit -o build/check-focus
build/check-focus
```

The checks open web views through the same `Views` registry as Emacs. They also
check that a hosted web view keeps no data between sessions, that a page
outside the app host goes to the default browser while the app stays, that
only a hosted app's main frame can use the bridge, and that a hosted app
reports each committed page over it. A click on it sends `select`, and a click
on a local link, even one longer than a record, returns the keyboard to Emacs
and sends `follow` over the bridge. A full notification pipe delays records without losing or
reordering them.
`test/native-terminal-stub.swift` stands in for the terminal kind, so they build
without Ghostty.

Replace `test/native-focus.swift` and `build/check-focus` with
`test/native-toolbar.swift` and `build/check-toolbar` to check toolbar layout,
focus-preserving buttons, back and forward in previews, zoom limits, TOC, find,
retained state, and a Markdown preview's Open in Emacs.

The compiled-host integration tests run without a graphical display:

```sh
./build.sh
ctest --test-dir build --output-on-failure
```

They exercise real HTTP requests, a relocated binary with no Bun on PATH,
shared startup, graceful shutdown, restart, crash recovery, startup timeout,
and partial or incompatible readiness messages.
They also check Markdown output, local link rewriting, rereading saved changes,
invalid paths, access-token and Host validation, and non-executable raw HTML.
Task browser tests use real folders: shallow discovery of both layouts,
symbolic links, status and title rules, problems and duplicates, filtering,
ID-preserving conversion, reloads after edits, link rewriting, missing and
invalid roots, and image reads kept inside the attachment folder.

## Scope

Web and terminal views support any number of buffers, each with one view that
follows its buffer into any frame.

The buffer remains an ordinary Emacs buffer. This does not add native widgets to
Emacs's text rendering system. The module runs inside Emacs, so use a separate
`emacs -Q` process while experimenting.

Implementation files are licensed under [GPL-3.0-or-later](LICENSE).
