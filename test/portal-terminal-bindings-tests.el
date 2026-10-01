;;; portal-terminal-bindings-tests.el --- Runtime registration checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-terminal)

(defmacro portal-bindings-test--maps (&rest body)
  (declare (indent 0))
  `(let ((portal-terminal-native-map (make-sparse-keymap))
         (portal-terminal-quick-native-map (make-sparse-keymap))
         (portal-terminal--native-maps (cons (make-sparse-keymap) (make-sparse-keymap))))
     ,@body))

(ert-deftest portal-bindings-live-registration-and-scope ()
  (portal-bindings-test--maps
    (portal-terminal-bind-key portal-terminal-native-map "s-j" #'ignore)
    (portal-terminal-bind-key portal-terminal-quick-native-map "s-j" #'portal-terminal-toggle)
    (should (eq (lookup-key (car portal-terminal--native-maps) (kbd "s-j")) #'ignore))
    (should (eq (lookup-key (cdr portal-terminal--native-maps) (kbd "s-j")) #'portal-terminal-toggle))
    (portal-terminal-unbind-key portal-terminal-quick-native-map "s-j")
    (should (eq (lookup-key (cdr portal-terminal--native-maps) (kbd "s-j")) #'ignore))
    (portal-terminal-unbind-key portal-terminal-native-map "s-j")
    (should-not (lookup-key (car portal-terminal--native-maps) (kbd "s-j")))
    (should-not (lookup-key (cdr portal-terminal--native-maps) (kbd "s-j")))))

(ert-deftest portal-bindings-prefixes-register-only-first-chord ()
  (portal-bindings-test--maps
    (portal-terminal-bind-key portal-terminal-native-map "C-x a b" #'ignore)
    (portal-terminal-bind-key portal-terminal-native-map "C-x <f5>" #'portal-terminal-unfocus)
    (let* ((compiled (portal-terminal--compile-native-map portal-terminal-native-map))
           (entries (cdr compiled)))
      (should (= (length entries) 1))
      (should (equal (alist-get 'character (aref entries 0)) "x"))
      (should (eq (lookup-key (car compiled) (kbd "C-x a b")) #'ignore)))
    (portal-terminal-unbind-key portal-terminal-native-map "C-x a b")
    (should (keymapp (lookup-key (car portal-terminal--native-maps) (kbd "C-x"))))
    (portal-terminal-unbind-key portal-terminal-native-map "C-x <f5>")
    (should-not (lookup-key (car portal-terminal--native-maps) (kbd "C-x")))))

(ert-deftest portal-bindings-raw-edits-require-explicit-refresh ()
  (portal-bindings-test--maps
    (keymap-set portal-terminal-native-map "s-j" #'ignore)
    (should-not (lookup-key (car portal-terminal--native-maps) (kbd "s-j")))
    (portal-terminal-refresh-bindings)
    (should (eq (lookup-key (car portal-terminal--native-maps) (kbd "s-j")) #'ignore))
    (keymap-set portal-terminal-native-map "s-j" #'portal-terminal-unfocus)
    (should (eq (lookup-key (car portal-terminal--native-maps) (kbd "s-j")) #'ignore))
    (portal-terminal-refresh-bindings)
    (should (eq (lookup-key (car portal-terminal--native-maps) (kbd "s-j")) #'portal-terminal-unfocus))))

(ert-deftest portal-bindings-invalid-edits-are-atomic ()
  (portal-bindings-test--maps
    (portal-terminal-bind-key portal-terminal-native-map "s-j" #'ignore)
    (dolist (key '("a" "<f5>" "s-<escape>" "s-S-1"))
      (should-error (portal-terminal-bind-key portal-terminal-native-map key #'ignore))
      (should (equal portal-terminal-native-map
                     (car portal-terminal--native-maps))))
    ;; C-b, once the prefix, is a chord like any other.
    (portal-terminal-bind-key portal-terminal-native-map "C-b x" #'ignore)
    (should (eq (lookup-key (car portal-terminal--native-maps) (kbd "C-b x")) #'ignore))
    (should (eq (lookup-key (car portal-terminal--native-maps) (kbd "s-j")) #'ignore))
    (should-error (portal-terminal-bind-key (make-sparse-keymap) "s-j" #'ignore))))

(ert-deftest portal-bindings-native-publication-and-failure-rollback ()
  (portal-bindings-test--maps
    (let (payload)
      (cl-letf (((symbol-function 'portal--terminal-bindings)
                 (lambda (json) (setq payload (json-parse-string json :object-type 'alist)))))
        (portal-terminal-bind-key portal-terminal-quick-native-map "s-`" #'portal-terminal-toggle)
        (should (= (length (alist-get 'regular payload)) 0))
        (should (= (length (alist-get 'quick payload)) 1)))
      (cl-letf (((symbol-function 'portal--terminal-bindings)
                 (lambda (_) (error "Native registration rejected"))))
        (should-error (portal-terminal-bind-key portal-terminal-quick-native-map "s-j" #'ignore))
        (should-not (lookup-key portal-terminal-quick-native-map (kbd "s-j")))
        (should (eq (lookup-key (cdr portal-terminal--native-maps) (kbd "s-`"))
                    #'portal-terminal-toggle))))))
