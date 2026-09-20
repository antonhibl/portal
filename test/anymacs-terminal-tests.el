;;; anymacs-terminal-tests.el --- Real native terminal checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'anymacs-terminal)
(declare-function anymacs--terminal-text "anymacs-terminal" (&optional id))
(declare-function anymacs--terminal-input "anymacs-terminal" (text enter &optional id))
(declare-function anymacs--terminal-state "anymacs-terminal" (&optional id))
(declare-function anymacs--terminal-focus "anymacs-terminal" (&optional id))
(declare-function anymacs-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function anymacs-test-native-post-key "test-terminal-input" (code flags text &optional windowless))

(defun anymacs-terminal-test--wait (predicate)
  "Wait for a real shell or native UI event, with a bounded timeout."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (should (funcall predicate))))

(defmacro anymacs-terminal-test--session (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (select-frame-set-input-focus (selected-frame))
                  (sit-for 0.1)
                  (anymacs-terminal) ,@body)
         (anymacs-terminal-close-all)))))

(ert-deftest anymacs-terminal-real-shell-survives-hiding-and-resizes ()
  (anymacs-terminal-test--session
    (let* ((terminal-buffer (current-buffer))
           (directory (make-temp-file "anymacs-terminal-test-" t))
           (receipt (expand-file-name "receipt" directory))
           (resumed (expand-file-name "resumed" directory))
           (initial (anymacs--terminal-state)))
      (unwind-protect
          (progn
            (should (plist-get initial :ready))
            (should (plist-get initial :visible))
            (should (plist-get initial :focused))
            (should (string-match-p "[Ll]ayer" (plist-get initial :layer)))
            (anymacs--terminal-input
             (format "export ANYMACS_TEST_VALUE=survived; printf '\\033[32mGHOSTTY_RENDER_OK\\033[0m\\n'; printf '%%s' \"$$\" > %s"
                     (shell-quote-argument receipt)) t)
            (anymacs-terminal-test--wait (lambda () (file-exists-p receipt)))
            (should (string-match-p "GHOSTTY_RENDER_OK" (anymacs--terminal-text)))
            (let ((pid (with-temp-buffer
                         (insert-file-contents receipt)
                         (string-to-number (buffer-string)))))
              (should (process-attributes pid))
              ;; Hiding must leave the same shell alive and draining its PTY.
              (switch-to-buffer (get-buffer-create "*scratch*"))
              (redisplay t)
              (should-not (plist-get (anymacs--terminal-state) :visible))
              (anymacs--terminal-input
               (format "printf '%%s:%%s' \"$$\" \"$ANYMACS_TEST_VALUE\" > %s"
                       (shell-quote-argument resumed)) t)
              (anymacs-terminal-test--wait (lambda () (file-exists-p resumed)))
              (should (equal (with-temp-buffer
                               (insert-file-contents resumed) (buffer-string))
                             (format "%s:survived" pid)))
              (switch-to-buffer terminal-buffer)
              (redisplay t)
              (should (plist-get (anymacs--terminal-state) :visible))
              ;; Splitting updates both the actual viewport and PTY dimensions.
              (let ((other (split-window-right)))
                (set-window-buffer other (get-buffer "*scratch*"))
                (redisplay t)
                (anymacs-terminal-test--wait
                 (lambda () (< (plist-get (anymacs--terminal-state) :columns)
                               (plist-get initial :columns))))
                (should (equal (plist-get (anymacs--terminal-state) :edges)
                               (window-inside-pixel-edges (selected-window)))))
              (anymacs-terminal-close)
              (should-not (anymacs--terminal-state))
              (anymacs-terminal-test--wait (lambda () (not (process-attributes pid))))))
        (delete-directory directory t)))))

