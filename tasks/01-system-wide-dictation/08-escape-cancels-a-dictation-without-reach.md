---
status: todo
---
# Escape cancels a dictation without reaching the app

Escape cancels a dictation: while it records or transcribes, Escape throws
the audio and text away, and nothing is pasted. The Escape never reaches the
frontmost app. A leaked Escape would, for example, interrupt a coding agent
running in the terminal the user is dictating into.

Portal knows nothing about dictation. It lets a global shortcut be a bare
Escape. The user's configuration registers Escape when a dictation starts
and releases it when the dictation ends, however it ends.

## Prior art

Every tool that cancels with Escape keeps the key from other apps during
dictation. OpenSuperWhisper, OpenWhispr and VoiceInk (until May 2026)
register a Carbon hot key only while active. VoiceInk now, Handy, Hex and
FluidVoice use an event tap, which needs Accessibility. Wispr Flow
documents it: "Escape does not reach other apps during dictation." Users
report accidental cancels (VoiceInk #108/#733, Handy #1047), and Handy
#2164 left Escape registered, so it was dead everywhere until Handy quit.
Notes: `.cache/research/dictation-escape-cancel.md` (local, ignored).

## Plan

- Core (`shortcuts.c`): Escape is a key, and the one key allowed without
  Control, Option or Command. Other bare keys stay refused.
- macOS: Escape is virtual key 53, for hot keys and posted chords.
- `portal-global-shortcut-set` documents it.
- Config (`ai.el`, not in this repo): register Escape when a dictation
  starts; release it in one place that every end goes through (delivered,
  cancelled, failed). Escape while recording or transcribing discards it.
  A recording longer than 10 seconds needs a second Escape.

## Acceptance

- [x] `Escape` registers as a global shortcut, and `Shift-A`/`A` are still refused.
- [x] In the VM, with Escape registered and another app frontmost, a
      posted Escape runs the shortcut and the app gets no Escape; once it is
      removed, the app gets the next Escape.
- [x] CTest covers the chord rules.
