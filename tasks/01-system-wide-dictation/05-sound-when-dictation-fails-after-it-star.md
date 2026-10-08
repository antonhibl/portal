---
status: todo
---
# Sound when dictation fails after it starts

Like 02, this lives in the dotfiles repo at `~/.local/share/obento`, file
`macos/.config/emacs/lisp/ai.el`. No Portal worktree or PR; do not commit
the dotfiles repo unless asked.

When dictation fails after it started, the only sign is a message in Emacs's
echo area, which the user cannot see from other apps. Worse, a recording
that died leaves the toggle out of step: the next press of Option-Space
starts a new recording instead of stopping one, and the user speaks into a
recording they think they just stopped.

Failures seen so far:

- The recorder exits on its own, such as FFmpeg failing to open the
  Scarlett (whisper.el reports "error in process sentinel: FFmpeg failed to
  record audio").
- Transcription fails or produces no output ("Whisper command produced no
  output").

A failed paste already plays Basso (`my/dictation-paste`).

## Plan

- When a dictation's recording process ends before the user stops it, or
  its transcription fails, play Basso and say why in a message. whisper.el
  signals these errors from its process sentinels, so a hook in our code
  has to see the process end, for example by wrapping the recording
  process's sentinel with `add-function` after `whisper-run` starts it.
- Only dictations started by `my/dictation-toggle` get the sound; `C-c v`
  keeps whisper.el's behaviour.

## Acceptance

- [ ] Killing the recorder while recording plays Basso and leaves a
      message naming the failure; the next press starts a recording and
      plays Tink.
- [ ] A transcription failure plays Basso.
- [ ] A normal dictation plays only the start and stop sounds.
