# Input bridge

Emacs is the system, and each native view an app running in it, as a page runs
in a browser. A view behaves as its app does outside Emacs. A chord its app does
not use reaches Emacs, which reads it with the view's buffer's keymaps. The
module's C core decides who gets each key; Emacs owns commands and the rest of
each key sequence. Bindings are runtime Elisp configuration: changing them
needs no rebuild or restart.

## Who gets a key

The core (`native/Core/input.c`) sends each key pressed in a view to the first
of these that takes it:

1. **Command-Escape** returns the keyboard to Emacs, which keeps it. `RET` in
   the view's buffer, or a click in the view, gives it back. This is the one
   reserved key, the last resort when an app uses the keys you need.
2. **A native binding** (below): a chord you claimed for Emacs in terminals.
3. **The view's app.** Only a chord can go further: a key that types a
   character, pressed with Control, Meta (Option) or Super (Command). Plain and
   Shift keys, and keys that type no character, such as arrows, Return, Tab and
   function keys, always stay with the app.
   - A terminal's program gets every chord but Super's: tmux gets `C-b`, and
     the shell `C-a` and `M-f`. On macOS, Ghostty sends a program nothing for a
     Super chord anyway, unless the program turns on the kitty keyboard
     protocol, and Portal gives those up.
   - A web view's page is offered each chord, and keeps those it uses.
4. **The view's shortcuts.** Super-C copies and Super-V pastes in every view.
   Then the toolbar's: Super-F finds in a web view's page, Super-R reloads it,
   and Super-=, Super-- and Super-0 size a terminal's text.
5. **Emacs**, which reads the rest of the key sequence, plain keys included,
   with the keymaps of the view's buffer, Evil's included, and runs its
   command as if it had been typed there.

Plain keys never reach Emacs: Emacs binds single keys too, such as Evil's `i`,
so they would make a view's buffer act strangely. A view is like Evil's insert
state: plain keys type, chords reach Emacs, and Command-Escape is Escape. For a
Space leader, bind a chord to it as well, as Doom's `M-SPC` does:

```elisp
(evil-set-leader 'normal (kbd "s-'"))
```

## Native bindings

A native binding claims a chord that a terminal's program would otherwise get,
such as a Control chord, for an Emacs command. A Super chord needs none: it
reaches Emacs anyway.

```elisp
;; A nested shortcut available in every terminal:
(portal-terminal-bind-key portal-terminal-native-map
                          "C-] b" #'switch-to-buffer)

;; Only in quick terminals:
(portal-terminal-bind-key portal-terminal-quick-native-map
                          "C-]" #'portal-terminal-toggle)

;; Remove an interception at runtime:
(portal-terminal-unbind-key portal-terminal-native-map "C-] b")
```

Both native maps start empty. The quick map overlays the shared map; removing an
override reveals the shared binding. Removing a prefix map's last command
releases its first chord to Ghostty. Helpers apply changes immediately; after
direct `keymap-set`/`keymap-unset` edits, call `portal-terminal-refresh-bindings`.
These maps apply only while the native terminal has focus. Repeating a
binding's first chord, as the first key after it, sends it to the program.

## Across the boundary

The native input machinery is shared by terminal and web views.

1. Registration validates and snapshots the native maps. Only first chords
   cross into the module, each as a character and Portal's modifier values
   (Shift 1, Control 2, Meta 4, Super 8), never a platform's key flags;
   command maps remain in Lisp. The C core checks them again, and replaces
   both binding profiles only when nothing collides.
2. The platform captures each key press in a view and asks the core what to
   do with it, as a chord: the character it types with Shift but no other
   modifier, or none, and those modifiers. On macOS, Option is Meta and
   Command is Super. The core answers pass it on, take it, hold it, or offer
   it.
   - To start a handoff, the core returns the keyboard to Emacs and sends a
     record with the view's target and a new handoff serial through the
     notification pipe. The platform holds that key, the trigger, and every
     key event after it until Lisp acknowledges.
   - To offer a chord, the platform delivers it to the page and holds every
     key event after it until the page answers. WebKit hands back a key a
     page did not use, sending it through the application again, and the
     platform reports it to the core (`portal_input_unused`), which runs a
     shortcut or starts a handoff. A page that used the chord gets the held
     events. That is known once a script in its own world, in every frame,
     reports that the chord reached the page, and WebKit has then finished
     with every key it had: typed into editable content, a key reaches
     WebKit's queue only after the input method is done with it. WebKit
     would give the page the next queued key before handing an unused one
     back, so the page has one chord at a time. A page that never answers
     within a second used a chord it saw; one that never saw it, as a view
     with no page yet, did not.
3. `portal-input--dispatch` selects the originating view's Emacs window and
   acknowledges; the platform then replays the held events, in order, with
   their repeats, releases and modifier changes. For a chord that fell
   through, Lisp reads the key sequence it starts with
   `read-key-sequence-vector` and the buffer's keymaps; for a native binding,
   the rest of the binding's prefix map. It applies normal command remapping,
   and executes the command outside the process filter.
