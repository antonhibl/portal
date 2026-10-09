---
status: todo
---
# Status panel that floats above every app

# Status panel that floats above every app

Dictation runs from other apps, where Emacs's mode line and echo area are
out of sight; sounds are the only sign of what it is doing. Show its status,
such as "Recording" or "Transcribing", in a small panel that floats above
every app.

Portal supplies the panel and knows nothing about dictation: Lisp shows a
line of text in it and hides it. Which statuses exist, their wording, and
when to hide an outcome belong to the user's configuration. A waveform is
deferred.

## Plan

- Two platform primitives in `native/Core/include/portal.h`: show TEXT in
  the status panel, replacing what it showed, and hide it. The bindings call
  them directly, as for the launcher.
- `portal-status-show TEXT` and `portal-status-hide` in `portal-system.el`.
- macOS: a borderless nonactivating `NSPanel` that can never become key or
  main and ignores the mouse, at status-bar level, on every Space and over
  fullscreen apps. Showing it never activates Emacs or changes the frontmost
  app or its keyboard focus. A capsule with the text, at the bottom center
  of the screen under the pointer.
- The fake backend records the shown text, for the batch tests.

## Acceptance

- [ ] From another app, `portal-status-show` shows the panel without taking
      focus: typing still goes to that app.
- [ ] The panel shows on another Space and over a fullscreen app.
- [ ] Showing new text while shown replaces it; hiding a hidden panel does
      nothing.
- [ ] CTest covers the Lisp functions through the fake backend.
