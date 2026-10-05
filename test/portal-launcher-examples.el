;;; portal-launcher-examples.el --- The README's launcher examples -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Tests evaluate the README's user configuration itself, so the documented
;; launchers are the tested ones.  An example is the Emacs Lisp block that
;; follows a line "<!-- example: NAME -->".

(require 'cl-lib)

(defconst portal-launcher-examples--readme
  (expand-file-name "../README.md"
                    (file-name-directory (or load-file-name
                                             (bound-and-true-p byte-compile-current-file)
                                             buffer-file-name))))

(defun portal-launcher-examples-form (name &optional chords)
  "Return the README's example NAME as one form, for `eval'.
CHORDS is an alist of (CHORD . REPLACEMENT): a test's own chords for the
example's, so that another running Emacs's shortcuts cannot conflict."
  (with-temp-buffer
    (insert-file-contents portal-launcher-examples--readme)
    (unless (re-search-forward
             (format "^<!-- example: %s -->\n```elisp\n" (regexp-quote name)) nil t)
      (error "README.md has no example %s" name))
    (let ((start (point)))
      (re-search-forward "^```$")
      (cl-sublis chords
                 (car (read-from-string
                       (concat "(progn\n" (buffer-substring-no-properties
                                           start (match-beginning 0))
                               ")")))
                 :test #'equal))))

(defvar portal-launcher-examples--binding nil
  "The value of `lexical-binding' while the last configuration file loaded.")

(defun portal-launcher-examples-load (names lexical &optional chords)
  "Load the README's examples NAMES from a file, as a configuration is loaded.
The file's cookie sets `lexical-binding' to LEXICAL.  Emacs 31 still loads a
file without the cookie with dynamic binding, so user configuration may run
either way.  CHORDS is as for `portal-launcher-examples-form'.  Return the
binding the file was loaded with."
  (let ((file (make-temp-file "portal-launcher-config" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (format ";;; config.el --- Test configuration -*- lexical-binding: %s -*-\n"
                            (if lexical "t" "nil")))
            (dolist (name names)
              (dolist (form (cdr (portal-launcher-examples-form name chords)))
                (prin1 form (current-buffer))
                (insert "\n")))
            (insert "(setq portal-launcher-examples--binding lexical-binding)\n"))
          (setq portal-launcher-examples--binding 'unloaded)
          (load file nil t t)
          portal-launcher-examples--binding)
      (delete-file file))))

(provide 'portal-launcher-examples)
;;; portal-launcher-examples.el ends here
