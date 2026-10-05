# Implementation and native boundaries

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

Portal has one native module: C Emacs bindings and a C core over a Swift macOS
backend. Start at these boundaries rather than treating features as separate
native libraries:

- [`portal-view.el`](../portal-view.el) owns Lisp-side view lifetime, placement and
  notifications; [ADR 0001](adr/0001-one-portal-view-per-buffer.md) and
  [ADR 0002](adr/0002-portal-view-native-seam.md) define one view per buffer and
  the shared lifecycle.
- [`native/Core/include/portal.h`](../native/Core/include/portal.h) is the canonical
  platform interface, including ownership and thread rules. Consult it for the
  current primitives and callbacks, rather than a copied API inventory.
  [ADR 0003](adr/0003-platform-interface-primitives.md) explains why the core owns
  policy and the platform supplies primitives.
- [`native/Backend.swift`](../native/Backend.swift) implements those primitives;
  [`native/Package.swift`](../native/Package.swift) defines the native library and
  pinned Ghostty dependency.
- The [input bridge](terminal-input-bridge.md), [hosted-app bridge](editor-bridge.md),
  [hosted actions](hosted-actions.md) and [launcher panel](launcher-native-panel.md)
  explain their protocols and platform-specific hazards.

## Shared native host

A small `NativeSurface` protocol lets each feature expose its view and keyboard handler.
`NativeHost` knows neither WebKit nor Ghostty: it attaches views to the correct
frame, remembers the original Emacs responder, and uses one event monitor to
route keys to the focused surface or a pending Portal command. A key released
after focus changes is not delivered to the newly focused feature.

Features own their state and cleanup. Closing a web view does not destroy a
terminal, and closing a terminal does not remove web views.

## C bindings and platform interface

The C bindings register every Lisp function and convert its arguments and results.
Lifecycle functions call the core's view registry, input functions its input handoff,
terminal functions its terminal rules, web functions its web rules, and toolbar
functions its toolbars. Portal's rules live in the core, and `portal.h` holds only
the primitives a platform must provide and the calls it makes into the core
([ADR 0003](adr/0003-platform-interface-primitives.md)); `native/Backend.swift`
implements the primitives on macOS. They use plain C types: borrowed UTF-8 arguments
with explicit lengths, results allocated with `malloc` that the core frees, and an
explicit error result that becomes a Lisp `error`. Structured results, such as
`portal--inspect`'s state, cross as JSON, which the bindings parse with
`json-parse-string`. The bindings check that argument strings are valid UTF-8, since
Emacs copies a unibyte string's raw bytes unchanged.

## Notification pipe