(ert-deftest anymacs-terminal-alternate-screen-and-buffer-cleanup ()
  (anymacs-terminal-test--session
    ;; A real interactive shell writes alternate-screen control sequences.
    ;; Read the actual Ghostty grid to verify the parser and screen switching.
    (anymacs--terminal-input
     "printf '\\033[?1049h\\033[2J\\033[HANYMACS_ALT_SCREEN'; sleep 1; printf '\\033[?1049l'; printf '\\nANYMACS_PRIMARY_SCREEN\\n'" t)
    (anymacs-terminal-test--wait
     (lambda () (string-prefix-p "ANYMACS_ALT_SCREEN" (anymacs--terminal-text))))
    (anymacs-terminal-test--wait
     (lambda () (string-match-p "^ANYMACS_PRIMARY_SCREEN" (anymacs--terminal-text))))
    (kill-buffer (current-buffer))
    (should-not (anymacs--terminal-state))))

(ert-deftest anymacs-terminal-native-keys-clipboard-and-focus ()
  (skip-unless (fboundp 'anymacs-test-native-key))
  (anymacs-terminal-test--session
    (let ((clipboard (gui-get-selection 'CLIPBOARD 'STRING)))
      (unwind-protect
          (progn
            (select-frame-set-input-focus (selected-frame))
            (anymacs-terminal-focus)
            ;; Cmd-V and Return traverse AppKit and the native key handler.
            (gui-set-selection 'CLIPBOARD "printf '\\nANYMACS_KEYBOARD_OK\\n'")
            (should (anymacs-test-native-key 9 (ash 1 20) "v"))
            (should (anymacs-test-native-key 36 0 "\r"))
            (anymacs-terminal-test--wait
             (lambda () (string-match-p "^ANYMACS_KEYBOARD_OK" (anymacs--terminal-text))))
            ;; The inspection selected the actual grid; Cmd-C must copy it.
            (should (anymacs-test-native-key 8 (ash 1 20) "c"))
            (should (string-match-p "ANYMACS_KEYBOARD_OK"
                                    (gui-get-selection 'CLIPBOARD 'STRING)))
            (anymacs--terminal-input "sleep 30" t)
            (accept-process-output nil 0.1)
            (should (anymacs-test-native-key 8 (ash 1 18) "\C-c"))
            (anymacs--terminal-input "printf '\\nANYMACS_INTERRUPT_OK\\n'" t)
            (anymacs-terminal-test--wait
             (lambda () (string-match-p "^ANYMACS_INTERRUPT_OK" (anymacs--terminal-text))))
            ;; Escape remains terminal input. Cmd-Escape alone returns focus.
            (should (anymacs-test-native-key 53 0 "\e"))
            (should (plist-get (anymacs--terminal-state) :focused))
            (should (anymacs-test-native-key 53 (ash 1 20) "\e"))
            (should-not (plist-get (anymacs--terminal-state) :focused))
            (anymacs-terminal-focus)
            (should (plist-get (anymacs--terminal-state) :focused)))
        (gui-set-selection 'CLIPBOARD clipboard)))))

(ert-deftest anymacs-terminal-windowless-escape-restores-emacs-input ()
  (skip-unless (fboundp 'anymacs-test-native-post-key))
  (anymacs-terminal-test--session
    (select-frame-set-input-focus (selected-frame))
    (anymacs-terminal-focus)
    ;; AppKit may route keys through the key window without event.window.
    (should (anymacs-test-native-key 53 (ash 1 20) "\e" t))
    (should-not (plist-get (anymacs--terminal-state) :focused))
    ;; Pump the real Emacs event loop: checking firstResponder alone misses
    ;; broken handoffs that still prevent Emacs commands from receiving keys.
    (should (anymacs-test-native-post-key 7 (ash 1 18) "\C-x"))
    (should (anymacs-test-native-post-key 11 0 "b"))
    (let ((keys (with-timeout (2 (ert-fail "Emacs did not receive C-x b"))
                  (read-key-sequence-vector nil))))
      (should (equal keys (vconcat (kbd "C-x b"))))
      (should (eq (key-binding keys) #'switch-to-buffer)))))

(ert-deftest anymacs-terminal-header-control-returns-focus ()
  (anymacs-terminal-test--session
    (let* ((button (nth 1 header-line-format))
           (map (get-text-property 0 'local-map button))
           (command (lookup-key map [header-line mouse-1])))
      (should (commandp command))
      (should (plist-get (anymacs--terminal-state) :focused))
      (call-interactively command)
      (should-not (plist-get (anymacs--terminal-state) :focused))
      (should (plist-get (anymacs--terminal-state) :ready))
      (anymacs-terminal-focus)
      (should (plist-get (anymacs--terminal-state) :focused)))))

(ert-deftest anymacs-terminal-invalid-session-id-preserves-live-shell ()
  (anymacs-terminal-test--session
    (should-error (anymacs--terminal-close "invalid") :type 'wrong-type-argument)
    (should (plist-get (anymacs--terminal-state) :ready))
    (should (plist-get (anymacs--terminal-state) :focused))))

(ert-deftest anymacs-terminal-native-vim-edits-a-real-file ()
  (skip-unless (and (fboundp 'anymacs-test-native-key) (executable-find "vim")))
  (anymacs-terminal-test--session
    (let ((file (make-temp-name (expand-file-name "anymacs-vim-" temporary-file-directory))))
      (unwind-protect
          (progn
            (select-frame-set-input-focus (selected-frame))
            (anymacs-terminal-focus)
            (anymacs--terminal-input
             (format "vim -Nu NONE -n -i NONE %s" (shell-quote-argument file)) t)
            (anymacs-terminal-test--wait
             (lambda () (string-match-p "\\[New\\]" (anymacs--terminal-text))))
            (should (anymacs-test-native-key 34 0 "i"))
            (should (anymacs-test-native-key 0 0 "Edited inside native Ghostty"))
            (should (anymacs-test-native-key 53 0 "\e"))
            (should (anymacs-test-native-key 41 (ash 1 17) ":"))
            (should (anymacs-test-native-key 13 0 "wq"))
            (should (anymacs-test-native-key 36 0 "\r"))
            (anymacs-terminal-test--wait (lambda () (file-exists-p file)))
            (should (equal (with-temp-buffer
                             (insert-file-contents file) (buffer-string))
                           "Edited inside native Ghostty\n")))
        (when (file-exists-p file) (delete-file file))))))

(provide 'anymacs-terminal-tests)
(defun anymacs-terminal-test--prefix (&rest strokes)
  "Send native prefix and follow-up STROKES through the real event channel."
  (select-frame-set-input-focus (selected-frame))
  (anymacs-terminal-focus)
  (should (anymacs-test-native-key (if (equal anymacs-terminal-prefix "C-a") 0 11)
                                  (ash 1 18) (if (equal anymacs-terminal-prefix "C-a") "\C-a" "\C-b") t))
  ;; Deliver immediately, before Lisp processes the notification. This catches
  ;; races that slower, individually evaluated synthetic keys would conceal.
  (dolist (stroke strokes) (should (apply #'anymacs-test-native-key stroke)))
  (let* ((keys (with-timeout (3 (ert-fail "Native prefix did not wake Emacs"))
                 (read-key-sequence-vector nil)))
         (event (aref keys 0)))
    (ert-info ((format "Received keys: %S" keys))
      (should (eq (car-safe event) 'anymacs-terminal-prefix)))
    (should (eq (key-binding keys) #'anymacs-terminal--dispatch))
    (with-timeout (3 (ert-fail "Prefix command did not finish"))
      (anymacs-terminal--dispatch event))))

(ert-deftest anymacs-terminal-prefix-creates-splits-and-switches ()
  (anymacs-terminal-test--session
    (let ((first (current-buffer))
          (first-id anymacs-terminal--id))
      (anymacs-terminal-test--prefix '(8 0 "c"))
      (let ((second (current-buffer)))
        (should-not (eq second first))
        (should (= (length (anymacs-terminal--frame-buffers)) 2))
        (should (plist-get (anymacs--terminal-state anymacs-terminal--id) :focused))
        (should-not (plist-get (anymacs--terminal-state first-id) :visible))
        (anymacs-terminal-test--prefix '(35 0 "p"))
        (should (eq (current-buffer) first))
        (anymacs-terminal-test--prefix '(45 0 "n"))
        (should (eq (current-buffer) second))
        (anymacs-terminal-test--prefix '(37 0 "l"))
        (should (eq (current-buffer) first))
        (anymacs-terminal-test--prefix (list 23 (ash 1 17) "%"))
        (should (= (length (window-list)) 2))
        (should (= (length (anymacs-terminal--frame-buffers)) 3))
        (should (plist-get (anymacs--terminal-state first-id) :visible))
        (let ((right (current-buffer)))
          (anymacs-terminal-test--prefix '(31 0 "o"))
          (should (eq (current-buffer) first))
          (anymacs-terminal-test--prefix '(124 0 "\uf703"))
          (should (eq (current-buffer) right))
          (anymacs-terminal-test--prefix '(6 0 "z"))
          (should (= (length (window-list)) 1))
          (anymacs-terminal-test--prefix '(6 0 "z"))
          (should (= (length (window-list)) 2))
          (anymacs-terminal-test--prefix '(7 0 "x") '(16 0 "y"))
          (should-not (buffer-live-p right))
          (should (= (length (window-list)) 1))
          (should (= (length (anymacs-terminal--frame-buffers)) 2)))))))

(ert-deftest anymacs-terminal-prefix-literal-and-live-customization ()
  (anymacs-terminal-test--session
    (let ((original anymacs-terminal-prefix)
          (directory (make-temp-file "anymacs-prefix-" t)))
      (unwind-protect
          (dolist (prefix '("C-b" "C-a"))
            (setq anymacs-terminal-prefix prefix)
            (let ((ready (expand-file-name (concat prefix "-ready") directory))
                  (receipt (expand-file-name prefix directory)))
              (anymacs--terminal-input
               (format "old=$(stty -g); stty -icanon -echo min 1 time 0; touch %s; dd bs=1 count=1 2>/dev/null | od -An -tu1 > %s; stty \"$old\""
                       (shell-quote-argument ready) (shell-quote-argument receipt)) t)
              (anymacs-terminal-test--wait (lambda () (file-exists-p ready)))
              ;; Neither unknown commands nor cancellation may leak a byte.
              (anymacs-terminal-test--prefix '(50 0 "`"))
              (anymacs-terminal-test--prefix (list 5 (ash 1 18) "\C-g"))
              (anymacs-terminal-test--prefix
               (list (if (equal prefix "C-a") 0 11) (ash 1 18)
                     (if (equal prefix "C-a") "\C-a" "\C-b")))
              (anymacs-terminal-test--wait
               (lambda () (and (file-exists-p receipt) (> (file-attribute-size (file-attributes receipt)) 0))))
              (should (= (with-temp-buffer (insert-file-contents receipt)
                                          (string-to-number (buffer-string)))
                         (if (equal prefix "C-a") 1 2)))
              (should (plist-get (anymacs--terminal-state) :focused))))
        (setq anymacs-terminal-prefix original)
        (delete-directory directory t)))))

(defvar anymacs-terminal-test--answer nil)
(defun anymacs-terminal-test--prompt ()
  (interactive)
  (setq anymacs-terminal-test--answer (read-string "Answer: ")))

(ert-deftest anymacs-terminal-prefix-minibuffer-cancel-and-emacs-mode ()
  (anymacs-terminal-test--session
    (let ((anymacs-terminal-prefix-map (copy-keymap anymacs-terminal-prefix-map)))
      (keymap-set anymacs-terminal-prefix-map "e" #'anymacs-terminal-test--prompt)
      (setq anymacs-terminal-test--answer nil)
      (anymacs-terminal-test--prefix '(14 0 "e") '(4 0 "h") '(34 0 "i") '(36 0 "\r"))
      (should (equal anymacs-terminal-test--answer "hi"))
      (should-not (active-minibuffer-window))
      (should (plist-get (anymacs--terminal-state) :focused))
      ;; The tmux command prompt counterpart runs real M-x and stays in Emacs.
      (anymacs-terminal-test--prefix
       (list 41 (ash 1 17) ":") '(34 0 "i") '(5 0 "g") '(45 0 "n")
       '(31 0 "o") '(15 0 "r") '(14 0 "e") '(36 0 "\r"))
      (should-not (active-minibuffer-window))
      (should-not (plist-get (anymacs--terminal-state) :focused))
      (anymacs-terminal-test--prefix '(50 0 "`"))
      (should (plist-get (anymacs--terminal-state) :focused))
      (anymacs-terminal-test--prefix (list 5 (ash 1 18) "\C-g"))
      (should (plist-get (anymacs--terminal-state) :focused))
      (anymacs-terminal-test--prefix (list 53 (ash 1 20) "\e"))
      (should-not (plist-get (anymacs--terminal-state) :focused))
      (anymacs-terminal-test--prefix '(2 0 "d"))
      (should-not (plist-get (anymacs--terminal-state) :focused))
      (anymacs-test-native-post-key 7 (ash 1 18) "\C-x")
      (anymacs-test-native-post-key 11 0 "b")
      (should (equal (with-timeout (3 (ert-fail "Detached editor did not receive C-x b"))
                       (read-key-sequence-vector nil))
                     (vconcat (kbd "C-x b")))))))

(ert-deftest anymacs-terminal-prefix-follows-native-pane-and-keeps-shells-independent ()
  (anymacs-terminal-test--session
    (let ((left (current-buffer))
          (left-id anymacs-terminal--id)
          (left-window (selected-window))
          (directory (make-temp-file "anymacs-sessions-" t)))
      (unwind-protect
          (progn
            (anymacs-terminal-split-right)
            (let ((right (current-buffer))
                  (right-id anymacs-terminal--id)
                  (left-file (expand-file-name "left" directory))
                  (right-file (expand-file-name "right" directory)))
              (anymacs--terminal-input (format "echo $$ > %s" (shell-quote-argument left-file)) t left-id)
              (anymacs--terminal-input (format "echo $$ > %s" (shell-quote-argument right-file)) t right-id)
              (anymacs-terminal-test--wait
               (lambda () (and (file-exists-p left-file) (file-exists-p right-file))))
              (should-not
               (equal (with-temp-buffer (insert-file-contents left-file) (buffer-string))
                      (with-temp-buffer (insert-file-contents right-file) (buffer-string))))
              ;; A click can focus a native pane without selecting its Emacs
              ;; window. The notification must carry the actual session ID.
              (anymacs--terminal-focus left-id)
              (should (eq (current-buffer) right))
              (anymacs-test-native-key 11 (ash 1 18) "\C-b" t)
              (anymacs-test-native-key 8 0 "c")
              (let ((event (aref (with-timeout (3 (ert-fail "No clicked-pane prefix"))
                                  (read-key-sequence-vector nil)) 0)))
                (with-timeout (3 (ert-fail "Clicked-pane command stalled"))
                  (anymacs-terminal--dispatch event)))
              (should (eq (selected-window) left-window))
              (should-not (memq (current-buffer) (list left right)))
              (should (plist-get (anymacs--terminal-state right-id) :visible))
              (kill-buffer right)
              (should-not (anymacs--terminal-state right-id))
              (should (plist-get (anymacs--terminal-state left-id) :ready))))
        (delete-directory directory t)))))

;;; anymacs-terminal-tests.el ends here
