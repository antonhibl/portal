;;; portal-integration-tests.el --- Native feature coexistence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load both graphical test suites and the test-only event injector first.

(require 'portal-terminal-tests)
(declare-function portal-test-native-focus-web "test-terminal-input" ())

(defconst portal-integration-test--page
  (concat "data:text/html,<title>Ready</title><input autofocus>"
          "<script>let down=0,up=0;"
          "document.onkeydown=()=>down++;"
          "document.onkeyup=()=>{up++;document.title="
          "document.querySelector('input').value+':'+down+':'+up}</script>"))

(defun portal-integration-test--emacs-input ()
  "Verify the real editor receives a complete Emacs key sequence."
  (portal-test-native-post-key 7 (ash 1 18) "\C-x")
  (portal-test-native-post-key 11 0 "b")
  (should (equal (with-timeout (3 (ert-fail "Emacs did not regain keyboard input"))
                   (read-key-sequence-vector nil))
                 (vconcat (kbd "C-x b")))))

(ert-deftest portal-integration-focus-and-cleanup-in-either-startup-order ()
  (skip-unless (fboundp 'portal-test-native-focus-web))
  (dolist (terminal-first '(t nil))
    (save-window-excursion
      (unwind-protect
          (let (terminal-window web-window terminal-id)
            (delete-other-windows)
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (if terminal-first
                (progn
                  (portal-terminal)
                  (setq terminal-window (selected-window)
                        terminal-id portal-terminal--id)
                  ;; Attach the second feature while the first owns native focus.
                  (select-window (split-window-right))
                  (portal-open-url portal-integration-test--page)
                  (setq web-window (selected-window)))
              (portal-open-url portal-integration-test--page)
              (setq web-window (selected-window))
              (portal-test--wait-for-page "Ready" 1)
              (should (portal-test-native-focus-web))
              (select-window (split-window-right))
              (portal-terminal)
              (setq terminal-window (selected-window)
                    terminal-id portal-terminal--id))
            (portal-test--wait-for-page "Ready" 1)
            (should (featurep 'portal-native-module))
            (should (plist-get (portal--terminal-state terminal-id) :ready))
            (portal-test--expect-window web-window)
            (select-window terminal-window)
            (portal-terminal-focus)
            (portal-test-native-key 53 (ash 1 20) "\e")
            (should-not (plist-get (portal--terminal-state terminal-id) :focused))
            (portal-integration-test--emacs-input)
            (portal-terminal-test--prefix '(2 0 "d"))
            (portal-integration-test--emacs-input)
            (select-window web-window)
            (should (portal-test-native-focus-web))
            (portal-test-native-key 0 0 "a")
            ;; A terminal must not swallow WebKit's key-up events.
            (portal-test--wait-for-page "a:1:1" 1)
            (portal-test-native-key 53 0 "\e")
            (portal-integration-test--emacs-input)
            (if terminal-first
                (progn
                  (portal-hide)
                  (should-not (portal-test--views))
                  (select-window terminal-window)
                  (portal-terminal-focus)
                  (should (plist-get (portal--terminal-state terminal-id) :focused))
                  (portal-terminal-test--prefix '(2 0 "d"))
                  (portal-integration-test--emacs-input))
              (portal-terminal-close-all)
              (should-not (portal--terminal-state terminal-id))
              (should (portal-test-native-focus-web))
              (portal-test-native-key 11 0 "b")
              (portal-test--wait-for-page "ab:2:2" 1)
              (portal-test-native-key 53 0 "\e")
              (portal-integration-test--emacs-input)))
        (portal-hide)
        (portal-terminal-close-all)
        (when (get-buffer "*portal-web*") (kill-buffer "*portal-web*"))))))

(ert-deftest portal-integration-frame-deletion-cleans-both-features ()
  (skip-unless (eq window-system 'ns))
  (let ((frame (make-frame))
        (receipt (make-temp-name (expand-file-name "portal-frame-shell-" temporary-file-directory)))
        terminal-id terminal-buffer pid)
    (unwind-protect
        (progn
          (select-frame-set-input-focus frame)
          (sit-for 0.1)
          (portal-terminal)
          (setq terminal-id portal-terminal--id terminal-buffer (current-buffer))
          (portal--terminal-input
           (format "echo $$ > %s" (shell-quote-argument receipt)) t)
          (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
          (setq pid (with-temp-buffer (insert-file-contents receipt)
                                     (string-to-number (buffer-string))))
          (should (process-attributes pid))
          (select-window (split-window-right))
          (portal-open-url portal-integration-test--page)
          (portal-test--wait-for-page "Ready" 1)
          (delete-frame frame)
          (should-not (portal--terminal-state terminal-id))
          (portal-terminal-test--wait (lambda () (not (process-attributes pid))))
          (should-not (portal-test--views)))
      (when (frame-live-p frame) (delete-frame frame))
      (portal-hide)
      (portal-terminal-close-all)
      (when (buffer-live-p terminal-buffer) (kill-buffer terminal-buffer))
      (when (file-exists-p receipt) (delete-file receipt))
      (when (get-buffer "*portal-web*") (kill-buffer "*portal-web*")))))

(provide 'portal-integration-tests)
;;; portal-integration-tests.el ends here
