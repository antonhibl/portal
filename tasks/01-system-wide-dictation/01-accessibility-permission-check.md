---
status: todo
---
# Accessibility permission check

Let Lisp ask whether Emacs has macOS Accessibility permission, and
optionally ask macOS to prompt for it.

## Plan

- Add a platform primitive to `native/Core/include/portal.h`, for example
  `bool portal_accessibility_trusted(bool prompt, bool *trusted, portal_text *error)`.
  The macOS backend calls `AXIsProcessTrustedWithOptions` with
  `kAXTrustedCheckOptionPrompt` set to PROMPT. With PROMPT, macOS adds Emacs to
  System Settings ▸ Privacy & Security ▸ Accessibility and shows its dialog.
- Register `portal--accessibility-trusted` in `native/Core/emacs.c`, taking an
  optional PROMPT and returning t or nil.
- Implement the primitive in `test/portal-fake-backend.c`, with a way for
  core tests to set the answer.
- Add a public Lisp function, `portal-accessibility-trusted-p`, in a new
  `portal-system.el` for system-wide facts and actions outside Portal's views.
  Follow `portal-global-shortcut.el` for style and docstrings. The docstring
  says the permission belongs to Emacs.app, follows its code signature, and
  needs an Emacs restart after granting.
- Document the primitive where `docs/architecture.md` lists the platform's
  primitives.

## Acceptance

- [ ] `(portal-accessibility-trusted-p)` returns t or nil without showing
      anything.
- [ ] `(portal-accessibility-trusted-p t)` shows the macOS prompt when Emacs
      is not trusted, and only then.
- [ ] A CTest suite covers the binding through the fake backend: both
      answers, the PROMPT argument reaching the platform, and a platform
      error becoming a Lisp `error`.
- [ ] The checks in `CONTRIBUTING.md` pass. Report the manual prompt check
      as run or not run.
