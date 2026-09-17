;;; anymacs-server-tests.el --- Compiled UI host integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'url)
(require 'anymacs-server)

(when-let* ((program (getenv "ANYMACS_TEST_HOST")))
  (setq anymacs-server-program program))

(defun anymacs-server-test--wait (predicate)
  "Allow asynchronous process work until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro anymacs-server-test--with-host (&rest body)
  (declare (indent 0))
  `(let ((anymacs-server-ready-hook nil)
         (anymacs-server-stopped-hook nil))
     (unwind-protect (progn ,@body)
       (let ((process anymacs--server-process))
         (anymacs-stop-server)
         (when process
           (anymacs-server-test--wait (lambda () (not (process-live-p process)))))))))

(defun anymacs-server-test--get (path)
  "Fetch PATH from the real HTTP listener."
  (let* ((url-proxy-services nil)
         (buffer (url-retrieve-synchronously
                  (concat (anymacs-server-url) path) t t 3)))
    (should (buffer-live-p buffer))
    (unwind-protect
        (with-current-buffer buffer (buffer-string))
      (kill-buffer buffer))))

(ert-deftest anymacs-server-load-is-lazy ()
  (should-not (anymacs-server-url))
  (let ((before (process-list)))
    (load "anymacs-server" nil t)
    (should (equal before (process-list)))))

(ert-deftest anymacs-server-standalone-serves-without-bun-or-source-assets ()
  (let* ((directory (make-temp-file "anymacs-standalone-" t))
         (program (expand-file-name "host" directory)))
    (unwind-protect
        (progn
          (copy-file anymacs-server-program program)
          (let ((anymacs-server-program program)
                (process-environment (cons "PATH=/nonexistent" process-environment)))
            (anymacs-server-test--with-host
              (let ((process (anymacs-start-server)))
                ;; Two simultaneous startup requests must share one child.
                (should (eq process (anymacs-start-server)))
                (anymacs-server-test--wait #'anymacs-server-url)
                (should (eq process (anymacs-start-server)))
                (let ((page (anymacs-server-test--get "/hello")))
                  (should (string-match-p "HTTP/1.1 200" page))
                  (should (string-match-p "text/html; charset=utf-8" page))
                  (should (string-match-p "<h1>Hello, world!</h1>" page)))
                (should (string-match-p "HTTP/1.1 404"
                                        (anymacs-server-test--get "/missing")))
                (anymacs-stop-server)
                (anymacs-server-test--wait (lambda () (not (process-live-p process))))
                (should (= (process-exit-status process) 0))))))
      (delete-directory directory t))))

(ert-deftest anymacs-server-restarts-and-recovers-after-a-crash ()
  (anymacs-server-test--with-host
    (let ((first (anymacs-start-server)))
      (anymacs-server-test--wait #'anymacs-server-url)
      (let ((second (anymacs-restart-server)))
        (should-not (eq first second))
        (anymacs-server-test--wait #'anymacs-server-url)
        (anymacs-server-test--wait (lambda () (not (process-live-p first))))
        ;; The old child's exit must leave the replacement server usable.
        (should (string-match-p "Hello, world!" (anymacs-server-test--get "/hello")))
        (signal-process second 'SIGKILL)
        (anymacs-server-test--wait (lambda () (not (anymacs-server-url))))
        (should-not anymacs--server-process)
        (let ((third (anymacs-start-server)))
          (should-not (eq second third))
          (anymacs-server-test--wait #'anymacs-server-url)
          (should (string-match-p "Hello, world!" (anymacs-server-test--get "/hello"))))))))

(ert-deftest anymacs-server-startup-timeout-cleans-up ()
  (let ((anymacs-server-program "/bin/cat")
        (anymacs-server-start-timeout 0.05))
    (anymacs-server-test--with-host
      (let ((process (anymacs-start-server)))
        (anymacs-server-test--wait (lambda () (not (process-live-p process))))
        (should-not (anymacs-server-url))
        (should-not anymacs--server-process)))))

(ert-deftest anymacs-server-early-exit-clears-startup ()
  (let ((anymacs-server-program "/usr/bin/false"))
    (anymacs-server-test--with-host
      (let ((process (anymacs-start-server)))
        (anymacs-server-test--wait (lambda () (not (process-live-p process))))
        (should-not (anymacs-server-url))
        (should-not anymacs--server-process)))))

(ert-deftest anymacs-server-readiness-can-arrive-in-pieces ()
  (let ((program (make-temp-file "anymacs-handshake-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '%s' '{\"type\":\"ready\",'\nsleep 0.05\n"
                    "printf '%s\\n' '\"protocol\":1,\"port\":12345}'\ncat >/dev/null\n"))
          (set-file-modes program #o700)
          (let ((anymacs-server-program program))
            (anymacs-server-test--with-host
              (anymacs-start-server)
              (anymacs-server-test--wait #'anymacs-server-url)
              (should (equal (anymacs-server-url) "http://127.0.0.1:12345")))))
      (delete-file program))))

(ert-deftest anymacs-server-rejects-incompatible-handshake ()
  (let ((program (make-temp-file "anymacs-handshake-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"protocol\":2,\"port\":12345}'\n"
                    "exec cat >/dev/null\n"))
          (set-file-modes program #o700)
          (let ((anymacs-server-program program))
            (anymacs-server-test--with-host
              (let ((process (anymacs-start-server)))
                (anymacs-server-test--wait (lambda () (not (process-live-p process))))
                (should-not (anymacs-server-url))))))
      (delete-file program))))

;;; anymacs-server-tests.el ends here
