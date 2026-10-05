---
id: launcher-persistent-buffer
status: done
---

# Keep custom buffer UIs interactive after their setup function returns

Reconciled from the completed historical task in `project.org`.
Org `CUSTOM_ID`: `launcher-persistent-buffer`.
Org `ID`: `e21d74b9-3d4c-412c-93a3-84961f7109f4`.
This Markdown document is the task's source of truth.

## Problem and outcome

A dashboard or hello-world function usually creates a buffer and returns.
The current session immediately hides that buffer. Add explicit session
lifetime control so a caller can finish setup and leave a usable panel open.

## Blocked by

Per-invocation presentation supplies buffer layout, ordinary function callbacks
and scoped appearance settings. This prerequisite is complete in PR #77;
its historical record is `project.org`, `CUSTOM_ID: launcher-presentation-options`.

## Interface and decisions

```emacs-lisp
(portal-launcher-present
 (lambda ()
   (switch-to-buffer (get-buffer-create "*Hello*"))
   (erase-buffer)
   (insert "Hello world!")
   (special-mode))
 :kind 'buffer :mode-line nil :keep-open t)
```

- `:keep-open` defaults to nil independently of `:kind`. A prompt normally
  closes on return; a buffer setup function can explicitly keep its UI open.
- Keep one active presentation, with working buffer keymaps and session-local
  cancellation while open. Do not ask callers to manage recursive edits,
  session identifiers or native teardown.
- Keep ownership of user buffers with their callers. Hiding a persistent
  presentation must not kill the supplied buffer or discard its contents.

## Plan

- Extend the existing session lifecycle to include the period after setup
  returns. Preserve display rules, key handling and focus-loss delivery for
  the whole interaction, including minibuffers opened by later buffer commands.
- Before implementation, record whether `:keep-open t` waits for dismissal or
  returns immediately, its return-value behavior, and whether it is valid with
  `:kind 'minibuffer`. Document these choices as part of the public contract.
- Preserve second-invocation dismissal, explicit `portal-launcher-hide` and
  `portal-launcher-cancel`, error cleanup, deletion and disable. Ensure later
  command errors and queued blur events cannot strand or dismiss a newer UI.
- Test through a small real buffer UI with a local command that opens a prompt;
  no external application package is needed.

## Acceptance

- [x] The hello-world example remains visible after its setup function finishes;
  a local buffer command and a subsequent minibuffer prompt accept real input.
- [x] Omitting `:keep-open` retains close-on-return semantics and existing
  command results. Invalid lifetime/layout combinations fail before display.
- [x] Escape, C-g, click-away, a second invocation, hide, deletion and disable
  clean up the complete interaction without leaked recursive edits or hooks.
- [x] Setup failures and later command failures are recoverable; a new
  presentation works, user buffers survive, and stale events are ignored.
- [x] Cancellation restores focus appropriately; successful external actions
  and click-away retain their destination's focus. Relevant batch and real
  graphical session/input checks pass.

## Outcome and lifetime policy

Implemented in [PR #79](https://github.com/xiaoxinghu/portal/pull/79), commit
`a66f638`. `portal-launcher-present` accepts `:keep-open t` for buffer panels
only, waits in a recursive edit after setup returns, and returns nil when the
panel is dismissed. Invalid values or a minibuffer/keep-open combination fail
before display or cancellation of an existing session.

The same session retains its keymaps, display rules, nested prompts and cleanup.
Setup errors propagate after cleanup; later command errors leave the panel
usable. Recorded focus loss and a session-scoped post-command check prevent a
command error from discarding the only dismissal event. Hiding kills no user
buffer. No native code changed.

The repeatable hello-world recipe in `README.md` binds `inhibit-read-only`
before erasing its special-mode buffer; use that recipe when invoking it again.

## Completion evidence

The matching DONE task in `project.org` has all five acceptance items checked
and records the following historical verification (not rerun for this status
reconciliation):

- `./build.sh` and all 34 CTest suites passed, including 29 launcher tests.
- The 20 launcher GUI tests passed in three runs after the last change,
  covering persistent-buffer input, later prompts, dismissal and error recovery.
- Daily-use and global-shortcut graphical tests passed; the README example was
  exercised twice and changed Lisp byte-compiled without warnings.
- Physical C-g and a real mouse click-away were not repeated in that task;
  retain that evidence limit rather than claiming fresh manual acceptance.