4. Completion releases the held trigger and normally focuses the selected
   Portal view. Keys typed after the trigger are Emacs's. Those its key
   sequence and command did not read, as after a chord that is a whole
   command, are its next command, so Emacs keeps the keyboard while any
   wait. Explicit unfocus, errors, ordinary buffers, or the user ending the
   handoff keep Emacs in control too. A command that hides the originating
   view, such as by showing another terminal in its pane, ends its handoff
   silently; the selected view still resumes. When finishing fails, Lisp
   first reads the records already in the pipe, so an `escape` sent while a
   command ran, even one that read no input, keeps Emacs in control.

Each view's handoff is in one state: idle, awaiting acknowledgement, reading a
command, or executing it. Whether the view has the keyboard, which the platform
reports, is kept apart from it. Every Lisp action names its handoff's serial,
and does nothing unless that handoff is still going, so a late acknowledgement
or completion never affects another handoff or view. Hiding or closing a view,
or Emacs's `unfocus`, ends its handoff silently. The user ending one, with
Command-Escape or a click in the view, sends an `escape` record first. So does
a hosted app handing Emacs a local link, or its toolbar's Open in Emacs: the
web core (`native/Core/web.c`) calls `portal_input_escape` before it sends the
`bridge` record. A focus change that Emacs's own call makes, such as a command
opening the find field, never ends a handoff. Command-Escape stays in the
platform, so it works immediately, without a round trip through Lisp or
JavaScript.

While Emacs reads a key sequence, `C-g` cancels it, and the trigger's own
repeats are dropped; pressed again, the trigger is part of the sequence, as in
`C-x C-x`. WebKit's retries of keys it did not handle are consumed after their
first delivery, so input meant for a page never later becomes an Emacs command.

## The notification pipe

Every notification from the native module reaches Emacs on one pipe.
`portal-view.el` owns its reading end: it creates the pipe process with the
first view and passes it to `portal--channel`. The module's C core owns the
writing end (`native/Core/channel.c`). The core's input handoff sends its
records directly; platform code, such as a hosted app's bridge or a click's
`select`, sends a record by calling the core's `portal_notify`.

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
each with the handoff serial:

| Record | Sent when |
| --- | --- |
| `key TARGET SERIAL CHARACTER MODIFIERS` | A chord the view's app did not use reaches Emacs, as typed: Shift made CHARACTER |
| `binding TARGET SERIAL EVENT` | The view captures the first chord of a native terminal binding |
| `literal TARGET SERIAL 0` | A binding's first chord is repeated while Emacs reads the rest of the sequence |
| `cancel TARGET SERIAL 0` | `C-g` is pressed in the view while Emacs reads the rest of the sequence |
| `escape TARGET SERIAL 0` | Command-Escape cancels a handoff, as does a click that hands off to Emacs or selects the view's pane |

A click that enters a view sends `select TARGET`, and Emacs selects the pane
showing the view. A terminal whose title, working directory or process state
changes sends `terminal TARGET`, and no other until Emacs inspects the view,
which carries the new text in any length.

Reads do not follow record boundaries: one record can arrive split across two
reads, and one read can carry several records. `portal-view.el` joins the reads
into lines. It dispatches each record through `portal-view-record-handlers`,
calling the handler for its type with the target's buffer current. Records for
targets that have no buffer, or of types with no handler, are dropped. Handlers
run inside the process filter, so they never prompt. `portal-input` registers
the five input types, and queues each record as an event such as
`(portal-input-key (TARGET SERIAL CHARACTER MODIFIERS))`, which the command
loop then runs. `portal-web` registers the `bridge` type, which announces a
hosted app's messages ([the bridge](editor-bridge.md)). `portal-terminal`
registers the `terminal` type, and caches what `portal--inspect` then reports
in the terminal's buffer.

## Boundaries and verification

Native bindings' first chords support modified printable ASCII, with `C` =
Control, `M` = Option, and `s` = Command. Use resulting punctuation (`s-!`, not
`s-S-1`); the rest of a sequence uses normal Emacs keys. Command-Escape remains
the fixed escape hatch. System-wide shortcut interception, such as Spotlight's
Command-Space, still happens before Portal receives an event.

Verified with [registration tests](../test/portal-terminal-bindings-tests.el),
[core input tests](../test/portal-input-tests.c), which press keys through a fake
platform whose pages answer offers (the order above, offers used and unused,
shortcuts, the keyboard moving during an offer, delayed acknowledgement, rapid
tails, repeated triggers, literal delivery, cancellation, stale serials, and
hiding or closing during a handoff), batch [Lisp input
tests](../test/portal-input-tests.el) (key sequences read with the buffer's
keymaps, Evil's included, escape, cancel and type-ahead), batch [record dispatch
tests](../test/portal-view-tests.el) (split, batched and unknown-target
records), [pipe tests](../test/portal-channel-tests.c) (a full pipe,
reconnects, malformed records and a closed reader), and graphical
[terminal](../test/portal-terminal-tests.el) and [web
input](../test/portal-input-gui-tests.el) tests with real AppKit input: Emacs
commands from Super chords, `C-b` and `C-a` reaching the shell, chords a page
uses or not, keys typed at once after a chord, in a sequence or after a
whole command, copy and paste, live rebinding, quick-only scope, shifted
characters, cancellation, literal PTY bytes, and rapid minibuffer input.
