;;; portal-gui-ert-tests.el --- The graphical runner's verdict -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch with test/ on `load-path'.

(require 'ert)
(require 'portal-gui-ert)

(ert-deftest portal-gui-ert-allows-only-the-named-skips ()
  (let ((stats (ert-run-tests
                (list 'member
                      (make-ert-test :name 'passes :body #'ignore)
                      (make-ert-test :name 'one-display
                                     :body (lambda () (ert-skip "one display")))
                      (make-ert-test :name 'no-injector
                                     :body (lambda () (ert-skip "no injector"))))
                #'ignore)))
    (should-not (portal-gui-ert--verdict stats '(one-display no-injector) nil))
    (should (equal (portal-gui-ert--verdict stats '(one-display) nil)
                   "skipped no-injector"))
    (should (equal (portal-gui-ert--verdict stats nil nil)
                   "skipped one-display, no-injector"))))

(provide 'portal-gui-ert-tests)
;;; portal-gui-ert-tests.el ends here
