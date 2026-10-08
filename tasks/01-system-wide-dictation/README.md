---
status: todo
---
# System-wide dictation

Dictate into any macOS app, not only Emacs buffers. A global shortcut starts
and stops recording; whisper.el transcribes locally; the text is inserted at
point when Emacs is frontmost, and otherwise replaces the clipboard and is
pasted into the frontmost app with a posted Command-V.

## Decisions

- **Split of responsibilities.** whisper.el records and transcribes. Lisp
  decides where the text goes. Portal's native module supplies two primitives
  that know nothing about dictation: whether Emacs has Accessibility
  permission, and posting a key chord to the frontmost app
  ([ADR 0003](../../docs/adr/0003-platform-interface-primitives.md)).
- **Always paste through the clipboard.** The transcript replaces the
  clipboard and stays there; nothing is restored. If the paste lands nowhere
  or fails, the text is still on the clipboard and in clipboard history.
- **No focus detection.** Whether a text field is focused is not checked.
  A Command-V with no target does nothing.
- **Not in scope:** clipboard restore, typing keystrokes instead of pasting,
  and refusing to paste when the frontmost app changed during transcription
  (that guard would need a third primitive, the frontmost app's identity).

## Prior art

Every open-source macOS dictation app read for this design (VoiceInk, Hex,
Handy, OpenWhispr, HyperWhisper) pastes with a synthesized Command-V, and
Superwhisper's default replaces the clipboard. Facts that shape the tasks:

- Posting keys to another app needs Accessibility permission. Without it
  macOS drops the events silently, so apps check `AXIsProcessTrusted()`
  before posting and fall back to the clipboard
  (VoiceInk `CursorPaster.swift`, OpenWhispr PR #2318).
- The Command-V key must follow the keyboard layout: OpenWhispr's
  `resources/macos-fast-paste.swift` and Handy's `src-tauri/src/input.rs`
  find the key that types "v" with Command held via `UCKeyTranslate`, and
  OpenWhispr refuses to post when none does, since on a non-QWERTY layout a
  fixed key code fires another shortcut.
- Accessibility belongs to Emacs.app, since the module runs in its process.
  Grants follow the code signature: reinstalling emacs-plus can break one
  until Emacs is removed and re-added, and a running process does not see a
  new grant until it restarts.
- Portal's global shortcuts use Carbon hot keys, which need no Input
  Monitoring permission and keep working under Secure Event Input.
