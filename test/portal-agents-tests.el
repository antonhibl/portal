;;; portal-agents-tests.el --- The agent dashboard -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-agents)

;; Tests kill live shells without asking; the prompt has its own tests.
(setq portal-terminal-confirm-kill nil)

;; Real buffers, windows and timers drive the dashboard against the fake native
;; module, whose `terminal' records change the terminals' cached metadata.
;; Batch Emacs never redisplays, so it never runs window change hooks: tests
;; call `portal-agents--window-changed' where redisplay would.  The GUI suite
;; checks the real hooks and focus.

(defvar portal-agents-test--directory nil "This test's temporary directory.")

(defmacro portal-agents-test--environment (&rest body)
  "Run BODY in one window, then kill its buffers and delete its directory.
The directory holds projects one/app and two/app.  Afterwards nothing is
tracked and no dashboard timer remains."
  (declare (indent 0))
  `(let* ((portal-agents-test--directory (file-truename (make-temp-file "portal-agents-" t)))
          (context (frame-parameter nil 'portal-project-context))
          (initial-buffers (buffer-list))
          (portal-agents-live-update t)
          (portal-agents-live-update-interval 2))
     (portal-fake-native-reset)
     (setq portal-agents--tracked nil)
     (dolist (folder '("one/app/.git" "one/app/src" "two/app/.git"))
       (make-directory (portal-agents-test--path folder) t))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (switch-to-buffer (get-buffer-create "*scratch*"))
                  ,@body)
         (portal-terminal-quick-dismiss)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory portal-agents-test--directory t)))
     (should-not (portal-view-buffers))
     (should-not portal-agents--buffer)
     (should (= (portal-agents-test--timers) 0))
     (setq portal-agents--tracked nil)))

(defun portal-agents-test--path (name)
  "Return NAME in this test's directory, as a directory name if it ends in /."
  (expand-file-name name portal-agents-test--directory))

(defun portal-agents-test--open (folder)
  "Start a terminal in FOLDER in the selected window and return its buffer."
  (let ((default-directory (file-name-as-directory (portal-agents-test--path folder))))
    (portal-terminal-new)
    (current-buffer)))

(defun portal-agents-test--report (buffer &rest facts)
  "Have BUFFER's terminal report FACTS, such as :title, :pwd and :exited."
  (apply #'portal-fake-native-report (buffer-local-value 'portal-view--target buffer) facts))

(defun portal-agents-test--timers ()
  "Return how many dashboard timers are scheduled."
  (cl-count #'portal-agents--tick timer-list :key #'timer--function))

(defun portal-agents-test--redisplay ()
  "Run the dashboard's window hook, as redisplay does after windows change."
  (portal-agents--window-changed (selected-frame)))

(defun portal-agents-test--show ()
  "Open the dashboard in the selected window, as a person does."
  (portal-agents)
  (portal-agents-test--redisplay)
  portal-agents--buffer)

(defun portal-agents-test--rows ()
  "Return the dashboard's printed rows, as (BUFFER COLUMN...)."
  (with-current-buffer portal-agents--buffer
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (push (cons (car (tabulated-list-get-id)) (append (tabulated-list-get-entry) nil)) rows)
          (forward-line 1))
        (nreverse rows)))))

(defun portal-agents-test--row (buffer)
  "Return BUFFER's printed row, without the buffer."
  (cdr (assq buffer (portal-agents-test--rows))))

(defun portal-agents-test--line (buffer)
  "Return how many rows the dashboard prints before BUFFER's row."
  (cl-position buffer (portal-agents-test--rows) :key #'car))

(defun portal-agents-test--focused ()
  "Return the targets of the views that have the keyboard."
  (cl-remove-if-not (lambda (target) (plist-get (portal--inspect target) :focused))
                    (portal-fake-native-targets)))

(defmacro portal-agents-test--quietly (&rest body)
  "Run BODY, failing if it asks native code, a person or the system anything.
It must not inspect or focus a view, prompt, start a process or open a
connection, nor change the selected window, the current buffer or focus."
  (declare (indent 0))
  `(let ((window (selected-window))
         (buffer (current-buffer))
         (focused (portal-agents-test--focused))
         (processes (process-list)))
     (cl-letf* ((fail (lambda (&rest arguments) (error "Refresh called %S" arguments)))
                ((symbol-function 'portal--inspect) fail)
                ((symbol-function 'portal--input) fail)
                ((symbol-function 'portal--open) fail)
                ((symbol-function 'portal--place) fail)
                ((symbol-function 'read-from-minibuffer) fail)
                ((symbol-function 'read-string) fail)
                ((symbol-function 'completing-read) fail))
       ,@body)
     ;; No process or network connection started.
     (should (equal (process-list) processes))
     (should (eq (selected-window) window))
     (should (eq (current-buffer) buffer))
     (should (equal (portal-agents-test--focused) focused))))

(defun portal-agents-test--tick ()
  "Run the dashboard timer's callback once, as it runs every interval."
  (portal-agents-test--quietly (portal-agents--tick)))

(ert-deftest portal-agents-dashboard-is-a-plain-buffer ()
  (portal-agents-test--environment
    (let ((terminal (portal-agents-test--open "one/app")))
      (switch-to-buffer "*scratch*")
      (portal-agents-track terminal)
      (setq portal-fake-native-log nil)
      (let ((dashboard (portal-agents-test--show)))
        (should (eq (window-buffer) dashboard))
        (should (derived-mode-p 'portal-agents-mode))
        ;; No native view, web page or app host.
        (should-not portal-fake-native-log)
        (should-not (buffer-local-value 'portal-view--target dashboard))
        (should-not (bound-and-true-p portal--server-process))
        (should (equal (portal-view-buffers) (list terminal)))
        ;; One dashboard, reused.
        (switch-to-buffer "*scratch*")
        (portal-agents)
        (should (eq portal-agents--buffer dashboard))
        (should (= (length (cl-remove-if-not (lambda (buffer)
                                               (with-current-buffer buffer
                                                 (derived-mode-p 'portal-agents-mode)))
                                             (buffer-list)))
                   1))
        ;; Ordinary text: movement and search work on it.
        (goto-char (point-min))
        (should (search-forward "*terminal: app*" nil t))
        (should (equal (mapcar #'car (append tabulated-list-format nil))
                       '("Terminal" "Agent" "Project" "Process" "Activity" "Directory" "Title")))
        ;; q quits the window, leaving the dashboard.
        (execute-kbd-macro "q")
        (should (eq (window-buffer) (get-buffer "*scratch*")))
        (should (buffer-live-p dashboard))
        (kill-buffer dashboard)))))

(ert-deftest portal-agents-tracks-sessions ()
  (portal-agents-test--environment
    (let* ((one (portal-agents-test--path "one/app/"))
           (first (portal-agents-test--open "one/app"))
           (second (portal-agents-test--open "one/app"))
           (other (portal-agents-test--open "two/app")))
      (portal-terminal-quick--show one)
      (let ((quick (current-buffer)))
        (portal-terminal-quick-dismiss)
        (switch-to-buffer "*scratch*")
        ;; Hidden and quick terminals can be tracked; tracking twice adds nothing.
        (portal-agents-track first)
        (portal-agents-track (buffer-name second) "claude")
        (portal-agents-track quick)
        (portal-agents-track first)
        (should-error (portal-agents-track "*scratch*") :type 'user-error)
        (portal-agents-test--show)
        ;; Two agents in one directory are two rows; activity is unknown.
        (should (equal (portal-agents-test--rows)
                       `((,first "*terminal: app*" "" "app" "running" "unknown"
                                 ,(abbreviate-file-name one) "")
                         (,second "*terminal: app*<2>" "claude" "app" "running" "unknown"
                                  ,(abbreviate-file-name one) "")
                         (,quick ,(buffer-name quick) "" "app" "running" "unknown"
                                 ,(abbreviate-file-name one) ""))))
        ;; Tracking follows the session through renames.
        (with-current-buffer first (portal-terminal-rename "reviewer"))
        (revert-buffer)
        (should (equal (car (portal-agents-test--row first)) "reviewer"))
        ;; An empty label removes a label; no label keeps it.
        (portal-agents-track second)
        (should (equal (nth 1 (portal-agents-test--row second)) "claude"))
        (portal-agents-track second " ")
        (should (equal (nth 1 (portal-agents-test--row second)) ""))
        (portal-agents-track second "codex")
        ;; Untracking leaves the terminal running.
        (portal-agents-untrack second)
        (should-not (portal-agents-test--row second))
        (should (memq second (portal-terminal-buffers)))
        (should (member (buffer-local-value 'portal-view--target second)
                        (portal-fake-native-targets)))
        (should-error (portal-agents-untrack second) :type 'user-error)
        ;; Tracking it again starts without the old label.
        (portal-agents-track second)
        (should (equal (nth 1 (portal-agents-test--row second)) ""))
        ;; In the dashboard, u untracks the terminal on this line.
        (goto-char (point-min))
        (forward-line (portal-agents-test--line quick))
        (execute-kbd-macro "u")
        (should-not (portal-agents-test--row quick))
        (should (buffer-live-p quick))
        ;; An exited program stays while its buffer keeps the view.
        (portal-agents-track other)
        (portal-agents-test--report other :exited t)
        (revert-buffer)
        (should (equal (nth 3 (portal-agents-test--row other)) "exited"))
        (should (equal (nth 4 (portal-agents-test--row other)) "unknown"))
        ;; Closing, killing or replacing a terminal drops it.
        (with-current-buffer other (portal-terminal-close))
        (should (buffer-live-p other))
        (with-current-buffer second
          (portal-view-close)
          (portal-view-open 'terminal nil))
        (kill-buffer first)
        (revert-buffer)
        (should-not (portal-agents-test--rows))
        (should-not portal-agents--tracked)
        (should-not (portal-agents--tracked-p second))))))

(ert-deftest portal-agents-replaced-quick-terminal-is-untracked ()
  (portal-agents-test--environment
    (let ((one (portal-agents-test--path "one/app/")))
      (portal-terminal-quick--show one)
      (let ((old (current-buffer))
            (name (buffer-name)))
        (portal-agents-track old)
        (cl-letf (((symbol-function 'yes-or-no-p) #'always))
          (portal-terminal-quick-reset))
        (let ((new (current-buffer)))
          (should-not (eq new old))
          (should-not (buffer-live-p old))
          (should (equal (buffer-name new) name))
          (portal-terminal-quick-dismiss)
          (portal-agents-test--show)
          (should-not (portal-agents-test--rows))
          (portal-agents-track new)
          (should (equal (mapcar #'car (portal-agents-test--rows)) (list new))))))))

(ert-deftest portal-agents-rows-follow-shared-metadata ()
  (portal-agents-test--environment
    (let* ((src (portal-agents-test--path "one/app/src/"))
           (two (portal-agents-test--path "two/app/"))
           (first (portal-agents-test--open "one/app"))
           (second (portal-agents-test--open "one/app/src")))
      (switch-to-buffer "*scratch*")
      (portal-agents-track first)
      (portal-agents-track second)
      (portal-agents-test--show)
      (portal-agents-test--report first :title "claude\tfixing\e[1mtests" :pwd (directory-file-name src))
      (portal-agents-test--tick)
      (should (equal (portal-agents-test--row first)
                     (list "*terminal: app*" "" "app" "running" "unknown"
                           (abbreviate-file-name src) "claude fixing [1mtests")))
      ;; Reassigning a project shows; a directory change never reassigns one.
      (with-current-buffer second (portal-terminal-set-project two))
      (portal-agents-test--tick)
      (should (equal (nth 2 (portal-agents-test--row first)) "one/app"))
      (should (equal (nth 2 (portal-agents-test--row second)) "two/app"))
      (portal-agents-test--report first :pwd (directory-file-name two))
      (portal-agents-test--tick)
      (should (equal (nth 5 (portal-agents-test--row first)) (abbreviate-file-name two)))
      (should (equal (nth 2 (portal-agents-test--row first)) "one/app"))
      (with-current-buffer second (portal-terminal-set-project nil))
      (with-current-buffer first (rename-buffer "agent"))
      (portal-agents-test--report second :title "" :exited t)
      (portal-agents-test--tick)
      (should (equal (portal-agents-test--rows)
                     `((,first "agent" "" "app" "running" "unknown" ,(abbreviate-file-name two)
                               "claude fixing [1mtests")
                       (,second "*terminal: app*<2>" "" "-" "exited" "unknown"
                                ,(abbreviate-file-name src) "")))))))

(ert-deftest portal-agents-refresh-keeps-places-and-skips-unchanged ()
  (portal-agents-test--environment
    (let* ((terminals (cl-loop for title in '("m" "b" "a" "k" "j" "i" "h" "g" "f" "e" "d" "c")
                               collect (let ((buffer (portal-agents-test--open "one/app")))
                                         (portal-agents-test--report buffer :title title)
                                         buffer)))
           (focused (car (last terminals))))
      (dolist (buffer terminals) (portal-agents-track buffer))
      ;; A terminal has the keyboard in one window; the dashboard is in two more.
      (let* ((terminal-window (selected-window))
             (top (split-window-below))
             (bottom (with-selected-window top (split-window-below))))
        (with-selected-window top (portal-agents-test--show))
        (set-window-buffer bottom portal-agents--buffer)
        (portal-agents-test--redisplay)
        (with-current-buffer portal-agents--buffer
          (should (equal (mapcar #'car (portal-agents-test--rows)) terminals))
          ;; Sort by title, then select rows and scroll one window.
          (tabulated-list-sort 6)
          (should (equal (mapcar (lambda (row) (nth 7 row)) (portal-agents-test--rows))
                         '("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "m")))
          (let ((b (nth 1 terminals))
                (h (nth 6 terminals))
                (f (nth 8 terminals))
                (tick (buffer-modified-tick)))
            (with-selected-window top
              (goto-char (point-min))
              (forward-line (portal-agents-test--line b))
              (move-to-column 3))
            (set-window-start bottom (save-excursion (goto-char (point-min))
                                                     (forward-line 5) (point)))
            (set-window-point bottom (save-excursion (goto-char (point-min))
                                                     (forward-line (portal-agents-test--line h))
                                                     (point)))
            (should (equal (portal-agents-test--focused)
                           (list (buffer-local-value 'portal-view--target focused))))
            ;; Nothing changed, so nothing is printed.
            (portal-agents-test--tick)
            (should (= (buffer-modified-tick) tick))
            ;; Rows move; each window stays on its session, on its screen line.
            (portal-agents-test--report b :title "z")
            (portal-agents-test--report h :title "jj")
            (portal-agents-test--tick)
            (should (> (buffer-modified-tick) tick))
            (should (equal (mapcar (lambda (row) (nth 7 row)) (portal-agents-test--rows))
                           '("a" "c" "d" "e" "f" "g" "i" "j" "jj" "k" "m" "z")))
            (should (equal tabulated-list-sort-key '("Title")))
            (should (eq (car (tabulated-list-get-id (window-point top))) b))
            (should (= (save-excursion (goto-char (window-point top)) (current-column)) 3))
            (should (eq (car (tabulated-list-get-id (window-point bottom))) h))
            (should (= (line-number-at-pos (window-start bottom))
                       (- (line-number-at-pos (window-point bottom)) 2)))
            (should (= (line-number-at-pos (window-point bottom)) 9))
            ;; A closed session's window stays on its line.
            (with-selected-window bottom
              (goto-char (point-min))
              (forward-line (portal-agents-test--line f)))
            (let ((line (line-number-at-pos (window-point bottom))))
              (kill-buffer f)
              (portal-agents-test--tick)
              (should (= (line-number-at-pos (window-point bottom)) line)))
            (should (eq (selected-window) terminal-window))
            ;; Restoring the first order, after refreshes, gives tracking order.
            (tabulated-list-sort -1)
            (should (equal (mapcar #'car (portal-agents-test--rows)) (remq f terminals)))))))))

(ert-deftest portal-agents-manual-refresh-without-live-updates ()
  (portal-agents-test--environment
    (let ((portal-agents-live-update nil)
          (terminal (portal-agents-test--open "one/app")))
      (portal-agents-track terminal)
      (portal-agents-test--show)
      (should (= (portal-agents-test--timers) 0))
      (portal-agents-test--report terminal :title "npm test")
      (should (equal (nth 6 (portal-agents-test--row terminal)) ""))
      ;; g refreshes, with live updates off.
      (execute-kbd-macro "g")
      (should (equal (nth 6 (portal-agents-test--row terminal)) "npm test"))
      ;; Showing the dashboard again refreshes it too.
      (portal-agents-test--report terminal :title "npm run build")
      (switch-to-buffer "*scratch*")
      (portal-agents-test--redisplay)
      (switch-to-buffer portal-agents--buffer)
      (portal-agents-test--redisplay)
      (should (equal (nth 6 (portal-agents-test--row terminal)) "npm run build"))
      (should (= (portal-agents-test--timers) 0)))))

(ert-deftest portal-agents-timer-runs-only-while-shown ()
  (portal-agents-test--environment
    (let ((terminal (portal-agents-test--open "one/app")))
      (switch-to-buffer "*scratch*")
      (portal-agents-track terminal)
      (should (= (portal-agents-test--timers) 0))
      (let ((dashboard (portal-agents-test--show)))
        (should (= (portal-agents-test--timers) 1))
        (should (equal (timer--repeat-delay portal-agents--timer) 2))
        ;; More windows and frames showing it still need one timer.
        (set-window-buffer (split-window-right) dashboard)
        (portal-agents-test--redisplay)
        (should (= (portal-agents-test--timers) 1))
        (portal-fake-native-with-frame frame
          (set-window-buffer (frame-selected-window frame) dashboard)
          (portal-agents--window-changed frame)
          (should (= (portal-agents-test--timers) 1))
          ;; Hidden here, it is shown only on a frame that is not visible.
          (delete-other-windows)
          (switch-to-buffer "*scratch*")
          (portal-agents-test--redisplay)
          (should (get-buffer-window dashboard t))
          (should (= (portal-agents-test--timers) 0))
          ;; While hidden, changes cause no work.
          (let ((tick (buffer-modified-tick dashboard)))
            (portal-agents-test--report terminal :title "hidden change")
            (portal-agents-track terminal "claude")
            (should (= (buffer-modified-tick dashboard) tick))
            ;; Shown again, it refreshes at once and updates live.
            (switch-to-buffer dashboard)
            (portal-agents-test--redisplay)
            (should (> (buffer-modified-tick dashboard) tick))
            (should (equal (portal-agents-test--row terminal)
                           (list "*terminal: app*" "claude" "app" "running" "unknown"
                                 (abbreviate-file-name (portal-agents-test--path "one/app/"))
                                 "hidden change")))
            (should (= (portal-agents-test--timers) 1))))
        ;; A tick that finds it hidden, with no hook run, stops the timer.
        (switch-to-buffer "*scratch*")
        (portal-agents-test--tick)
        (should (= (portal-agents-test--timers) 0))
        (portal-agents-test--redisplay)
        (should (= (portal-agents-test--timers) 0))
        ;; Toggling live updates starts and stops the timer only while shown.
        (portal-agents-toggle-live-update)
        (should-not portal-agents-live-update)
        (portal-agents-toggle-live-update)
        (should (= (portal-agents-test--timers) 0))
        (switch-to-buffer dashboard)
        (portal-agents-test--redisplay)
        (should (= (portal-agents-test--timers) 1))
        (portal-agents-toggle-live-update)
        (should (= (portal-agents-test--timers) 0))
        (portal-agents-test--tick)
        (should (= (portal-agents-test--timers) 0))
        (portal-agents-toggle-live-update 1)
        (portal-agents-toggle-live-update 1)
        (should (= (portal-agents-test--timers) 1))
        ;; Killing it stops everything; a new dashboard starts afresh.
        (kill-buffer dashboard)
        (should (= (portal-agents-test--timers) 0))
        (should-not (memq #'portal-agents--window-changed
                          (default-value 'window-state-change-functions)))
        (portal-agents-test--show)
        (should (= (portal-agents-test--timers) 1))
        (should (memq #'portal-agents--window-changed
                      (default-value 'window-state-change-functions)))
        ;; Changing its mode ends it as a dashboard.
        (fundamental-mode)
        (should (= (portal-agents-test--timers) 0))
        (should-not portal-agents--buffer)))))

(ert-deftest portal-agents-visit-focuses-the-terminal ()
  (portal-agents-test--environment
    (let* ((one (portal-agents-test--path "one/app/"))
           (first (portal-agents-test--open "one/app"))
           (second (portal-agents-test--open "one/app"))
           (quick (progn (portal-terminal-quick--show one) (current-buffer))))
      (portal-terminal-quick-dismiss)
      (switch-to-buffer "*scratch*")
      (dolist (buffer (list first second quick)) (portal-agents-track buffer))
      (cl-flet ((visit (buffer)
                  (switch-to-buffer portal-agents--buffer)
                  (goto-char (point-min))
                  (forward-line (portal-agents-test--line buffer))
                  (execute-kbd-macro (kbd "RET"))
                  (portal-view-sync)))
        (portal-agents-test--show)
        ;; Of two terminals in one directory, RET visits the one on its line.
        (visit second)
        (should (eq (window-buffer) second))
        (should (equal (portal-agents-test--focused)
                       (list (buffer-local-value 'portal-view--target second))))
        (visit first)
        (should (eq (window-buffer) first))
        (should (equal (portal-agents-test--focused)
                       (list (buffer-local-value 'portal-view--target first))))
        ;; A quick terminal opens in its panel, with the keyboard.
        (let ((window (selected-window)))
          (visit quick)
          (should (window-parameter nil 'portal-terminal-quick))
          (should (eq (window-buffer) quick))
          (should (eq (window-buffer window) portal-agents--buffer))
          (should (equal (portal-agents-test--focused)
                         (list (buffer-local-value 'portal-view--target quick)))))
        (portal-terminal-quick-dismiss)
        ;; A terminal shown in another frame moves to the dashboard's window.
        (portal-fake-native-with-frame frame
          (set-window-buffer (frame-selected-window frame) second)
          (portal-view-sync)
          (should (eq (plist-get (portal--inspect (buffer-local-value 'portal-view--target second))
                                 :frame)
                      frame))
          (visit second)
          (should (eq (window-buffer) second))
          (should (eq (plist-get (portal--inspect (buffer-local-value 'portal-view--target second))
                                 :frame)
                      (selected-frame)))
          (should (equal (portal-agents-test--focused)
                         (list (buffer-local-value 'portal-view--target second)))))
        ;; A row whose terminal closed since the last refresh visits nothing.
        (switch-to-buffer portal-agents--buffer)
        (goto-char (point-min))
        (forward-line (portal-agents-test--line first))
        (with-current-buffer first (portal-terminal-close))
        (should-error (portal-agents-visit) :type 'user-error)
        (should (eq (window-buffer) portal-agents--buffer))
        (should-not (portal-agents-test--row first))))))

(ert-deftest portal-agents-interactive-tracking-reads-terminals ()
  (portal-agents-test--environment
    (let* ((first (portal-agents-test--open "one/app"))
           (second (portal-agents-test--open "two/app"))
           offered)
      (cl-letf (((symbol-function 'read-buffer)
                 (lambda (_prompt default _require predicate)
                   (setq offered (cl-remove-if-not
                                  (lambda (buffer) (funcall predicate (cons (buffer-name buffer) buffer)))
                                  (buffer-list)))
                   (or default (buffer-name (car offered)))))
                ((symbol-function 'read-string) (lambda (&rest _) "claude")))
        ;; From a terminal, it is the default; only terminals are offered.
        (call-interactively #'portal-agents-track)
        (should (seq-set-equal-p offered (list first second)))
        (should (equal (mapcar #'caar portal-agents--tracked) (list second)))
        (should-not (cdar portal-agents--tracked))
        (switch-to-buffer first)
        (let ((current-prefix-arg '(4)))
          (call-interactively #'portal-agents-track))
        (should (equal (cdr (portal-agents--tracked-p first)) "claude"))
        ;; Untracking offers only tracked terminals.
        (switch-to-buffer "*scratch*")
        (with-current-buffer second (portal-agents-untrack second))
        (call-interactively #'portal-agents-untrack)
        (should (equal offered (list first)))
        (should-not portal-agents--tracked)))))

(provide 'portal-agents-tests)
;;; portal-agents-tests.el ends here
