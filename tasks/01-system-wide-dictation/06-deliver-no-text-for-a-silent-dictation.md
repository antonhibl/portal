---
status: todo
---
# Deliver no text for a silent dictation

Like 02, this lives in the dotfiles repo at `~/.local/share/obento`, file
`macos/.config/emacs/lisp/ai.el`. No Portal worktree or PR; do not commit
the dotfiles repo unless asked.

A dictation with no speech still delivers text. A near-silent recording came
back as "Thank you.", which replaced the clipboard. Whisper models are known
to invent short phrases like this from silence or noise.

## Options

The whisper.cpp that whisper.el installed (1.9.5, under
`~/.config/emacs/var/whisper/whisper.cpp/build/bin`) has:

- `--vad` with `--vad-model`: Silero voice activity detection, which
  transcribes only the parts with speech. It needs a VAD model file.
- `--suppress-nst`: suppress non-speech tokens.
- `--no-speech-thold`: the no-speech probability threshold (0.60 by
  default).

Check which way whisper.el runs whisper.cpp with this config (subprocess
through `whisper-command`, or the local server) and pass the options there.
Prefer voice activity detection over filtering known phrases from the
output.

## Acceptance

- [ ] Starting and stopping a dictation without speaking delivers no text
      and leaves the clipboard unchanged.
- [ ] Normal dictations transcribe as before, including short ones of a
      word or two.
- [ ] Transcription time for a 10-second dictation does not get noticeably
      slower.
