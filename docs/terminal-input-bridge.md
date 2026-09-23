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

The native input machinery is shared by terminals, editors, and web previews.
`portal-input-prefix` configures their common prefix; the old
`portal-terminal-prefix` name is an alias. Terminal-specific native maps retain
their scope and registration API.

1. Registration validates and snapshots the terminal maps as before. Only first
   chords cross into Swift; command maps remain in Lisp.
2. `NativeHost` routes input to the focused surface's `NativeInput`. A reserved
   chord returns focus to Emacs, sends a target and handoff serial through the
   shared pipe, and buffers fast follow-up input until Lisp acknowledges.
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

## Boundaries and verification

First chords currently support modified printable ASCII, with `C` = Control,
`M` = Option, and `s` = Command. Use resulting punctuation (`s-!`, not `s-S-1`);
prefix tails use normal Emacs keys. The shared `portal-input-prefix`
remains live-configurable and cannot collide with these maps. Command-Escape
remains the fixed escape hatch. System-wide shortcut interception still happens
before Portal receives an event.

Verified with [registration tests](../test/portal-terminal-bindings-tests.el),
six quick-terminal behavior tests, and
[18 graphical terminal tests](../test/portal-terminal-tests.el), including real
AppKit input, live rebinding/unbinding, quick-only scope, hidden-session updates,
shifted characters, cancellation, literal PTY bytes, and rapid minibuffer input.