The notification pipe was the first of Portal's rules in the core,
`native/Core/channel.c`. `portal--channel` hands it the pipe's descriptor, and
platform code sends records by calling `portal_notify`, which the core
implements ([details](terminal-input-bridge.md#the-notification-pipe)). The
core asks the platform for one primitive in return, a timer that calls it back.
Calls into the core run on the module thread and never reach Emacs.

## View identity and failure rules

Terminal and web views run on the shared Portal view lifecycle
([ADR 0002](adr/0002-portal-view-native-seam.md)). `portal-view.el` makes
every native lifecycle call: `portal--open KIND OPTIONS` returns a target such as
`terminal:3` or `web:4`, and `portal--place`, `portal--hide`, `portal--close` and
`portal--inspect` take that target.

The C core owns every view's identity, in `native/Core/views.c`. It gives out
targets, with IDs that are global across kinds and never reused, even after a
failed open, so a stale target can never reach a newer view. It holds each
platform view from create to destroy, checks the kind of every view that a kind's
operation names, and keeps what every kind shares: whether the view is attached,
and at which edges. The platform supplies five primitives: create a view of a kind,
destroy it, attach it at a rectangle in the frame with a given title, detach it, and
describe what only it knows, such as a page's title or a terminal's grid.
`portal--inspect` combines that description with the core's `:id`, `:kind`,
`:visible` and `:edges`. Closing removes the target before the platform destroys
the view, so the platform destroys it exactly once and nothing it does meanwhile
reaches the view. The core drops a record the platform sends for a target that
names no open view. A primitive that fails changes nothing: a failed open leaves
nothing registered, and a failed placement, such as for a deleted frame, leaves
the view where it was and still open, for Lisp to place again or close.

## Terminal rules and metadata

The core also owns Portal's terminal rules, in `native/Core/terminals.c`, and asks
the platform for six primitives on one terminal, or on the engine: list the theme
names, apply a named theme or the default, paste text, press Enter, read all text, and
set the font size. Before the platform creates a terminal, the core checks its
options: `:directory` must be a string; `:command`, `:argv` and
`:theme` a string or nil; `:command` and `:argv` mutually exclusive; and `:theme`
a name the platform lists. The adapter decodes literal arguments from `:argv`
and starts the user's interactive login shell to execute them. The core checks a
theme's name the same way before applying it to every open terminal, oldest
first, so an unknown name changes none. If
one terminal rejects a theme, the error is that terminal's: those before it keep the
new theme, and it and those after it keep their old one. `portal--terminal-themes`
returns the platform's names sorted by code point. `portal--terminal-paste` pastes,
then, with ENTER, presses Enter as a separate key, but only if the paste succeeded.
Enter is its own primitive: input replays real native events and needs no synthetic
key. Reading text on macOS selects all and leaves the selection active. The macOS
platform keeps the Ghostty types, binding strings such as `select_all` and
`set_font_size`, and the default theme that follows the system appearance. The
core keeps each terminal's text size, which starts at `PORTAL_TERMINAL_POINTS`.

A terminal describes its `:ready`, `:title`, `:pwd`, `:columns`, `:rows` and
`:exited`, which every platform reports. `:title` and `:pwd` are what the running
program last set and reported, `""` until it does; Ghostty passes on only working
directories reported from this host, percent-decoded. Other facts are diagnostics
for tests: `:layer`, the class of the macOS renderer's layer, and `:focused`, which
input owns. A process that exits leaves its view open with its last output, and its
buffer too, until Lisp closes it; nothing restarts the shell. Closing the view,
which destroys it, ends the process. As for every kind, the core never passes a
closed terminal to the platform: a stale target fails with "No Portal view TARGET",
and a theme reaches only open terminals.

The platform reports each change of title, working directory or exit with
`portal_terminal_changed`. The core sends Emacs one `terminal TARGET` record, and no
other for that view until `portal--inspect` has described it, so a program that
retitles itself constantly cannot flood the pipe. The texts stay with the platform,
which reports them in any length; `portal-terminal.el` inspects the view for them
and caches them in the buffer. A change reported while the view opens has no target
yet, so the core drops its record; Lisp inspects every new terminal once. On macOS, Ghostty reports an exit as a request to
close the surface, at once because Portal turns off its `wait-after-command` and
counts no exit as a failed launch; Portal keeps the view, and the first key after
the exit returns the keyboard to Emacs.

## Web navigation and bridge

Web views' rules live in the core too, in `native/Core/web.c`
([details](editor-bridge.md#transport)). It checks each URL Lisp loads,
and either asks the platform to load it or, for the document already on screen,
to reload it. It answers every navigation a hosted app's page asks for: allow it on
the app host's origin, open another site in the default browser, or hand a local
file to Emacs. It owns the bridge's queue and its one outstanding `bridge` record,
and decides which posted messages to keep from what the platform observed about
the sender, never from what a page claims. The platform's web primitives
parse a URL, returning its own spelling of it, and, on one view, load
a URL, step through history (back, forward or reload, as an enum), post a
message to the page, set its zoom or appearance, find text in it, and call a
function of a shared script with a JSON argument; finds and calls answer later, with the token the core
gave them. The core keeps every URL in the platform's spelling, the one
WebKit reports pages in, with spaces percent-encoded and Unicode hosts in punycode,
so it compares URLs byte for byte and one parser decides when two are the same. It reports what pages do by
calling the core: a message was posted, a navigation is wanted, a page was
committed or finished loading, its history changed, something failed, a find or
call finished, or the contents script counted headings. Those calls name
the view by target, so a completion that finishes after the view closed reaches
nothing. The browser scripts every platform shares, for local links and the
toolbar's contents, are JavaScript in `native/Core/scripts`, which the core embeds
with `#embed` when it is compiled, so no platform needs files or the app host at run
time. Each is a function the platform starts in an isolated world with its own
transport; only platform glue names WebKit. Hosted apps see one interface,
`window.portalBridge`, with `postMessage` and `receive`.

## Toolbar state

Toolbars live in the core too, in `native/Core/toolbar.c`. It keeps each view's
layout, fixed when the view opens from `:toolbar` or, for a terminal, `:quick`; its
zoom or text size, with the zoom steps and the 1 to 255 point limits; whether the
table of contents is open and how many headings the page has; and the find field's
text and matches. It reads who has the keyboard from the input core and whether the
page can go back or forward from the web core, and never copies them. After anything
that may change what a toolbar shows, the core builds a snapshot, a `portal_toolbar`
with the visibility and colors in it, and asks the platform to draw it only if it
differs from the last one drawn; nothing serializes JSON to decide. A click, the
find field's text, a Lisp command and a keyboard shortcut all run the same code on
the same state, and `portal--toolbar-action` returns that state as JSON. Searches
run one at a time, each a count by the contents script and then a find: text that
changes replaces the searches still waiting, a page that finishes loading drops the
result of one from before and searches again, and a result no request waits for
reaches nothing. Opening find gives the field the keyboard with
`portal_toolbar_focus`; closing it gives the page the keyboard with
`portal_view_focus`, but only while the view still has it, so it never takes the
keyboard back from Emacs or another view. The platform keeps drawing: AppKit
buttons and the search field, layout, SF Symbols, tooltips, accessibility, tracking
areas and appearance changes, and turns face colors into `NSColor`s.

## Geometry, attachment and lifetime

Rectangles are in Emacs's frame pixels, from the top left of the frame's content
area, as `window-inside-pixel-edges` reports them. On macOS these are AppKit points,
so the platform only flips the y axis. On each window change, `portal-view.el` picks one window per view,
in any frame: the selected window if it shows the buffer, then the view's current
window, then any other window showing the buffer. With none, the view is hidden.
A geometry cache means nothing crosses the seam when nothing moved. Each placement
renames the frame briefly so Swift can find its native window; nothing about
frames is cached. Placing a view in another frame moves it there within the one
call. In Swift, `NativeView` attaches both kinds, and each kind implements the
small `PortalView` protocol. Detaching parks a view in an offscreen window that is
never shown. New views start there, so a view is always in some window and its session
or page keeps running. Deleting a frame hides its views, and the next sync places each
one wherever its buffer is still shown. Killing the buffer or changing its major
mode closes the view. Operations that belong to one kind have their own exports,
such as `portal--web-load TARGET URL`. Batch
tests replace the native module with `test/portal-fake-native.el`.

The frame-title trick and the geometry cache mean there is no polling timer. No
native code retains an Emacs value or environment pointer after a module call
returns: the C bindings copy each argument, and the backend sees only those copies. Native navigation callbacks report to the core; they never call
back into Lisp.
