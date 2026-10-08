---
status: todo
blocked-by: [01-system-wide-dictation/01-accessibility-permission-check, 01-system-wide-dictation/02-post-a-key-chord-to-the-frontmost-app]
---
# Dictation command in the Emacs config

Wire the pieces into a dictation command bound to a global shortcut.

This task lives in the user's Emacs configuration, not in Portal: the
dotfiles repo at `~/.local/share/obento`, file
`macos/.config/emacs/lisp/ai.el`, next to the existing `whisper` block. No
Portal worktree or PR; do not commit the dotfiles repo unless asked.

## Plan

- A toggle command, bound with `portal-global-shortcut-set` to a chord the
  user picks:
  - Not recording: run `whisper-run` inside a hidden scratch buffer
    (` *dictation*`). whisper.el records its insertion marker in the current
    buffer (`whisper--record-audio`), so the text lands there, never in
    whatever buffer is current, and `whisper--check-buffer-read-only-p` never
    fires.
  - Recording: call `whisper-run` again to stop and transcribe.
- A function on `whisper-after-insert-hook` that acts only in the scratch
  buffer: take its text, empty it, then deliver:
  - Emacs frontmost (a frame has focus, see `frame-focus-state`) and the
    selected window shows no Portal view (`portal-view-target` is nil):
    insert at point in the selected window's buffer.
  - Otherwise: put the text on the clipboard with
    `(gui-set-selection 'CLIPBOARD text)` and call
    `(portal-post-key "Command-V")`. Portal views handle Command-V
    themselves. Check how a Portal view buffer whose view does not hold the
    keyboard handles the posted Command-V, and pick the better of pasting and
    inserting there.
  - If posting fails: say the text is on the clipboard, and when the error is
    missing Accessibility, offer `(portal-accessibility-trusted-p t)`.
- Play a short system sound on start and stop
  (`afplay /System/Library/Sounds/Tink.aiff`), since the mode line is not
  visible from other apps.

## Acceptance

- [ ] From another app with a text field focused, press, speak, press: the
      text appears in that field and is on the clipboard.
- [ ] With nothing focused (for example Finder's desktop), the text is on the
      clipboard and in Spotlight's clipboard history.
- [ ] With an Emacs buffer focused, the text is inserted at point and the
      clipboard is unchanged.
- [ ] With a Portal terminal focused, the text is pasted into the terminal.
- [ ] Dictating from Emacs with `C-c v` (plain `whisper-run`) still works.
- [ ] Without Accessibility permission, the message says the text is on the
      clipboard and how to grant permission.
