# Terminal input bridge

Bindings are runtime Elisp configuration. Swift recognizes registered first
chords; Emacs owns commands and the rest of each key sequence. Once this native
bridge is built and loaded, changing bindings requires no rebuild or restart.

## Configure

After loading Portal, opt into the same toggle from the editor and quick terminal:

```elisp
(keymap-global-set "s-`" #'portal-terminal-toggle)
(portal-terminal-bind-key portal-terminal-quick-native-map
                          "s-`" #'portal-terminal-toggle)

;; A nested shortcut available in every terminal:
(portal-terminal-bind-key portal-terminal-native-map
                          "s-j b" #'switch-to-buffer)

;; Remove an interception at runtime:
(portal-terminal-unbind-key portal-terminal-native-map "s-j b")
```

Both native maps start empty. The quick map overlays the shared map; removing an
override reveals the shared binding. Removing a prefix's last command releases
its first chord to Ghostty. Helpers apply changes immediately; after direct
`keymap-set`/`keymap-unset` edits, call `portal-terminal-refresh-bindings`.
These maps apply only while the native terminal has focus.

## Across the boundary

The native input machinery is shared by terminal and web views.
`portal-input-prefix` configures their common prefix; the old
`portal-terminal-prefix` name is an alias. Terminal-specific native maps retain
their scope and registration API.

1. Registration validates and snapshots the terminal maps as before. Only first
   chords cross into Swift; command maps remain in Lisp.
2. `NativeHost` routes input to the focused surface's `NativeInput`. A reserved
   chord returns focus to Emacs, sends a record with the view's target and a
   handoff serial through the notification pipe, and buffers fast follow-up
   input until Lisp acknowledges.
3. `portal-input--dispatch` selects the originating native view's Emacs window.
   Lisp reads prefix tails using `read-key-sequence-vector`, applies normal
   command remapping, and executes the command outside the process filter.
4. Completion releases capture and normally focuses the selected Portal view.
   Explicit unfocus, errors, ordinary buffers, or an invalidated handoff keep
   Emacs in control. Command-Escape can invalidate a handoff before acknowledgement.

Repeating the first chord sends its captured native key-down/key-up pair to the
app. Once a sequence has begun, that same key remains available inside nested
Emacs bindings, such as `C-b C-x C-b`. WebKit's asynchronous retries of unhandled
keys are consumed after their first delivery, preventing input intended for a
page from later becoming Emacs commands.

## The notification pipe

Every notification from the native module reaches Emacs on one pipe.
`portal-view.el` owns its reading end: it creates the pipe process with the
first view and passes it to `portal--channel`. The module's C core owns the
writing end (`native/Core/channel.c`). Platform code, such as Swift's input and
bridge, sends a record by calling the core's `portal_notify`.

Each record is one line, `TYPE TARGET FIELD...`, of printable ASCII words
separated by spaces and at most `PIPE_BUF` bytes long, so every write is
atomic. The core refuses any other record, and returns whether it accepted
one. Records reach Emacs in the order they are sent. While the pipe is full, a
record waits in the core, with those sent after it, and the core retries it
on a timer the platform provides. A busy Emacs thus delays records but never
loses or reorders them. While no pipe is connected, or after Emacs closes its
end, records wait for Emacs to connect one, and records still waiting then go
to the new pipe first. The pipe never raises SIGPIPE, so a closed end cannot
end Emacs, and child processes do not inherit it. Input sends these records,
each with the handoff serial and a key field:

| Record | Sent when |
| --- | --- |
| `prefix TARGET SERIAL 0` | The view captures the prefix |
| `binding TARGET SERIAL EVENT` | The view captures the first chord of a native terminal binding |
| `literal TARGET SERIAL 0` | The first chord is repeated while Emacs reads the rest of the sequence |
| `cancel TARGET SERIAL 0` | `C-g` is pressed in the view while Emacs reads the rest of the sequence |
| `escape TARGET SERIAL 0` | Command-Escape cancels a handoff, as does a click that hands off to Emacs or selects the view's pane |

A click that enters a view sends `select TARGET`, and Emacs selects the pane
showing the view.

Reads do not follow record boundaries: one record can arrive split across two
reads, and one read can carry several records. `portal-view.el` joins the reads
into lines. It dispatches each record through `portal-view-record-handlers`,
calling the handler for its type with the target's buffer current. Records for
targets that have no buffer, or of types with no handler, are dropped. Handlers
run inside the process filter, so they never prompt. `portal-input` registers
the five input types, and queues each record as an event such as
`(portal-input-prefix (TARGET SERIAL KEY))`, which the command loop then runs.
`portal-web` registers the `bridge` type, which announces a hosted app's
messages ([the bridge](editor-bridge.md)).

## Boundaries and verification

First chords currently support modified printable ASCII, with `C` = Control,
`M` = Option, and `s` = Command. Use resulting punctuation (`s-!`, not `s-S-1`);
prefix tails use normal Emacs keys. The shared `portal-input-prefix`
remains live-configurable and cannot collide with these maps. Command-Escape
remains the fixed escape hatch. System-wide shortcut interception still happens
before Portal receives an event.

Verified with [registration tests](../test/portal-terminal-bindings-tests.el),
batch [record dispatch tests](../test/portal-view-tests.el) (split, batched and
unknown-target records), [pipe tests](../test/portal-channel-tests.c) (a full
pipe, reconnects, malformed records and a closed reader),
six quick-terminal behavior tests, and
[18 graphical terminal tests](../test/portal-terminal-tests.el), including real
AppKit input, live rebinding/unbinding, quick-only scope, hidden-session updates,
shifted characters, cancellation, literal PTY bytes, and rapid minibuffer input.
