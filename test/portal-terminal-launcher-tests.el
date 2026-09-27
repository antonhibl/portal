;;; portal-terminal-launcher-tests.el --- Child exec contract -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'json)

(defun portal-launcher-test--run (program removals restore &rest arguments)
  "Run PROGRAM with ARGUMENTS, REMOVALS and transport RESTORE value."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "PORTAL_TERMINAL_LAUNCH"
            (json-serialize (list :program program :unset (vconcat removals) :restore restore)))
    (with-temp-buffer
      (let ((status (apply #'call-process (getenv "PORTAL_TEST_LAUNCHER") nil t nil arguments)))
        (list status (buffer-string))))))

(ert-deftest portal-launcher-removes-only-requested-values-and-forwards-literal-arguments ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "PORTAL_TEST_REMOVE" "inherited")
    (setenv "PORTAL_TEST_KEEP" "")
    (setenv "PORTAL_TERMINAL_LAUNCH" "parent")
    (dolist (restore '(:null "" "caller ' é"))
      (should
       (equal
        (portal-launcher-test--run
         "/bin/sh" '("PORTAL_TEST_REMOVE") restore "-c"
         "printf '%s|%s|%s|%s|%s' \"${PORTAL_TEST_REMOVE-absent}\" \"${PORTAL_TEST_KEEP-absent}\" \"${PORTAL_TERMINAL_LAUNCH-absent}\" \"$1\" \"$2\""
         "sh" "literal ' é $(exit 91) `pwd`" "")
        (list 0 (concat "absent||" (if (eq restore :null) "absent" restore)
                        "|literal ' é $(exit 91) `pwd`|")))))
    ;; A caller can explicitly remove the transport variable itself.
    (should (equal (portal-launcher-test--run
                    "/bin/sh" '("PORTAL_TERMINAL_LAUNCH") "overridden" "-c"
                    "printf '%s' \"${PORTAL_TERMINAL_LAUNCH-absent}\"")
                   '(0 "absent")))
    (should (equal (getenv "PORTAL_TEST_REMOVE") "inherited"))
    (should (equal (getenv "PORTAL_TERMINAL_LAUNCH") "parent"))))

(ert-deftest portal-launcher-preserves-exit-status-and-rejects-invalid-launches ()
  (should (equal (portal-launcher-test--run "/bin/sh" nil :null "-c" "exit 37") '(37 "")))
  (should (= (car (portal-launcher-test--run "/missing/portal-program" nil :null)) 127))
  (should (= (car (portal-launcher-test--run "/bin/sh" '("INVALID=NAME") :null)) 126)))
