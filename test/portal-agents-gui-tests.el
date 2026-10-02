;;; portal-agents-gui-tests.el --- The agent dashboard with real terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real native terminals, windows and frames.  Redisplay runs the window hooks
;; that start and stop live updates, and the timer refreshes the dashboard
;; while the event loop waits, as it does while a person types.

(require 'portal-terminal-tests)
(require 'portal-agents)

(defmacro portal-agents-gui--environment (&rest body)
  "Run BODY in one window with live updates every 0.2 seconds.
Afterwards nothing is tracked, and no dashboard, terminal or timer remains."
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((buffers (buffer-list))
           (portal-agents-live-update t)
           (portal-agents-live-update-interval 0.2))
       (setq portal-agents--tracked nil)
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             ,@body)
         (when (buffer-live-p portal-agents--buffer) (kill-buffer portal-agents--buffer))
         (setq portal-agents--tracked nil)
         (portal-terminal-close-all)
         (dolist (buffer (buffer-list))
           (unless (memq buffer buffers) (kill-buffer buffer))))
       (should (= (portal-agents-gui--timers) 0)))))

(defun portal-agents-gui--timers ()
  "Return how many dashboard timers are scheduled."
  (cl-count #'portal-agents--tick timer-list :key #'timer--function))

(defun portal-agents-gui--wait (seconds)
  "Run the event loop for SECONDS, with timers and redisplay.
Unlike `sit-for', it waits while input is pending."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.05)
      (redisplay))))

(defun portal-agents-gui--settle ()
  "Redisplay, which runs window hooks, and handle waiting native records."
  (redisplay t)
  (accept-process-output nil 0.05)
  (redisplay t))

(defun portal-agents-gui--open (name)
  "Start a terminal named NAME in the selected window and return its buffer."
  (portal-terminal-new)
  (portal-terminal-rename name)
  (current-buffer))

(defun portal-agents-gui--row (buffer)
  "Return BUFFER's row as the dashboard prints it, or nil."
  (with-current-buffer portal-agents--buffer
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp)) (not (eq (car (tabulated-list-get-id)) buffer)))
        (forward-line 1))
      (append (tabulated-list-get-entry) nil))))

(defun portal-agents-gui--view (buffer)
  "Return where BUFFER's view is and whether it has the keyboard.
Where is the window showing BUFFER at the view's edges, in any frame, nil
when the view is hidden, or `elsewhere'."
  (portal-agents-gui--settle)
  (let* ((state (portal-terminal-test--state (buffer-local-value 'portal-view--target buffer)))
         (edges (plist-get state :edges)))
    (list (and (plist-get state :visible)
               (or (seq-find (lambda (window)
                               (and (eq (window-buffer window) buffer)
                                    (equal (append (window-inside-pixel-edges window) nil) edges)))
                             (window-list-1 nil 'nomini t))
                   'elsewhere))
          (and (plist-get state :focused) t))))

(defun portal-agents-gui--visit (buffer)
  "Show the dashboard in the selected window and type RET on BUFFER's row."
  (switch-to-buffer portal-agents--buffer)
  (portal-agents-gui--settle)
  (goto-char (point-min))
  (while (not (eq (car (tabulated-list-get-id)) buffer))
    (forward-line 1))
  (execute-kbd-macro (kbd "RET"))
  (portal-agents-gui--settle))

(ert-deftest portal-agents-gui-visit-focuses-terminals ()
  (portal-agents-gui--environment
    (let* ((window (selected-window))
           (shown (portal-agents-gui--open "agent-shown"))
           (hidden (portal-agents-gui--open "agent-hidden"))
           (quick (progn (portal-terminal-quick--show (file-name-as-directory
                                                       temporary-file-directory))
                         (current-buffer)))
           ;; It shows a terminal, but keys stay with this frame until asked.
           (frame (make-frame '((no-accept-focus . t))))
           (remote (frame-selected-window frame)))
      (portal-terminal-quick-dismiss)
      (dolist (buffer (list shown hidden quick)) (portal-agents-track buffer))
      (unwind-protect
          (progn
            (set-window-buffer remote shown)
            (select-frame-set-input-focus (window-frame window))
            (select-window window)
            (portal-agents)
            (should (equal (portal-agents-gui--view shown) (list remote nil)))
            (should (equal (portal-agents-gui--view hidden) '(nil nil)))
            ;; A hidden terminal appears here with the keyboard.
            (portal-agents-gui--visit hidden)
            (should (eq (window-buffer window) hidden))
            (should (equal (portal-agents-gui--view hidden) (list window t)))
            ;; One shown in another frame moves here with the keyboard.
            (portal-agents-gui--visit shown)
            (should (equal (portal-agents-gui--view shown) (list window t)))
            (should (equal (portal-agents-gui--view hidden) '(nil nil)))
            ;; A quick terminal opens in its panel with the keyboard.
            (portal-agents-gui--visit quick)
            (let ((panel (portal-terminal-quick--window)))
              (should panel)
              (should (eq (window-buffer window) portal-agents--buffer))
              (should (equal (portal-agents-gui--view quick) (list panel t))))
            (portal-terminal-quick-dismiss)
            ;; From the dashboard in the other frame, a terminal moves there.
            (switch-to-buffer hidden)
            (select-frame-set-input-focus frame)
            (select-window remote)
            (portal-agents-gui--visit hidden)
            (should (eq (window-buffer remote) hidden))
            (should (equal (portal-agents-gui--view hidden) (list remote t))))
        (delete-frame frame)))))

(ert-deftest portal-agents-gui-live-updates-only-while-shown ()
  (portal-agents-gui--environment
    (let* ((window (selected-window))
           (terminal (portal-agents-gui--open "agent-live"))
           (target (buffer-local-value 'portal-view--target terminal))
           (other (split-window-right)))
      (portal-agents-track terminal)
      ;; The terminal keeps the keyboard while the dashboard opens beside it.
      (portal-terminal-focus)
      (with-selected-window other (portal-agents))
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 1))
      (should (equal (portal-agents-gui--view terminal) (list window t)))
      ;; A title the program sets appears without g; the keyboard stays.
      (portal-terminal-test--paste "printf '\\033]2;PORTAL agent title\\007'; sleep 5" t target)
      (portal-terminal-test--wait
       (lambda () (equal (nth 6 (portal-agents-gui--row terminal)) "PORTAL agent title")))
      (should (eq (selected-window) window))
      (should (equal (portal-agents-gui--view terminal) (list window t)))
      ;; Ticks with nothing changed redraw nothing.
      (let ((tick (buffer-modified-tick portal-agents--buffer)))
        (portal-agents-gui--wait 1)
        (should (= (buffer-modified-tick portal-agents--buffer) tick)))
      ;; Hidden, the timer stops, and changes cost the dashboard nothing.
      (set-window-buffer other (get-buffer-create "*scratch*"))
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 0))
      (let ((tick (buffer-modified-tick portal-agents--buffer)))
        (portal-terminal-test--paste "printf '\\033]2;PORTAL hidden title\\007'; sleep 5" t target)
        (portal-terminal-test--wait
         (lambda () (equal (plist-get (portal-terminal-metadata terminal) :title)
                           "PORTAL hidden title")))
        (portal-agents-gui--wait 0.5)
        (should (= (buffer-modified-tick portal-agents--buffer) tick)))
      ;; Shown in another frame, it refreshes at once, and one timer runs.
      (let ((frame (make-frame '((no-accept-focus . t)))))
        (unwind-protect
            (progn
              (set-window-buffer (frame-selected-window frame) portal-agents--buffer)
              (portal-agents-gui--settle)
              (should (equal (nth 6 (portal-agents-gui--row terminal)) "PORTAL hidden title"))
              (should (= (portal-agents-gui--timers) 1))
              (set-window-buffer other portal-agents--buffer)
              (portal-agents-gui--settle)
              (should (= (portal-agents-gui--timers) 1))
              ;; Shown only on an invisible frame, the next tick stops it.
              (set-window-buffer other (get-buffer "*scratch*"))
              (make-frame-invisible frame t)
              (portal-agents-gui--settle)
              (portal-agents-gui--wait 0.5)
              (should (= (portal-agents-gui--timers) 0)))
          (delete-frame frame)))
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 0))
      ;; Killing the dashboard leaves no timer or hook.
      (set-window-buffer other portal-agents--buffer)
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 1))
      (kill-buffer portal-agents--buffer)
      (portal-agents-gui--settle)
      (should (= (portal-agents-gui--timers) 0))
      (should-not (memq #'portal-agents--window-changed
                        (default-value 'window-state-change-functions)))
      (should (equal (portal-agents-gui--view terminal) (list window t))))))

(provide 'portal-agents-gui-tests)
;;; portal-agents-gui-tests.el ends here
