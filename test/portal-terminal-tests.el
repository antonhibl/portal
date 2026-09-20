;;; portal-terminal-tests.el --- Real native terminal checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'portal-terminal)
(declare-function portal--terminal-text "portal-terminal" (&optional id))
(declare-function portal--terminal-input "portal-terminal" (text enter &optional id))
(declare-function portal--terminal-state "portal-terminal" (&optional id))
(declare-function portal--terminal-focus "portal-terminal" (&optional id))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))

(defun portal-terminal-test--wait (predicate)
  "Wait for a real shell or native UI event, with a bounded timeout."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (should (funcall predicate))))

(defmacro portal-terminal-test--session (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (select-frame-set-input-focus (selected-frame))
                  (sit-for 0.1)
                  (portal-terminal) ,@body)
         (portal-terminal-close-all)))))

(ert-deftest portal-terminal-real-shell-survives-hiding-and-resizes ()
  (portal-terminal-test--session
    (let* ((terminal-buffer (current-buffer))
           (directory (make-temp-file "portal-terminal-test-" t))
           (receipt (expand-file-name "receipt" directory))
           (resumed (expand-file-name "resumed" directory))
           (initial (portal--terminal-state)))
      (unwind-protect
          (progn
            (should (plist-get initial :ready))
            (should (plist-get initial :visible))
            (should (plist-get initial :focused))
            (should (string-match-p "[Ll]ayer" (plist-get initial :layer)))
            (portal--terminal-input
             (format "export PORTAL_TEST_VALUE=survived; printf '\\033[32mGHOSTTY_RENDER_OK\\033[0m\\n'; printf '%%s' \"$$\" > %s"
                     (shell-quote-argument receipt)) t)
            (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
            (should (string-match-p "GHOSTTY_RENDER_OK" (portal--terminal-text)))
            (let ((pid (with-temp-buffer
                         (insert-file-contents receipt)
                         (string-to-number (buffer-string)))))
              (should (process-attributes pid))
              ;; Hiding must leave the same shell alive and draining its PTY.
              (switch-to-buffer (get-buffer-create "*scratch*"))
              (redisplay t)
              (should-not (plist-get (portal--terminal-state) :visible))
              (portal--terminal-input
               (format "printf '%%s:%%s' \"$$\" \"$PORTAL_TEST_VALUE\" > %s"
                       (shell-quote-argument resumed)) t)
              (portal-terminal-test--wait (lambda () (file-exists-p resumed)))
              (should (equal (with-temp-buffer
                               (insert-file-contents resumed) (buffer-string))
                             (format "%s:survived" pid)))
              (switch-to-buffer terminal-buffer)
              (redisplay t)
              (should (plist-get (portal--terminal-state) :visible))
              ;; Splitting updates both the actual viewport and PTY dimensions.
              (let ((other (split-window-right)))
                (set-window-buffer other (get-buffer "*scratch*"))
                (redisplay t)
                (portal-terminal-test--wait
                 (lambda () (< (plist-get (portal--terminal-state) :columns)
                               (plist-get initial :columns))))
                (should (equal (plist-get (portal--terminal-state) :edges)
                               (window-inside-pixel-edges (selected-window)))))
              (portal-terminal-close)
              (should-not (portal--terminal-state))
              (portal-terminal-test--wait (lambda () (not (process-attributes pid))))))
        (delete-directory directory t)))))

(ert-deftest portal-terminal-alternate-screen-and-buffer-cleanup ()
  (portal-terminal-test--session
    ;; A real interactive shell writes alternate-screen control sequences.
    ;; Read the actual Ghostty grid to verify the parser and screen switching.
    (portal--terminal-input
     "printf '\\033[?1049h\\033[2J\\033[HPORTAL_ALT_SCREEN'; sleep 1; printf '\\033[?1049l'; printf '\\nPORTAL_PRIMARY_SCREEN\\n'" t)
    (portal-terminal-test--wait
     (lambda () (string-prefix-p "PORTAL_ALT_SCREEN" (portal--terminal-text))))
    (portal-terminal-test--wait
     (lambda () (string-match-p "^PORTAL_PRIMARY_SCREEN" (portal--terminal-text))))
    (kill-buffer (current-buffer))
    (should-not (portal--terminal-state))))

(ert-deftest portal-terminal-native-keys-clipboard-and-focus ()
  (skip-unless (fboundp 'portal-test-native-key))
  (portal-terminal-test--session
    (let ((clipboard (gui-get-selection 'CLIPBOARD 'STRING)))
      (unwind-protect
          (progn
            (select-frame-set-input-focus (selected-frame))
            (portal-terminal-focus)
            ;; Cmd-V and Return traverse AppKit and the native key handler.
            (gui-set-selection 'CLIPBOARD "printf '\\nPORTAL_KEYBOARD_OK\\n'")
            (should (portal-test-native-key 9 (ash 1 20) "v"))
            (should (portal-test-native-key 36 0 "\r"))
            (portal-terminal-test--wait
             (lambda () (string-match-p "^PORTAL_KEYBOARD_OK" (portal--terminal-text))))
            ;; The inspection selected the actual grid; Cmd-C must copy it.
            (should (portal-test-native-key 8 (ash 1 20) "c"))
            (should (string-match-p "PORTAL_KEYBOARD_OK"
                                    (gui-get-selection 'CLIPBOARD 'STRING)))
            (portal--terminal-input "sleep 30" t)
            (accept-process-output nil 0.1)
            (should (portal-test-native-key 8 (ash 1 18) "\C-c"))
            (portal--terminal-input "printf '\\nPORTAL_INTERRUPT_OK\\n'" t)
            (portal-terminal-test--wait
             (lambda () (string-match-p "^PORTAL_INTERRUPT_OK" (portal--terminal-text))))
            ;; Escape remains terminal input. Cmd-Escape alone returns focus.
            (should (portal-test-native-key 53 0 "\e"))
            (should (plist-get (portal--terminal-state) :focused))
            (should (portal-test-native-key 53 (ash 1 20) "\e"))
            (should-not (plist-get (portal--terminal-state) :focused))
            (portal-terminal-focus)
            (should (plist-get (portal--terminal-state) :focused)))
        (gui-set-selection 'CLIPBOARD clipboard)))))

(ert-deftest portal-terminal-windowless-escape-restores-emacs-input ()
  (skip-unless (fboundp 'portal-test-native-post-key))
  (portal-terminal-test--session
    (select-frame-set-input-focus (selected-frame))
    (portal-terminal-focus)
    ;; AppKit may route keys through the key window without event.window.
    (should (portal-test-native-key 53 (ash 1 20) "\e" t))
    (should-not (plist-get (portal--terminal-state) :focused))
    ;; Pump the real Emacs event loop: checking firstResponder alone misses
    ;; broken handoffs that still prevent Emacs commands from receiving keys.
    (should (portal-test-native-post-key 7 (ash 1 18) "\C-x"))
    (should (portal-test-native-post-key 11 0 "b"))
    (let ((keys (with-timeout (2 (ert-fail "Emacs did not receive C-x b"))
                  (read-key-sequence-vector nil))))
      (should (equal keys (vconcat (kbd "C-x b"))))
      (should (eq (key-binding keys) #'switch-to-buffer)))))

(ert-deftest portal-terminal-header-control-returns-focus ()
  (portal-terminal-test--session
    (let* ((button (nth 1 header-line-format))
           (map (get-text-property 0 'local-map button))
           (command (lookup-key map [header-line mouse-1])))
      (should (commandp command))
      (should (plist-get (portal--terminal-state) :focused))
      (call-interactively command)
      (should-not (plist-get (portal--terminal-state) :focused))
      (should (plist-get (portal--terminal-state) :ready))
      (portal-terminal-focus)
      (should (plist-get (portal--terminal-state) :focused)))))

(ert-deftest portal-terminal-invalid-session-id-preserves-live-shell ()
  (portal-terminal-test--session
    (should-error (portal--terminal-close "invalid") :type 'wrong-type-argument)
    (should (plist-get (portal--terminal-state) :ready))
    (should (plist-get (portal--terminal-state) :focused))))

(ert-deftest portal-terminal-native-vim-edits-a-real-file ()
  (skip-unless (and (fboundp 'portal-test-native-key) (executable-find "vim")))
  (portal-terminal-test--session
    (let ((file (make-temp-name (expand-file-name "portal-vim-" temporary-file-directory))))
      (unwind-protect
          (progn
            (select-frame-set-input-focus (selected-frame))
            (portal-terminal-focus)
            (portal--terminal-input
             (format "vim -Nu NONE -n -i NONE %s" (shell-quote-argument file)) t)
            (portal-terminal-test--wait
             (lambda () (string-match-p "\\[New\\]" (portal--terminal-text))))
            (should (portal-test-native-key 34 0 "i"))
            (should (portal-test-native-key 0 0 "Edited inside native Ghostty"))
            (should (portal-test-native-key 53 0 "\e"))
            (should (portal-test-native-key 41 (ash 1 17) ":"))
            (should (portal-test-native-key 13 0 "wq"))
            (should (portal-test-native-key 36 0 "\r"))
            (portal-terminal-test--wait (lambda () (file-exists-p file)))
            (should (equal (with-temp-buffer
                             (insert-file-contents file) (buffer-string))
                           "Edited inside native Ghostty\n")))
        (when (file-exists-p file) (delete-file file))))))

(provide 'portal-terminal-tests)
(defun portal-terminal-test--prefix (&rest strokes)
  "Send native prefix and follow-up STROKES through the real event channel."
  (select-frame-set-input-focus (selected-frame))
  (portal-terminal-focus)
  (should (portal-test-native-key (if (equal portal-terminal-prefix "C-a") 0 11)
                                  (ash 1 18) (if (equal portal-terminal-prefix "C-a") "\C-a" "\C-b") t))
  ;; Deliver immediately, before Lisp processes the notification. This catches
  ;; races that slower, individually evaluated synthetic keys would conceal.
  (dolist (stroke strokes) (should (apply #'portal-test-native-key stroke)))
  (let* ((keys (with-timeout (3 (ert-fail "Native prefix did not wake Emacs"))
                 (read-key-sequence-vector nil)))
         (event (aref keys 0)))
    (ert-info ((format "Received keys: %S" keys))
      (should (eq (car-safe event) 'portal-terminal-prefix)))
    (should (eq (key-binding keys) #'portal-terminal--dispatch))
    (with-timeout (3 (ert-fail "Prefix command did not finish"))
      (portal-terminal--dispatch event))))

(ert-deftest portal-terminal-prefix-creates-splits-and-switches ()
  (portal-terminal-test--session
    (let ((first (current-buffer))
          (first-id portal-terminal--id))
      (portal-terminal-test--prefix '(8 0 "c"))
      (let ((second (current-buffer)))
        (should-not (eq second first))
        (should (= (length (portal-terminal--frame-buffers)) 2))
        (should (plist-get (portal--terminal-state portal-terminal--id) :focused))
        (should-not (plist-get (portal--terminal-state first-id) :visible))
        (portal-terminal-test--prefix '(35 0 "p"))
        (should (eq (current-buffer) first))
        (portal-terminal-test--prefix '(45 0 "n"))
        (should (eq (current-buffer) second))
        (portal-terminal-test--prefix '(37 0 "l"))
        (should (eq (current-buffer) first))
        (portal-terminal-test--prefix (list 23 (ash 1 17) "%"))
        (should (= (length (window-list)) 2))
        (should (= (length (portal-terminal--frame-buffers)) 3))
        (should (plist-get (portal--terminal-state first-id) :visible))
        (let ((right (current-buffer)))
          (portal-terminal-test--prefix '(31 0 "o"))
          (should (eq (current-buffer) first))
          (portal-terminal-test--prefix '(124 0 "\uf703"))
          (should (eq (current-buffer) right))
          (portal-terminal-test--prefix '(6 0 "z"))
          (should (= (length (window-list)) 1))
          (portal-terminal-test--prefix '(6 0 "z"))
          (should (= (length (window-list)) 2))
          (portal-terminal-test--prefix '(7 0 "x") '(16 0 "y"))
          (should-not (buffer-live-p right))
          (should (= (length (window-list)) 1))
          (should (= (length (portal-terminal--frame-buffers)) 2)))))))

(ert-deftest portal-terminal-prefix-literal-and-live-customization ()
  (portal-terminal-test--session
    (let ((original portal-terminal-prefix)
          (directory (make-temp-file "portal-prefix-" t)))
      (unwind-protect
          (dolist (prefix '("C-b" "C-a"))
            (setq portal-terminal-prefix prefix)
            (let ((ready (expand-file-name (concat prefix "-ready") directory))
                  (receipt (expand-file-name prefix directory)))
              (portal--terminal-input
               (format "old=$(stty -g); stty -icanon -echo min 1 time 0; touch %s; dd bs=1 count=1 2>/dev/null | od -An -tu1 > %s; stty \"$old\""
                       (shell-quote-argument ready) (shell-quote-argument receipt)) t)
              (portal-terminal-test--wait (lambda () (file-exists-p ready)))
              ;; Neither unknown commands nor cancellation may leak a byte.
              (portal-terminal-test--prefix '(50 0 "`"))
              (portal-terminal-test--prefix (list 5 (ash 1 18) "\C-g"))
              (portal-terminal-test--prefix
               (list (if (equal prefix "C-a") 0 11) (ash 1 18)
                     (if (equal prefix "C-a") "\C-a" "\C-b")))
              (portal-terminal-test--wait
               (lambda () (and (file-exists-p receipt) (> (file-attribute-size (file-attributes receipt)) 0))))
              (should (= (with-temp-buffer (insert-file-contents receipt)
                                          (string-to-number (buffer-string)))
                         (if (equal prefix "C-a") 1 2)))
              (should (plist-get (portal--terminal-state) :focused))))
        (setq portal-terminal-prefix original)
        (delete-directory directory t)))))

(defvar portal-terminal-test--answer nil)
(defun portal-terminal-test--prompt ()
  (interactive)
  (setq portal-terminal-test--answer (read-string "Answer: ")))

(ert-deftest portal-terminal-prefix-minibuffer-cancel-and-emacs-mode ()
  (portal-terminal-test--session
    (let ((portal-terminal-prefix-map (copy-keymap portal-terminal-prefix-map)))
      (keymap-set portal-terminal-prefix-map "e" #'portal-terminal-test--prompt)
      (setq portal-terminal-test--answer nil)
      (portal-terminal-test--prefix '(14 0 "e") '(4 0 "h") '(34 0 "i") '(36 0 "\r"))
      (should (equal portal-terminal-test--answer "hi"))
      (should-not (active-minibuffer-window))
      (should (plist-get (portal--terminal-state) :focused))
      ;; The tmux command prompt counterpart runs real M-x and stays in Emacs.
      (portal-terminal-test--prefix
       (list 41 (ash 1 17) ":") '(34 0 "i") '(5 0 "g") '(45 0 "n")
       '(31 0 "o") '(15 0 "r") '(14 0 "e") '(36 0 "\r"))
      (should-not (active-minibuffer-window))
      (should-not (plist-get (portal--terminal-state) :focused))
      (portal-terminal-test--prefix '(50 0 "`"))
      (should (plist-get (portal--terminal-state) :focused))
      (portal-terminal-test--prefix (list 5 (ash 1 18) "\C-g"))
      (should (plist-get (portal--terminal-state) :focused))
      (portal-terminal-test--prefix (list 53 (ash 1 20) "\e"))
      (should-not (plist-get (portal--terminal-state) :focused))
      (portal-terminal-test--prefix '(2 0 "d"))
      (should-not (plist-get (portal--terminal-state) :focused))
      (portal-test-native-post-key 7 (ash 1 18) "\C-x")
      (portal-test-native-post-key 11 0 "b")
      (should (equal (with-timeout (3 (ert-fail "Detached editor did not receive C-x b"))
                       (read-key-sequence-vector nil))
                     (vconcat (kbd "C-x b")))))))

(ert-deftest portal-terminal-prefix-follows-native-pane-and-keeps-shells-independent ()
  (portal-terminal-test--session
    (let ((left (current-buffer))
          (left-id portal-terminal--id)
          (left-window (selected-window))
          (directory (make-temp-file "portal-sessions-" t)))
      (unwind-protect
          (progn
            (portal-terminal-split-right)
            (let ((right (current-buffer))
                  (right-id portal-terminal--id)
                  (left-file (expand-file-name "left" directory))
                  (right-file (expand-file-name "right" directory)))
              (portal--terminal-input (format "echo $$ > %s" (shell-quote-argument left-file)) t left-id)
              (portal--terminal-input (format "echo $$ > %s" (shell-quote-argument right-file)) t right-id)
              (portal-terminal-test--wait
               (lambda () (and (file-exists-p left-file) (file-exists-p right-file))))
              (should-not
               (equal (with-temp-buffer (insert-file-contents left-file) (buffer-string))
                      (with-temp-buffer (insert-file-contents right-file) (buffer-string))))
              ;; A click can focus a native pane without selecting its Emacs
              ;; window. The notification must carry the actual session ID.
              (portal--terminal-focus left-id)
              (should (eq (current-buffer) right))
              (portal-test-native-key 11 (ash 1 18) "\C-b" t)
              (portal-test-native-key 8 0 "c")
              (let ((event (aref (with-timeout (3 (ert-fail "No clicked-pane prefix"))
                                  (read-key-sequence-vector nil)) 0)))
                (with-timeout (3 (ert-fail "Clicked-pane command stalled"))
                  (portal-terminal--dispatch event)))
              (should (eq (selected-window) left-window))
              (should-not (memq (current-buffer) (list left right)))
              (should (plist-get (portal--terminal-state right-id) :visible))
              (kill-buffer right)
              (should-not (portal--terminal-state right-id))
              (should (plist-get (portal--terminal-state left-id) :ready))))
        (delete-directory directory t)))))

;;; portal-terminal-tests.el ends here
