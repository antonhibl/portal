;;; portal-toolbar-tests.el --- Native toolbar command contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'portal-input)

(ert-deftest portal-toolbar-commands-read-native-state ()
  (let ((native-value 100) calls)
    (cl-letf (((symbol-function 'portal-view-target) (lambda (&rest _) "web:3"))
              ((symbol-function 'portal--toolbar-action)
               (lambda (target action)
                 (push (list target action) calls)
                 (when (equal action "increase") (setq native-value 110))
                 (format "{\"value\":%d,\"toc\":true}" native-value))))
      (should (= (portal-zoom-in) 110))
      ;; A native button click must not leave a stale Lisp copy.
      (setq native-value 175)
      (should (= (portal-zoom-out) 175))
      (should (portal-toggle-toc))
      (should (equal (car calls) '("web:3" "toc")))
      (should-error (portal-terminal-text-size-increase) :type 'user-error))))

(ert-deftest portal-toolbar-setting-applies-live ()
  (let (values)
    (cl-letf (((symbol-function 'portal--toolbar) (lambda (value) (push value values))))
      (let ((portal-toolbar nil))
        (setq portal-toolbar t)
        (setq portal-toolbar nil))
      (should (equal (reverse values) '(nil t nil t))))))

(ert-deftest portal-toolbar-find-keeps-field-focus-after-prefix ()
  (let ((portal-input--resume t))
    (cl-letf (((symbol-function 'portal-view-target) (lambda (&rest _) "web:7"))
              ((symbol-function 'portal--toolbar-action) (lambda (&rest _) "{\"find\":true}")))
      (portal-find)
      (should-not portal-input--resume))))

(ert-deftest portal-toolbar-input-mode-leaves-header-alone ()
  (with-temp-buffer
    (setq-local header-line-format "User header")
    (portal-input-mode 1)
    (should (equal header-line-format "User header"))
    (portal-input-mode -1)
    (should (equal header-line-format "User header"))))
