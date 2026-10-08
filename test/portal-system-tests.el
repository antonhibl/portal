;;; portal-system-tests.el --- System-wide actions in batch Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Runs the real Lisp module on the real C core: PORTAL_TEST_MODULE names
;; the module built with test/portal-fake-backend.c, which posts any chord
;; but one with F19, refusing it with a message that names the key and
;; modifiers it was asked to post.  test/portal-shortcuts-tests.c covers
;; what reaches the platform for each chord.

(require 'ert)

(let ((file (getenv "PORTAL_TEST_MODULE")))
  (unless (and file (file-exists-p file))
    (error "Set PORTAL_TEST_MODULE to the fake-backend module"))
  (module-load file))

(require 'portal-system)
(require 'portal-global-shortcut)
(declare-function portal--shortcuts "portal-global-shortcut" ())

(defmacro portal-system-tests--with (&rest body)
  "Run BODY with the native module standing in for macOS's."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'portal-view--load) #'ignore))
     ,@body))

(ert-deftest portal-system-post-key-posts-valid-chords ()
  (portal-system-tests--with
    (dolist (chord '("Command-V" "command-v" "Shift-Option-Command-7" "Control-Space"
                     "Control-F12"))
      (should-not (portal-post-key chord)))
    (should-not (portal--shortcuts))))

(ert-deftest portal-system-post-key-rejects-what-global-shortcuts-reject ()
  (portal-system-tests--with
    (dolist (chord '("" "V" "Shift-V" "Hyper-V" "Command-Command-V" "Command-F21"
                     "Command-!" "Command-V Q" "Command-É"))
      (let ((posting (should-error (portal-post-key chord)))
            (setting (should-error (portal-global-shortcut-set 'portal-system-tests chord
                                                               #'ignore))))
        (should (equal posting setting))))
    (dolist (chord '(nil 86 Command-V))
      (should-error (portal-post-key chord) :type 'user-error))
    (should-not portal-global-shortcut--registrations)))

(ert-deftest portal-system-post-key-signals-the-platform-error ()
  (portal-system-tests--with
    ;; The platform received the parsed key and modifiers: F19, Control and
    ;; Shift.
    (should (equal (should-error (portal-post-key "shift-control-f19"))
                   '(error "Cannot post Control-Shift-F19: The fake may not post F19+3")))))

(provide 'portal-system-tests)
;;; portal-system-tests.el ends here
