---
status: done
---
# Hidden launcher frame keeps focus and selection

After a launcher session ends, Emacs can still treat the hidden launcher
frame as selected and focused, so code that asks Emacs where focus is gets
the wrong answer. Found while building dictation, whose Emacs config now
works around it by counting only visible frames
(`~/.local/share/obento/macos/.config/emacs/lisp/ai.el`,
`my/dictation-deliver`).

## Observed

With Google Chrome frontmost, after Command-Space launcher sessions earlier
in the day:

- `(selected-frame)` was the "Portal launcher" frame, with
  `frame-visible-p` nil and `frame-focus-state` t. The terminal frame,
  visible, reported nil. Commands run from a global shortcut therefore ran
  in the hidden launcher frame's selected window.
- Later, the terminal frame was selected again, but the hidden launcher
  frame still reported `frame-focus-state` t, which it kept with TextEdit
  frontmost.

`portal-launcher-present`'s cleanup hides the panel, makes the frame
invisible and selects the previous window with `norecord`. Something after
that, such as a focus or switch-frame event the panel caused, may select the
launcher frame again, and the frame never gets a focus-out event once it is
hidden. Neither is confirmed yet.

## Plan

- Reproduce in the VM: present a launcher, dismiss it by success, by
  Escape and by clicking away, with another app frontmost and with Emacs
  frontmost. After each, record `(selected-frame)` and each frame's
  `frame-focus-state`.
- Find where the launcher frame becomes selected again and why its focus
  state stays t, and fix the cause in Portal rather than in callers.

## Acceptance

- [ ] After any dismissal, the selected frame is the frame that was
      selected before the launcher appeared, or the one the user moved to.
- [ ] Once hidden, the launcher frame's `frame-focus-state` is not t.
- [ ] A test covers both, if the GUI test suite can reach them.
