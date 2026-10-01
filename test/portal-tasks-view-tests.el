;;; portal-tasks-view-tests.el --- The task view of project.org -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real Org buffers, org-ql and project detection drive `portal-tasks'; org-ql
;; and its libraries come from `build/elpa' (see CMakeLists.txt).  Terminals
;; use the fake native module.  Batch Emacs runs no window change functions,
;; so returning to the view calls the function they run; the graphical suite
;; checks that redisplay runs it.
(require 'ert)
(require 'cl-lib)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal)
(require 'org)
(require 'org-agenda)

;; Tests kill live shells without asking.
(setq portal-terminal-confirm-kill nil)

(defvar portal-tasks-view-test--directory nil "This test's temporary directory.")

(defmacro portal-tasks-view-test--environment (&rest body)
  "Run BODY in one window, then kill its buffers and delete its directory."
  (declare (indent 0))
  `(let ((portal-tasks-view-test--directory
          (file-name-as-directory (file-truename (make-temp-file "portal-tasks-view-" t))))
         (context (frame-parameter nil 'portal-project-context))
         (initial-buffers (buffer-list)))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (progn (set-frame-parameter nil 'portal-project-context nil)
                  (delete-other-windows)
                  (switch-to-buffer (get-buffer-create "*scratch*"))
                  ,@body)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory portal-tasks-view-test--directory t)))
     (should-not (portal-view-buffers))))

(defun portal-tasks-view-test--day (days)
  "Return an Org timestamp DAYS after today."
  (format "<%s>" (org-read-date nil nil (format "%+dd" days))))

(cl-defun portal-tasks-view-test--task (heading &key id depends planning)
  "Return a task HEADING with planning line PLANNING, CUSTOM_ID ID and DEPENDS."
  (concat "** " heading " :task:\n"
          (if planning (concat planning "\n") "")
          (if (or id depends)
              (concat ":PROPERTIES:\n"
                      (if id (format ":CUSTOM_ID: %s\n" id) "")
                      (if depends (format ":DEPENDS_ON: %s\n" depends) "")
                      ":END:\n")
            "")))

(defun portal-tasks-view-test--project (name &rest tasks)
  "Make project NAME whose project.org holds TASKS under one area; return it.
The file declares TODO, DONE and CANCELLED."
  (let ((file (expand-file-name (concat name "/project.org") portal-tasks-view-test--directory)))
    (make-directory (expand-file-name (concat name "/.git") portal-tasks-view-test--directory) t)
    (with-temp-file file
      (insert "#+TODO: TODO | DONE CANCELLED\n* Area\n" (apply #'concat tasks)))
    file))

(defun portal-tasks-view-test--open (file)
  "Visit FILE in the selected window, then open its project's task view."
  (find-file file)
  (portal-tasks))

(defun portal-tasks-view-test--lines (view)
  "Return the lines of task VIEW, with runs of blanks as one space."
  (with-current-buffer view
    (mapcar (lambda (line) (string-trim (replace-regexp-in-string "[ \t]+" " " line)))
            (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))))

(defun portal-tasks-view-test--titles (view)
  "Return the title of each task line in VIEW, and the other lines as they are."
  (with-current-buffer view
    (save-excursion
      (goto-char (point-min))
      (let (lines)
        (while (not (eobp))
          (let ((marker (get-text-property (point) 'org-hd-marker)))
            (unless (eolp)
              (push (if marker
                        (org-with-point-at marker (org-get-heading t t t t))
                      (buffer-substring-no-properties (point) (line-end-position)))
                    lines)))
          (forward-line))
        (nreverse lines)))))

(defun portal-tasks-view-test--at (view)
  "Return the title of the task on the line at point in VIEW, or nil."
  (with-current-buffer view
    (when-let* ((marker (get-text-property (line-beginning-position) 'org-hd-marker)))
      (org-with-point-at marker (org-get-heading t t t t)))))

(defun portal-tasks-view-test--goto (view title)
  "Move point in VIEW, and in its window if any, to the line of task TITLE."
  (with-current-buffer view
    (goto-char (point-min))
    (while (not (equal (portal-tasks-view-test--at view) title))
      (unless (zerop (forward-line))
        (error "No task %s in the view" title)))
    (when-let* ((window (get-buffer-window view)))
      (set-window-point window (point)))))

(defun portal-tasks-view-test--set (file title keyword)
  "Give the task TITLE in FILE's buffer KEYWORD, leaving the buffer unsaved."
  (with-current-buffer (find-buffer-visiting file)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (format "^\\*+ .*\\<%s\\>" (regexp-quote title)))
      (let ((org-inhibit-logging t)) (org-todo keyword)))))

(ert-deftest portal-tasks-view-is-a-command ()
  (should (commandp #'portal-tasks))
  (should (commandp #'portal-tasks-browser)))

(ert-deftest portal-tasks-view-lists-actionable-tasks-in-order ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO Plain" :id "plain")
                  (portal-tasks-view-test--task "TODO [#C] Low" :id "low")
                  (portal-tasks-view-test--task "TODO Due later" :id "due-later"
                                                :planning (concat "DEADLINE: " (portal-tasks-view-test--day 10)))
                  (portal-tasks-view-test--task "TODO [#A] Urgent" :id "urgent")
                  (portal-tasks-view-test--task "TODO Due soon" :id "due-soon"
                                                :planning (concat "DEADLINE: " (portal-tasks-view-test--day 2)))
                  (portal-tasks-view-test--task "TODO Overdue" :id "overdue"
                                                :planning (concat "DEADLINE: " (portal-tasks-view-test--day -3)))
                  (portal-tasks-view-test--task "TODO Today" :id "today"
                                                :planning (concat "SCHEDULED: " (portal-tasks-view-test--day 0)))
                  (portal-tasks-view-test--task "TODO Yesterday" :id "yesterday"
                                                :planning (concat "SCHEDULED: " (portal-tasks-view-test--day -1)))
                  (portal-tasks-view-test--task "TODO Tomorrow" :id "tomorrow"
                                                :planning (concat "SCHEDULED: " (portal-tasks-view-test--day 1)))
                  ;; A deadline makes a task urgent, not eligible.
                  (portal-tasks-view-test--task
                   "TODO Later but due" :id "later-but-due"
                   :planning (concat "SCHEDULED: " (portal-tasks-view-test--day 5)
                                     " DEADLINE: " (portal-tasks-view-test--day 1)))
                  (portal-tasks-view-test--task "DONE Shipped" :id "shipped")
                  ;; Only headings with their own task tag are tasks.
                  "** TODO Untagged\n:PROPERTIES:\n:CUSTOM_ID: untagged\n:END:\n"
                  "*** TODO Inherits the tag\n"))
           (view (portal-tasks-view-test--open file)))
      (should (eq view (current-buffer)))
      (should (eq major-mode 'org-agenda-mode))
      (should (equal (buffer-name) (format "*tasks: %s*" (abbreviate-file-name
                                                          (directory-file-name (file-name-directory file))))))
      (should (equal header-line-format (format "Actionable tasks in %s" (abbreviate-file-name file))))
      (should (eq (key-binding "g") #'portal-tasks-refresh))
      (should (eq (key-binding "v") #'portal-tasks-toggle-all))
      ;; Org's own keys stay: RET goes to the task.
      (should (eq (key-binding (kbd "RET")) #'org-agenda-switch-to))
      ;; Priority, with Org's default for none, then nearest deadline, then file order.
      (should (equal (portal-tasks-view-test--titles view)
                     '("Urgent" "Overdue" "Due soon" "Due later" "Plain" "Today" "Yesterday" "Low")))
      ;; All tasks shows the deferred and closed ones too, in the same order.
      (portal-tasks-toggle-all)
      (should (equal header-line-format (format "All tasks in %s" (abbreviate-file-name file))))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (8)" "Urgent" "Overdue" "Due soon" "Due later" "Plain" "Today"
                       "Yesterday" "Low"
                       "Deferred (2)" "Later but due" "Tomorrow"
                       "Closed (1)" "Shipped")))
      ;; org-ql says when a date is; the view says why a task waits.
      (should (member (format "TODO Tomorrow in 1d — scheduled %s :task:"
                              (portal-tasks-view-test--day 1))
                      (portal-tasks-view-test--lines view)))
      ;; Opening the view again keeps its buffer and its choice of tasks.
      (switch-to-buffer "*scratch*")
      (find-file file)
      (should (eq (portal-tasks) view))
      (should (eq (window-buffer) view))
      (should (equal (car (portal-tasks-view-test--titles view)) "Actionable (8)")))))

(ert-deftest portal-tasks-view-follows-dependencies-in-the-buffer ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :depends "first first")
                  (portal-tasks-view-test--task "TODO Third" :id "third" :depends "first second")))
           (view (portal-tasks-view-test--open file)))
      (should (equal (portal-tasks-view-test--titles view) '("First")))
      (portal-tasks-toggle-all)
      ;; Each prerequisite is named once, however often it is listed.
      (should (equal (portal-tasks-view-test--lines view)
                     '("Actionable (1)" "TODO First :task:"
                       "Blocked (2)"
                       "TODO Second — waiting for first (TODO) :task:"
                       "TODO Third — waiting for first (TODO); waiting for second (TODO) :task:")))
      ;; The unsaved buffer is what the view reads.
      (portal-tasks-view-test--set file "First" "DONE")
      (with-current-buffer view (portal-tasks-refresh))
      (should (buffer-modified-p (find-buffer-visiting file)))
      (should (equal (portal-tasks-view-test--lines view)
                     '("Actionable (1)" "TODO Second :task:"
                       "Blocked (1)" "TODO Third — waiting for second (TODO) :task:"
                       "Closed (1)" "DONE First :task:")))
      ;; A cancelled prerequisite keeps its dependents blocked.
      (portal-tasks-view-test--set file "First" "CANCELLED")
      (with-current-buffer view (portal-tasks-refresh))
      (should (equal (portal-tasks-view-test--lines view)
                     '("Blocked (2)"
                       "TODO Second — waiting for first (CANCELLED) :task:"
                       "TODO Third — waiting for first (CANCELLED); waiting for second (TODO) :task:"
                       "Closed (1)" "CANCELLED First :task:")))
      ;; A blocker's link goes to its heading.
      (with-current-buffer view
        (goto-char (button-start (next-button (point-min))))
        (should (equal (button-label (button-at (point))) "first"))
        (should (equal (portal-tasks-view-test--at view) "Second"))
        (push-button))
      (with-current-buffer (window-buffer)
        (should (eq (current-buffer) (find-buffer-visiting file)))
        (should (equal (org-get-heading t t t t) "First"))))))

(ert-deftest portal-tasks-view-blocks-tasks-in-invalid-graphs ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO Anonymous")
                  (portal-tasks-view-test--task "TODO Twin one" :id "twin")
                  (portal-tasks-view-test--task "TODO Twin two" :id "twin")
                  (portal-tasks-view-test--task "TODO Needs twin" :id "needs-twin" :depends "twin")
                  (portal-tasks-view-test--task "TODO Needs ghost" :id "needs-ghost" :depends "ghost")
                  "** DONE Not a task\n:PROPERTIES:\n:CUSTOM_ID: untagged\n:END:\n"
                  (portal-tasks-view-test--task "TODO Needs untagged" :id "needs-untagged"
                                                :depends "untagged")
                  (portal-tasks-view-test--task "TODO Self" :id "self" :depends "self")
                  (portal-tasks-view-test--task "TODO Loop" :id "loop" :depends "loop-done")
                  (portal-tasks-view-test--task "DONE Loop done" :id "loop-done" :depends "loop")
                  (portal-tasks-view-test--task "TODO After the loop" :id "after-loop" :depends "loop-done")
                  (portal-tasks-view-test--task "Without keyword" :id "bare")))
           (view (portal-tasks-view-test--open file)))
      ;; Only the dependent of a done task in a loop is actionable.
      (should (equal (portal-tasks-view-test--titles view) '("After the loop")))
      (portal-tasks-toggle-all)
      (should (equal (portal-tasks-view-test--lines view)
                     '("Actionable (1)" "TODO After the loop :task:"
                       "Blocked (9)"
                       "TODO Anonymous — no CUSTOM_ID :task:"
                       "TODO Twin one — CUSTOM_ID twin is not unique :task:"
                       "TODO Twin two — CUSTOM_ID twin is not unique :task:"
                       "TODO Needs twin — twin is not unique :task:"
                       "TODO Needs ghost — no task ghost :task:"
                       "TODO Needs untagged — no task untagged :task:"
                       "TODO Self — waiting for self (TODO); dependency cycle through self :task:"
                       "TODO Loop — dependency cycle through loop-done :task:"
                       "Without keyword — no TODO keyword :task:"
                       "Closed (1)" "DONE Loop done :task:")))
      ;; Fixing the graph unblocks its tasks.
      (with-current-buffer (find-buffer-visiting file)
        (goto-char (point-min))
        (re-search-forward "^:DEPENDS_ON: loop\n")
        (replace-match ""))
      (with-current-buffer view (portal-tasks-refresh))
      (should (member "TODO Loop :task:" (portal-tasks-view-test--lines view))))))

(ert-deftest portal-tasks-view-finds-prerequisites-in-archives ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO After archived" :id "after" :depends "archived")
                  (portal-tasks-view-test--task "TODO After shelved" :id "later" :depends "shelved")
                  (portal-tasks-view-test--task "TODO Reused" :id "reused")
                  (portal-tasks-view-test--task "TODO Circular" :id "circular"
                                                :depends "archived-loop")))
           (view nil))
      (with-temp-file (concat file "_archive")
        (insert "#    -*- mode: org -*-\n#+TODO: TODO | DONE CANCELLED\n"
                "* DONE Archived :task:\n:PROPERTIES:\n:CUSTOM_ID: archived\n:END:\n"
                "* TODO Shelved :task:\n:PROPERTIES:\n:CUSTOM_ID: shelved\n:END:\n"
                "* DONE Reused before :task:\n:PROPERTIES:\n:CUSTOM_ID: reused\n:END:\n"
                "* DONE Archived loop :task:\n"
                ":PROPERTIES:\n:CUSTOM_ID: archived-loop\n:DEPENDS_ON: circular\n:END:\n"))
      (setq view (portal-tasks-view-test--open file))
      (portal-tasks-toggle-all)
      ;; Archived tasks satisfy and block dependents, and close cycles, but
      ;; are not listed.
      (should (equal (portal-tasks-view-test--lines view)
                     '("Actionable (1)" "TODO After archived :task:"
                       "Blocked (3)"
                       "TODO After shelved — waiting for shelved (TODO) :task:"
                       "TODO Reused — CUSTOM_ID reused is not unique :task:"
                       "TODO Circular — dependency cycle through archived-loop :task:")))
      ;; The view follows the archive's buffer too, and its link goes there.
      (with-current-buffer (find-buffer-visiting (concat file "_archive"))
        (goto-char (point-min))
        (re-search-forward "^\\* TODO Shelved")
        (let ((org-inhibit-logging t)) (org-todo "DONE"))
        (save-buffer))
      (should (member "TODO After shelved :task:" (portal-tasks-view-test--lines view)))
      (with-current-buffer (find-buffer-visiting (concat file "_archive"))
        (goto-char (point-min))
        (re-search-forward "^\\* DONE Shelved")
        (let ((org-inhibit-logging t)) (org-todo "TODO")))
      (with-current-buffer view
        (portal-tasks-refresh)
        (goto-char (button-start (next-button (point-min))))
        (push-button))
      (with-current-buffer (window-buffer)
        (should (equal buffer-file-name (concat file "_archive")))
        (should (equal (org-get-heading t t t t) "Shelved"))))))

(ert-deftest portal-tasks-view-belongs-to-the-current-project ()
  (portal-tasks-view-test--environment
    (let* ((one (portal-tasks-view-test--project "one/app" (portal-tasks-view-test--task "TODO In one" :id "a")))
           (two (portal-tasks-view-test--project "two/app" (portal-tasks-view-test--task "TODO In two" :id "a")))
           (bare (expand-file-name "bare/" portal-tasks-view-test--directory))
           (loose (expand-file-name "loose/" portal-tasks-view-test--directory))
           (first (portal-tasks-view-test--open one)))
      (make-directory (expand-file-name ".git" bare) t)
      (make-directory loose t)
      (should (equal (portal-tasks-view-test--titles first) '("In one")))
      ;; From a terminal, the project is the terminal's, not the last file's.
      (let ((default-directory (file-name-directory two)))
        (portal-terminal-new))
      (should (portal-terminal-metadata))
      (should (equal (frame-parameter nil 'portal-project-context) (file-name-directory one)))
      (let ((second (portal-tasks)))
        (should-not (eq second first))
        (should (equal (portal-tasks-view-test--titles second) '("In two")))
        ;; From an auxiliary buffer, it is the last file's; from a view, its own.
        (switch-to-buffer (get-buffer-create "*auxiliary*"))
        (should (eq (portal-tasks) first))
        (should (eq (portal-tasks) first))
        (switch-to-buffer second)
        (should (eq (portal-tasks) second)))
      ;; Without a project, or a project.org, there is no view.
      (let ((default-directory loose))
        (portal-terminal-new))
      (should-error (portal-tasks) :type 'user-error)
      (switch-to-buffer (get-buffer-create "*auxiliary*"))
      (set-frame-parameter nil 'portal-project-context loose)
      (should-error (portal-tasks) :type 'user-error)
      (set-frame-parameter nil 'portal-project-context bare)
      (should-error (portal-tasks) :type 'user-error))))

(ert-deftest portal-tasks-view-refreshes-and-keeps-each-pane-on-its-task ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :depends "first")
                  (portal-tasks-view-test--task "TODO Third" :id "third")
                  (portal-tasks-view-test--task "TODO Fourth" :id "fourth"
                                                :planning (concat "SCHEDULED: " (portal-tasks-view-test--day 1)))))
           (view (portal-tasks-view-test--open file))
           (source (find-buffer-visiting file))
           (other (split-window)))
      (portal-tasks-toggle-all)
      (set-window-buffer other view)
      (portal-tasks-view-test--goto view "Third")
      (with-selected-window other (portal-tasks-view-test--goto view "Second"))
      ;; g keeps the choice of tasks, and each pane its task, as tasks move.
      (with-current-buffer source
        (goto-char (point-min))
        (re-search-forward "^\\*\\* TODO First")
        (beginning-of-line)
        (insert (portal-tasks-view-test--task "TODO Zeroth" :id "zeroth")))
      (portal-tasks-refresh)
      (should (equal (car (portal-tasks-view-test--titles view)) "Actionable (3)"))
      (should (equal (portal-tasks-view-test--at view) "Third"))
      (with-selected-window other
        (should (equal (portal-tasks-view-test--at view) "Second")))
      ;; Saving the file redraws the view; a task that is gone leaves its pane
      ;; on the same line.
      (portal-tasks-view-test--set file "First" "DONE")
      (with-current-buffer source (save-buffer))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (3)" "Zeroth" "Second" "Third" "Deferred (1)" "Fourth"
                       "Closed (1)" "First")))
      (should (equal (portal-tasks-view-test--at view) "Third"))
      (with-selected-window other
        (should (equal (portal-tasks-view-test--at view) "Second")))
      ;; Returning to the view after an edit redraws it, and after the day
      ;; changes too.
      (portal-tasks-view-test--set file "First" "TODO")
      (portal-tasks--shown (selected-window))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (3)" "Zeroth" "First" "Third" "Blocked (1)" "Second"
                       "Deferred (1)" "Fourth")))
      (let ((tomorrow (1+ (org-today))))
        (cl-letf (((symbol-function 'org-today) (lambda () tomorrow)))
          (portal-tasks--shown (selected-window))))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (4)" "Zeroth" "First" "Third" "Fourth" "Blocked (1)" "Second")))
      ;; Switching to actionable tasks keeps the task at point when it is listed.
      (portal-tasks-view-test--goto view "Third")
      (portal-tasks-toggle-all)
      (should (equal (portal-tasks-view-test--at view) "Third"))
      ;; A pane that showed the view may show another buffer by the time
      ;; Emacs reports it; that buffer is left alone.
      (let ((text (with-current-buffer source (buffer-string))))
        (set-window-buffer other source)
        (portal-tasks--shown other)
        (should (equal (with-current-buffer source (buffer-string)) text))
        (with-current-buffer source
          (should-error (portal-tasks-refresh) :type 'user-error)
          (should-error (portal-tasks-toggle-all) :type 'user-error))
        (should (equal (with-current-buffer source (buffer-string)) text))))))

(ert-deftest portal-tasks-view-explains-an-empty-list ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO Waiting" :id "waiting" :depends "elsewhere")))
           (view (portal-tasks-view-test--open file)))
      (should (equal (portal-tasks-view-test--lines view)
                     '("No actionable tasks. v lists every task.")))
      (with-current-buffer (find-buffer-visiting file)
        (erase-buffer)
        (insert "* Notes\n"))
      (with-current-buffer view (portal-tasks-refresh))
      (should (equal (portal-tasks-view-test--lines view)
                     '("No headings in this file have a task tag."))))))

(ert-deftest portal-tasks-view-lines-take-org-agenda-commands ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :depends "first")))
           (view (portal-tasks-view-test--open file)))
      (portal-tasks-view-test--goto view "First")
      (let ((org-inhibit-logging t)) (org-agenda-todo "DONE"))
      (with-current-buffer (find-buffer-visiting file)
        (goto-char (point-min))
        (re-search-forward "^\\*\\* \\(\\w+\\) First")
        (should (equal (match-string 1) "DONE")))
      (portal-tasks-refresh)
      (should (equal (portal-tasks-view-test--titles view) '("Second")))
      ;; Killing the view leaves the markers of other agenda buffers alone.
      (let ((marker (with-current-buffer (find-buffer-visiting file)
                      (org-agenda-new-marker (point-min)))))
        (kill-buffer view)
        (should (marker-buffer marker))))))

(provide 'portal-tasks-view-tests)
;;; portal-tasks-view-tests.el ends here
