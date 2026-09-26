;;; portal-tests.el --- Real WebKit loading checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a disposable graphical Emacs, with portal.el already loaded.  Web
;; buffers and placement are tested in batch by portal-web-tests.el.

(require 'ert)
(require 'portal)

(declare-function portal--inspect "portal-view" (target))
(declare-function portal--web-load "portal-web" (target url))

(defmacro portal-test--with-web (&rest body)
  "Run BODY in one window, then kill the web buffers it opened."
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((buffers (portal-view-buffers 'web)))
       (save-window-excursion
         (unwind-protect
             (progn (delete-other-windows) ,@body)
           (dolist (buffer (portal-view-buffers 'web))
             (unless (memq buffer buffers) (kill-buffer buffer))))))))

(defun portal-test--wait-for-page (title &optional target)
  "Wait for web view TARGET to finish loading a page titled TITLE.
TARGET defaults to the selected pane's view.  Return its state."
  (let ((target (or target (portal-view-target)))
        (deadline (+ (float-time) 15))
        state)
    (while (progn
             (redisplay t)
             (setq state (portal--inspect target))
             (and (< (float-time) deadline)
                  (not (and (equal (plist-get state :title) title)
                            (not (plist-get state :loading))))))
      (sleep-for 0.05))
    (should (equal (plist-get state :title) title))
    (should-not (plist-get state :loading))
    (should-not (plist-get state :error))
    state))

(defun portal-test--shown (target window)
  "Whether web view TARGET is visible within WINDOW's text area."
  (redisplay t)
  (let ((state (portal--inspect target)))
    (and (plist-get state :visible)
         (equal (plist-get state :edges) (window-inside-pixel-edges window)))))

(ert-deftest portal-web-runs-javascript-and-keeps-its-page-while-hidden ()
  (portal-test--with-web
    (portal-open-url
     "data:text/html,<title>Initial</title><h1>WebKit works</h1><script>document.title='JS works'</script>")
    (portal-test--wait-for-page "JS works")
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (portal-test--shown target (selected-window)))
      (quit-window)
      (redisplay t)
      (should-not (plist-get (portal--inspect target) :visible))
      (switch-to-buffer buffer)
      (should (portal-test--shown target (selected-window)))
      (portal-test--wait-for-page "JS works")
      (kill-buffer buffer)
      (should-not (portal--inspect target)))))

(ert-deftest portal-web-loads-local-file-with-relative-javascript ()
  (portal-test--with-web
    (let* ((directory (make-temp-file "portal-web-" t))
           (file (expand-file-name "Résumé #%?.HTML" directory)))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "<title>Initial</title><script src='script.js'></script>"))
            (with-temp-file (expand-file-name "script.js" directory)
              (insert "document.title = 'Local assets work';"))
            (with-temp-buffer
              (setq buffer-file-name file)
              (call-interactively #'portal-preview-html))
            (portal-test--wait-for-page "Local assets work"))
        (delete-directory directory t)))))

(ert-deftest portal-web-loads-again-and-rejects-invalid-urls ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>First</title>")
    (let ((target (portal-view-target)))
      (portal-test--wait-for-page "First")
      (should-error (portal--web-load target 42) :type 'wrong-type-argument)
      (dolist (url '("relative/path" "javascript:alert(1)" "https://"))
        (should-error (portal--web-load target url)))
      (should-error (portal--web-load "web:999999" "about:blank"))
      (portal-test--wait-for-page "First")
      (portal--web-load target "data:text/html,<title>Second</title>")
      (portal-test--wait-for-page "Second"))))

(provide 'portal-tests)
