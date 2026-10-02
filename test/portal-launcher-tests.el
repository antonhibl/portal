;;; portal-launcher-tests.el --- Launcher policy checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-launcher)

(ert-deftest portal-launcher-load-is-inert ()
  (should-not portal-launcher-mode)
  (should-not portal-launcher--frame)
  (should-not (memq #'portal-launcher--before-delete delete-frame-functions))
  (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters)))

(ert-deftest portal-launcher-rejects-unsupported-before-loading ()
  (let ((emacs-repository-version "unvalidated")
        (frames (frame-list)))
    (cl-letf (((symbol-function 'portal-view--load) (lambda () (ert-fail "Loaded native code"))))
      (should-error (portal-launcher-show) :type 'user-error)
      (should-not portal-launcher-mode)
      (should (equal frames (frame-list))))))

(ert-deftest portal-launcher-rejects-invalid-input-before-enabling ()
  (dolist (size '(nil (199 420) (720 99) (720) (720 420 3) (720 . 420) (720 420.5)))
    (let ((portal-launcher-size size))
      (should-error (portal-launcher-show) :type 'user-error)))
  (let ((portal-launcher-offset '(0))) (should-error (portal-launcher-show) :type 'user-error))
  (let ((portal-launcher-screen -1)) (should-error (portal-launcher-show) :type 'user-error))
  (let ((portal-launcher-corner-radius -1)) (should-error (portal-launcher-show) :type 'user-error))
  (should-error (portal-launcher-show "missing launcher test buffer") :type 'user-error)
  (should-not portal-launcher-mode))

(ert-deftest portal-launcher-requires-guard-for-native-callers ()
  (skip-unless (featurep 'native-compile))
  (let ((comp-installed-trampolines-h (make-hash-table)))
    (should-error (portal-launcher--check-guard) :type 'user-error)
    (puthash 'modify-frame-parameters t comp-installed-trampolines-h)
    (should-not (portal-launcher--check-guard))))

(ert-deftest portal-launcher-failed-enable-removes-partial-hooks ()
  (skip-unless (featurep 'native-compile))
  (let ((comp-installed-trampolines-h (make-hash-table))
        (native-comp-enable-subr-trampolines nil))
    (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
              ((symbol-function 'portal-view--load) #'ignore)
              ((symbol-function 'portal--launcher-attach) #'ignore))
      (should-error (portal-launcher-mode 1) :type 'user-error)
      (should-not portal-launcher-mode)
      (should-not portal-launcher--frame)
      (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters))
      (should-not (memq #'portal-launcher--before-delete delete-frame-functions)))))

(ert-deftest portal-launcher-role-guard-is-atomic-and-scoped ()
  (let ((portal-launcher--frame (selected-frame)) passed)
    (dolist (change '((undecorated . nil) (fullscreen . fullboth) (parent-frame . other)
                      (tool-bar-lines . 1) (no-focus-on-map . nil) (minibuffer . nil)))
      (should-error
       (portal-launcher--guard-parameters
        (lambda (&rest _) (ert-fail "Mutated frame")) nil
        (list '(background-color . "red") change))
       :type 'user-error))
    (portal-launcher--guard-parameters
     (lambda (_frame parameters) (setq passed parameters)) nil
     '((parent-frame . nil) (undecorated . t) (font . "Menlo 18") (ns-appearance . dark)))
    (should (equal passed '((font . "Menlo 18") (ns-appearance . dark)))))
  (let (portal-launcher--frame)
    (should (equal
             (portal-launcher--guard-parameters (lambda (_frame parameters) parameters)
                                                nil '((fullscreen . fullboth)))
             '((fullscreen . fullboth))))))

(ert-deftest portal-launcher-disable-removes-hooks-without-a-frame ()
  (unwind-protect
      (progn
        (portal-launcher--hooks t)
        (portal-launcher--hooks t)
        (portal-launcher-mode -1)
        (portal-launcher-mode -1)
        (should-not (memq #'portal-launcher--before-delete delete-frame-functions))
        (should-not (memq #'portal-launcher--disable kill-emacs-hook))
        (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters)))
    (portal-launcher--hooks nil)))

(provide 'portal-launcher-tests)
