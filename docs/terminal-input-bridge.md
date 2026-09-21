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

1. **Register.** [Map compilation](../portal-terminal-bindings.el#L32) validates
   first chords and copies dispatch maps. [Refresh](../portal-terminal-bindings.el#L66)
   sends JSON with `regular` and `quick` arrays. Each entry contains only
   `{character, flags, event}`: a native chord and its encoded Emacs event.
   [The module entry point](../native/Module.swift#L278) passes it to
   [Swift's registry](../native/Terminal.swift#L236), which validates both profiles
   before replacing either. Hidden and future sessions use the same live tables.
   Lisp publishes its snapshots only after native registration succeeds;
   failed helper edits roll back the editable map too.

2. **Intercept.** [NativeHost routes AppKit events](../native/NativeHost.swift#L113)
   to the focused surface. [The terminal handler](../native/Terminal.swift#L131)
   passes unmatched input to Ghostty. A match returns focus to Emacs, writes
   `binding SESSION-ID EVENT\n` to the pipe, and captures subsequent events until
   Lisp acknowledges. Swift never invokes interactive Lisp from this callback.

3. **Dispatch.** [The pipe filter](../portal-terminal.el#L200) assembles fragmented
   messages and queues a synthetic `portal-terminal-binding` event in
   `unread-command-events`. [The command-loop dispatcher](../portal-terminal.el#L371)
   selects the originating session's buffer and resolves its registered map.
   A command executes directly; a prefix uses
   [`read-key-sequence-vector`](../portal-terminal.el#L353) for the remaining keys.

4. **Hand back.** [Acknowledgement](../native/Terminal.swift#L181) replays buffered
   events in order, allowing rapid prefix tails and minibuffer typing to reach
   Emacs. Cleanup releases capture. Focus returns to the selected terminal after
   the command finishes; dismissal, selecting an editor buffer, explicit unfocus,
   or an error leaves Emacs in control. Prefix repetition sends the captured
   native keystroke literally; `C-g` cancels.

## Boundaries and verification

First chords currently support modified printable ASCII, with `C` = Control,
`M` = Option, and `s` = Command. Use resulting punctuation (`s-!`, not `s-S-1`);
prefix tails use normal Emacs keys. The existing `portal-terminal-prefix`
remains live-configurable and cannot collide with these maps. Command-Escape
remains the fixed escape hatch. System-wide shortcut interception still happens
before Portal receives an event.

Verified with [six registration tests](../test/portal-terminal-bindings-tests.el),
six quick-terminal behavior tests, and
[18 graphical terminal tests](../test/portal-terminal-tests.el), including real
AppKit input, live rebinding/unbinding, quick-only scope, hidden-session updates,
shifted characters, cancellation, literal PTY bytes, and rapid minibuffer input.
