---
status: done
---
# Post a key chord to the frontmost app

Let Lisp post a key chord, such as Command-V, to the frontmost application.

## Plan

- Add a platform primitive to `native/Core/include/portal.h`, for example
  `bool portal_key_post(uint32_t key, uint32_t modifiers, portal_text *error)`.
- The core parses the chord with the parser in `native/Core/shortcuts.c`,
  so chords read as global shortcuts do (`"Command-V"`). One difference,
  documented in `portal.h`: here a letter or digit names the character the
  current keyboard layout types with MODIFIERS held, not a US key position.
  Resolving it is the platform's job.
- The macOS backend:
  - Fails with an error naming Accessibility when `AXIsProcessTrusted()` is
    false. macOS would otherwise drop the events silently.
  - Finds the virtual key for the character in the current layout with
    `UCKeyTranslate` (Command state included), falling back to the current
    ASCII-capable layout when the input source has no layout data. It fails
    without posting when no key types the character. OpenWhispr's
    `resources/macos-fast-paste.swift` is a reference.
  - Posts key down and key up with `CGEvent`, with exactly MODIFIERS as flags,
    so modifiers the user still holds do not leak into the chord.
- Register `portal--key-post` in `native/Core/emacs.c`, and implement the
  primitive in `test/portal-fake-backend.c`, recording what it was asked to
  post.
- Add a public `portal-post-key` in a new `portal-system.el`, for
  system-wide actions outside Portal's views. Follow
  `portal-global-shortcut.el` for style. The docstring says the chord goes to
  whatever app is frontmost, possibly Emacs itself, and that posting needs
  Accessibility permission for Emacs.app: granted once in System Settings ▸
  Privacy & Security ▸ Accessibility, tied to Emacs's code signature, and
  seen only after an Emacs restart.
- Document the primitive with the other platform primitives in
  `docs/architecture.md`.

## Acceptance

- [ ] `(portal-post-key "Command-V")` pastes the clipboard into the focused
      text field of another app, such as TextEdit.
- [ ] With a Dvorak or other non-QWERTY layout, the same call still pastes.
- [ ] Without Accessibility permission it signals an error saying so and
      posts nothing.
- [ ] An invalid chord signals the same errors as `portal-global-shortcut-set`.
- [ ] CTest covers the binding through the fake backend: the parsed key and
      modifiers reach the platform, invalid chords never do, and platform
      errors become Lisp errors.
- [ ] The checks in `CONTRIBUTING.md` pass. Posting into another app and the
      layout check are manual; report each as run or not run. If a VM GUI
      check is added, `docs/testing.md` says whether its Emacs has
      Accessibility.
