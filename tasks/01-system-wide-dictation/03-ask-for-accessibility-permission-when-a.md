---
status: done
---
# Ask for Accessibility permission when a post needs it

Today a post without Accessibility permission fails with "allow it in System
Settings > Privacy & Security > Accessibility, then restart Emacs", and the
user has to find the pane and add Emacs by hand. Have macOS ask instead, as
other apps do.

## Sequence

1. Ask only when a post needs the permission, never when Portal loads or a
   global shortcut is set. Apple's guidance is to request a permission in
   context, when the feature that needs it is used.
2. A post without permission calls `AXIsProcessTrustedWithOptions` with
   `kAXTrustedCheckOptionPrompt`. macOS shows its own alert ("Emacs would
   like to control this computer using accessibility features") with Open
   System Settings and Deny, and adds Emacs to the Accessibility list,
   switched off, so the user only flips the switch. The post still fails
   with an error; the caller has already put its text where it wants it
   (dictation: the clipboard).
3. Prompt at most once per Emacs session; later failed posts only signal
   the error. First check whether macOS already suppresses repeated
   alerts: if it does, drop this guard.
4. After the grant, the next post works. Check whether that needs an Emacs
   restart, as the docs say today. Rectangle polls `AXIsProcessTrusted()`
   every 0.3 s and carries on once it is true, without relaunching
   (`Rectangle/AccessibilityAuthorization/AccessibilityAuthorization.swift`).
   If posting works without a restart, remove "then restart Emacs" from the
   error, the `portal-post-key` docstring, `docs/architecture.md` and the
   dictation README; if not, keep it and say why there.

## Where

- `native/KeyPost.swift`, the check before posting. `portal_key_post` stays
  a primitive that posts or fails; prompting is the macOS platform's
  business ([ADR 0003](../../docs/adr/0003-platform-interface-primitives.md)).
- The dictation README's decision "Accessibility permission is granted once
  by hand" changes to: macOS asks on the first post that needs it.

## Acceptance

- [ ] With Emacs not in the Accessibility list (reset with `tccutil reset
      Accessibility <Emacs's bundle ID>` in the VM), the first
      `(portal-post-key "Command-V")` shows the system alert, signals an
      error, and Emacs appears in the list switched off.
- [ ] A second failed post in the same session shows no alert, or the
      task records that macOS suppresses it.
- [ ] After granting, posting works, with or without a restart as found
      in step 4, and the error, docstring and docs say the same.
- [ ] Loading Portal and setting global shortcuts never prompt.
