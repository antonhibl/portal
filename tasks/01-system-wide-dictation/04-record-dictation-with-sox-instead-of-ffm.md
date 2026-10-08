---
status: todo
---
# Record dictation with sox instead of ffmpeg

Like 02, this lives in the dotfiles repo at `~/.local/share/obento`: files
`macos/.config/emacs/lisp/ai.el` and `macos/Brewfile`. No Portal worktree
or PR; do not commit the dotfiles repo unless asked.

## Why

FFmpeg's avfoundation input takes the audio format from the first sample
buffer and accepts only packed linear PCM: float32, s16, s24 or s32
(`libavdevice/avfoundation.m`, `get_audio_config`, the same in 8.0 and
9.0.2). It never sets `audioSettings` on its `AVCaptureAudioDataOutput`, so
the first buffer comes in whatever format AVFoundation picks. For the
Scarlett Solo USB that is sometimes packed float32, which works, and
sometimes 24-bit integers in 4-byte slots, not packed, which fails with
"audio format is not supported" and exit code 251. About one start in
three failed; the built-in microphone never did. A failed start leaves
nothing recording, so the next press of the dictation shortcut starts a
recording instead of stopping one.

The current workaround, `my/whisper-retry-open` in `ai.el`, wraps FFmpeg in
a shell loop that retries on exit code 251. Each retry costs about a second
before recording starts.

sox records through Core Audio and converts to the requested rate, channels
and sample size itself, so the first buffer's format does not matter.

## Plan

- Add `brew "sox"` to the Brewfile. Keep FFmpeg: whisper.el checks for it
  in `whisper--record-command` and uses it to convert files for
  `whisper-file`.
- Replace `my/whisper-retry-open` with an advice on `whisper--record-command`
  that, when recording (`whisper--ffmpeg-input-file` is nil), returns a sox
  command that records the default input to whisper's file as 16 kHz mono
  16-bit WAV and honours `whisper-recording-timeout`, for example
  `sox -q -d -r 16000 -c 1 -b 16 FILE trim 0 TIMEOUT`.
- whisper.el's recording sentinel transcribes only on "finished",
  "terminated" or exit code 255. Check how sox exits after whisper's
  `interrupt-process` (SIGINT) and that the WAV is complete; adapt the
  command if needed.
- Drop `whisper--ffmpeg-input-device` if nothing uses it any more.

## Acceptance

- [ ] 20 consecutive starts with the Scarlett as the default input all
      record, and each stops on the next press with a complete WAV.
- [ ] Dictation with Option-Space and with `C-c v` both transcribe.
- [ ] With the MacBook microphone as the default input, recording uses it
      without a config change.
- [ ] `whisper-file` still transcribes a file.
