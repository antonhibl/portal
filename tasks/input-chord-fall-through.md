---
id: input-chord-fall-through
status: done
---

# Chords a view does not use fall through to Emacs

## Problem and outcome

Portal's input followed tmux: a `C-b` prefix handed the next command to Emacs.
That split the experience. In a native view, Emacs habits such as `s-x` did
nothing until `C-b d` returned to Emacs, and tmux inside a Portal terminal
fought over `C-b`.

Treat Emacs as the operating system and each native view as an app running
in it, as a Mac app runs in macOS or a page in a browser. A view behaves as
its app would outside Emacs. A chord its app does not use goes to Emacs, which
reads it with the buffer's own keymaps. Nothing needs listing, whatever the
user's Emacs looks like.

## Decisions

Agreed with the user on 2026-09-30.

- **Order.** For each key pressed in a view:
  1. Command-Escape returns to Emacs and stays there, as the last resort when
     an app takes the keys the user needs. It is the only reserved key.
  2. A key the user claimed with a native binding goes to Emacs.
  3. The view's app gets the key. Only a chord can go further: a key that
     types a character, pressed with Control, Meta or Super. Plain and
     Shift-only keys, and keys that type no character (arrows, Return,
     function keys), always stay with the app.
  4. The view's shortcuts: Super-C copies and Super-V pastes in every view;
     the toolbar's shortcuts (find, reload, text size) follow.
  5. Emacs, which reads the rest of the key sequence with the buffer's
     keymaps, plain keys included.
- **Why chords only.** Emacs binds single keys too (Evil's `i`), so plain
  keys falling through would make a view's buffer act strangely. A view is
  like Evil insert state: plain keys type, chords reach Emacs, and
  Command-Escape is Escape. A Space leader needs a modified alias in the
  user's config, as Doom's `M-SPC`.
- **Decided at run time.** A terminal's app never uses a Super chord: Ghostty
  sends a program nothing for one on macOS, unless the program turns on the
  kitty keyboard protocol, which Portal gives up. So the core decides a
  terminal's keys at once. A web page's use of a chord is known only after
  the page has seen it: the platform offers the chord, holds every key after
  it, and reports it back if the page did not use it.
- **One place.** The order lives in the C core's input module
  (`native/Core/input.c`); platforms supply primitives.
- **Removed.** The `C-b` prefix and everything that existed for it:
  `portal-input-prefix`, `portal-command-map`, the prefix gateways, the
  terminal, quick and Excalidraw prefix maps, the `m` feature maps, prefix
  help, and passthrough, whose job was to release the prefix. Window
  management stays Emacs's: views get no tab or split keys, and Ghostty's own
  Super bindings no longer apply.

## Scope

- Core: the order above; a Super chord in a terminal decided at once; an
  offered chord in a web view, and `portal_input_unused` when it comes back;
  a `key` record carrying the chord; copy and paste primitives; no prefix or
  passthrough.
- macOS: hold keys after an offered chord until WebKit has processed it, and
  report WebKit's unhandled re-send; copy and paste in terminals and pages.
- Lisp: read a fallen-through chord's key sequence with the buffer's keymaps
  and run its command through the existing handoff; remove the prefix,
  passthrough and prefix maps; keep claimed keys (native bindings).
- Docs and tests for all of the above.

## Acceptance criteria

- [x] In a terminal, `s-x` runs `execute-extended-command`, and other Super
  chords the user binds work without leaving the terminal; tmux receives
  `C-b`. Super-C and Super-V copy and paste.
- [x] In a web page, a chord the page does not use reaches Emacs, whole key
  sequences included (`C-x b`); a chord the page uses stays with it; keys
  typed after a chord go wherever the chord went.
- [x] Plain and Shift-only keys never reach Emacs from a view.
- [x] Command-Escape returns to Emacs; `RET` or a click re-enters.
- [x] Core tests cover the order, offers, cancellation and stale handoffs;
  Lisp and graphical tests cover fall-through end to end; project checks pass.

## Outcome

Done 2026-09-30. `native/Core/input.c` holds the whole order. The `C-b`
prefix, its maps, gateways and help, and passthrough are gone, along with the
`portal--input-prefix` export and the toolbar's passthrough state. A chord
that reaches Emacs arrives as a `key` record, and `portal-input.el` reads its
key sequence with the buffer's keymaps, so Evil's state keymaps, remapping and
prefix keys apply as if it were typed there. Native bindings stay, for chords a
terminal's program would otherwise get. Terminal commands keep their names
without keys; the README shows binding them to Command chords.

Found while implementing:

- Keys typed at once after a chord that is a whole command are Emacs's next
  command. The platform replays them when Emacs acknowledges, but Emacs reads
  no key after the trigger, and the redisplay before it gave the view the
  keyboard back took them in, so they ran in the buffer behind the resumed
  view. Emacs now keeps the keyboard while any wait. Agreed with the user in
  review on 2026-10-01. It keeps it too while a command leaves a prefix
  argument or a transient keymap, as `universal-argument` and isearch do.
- WebKit hands back a key a page did not use by sending the same event
  through `[NSApp sendEvent:]`, which Portal already saw and discarded. It sends
  the next queued key to the page first, so Portal holds keys after a chord
  until the page answers.
- A page's use of a chord has no direct signal. In editable content, a key
  reaches WebKit's queue only after the input method's asynchronous pass, so
  WebKit's `_doAfterProcessingAllPendingKeyEvents:` cannot be asked right
  after delivery. A script in its own world, in every frame, reports the chord
  reaching the page, and only then is WebKit asked. A view with no page yet
  has no web process, and WebKit drops keys silently: a chord the page never
  saw goes to Emacs after a second, while one it saw but never finished with
  stays the page's.
- Ghostty sends a program nothing for a Super chord on macOS, and its key call
  reports that, but the wrapper does not expose the result. The core decides
  a terminal's Super chords itself, which also means Ghostty's own Command-key
  bindings, and the four that Portal unbound, never apply.
- `NativeHost` kept who owned a pressed key by handler, which differs between
  a view and its input while keys are held, so an offered chord's release was
  dropped. It keeps the view instead.
- A web view's find field is an AppKit field: it uses Control and Option
  chords, and a Command chord there goes to the view's shortcuts or Emacs, so
  Command-V pastes into the field and Command-R reloads.

Verified with the core suites (`ctest --test-dir build/core`, 7 of 7), the
project suites (`ctest --test-dir build`, 23 of 23), the combined graphical
suite in a disposable Emacs (61 passed, 1 skipped for its shell-startup
setting), both standalone AppKit checks, and warning-free byte compilation.
