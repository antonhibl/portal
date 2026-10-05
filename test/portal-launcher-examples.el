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

(provide 'portal-launcher-examples)
;;; portal-launcher-examples.el ends here
