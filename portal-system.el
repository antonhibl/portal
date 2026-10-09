;;; portal-system.el --- System-wide actions outside Portal's views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Actions on the system rather than on a Portal view, such as posting a key
;; chord to whatever application is frontmost, or showing a status above
;; every application.  The native module does the work; loading this file
;; does nothing.

(require 'portal-view)

(declare-function portal--key-post "portal-system" (chord))
(declare-function portal--status-show "portal-system" (text))
(declare-function portal--status-hide "portal-system" ())

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

Posting needs Accessibility permission for Emacs.app.  A post without
it makes macOS ask: its alert offers to open System Settings > Privacy
& Security > Device Control and Data Access (Accessibility before macOS
27), where Emacs is now listed, switched off; that post still fails.
Once the switch is on, the next post works without restarting Emacs.
The grant belongs to Emacs's code signature, so a rebuilt Emacs no
longer matches its entry: the switch shows on, yet posts fail and macOS
asks again.  Remove Emacs from that list and add it again.

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

(defun portal-status-show (text)
  "Show TEXT in the status panel, above every application.
The status panel is one small panel at the bottom center of a screen,
on every Space and over fullscreen apps, that shows a line of TEXT,
such as what a command bound with `portal-global-shortcut-set' is
doing while another application is frontmost.  TEXT replaces what the
panel showed; a hidden panel appears on the screen under the pointer.
It stays until `portal-status-hide'.

The panel never takes the keyboard or the mouse: showing it neither
activates Emacs nor changes where keys go.  Return nil."
  (unless (and (stringp text) (not (string-empty-p text)))
    (user-error "A status must be a nonempty string, not %S" text))
  (portal-view--load)
  (unless (fboundp 'portal--status-show)
    (user-error "Rebuild Portal and restart Emacs to show a status"))
  (portal--status-show text)
  nil)

(defun portal-status-hide ()
  "Hide the status panel of `portal-status-show'.
Do nothing when it is hidden.  Return nil."
  (portal-view--load)
  (unless (fboundp 'portal--status-hide)
    (user-error "Rebuild Portal and restart Emacs to hide a status"))
  (portal--status-hide)
  nil)

(provide 'portal-system)
;;; portal-system.el ends here
