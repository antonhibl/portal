;;; anymacs-integration-tests.el --- Native feature coexistence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load both graphical test suites and the test-only event injector first.

(require 'anymacs-terminal-tests)
(declare-function anymacs-test-native-focus-web "test-terminal-input" ())

(defconst anymacs-integration-test--page
  (concat "data:text/html,<title>Ready</title><input autofocus>"
          "<script>let down=0,up=0;"
          "document.onkeydown=()=>down++;"
          "document.onkeyup=()=>{up++;document.title="
          "document.querySelector('input').value+':'+down+':'+up}</script>"))

(defun anymacs-integration-test--emacs-input ()
  "Verify the real editor receives a complete Emacs key sequence."
  (anymacs-test-native-post-key 7 (ash 1 18) "\C-x")
  (anymacs-test-native-post-key 11 0 "b")
  (should (equal (with-timeout (3 (ert-fail "Emacs did not regain keyboard input"))
                   (read-key-sequence-vector nil))
                 (vconcat (kbd "C-x b")))))

(ert-deftest anymacs-integration-focus-and-cleanup-in-either-startup-order ()
  (skip-unless (fboundp 'anymacs-test-native-focus-web))
  (dolist (terminal-first '(t nil))
    (save-window-excursion
      (unwind-protect
          (let (terminal-window web-window terminal-id)
            (delete-other-windows)
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (if terminal-first
                (progn
                  (anymacs-terminal)
                  (setq terminal-window (selected-window)
                        terminal-id anymacs-terminal--id)
                  ;; Attach the second feature while the first owns native focus.
                  (select-window (split-window-right))
                  (anymacs-open-url anymacs-integration-test--page)
                  (setq web-window (selected-window)))
              (anymacs-open-url anymacs-integration-test--page)
              (setq web-window (selected-window))
              (anymacs-test--wait-for-page "Ready" 1)
              (should (anymacs-test-native-focus-web))
              (select-window (split-window-right))
              (anymacs-terminal)
              (setq terminal-window (selected-window)
                    terminal-id anymacs-terminal--id))
            (anymacs-test--wait-for-page "Ready" 1)
            (should (featurep 'anymacs-native-module))
            (should (plist-get (anymacs--terminal-state terminal-id) :ready))
            (anymacs-test--expect-window web-window)
            (select-window terminal-window)
            (anymacs-terminal-focus)
            (anymacs-test-native-key 53 (ash 1 20) "\e")
            (should-not (plist-get (anymacs--terminal-state terminal-id) :focused))
            (anymacs-integration-test--emacs-input)
            (anymacs-terminal-test--prefix '(2 0 "d"))
            (anymacs-integration-test--emacs-input)
            (select-window web-window)
            (should (anymacs-test-native-focus-web))
            (anymacs-test-native-key 0 0 "a")
            ;; A terminal must not swallow WebKit's key-up events.
            (anymacs-test--wait-for-page "a:1:1" 1)
            (anymacs-test-native-key 53 0 "\e")
            (anymacs-integration-test--emacs-input)
            (if terminal-first
                (progn
                  (anymacs-hide)
                  (should-not (anymacs-test--views))
                  (select-window terminal-window)
                  (anymacs-terminal-focus)
                  (should (plist-get (anymacs--terminal-state terminal-id) :focused))
                  (anymacs-terminal-test--prefix '(2 0 "d"))
                  (anymacs-integration-test--emacs-input))
              (anymacs-terminal-close-all)
              (should-not (anymacs--terminal-state terminal-id))
              (should (anymacs-test-native-focus-web))
              (anymacs-test-native-key 11 0 "b")
              (anymacs-test--wait-for-page "ab:2:2" 1)
              (anymacs-test-native-key 53 0 "\e")
              (anymacs-integration-test--emacs-input)))
        (anymacs-hide)
        (anymacs-terminal-close-all)
        (when (get-buffer "*anymacs-web*") (kill-buffer "*anymacs-web*"))))))

(ert-deftest anymacs-integration-frame-deletion-cleans-both-features ()
  (skip-unless (eq window-system 'ns))
  (let ((frame (make-frame))
        (receipt (make-temp-name (expand-file-name "anymacs-frame-shell-" temporary-file-directory)))
        terminal-id terminal-buffer pid)
    (unwind-protect
        (progn
          (select-frame-set-input-focus frame)
          (sit-for 0.1)
          (anymacs-terminal)
          (setq terminal-id anymacs-terminal--id terminal-buffer (current-buffer))
          (anymacs--terminal-input
           (format "echo $$ > %s" (shell-quote-argument receipt)) t)
          (anymacs-terminal-test--wait (lambda () (file-exists-p receipt)))
          (setq pid (with-temp-buffer (insert-file-contents receipt)
                                     (string-to-number (buffer-string))))
          (should (process-attributes pid))
          (select-window (split-window-right))
          (anymacs-open-url anymacs-integration-test--page)
          (anymacs-test--wait-for-page "Ready" 1)
          (delete-frame frame)
          (should-not (anymacs--terminal-state terminal-id))
          (anymacs-terminal-test--wait (lambda () (not (process-attributes pid))))
          (should-not (anymacs-test--views)))
      (when (frame-live-p frame) (delete-frame frame))
      (anymacs-hide)
      (anymacs-terminal-close-all)
      (when (buffer-live-p terminal-buffer) (kill-buffer terminal-buffer))
      (when (file-exists-p receipt) (delete-file receipt))
      (when (get-buffer "*anymacs-web*") (kill-buffer "*anymacs-web*")))))

(provide 'anymacs-integration-tests)
;;; anymacs-integration-tests.el ends here
