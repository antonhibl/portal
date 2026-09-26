;;; portal-view-tests.el --- Portal view lifecycle against the fake module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real buffers and windows drive `portal-view.el'; only the native module is
;; replaced.  Batch Emacs never runs window change hooks, so tests sync.
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)

(defmacro portal-view-test--environment (&rest body)
  "Run BODY in one fresh window, then kill its buffers and check cleanup."
  (declare (indent 0))
  `(let ((initial-buffers (buffer-list))
         (title (frame-parameter nil 'title)))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*scratch*"))
             ,@body)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (kill-buffer buffer))))
     (should-not (portal-view-buffers))
     (should-not (portal-fake-native-targets))
     (should-not (memq #'portal-view-sync window-state-change-functions))
     (should (equal (frame-parameter nil 'title) title))))

(defun portal-view-test--open (name)
  "Show a new buffer called NAME in the selected window, give it a view.
Return the view's target."
  (switch-to-buffer (generate-new-buffer name))
  (portal-view-open 'terminal (list :directory temporary-file-directory)))

(defun portal-view-test--shown (target &optional window)
  "Whether TARGET is visible at WINDOW's edges, with no other window's target."
  (let ((window (or window (selected-window)))
        (state (portal--inspect target)))
    (and (plist-get state :visible)
         (equal (plist-get state :edges) (window-inside-pixel-edges window))
         (eq (plist-get state :frame) (window-frame window))
         (equal (portal-view-target window) target)
         (cl-every (lambda (other) (or (eq other window) (null (portal-view-target other))))
                   (window-list)))))

(ert-deftest portal-view-open-places-the-view-in-the-selected-window ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view")))
      (should (string-prefix-p "terminal:" target))
      (should (portal-view-test--shown target))
      (should (equal (plist-get (plist-get (portal--inspect target) :options) :directory)
                     temporary-file-directory))
      (should (equal (portal-view-buffers) (list (current-buffer))))
      (should (equal (portal-view-buffers 'terminal) (list (current-buffer))))
      (should-not (portal-view-buffers 'web))
      (should (memq #'portal-view-sync window-state-change-functions))
      (should (memq #'portal-view-sync window-selection-change-functions))
      (should-error (portal-view-open 'terminal nil))
      (let ((second (portal-view-test--open "second")))
        (should-not (equal second target))
        (should (equal (portal-view-buffers) (list (get-buffer "view") (current-buffer))))))))

(ert-deftest portal-view-split-keeps-one-view-in-the-selected-pane ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right)))
      (should (eq (window-buffer other) (current-buffer)))
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-view-follows-the-selected-pane-showing-its-buffer ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (origin (selected-window))
           (other (split-window-right))
           (unrelated (split-window-below)))
      (set-window-buffer unrelated (get-buffer "*scratch*"))
      (select-window other)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      ;; A selected pane showing another buffer leaves the view where it was.
      (select-window unrelated)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      (select-window origin)
      (portal-view-sync)
      (should (portal-view-test--shown target origin))
      ;; ORIGIN comes after OTHER in window order from UNRELATED; it still stays.
      (select-window unrelated)
      (should (equal (get-buffer-window-list (window-buffer origin)) (list other origin)))
      (portal-view-sync)
      (should (portal-view-test--shown target origin)))))

(ert-deftest portal-view-quit-window-hides-without-ending ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (buffer (current-buffer)))
      (quit-window)
      (should-not (eq (window-buffer) buffer))
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      (should-not (portal-view-target))
      (should (equal (portal-view-buffers) (list buffer)))
      (should-not (portal-fake-native-calls 'portal--close))
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target)))))

(ert-deftest portal-view-appears-in-another-pane-showing-its-buffer ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (buffer (current-buffer))
           (other (split-window-right)))
      (switch-to-buffer "*scratch*")
      (set-window-buffer other (get-buffer "*scratch*"))
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      ;; Shown only in a pane that is not selected: the view goes there.
      (set-window-buffer other buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target other))
      ;; Then shown in the selected pane as well: the view follows selection.
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (portal-view-test--shown target (selected-window))))))

(ert-deftest portal-view-kill-buffer-ends-the-view ()
  (portal-view-test--environment
    (let ((target (portal-view-test--open "view"))
          (kept (portal-view-test--open "kept")))
      (kill-buffer "view")
      (should (equal (portal-fake-native-calls 'portal--close) (list (list target))))
      (should-not (portal--inspect target))
      (should (equal (portal-fake-native-targets) (list kept)))
      (should (equal (portal-view-buffers) (list (current-buffer))))
      (should (memq #'portal-view-sync window-state-change-functions))
      ;; Changing major mode ends the view too, and the last one removes the hooks.
      (fundamental-mode)
      (should-not (portal-view-buffers))
      (should-not (portal-fake-native-targets))
      (should-not (memq #'portal-view-sync window-state-change-functions))
      (should-not (memq #'portal-view-close kill-buffer-hook)))))

(ert-deftest portal-view-sync-makes-no-native-call-when-nothing-moved ()
  (portal-view-test--environment
    (let* ((target (portal-view-test--open "view"))
           (other (split-window-below)))
      (set-window-buffer other (get-buffer "*scratch*"))
      (portal-view-sync)
      (setq portal-fake-native-log nil)
      (portal-view-sync)
      (select-window other)
      (portal-view-sync)
      (portal-view-sync (selected-frame))
      (should-not portal-fake-native-log)
      ;; Resizing moves the view: one placement, then nothing again.
      (window-resize other 2)
      (portal-view-sync)
      (portal-view-sync)
      (should (equal (mapcar #'car (portal-fake-native-calls 'portal--place)) (list target)))
      (should (= (length portal-fake-native-log) 1)))))

(ert-deftest portal-view-failed-open-leaves-nothing-registered ()
  (portal-view-test--environment
    (dolist (failure '(portal--open portal--place))
      (switch-to-buffer (generate-new-buffer (symbol-name failure)))
      (let ((portal-fake-native-failures (list failure)))
        (should-error (portal-view-open 'terminal (list :directory temporary-file-directory))))
      (should-not (portal-view-buffers))
      (should-not (portal-view-target))
      (should-not (portal-fake-native-targets))
      (should-not (memq #'portal-view-close kill-buffer-hook))
      (should-not (memq #'portal-view-sync window-state-change-functions)))
    ;; A failed placement released the view that the native module opened.
    (should (equal (portal-fake-native-calls 'portal--close)
                   (list (list (caar (portal-fake-native-calls 'portal--place))))))
    ;; The buffer can still open a view afterwards.
    (should (portal-view-test--shown (portal-view-open 'terminal nil)))))

(ert-deftest portal-view-terminal-buffers-follow-the-view-lifecycle ()
  (portal-view-test--environment
    (portal-terminal)
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (eq major-mode 'portal-terminal-mode))
      (should (equal (plist-get (plist-get (portal--inspect target) :options) :quick) nil))
      (should (equal (portal-input--target) target))
      (let ((other (split-window-right)))
        (portal-view-sync)
        (should (portal-view-test--shown target))
        (should-not (portal-input--target other))
        (select-window other)
        (portal-view-sync)
        (should (portal-view-test--shown target other))
        (should (equal (portal-input--target) target))
        (delete-window other))
      (quit-window)
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      ;; Returning reuses the same hidden shell.
      (portal-terminal)
      (should (eq (current-buffer) buffer))
      (should (portal-view-test--shown target))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1))
      (portal-terminal-close)
      (should-not (portal--inspect target))
      (should (buffer-live-p buffer))
      (should-error (portal-terminal-focus) :type 'user-error))))

(provide 'portal-view-tests)
;;; portal-view-tests.el ends here
