;;; portal-system.el --- System-wide actions outside Portal's views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Actions on the system rather than on a Portal view, such as posting a key
;; chord to whatever application is frontmost.  The native module does the
;; posting; loading this file does nothing.

(require 'portal-view)

(declare-function portal--key-post "portal-system" (chord))

(defun portal-post-key (chord)
  "Press and release CHORD in the frontmost application.
CHORD is written as for `portal-global-shortcut-set', such as
\"Command-V\", except that its letter or digit names the character the
key types in the current keyboard layout, not a position on a US
keyboard: on a Dvorak layout, \"Command-V\" still pastes.  Exactly
CHORD's modifiers are held with the key, whatever keys the user holds.

The chord goes to whatever application is frontmost, which may be Emacs
itself.  It is only posted: the application handles it after this
returns, or ignores it, as when no text field has focus.

Posting needs Accessibility permission for Emacs.app.  The first post
without it makes macOS ask, once per Emacs session: its alert offers to
open System Settings > Privacy & Security > Device Control and Data
Access (Accessibility before macOS 27), where Emacs is now listed,
switched off; that post still fails.  Once the switch is on, the next
post works without restarting Emacs.  The grant belongs to Emacs's code
signature, so reinstalling Emacs can break it until Emacs is removed
from that list and added again.

Return nil.  Signal an error and post nothing if CHORD is invalid, if
no key types its character in the current layout, or if Emacs lacks
Accessibility permission."
  (unless (stringp chord)
    (user-error "A key chord must be a string, not %S" chord))
  (portal-view--load)
  (unless (fboundp 'portal--key-post)
    (user-error "Rebuild Portal and restart Emacs to post key chords"))
  (portal--key-post chord)
  nil)

(provide 'portal-system)
;;; portal-system.el ends here
