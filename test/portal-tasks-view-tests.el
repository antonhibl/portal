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

;; One test loads evil-collection, which needs Evil without its own keys.
(defvar evil-want-keybinding nil)

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

(cl-defun portal-tasks-view-test--task (heading &key id depends planning body)
  "Return a task HEADING with planning line PLANNING, CUSTOM_ID ID and DEPENDS.
BODY follows its properties."
  (concat "** " heading " :task:\n"
          (if planning (concat planning "\n") "")
          (if (or id depends)
              (concat ":PROPERTIES:\n"
                      (if id (format ":CUSTOM_ID: %s\n" id) "")
                      (if depends (format ":DEPENDS_ON: %s\n" depends) "")
                      ":END:\n")
            "")
          (or body "")))

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

(defun portal-tasks-view-test--detail ()
  "Return the title of the task the selected pane's task detail shows, or nil.
The detail is narrowed to all of that task."
  (with-current-buffer (window-buffer)
    (when portal-tasks-detail-mode
      (save-excursion
        (goto-char (point-min))
        (should (org-at-heading-p))
        (should (= (point-max) (save-excursion (save-restriction
                                                 (widen)
                                                 (org-end-of-subtree t t)
                                                 (if (eobp) (point) (1- (point)))))))
        (org-get-heading t t t t)))))

(defun portal-tasks-view-test--hidden-p (buffer text)
  "Return non-nil if Org folds away TEXT in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (search-forward text)
        (invisible-p (match-beginning 0))))))

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
      ;; RET shows the task in its detail; Org's other keys stay.
      (should (eq (key-binding (kbd "RET")) #'portal-tasks-open))
      (should (eq (key-binding "t") #'org-agenda-todo))
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
      ;; A blocker's link shows it in the task detail.
      (with-current-buffer view
        (goto-char (button-start (next-button (point-min))))
        (should (equal (button-label (button-at (point))) "first"))
        (should (equal (portal-tasks-view-test--at view) "Second"))
        (push-button))
      (with-current-buffer (window-buffer)
        (should (eq (buffer-base-buffer) (find-buffer-visiting file)))
        (should (equal (portal-tasks-view-test--detail) "First"))))))

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
        (should (equal (buffer-file-name (buffer-base-buffer)) (concat file "_archive")))
        (should (equal (portal-tasks-view-test--detail) "Shelved"))))))

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

(ert-deftest portal-tasks-view-keys-work-with-evil-collection ()
  ;; evil-collection shows agenda buffers in Evil's normal state, whose
  ;; agenda keys outrank the view's own.
  (require 'evil)
  (require 'evil-collection)
  (evil-collection-init 'org-agenda)
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :depends "first")))
           (view (portal-tasks-view-test--open file)))
      (evil-local-mode 1)
      (should (eq evil-state 'normal))
      ;; Portal's commands have evil-collection's keys for them; the other
      ;; keys stay evil-collection's and Evil's.
      (dolist (binding '(("RET" . portal-tasks-open) ("<return>" . portal-tasks-open)
                         ("gr" . portal-tasks-refresh) ("gR" . portal-tasks-refresh)
                         ("v" . portal-tasks-toggle-all) ("q" . quit-window)
                         ("t" . org-agenda-todo) ("r" . org-agenda-refile)
                         ("gj" . org-agenda-next-item) ("gg" . evil-goto-first-line)))
        (should (eq (key-binding (kbd (car binding))) (cdr binding))))
      (execute-kbd-macro (kbd "v"))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (1)" "First" "Blocked (1)" "Second")))
      (portal-tasks-view-test--goto view "First")
      (execute-kbd-macro (kbd "RET"))
      (should (equal (portal-tasks-view-test--detail) "First"))
      (switch-to-buffer view)
      (portal-tasks-view-test--set file "First" "DONE")
      (execute-kbd-macro (kbd "gr"))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (1)" "Second" "Closed (1)" "First")))
      (execute-kbd-macro (kbd "q"))
      (should-not (eq (window-buffer) view)))))

(ert-deftest portal-tasks-detail-shows-one-task-in-org ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first"
                                                :body "First's body.\n*** Notes\nA note.\n")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :body "Second's body.\n")
                  (portal-tasks-view-test--task "TODO Anonymous" :body "No ID.\n")
                  (portal-tasks-view-test--task "TODO Twin one" :id "twin")
                  (portal-tasks-view-test--task "TODO Twin two" :id "twin" :depends "first")))
           (view (portal-tasks-view-test--open file))
           (source (find-buffer-visiting file))
           (keys (mapcar #'kbd '("a" "RET" "TAB" "C-c C-t" "C-c C-o" "C-c C-s" "C-c C-c"
                                 "C-c C-x C-b" "C-x C-s" "C-/"))))
      (with-current-buffer source (org-overview))
      (portal-tasks-view-test--goto view "First")
      (portal-tasks-open)
      (let ((detail (window-buffer)))
        (should (equal (buffer-name detail)
                       (format "*task: %s*" (abbreviate-file-name
                                             (directory-file-name (file-name-directory file))))))
        (should (eq (buffer-base-buffer detail) source))
        ;; The whole task, at its heading, with folds of its own.
        (should (equal (portal-tasks-view-test--detail) "First"))
        (should (= (window-point) (point-min)))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (concat "** TODO First :task:\n:PROPERTIES:\n:CUSTOM_ID: first\n:END:\n"
                               "First's body.\n*** Notes\nA note.")))
        (should-not (portal-tasks-view-test--hidden-p detail "A note."))
        (should-not (portal-tasks-view-test--hidden-p detail ":CUSTOM_ID:"))
        (should (portal-tasks-view-test--hidden-p source "First's body."))
        ;; Typing at its end edits no folded text.
        (goto-char (point-max))
        (let ((org-fold-catch-invisible-edits 'error))
          (execute-kbd-macro (kbd "!")))
        (should (string-suffix-p "A note.!" (buffer-string)))
        (delete-char -1)
        (goto-char (point-min))
        ;; Keys are Org's, but for Back.
        (should (derived-mode-p 'org-mode))
        (dolist (key keys)
          (should (eq (key-binding key) (with-current-buffer source (key-binding key)))))
        (should (eq (key-binding (kbd "M-,")) #'portal-tasks-back))
        ;; Back shows the view on the task; the next task reuses the detail.
        (portal-tasks-back)
        (should (eq (window-buffer) view))
        (should (equal (portal-tasks-view-test--at view) "First"))
        (portal-tasks-view-test--goto view "Second")
        (portal-tasks-open)
        (should (eq (window-buffer) detail))
        (should (equal (portal-tasks-view-test--detail) "Second"))
        (should (portal-tasks-view-test--hidden-p source "Second's body."))
        ;; The detail's project is its own.
        (should (eq (portal-tasks) view))
        ;; A task its CUSTOM_ID does not find, as it has none or shares it,
        ;; opens in its file, as in Org.
        (portal-tasks-toggle-all)
        (dolist (title '("Anonymous" "Twin one" "Twin two"))
          (portal-tasks-view-test--goto view title)
          (portal-tasks-open)
          (should (eq (window-buffer) source))
          (should (equal (org-get-heading t t t t) title))
          (switch-to-buffer view))
        ;; Back from its blocker returns to its line, not to its twin's.
        (portal-tasks-view-test--goto view "Twin two")
        (goto-char (button-start (next-button (point))))
        (push-button)
        (should (eq (window-buffer) detail))
        (should (equal (portal-tasks-view-test--detail) "First"))
        (portal-tasks-back)
        (should (eq (window-buffer) view))
        (should (equal (portal-tasks-view-test--at view) "Twin two"))))))

(ert-deftest portal-tasks-detail-follows-task-links-and-goes-back ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first")
                  (portal-tasks-view-test--task
                   "TODO Second" :id "second" :depends "first"
                   :body (concat "*** Blocked by\n[[#first][The first task]], once "
                                 "[[#archived][the archived one]] was done.\n"
                                 "Not [[#twin][a twin]].\n"
                                 "See [[#second-notes][the notes]].\n"
                                 "*** Notes\n:PROPERTIES:\n:CUSTOM_ID: second-notes\n:END:\n"
                                 "Notes.\n"))
                  (portal-tasks-view-test--task "TODO Third" :id "third")
                  (portal-tasks-view-test--task "TODO Twin" :id "twin")))
           (archive (concat file "_archive"))
           (view nil) (detail nil) (name nil) (link nil))
      (with-temp-file archive
        (insert "#    -*- mode: org -*-\n#+TODO: TODO | DONE CANCELLED\n"
                "* DONE Archived :task:\n:PROPERTIES:\n:CUSTOM_ID: archived\n:END:\nDone long ago.\n"
                "* DONE Twin before :task:\n:PROPERTIES:\n:CUSTOM_ID: twin\n:END:\n"))
      (setq view (portal-tasks-view-test--open file))
      (portal-tasks-toggle-all)
      (portal-tasks-view-test--goto view "Second")
      (portal-tasks-open)
      (setq detail (window-buffer) name (buffer-name detail))
      ;; A task's link shows it, and Back returns to the link.
      (search-forward "first task")
      (setq link (point))
      (org-open-at-point)
      (should (eq (window-buffer) detail))
      (should (equal (portal-tasks-view-test--detail) "First"))
      (portal-tasks-back)
      (should (equal (portal-tasks-view-test--detail) "Second"))
      (should (= (window-point) link))
      ;; An archived task shows in the same detail, and unsaved edits stay.
      (insert " Edited")
      (search-forward "archived one")
      (setq link (point))
      (org-open-at-point)
      (should (equal (portal-tasks-view-test--detail) "Archived"))
      (should (equal (buffer-file-name (buffer-base-buffer)) archive))
      (should (equal (buffer-name) name))
      (portal-tasks-back)
      (should (equal (portal-tasks-view-test--detail) "Second"))
      (should (equal (buffer-file-name (buffer-base-buffer)) file))
      (should (= (window-point) link))
      (should (search-backward "first task Edited]], once" nil t))
      (should (buffer-modified-p (buffer-base-buffer)))
      (goto-char link)
      ;; A CUSTOM_ID two tasks share, here and in the archive, shows neither.
      (search-forward "a twin")
      (should-error (org-open-at-point) :type 'user-error)
      (should (equal (portal-tasks-view-test--detail) "Second"))
      ;; Org follows a link to a heading that is not a task.
      (search-forward "the notes")
      (org-open-at-point)
      (should (equal (portal-tasks-view-test--detail) "Second"))
      (should (looking-at-p "\\*\\*\\* Notes"))
      ;; Back reaches the view, on the task the detail was opened from,
      ;; though another pane has moved in the view since.
      (setq detail (window-buffer))
      (let ((other (split-window)))
        (set-window-buffer other view)
        (with-selected-window other (portal-tasks-view-test--goto view "Third"))
        (portal-tasks-back)
        (delete-window other))
      (should (eq (window-buffer) view))
      (should (equal (portal-tasks-view-test--at view) "Second"))
      (should (equal (car (portal-tasks-view-test--titles view)) "Actionable (2)"))
      ;; A blocker's button in the view comes back to its line.
      (portal-tasks-view-test--goto view "Third")
      (portal-tasks-view-test--goto view "Second")
      (goto-char (button-start (next-button (point))))
      (push-button)
      (should (eq (window-buffer) detail))
      (should (equal (portal-tasks-view-test--detail) "First"))
      (portal-tasks-back)
      (should (eq (window-buffer) view))
      (should (equal (portal-tasks-view-test--at view) "Second"))
      ;; Without the view, Back makes another, listing all tasks again.
      (portal-tasks-view-test--goto view "Second")
      (portal-tasks-open)
      (kill-buffer view)
      (portal-tasks-back)
      (should (equal (buffer-local-value 'portal-tasks--file (window-buffer)) file))
      (should (equal (car (portal-tasks-view-test--titles (window-buffer))) "Actionable (2)"))
      (should (equal (portal-tasks-view-test--at (window-buffer)) "Second")))))

(ert-deftest portal-tasks-detail-edits-the-file-buffer ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first" :body "Body.\n")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :depends "first")))
           (view (portal-tasks-view-test--open file))
           (source (find-buffer-visiting file))
           (text (with-current-buffer source (buffer-string))))
      (portal-tasks-view-test--goto view "First")
      (execute-kbd-macro (kbd "RET"))
      ;; Typing and Org's keys edit the task in the file's buffer, unsaved.
      (goto-char (point-max))
      (execute-kbd-macro (kbd "RET A d d e d . M-< C-c C-t"))
      (should (equal (portal-tasks-view-test--detail) "First"))
      (should (string-suffix-p "Body.\nAdded." (buffer-string)))
      (should (string-prefix-p "** DONE First" (buffer-string)))
      ;; Back redraws the view, which reads the unsaved buffer.
      (execute-kbd-macro (kbd "M-,"))
      (should (eq (window-buffer) view))
      (should (equal (portal-tasks-view-test--titles view) '("Second")))
      (should (buffer-modified-p source))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) text))
      ;; The task keeps its edits when shown again, and undo is the file's.
      (portal-tasks-toggle-all)
      (portal-tasks-view-test--goto view "First")
      (execute-kbd-macro (kbd "RET"))
      (should (string-prefix-p "** DONE First" (buffer-string)))
      (should (string-suffix-p "Added." (buffer-string)))
      (execute-kbd-macro (kbd "C-/"))
      (should (string-prefix-p "** TODO First" (buffer-string)))
      (with-current-buffer source
        (goto-char (point-min))
        (should (re-search-forward "^\\*\\* TODO First" nil t)))
      ;; Saving there saves the file, and redraws the view.
      (execute-kbd-macro (kbd "C-x C-s"))
      (should-not (buffer-modified-p source))
      (should (string-match-p "Body\\.\nAdded\\.\n"
                              (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (1)" "First" "Blocked (1)" "Second"))))))

(ert-deftest portal-tasks-detail-changes-any-state-and-reopens-closed-tasks ()
  (portal-tasks-view-test--environment
    (let* ((file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "DONE Shipped" :id "shipped"
                                                :body "*** Outcome\nIt shipped.\n")
                  (portal-tasks-view-test--task "CANCELLED Dropped" :id "dropped"
                                                :body "*** Outcome\nNot needed.\n")
                  (portal-tasks-view-test--task "TODO After" :id "after" :depends "dropped")
                  (portal-tasks-view-test--task "TODO Waiting" :id "waiting" :depends "after")))
           (view (portal-tasks-view-test--open file))
           (org-inhibit-logging t))
      (portal-tasks-toggle-all)
      (should (equal (portal-tasks-view-test--titles view)
                     '("Blocked (2)" "After" "Waiting" "Closed (2)" "Shipped" "Dropped")))
      ;; Closed tasks reopen in their detail, keeping their sections.
      (dolist (title '("Shipped" "Dropped"))
        (portal-tasks-view-test--goto view title)
        (portal-tasks-open)
        (org-todo "TODO")
        (should (equal (portal-tasks-view-test--detail) title))
        (should (string-match-p "\\*\\*\\* Outcome\n" (buffer-string)))
        (portal-tasks-back))
      (should (equal (portal-tasks-view-test--titles view)
                     '("Actionable (2)" "Shipped" "Dropped" "Blocked (2)" "After" "Waiting")))
      ;; Readiness never stops a state change: a blocked task can be done.
      (portal-tasks-view-test--goto view "Waiting")
      (portal-tasks-open)
      (org-todo "DONE")
      (portal-tasks-back)
      ;; Cancelling a task blocks its dependents again.
      (portal-tasks-view-test--goto view "Dropped")
      (portal-tasks-open)
      (org-todo "CANCELLED")
      (portal-tasks-back)
      (should (equal (portal-tasks-view-test--lines view)
                     '("Actionable (1)" "TODO Shipped :task:"
                       "Blocked (1)" "TODO After — waiting for dropped (CANCELLED) :task:"
                       "Closed (2)" "CANCELLED Dropped :task:" "DONE Waiting :task:"))))))

(defun portal-tasks-view-test--launch ()
  "Return the latest terminal start as (DIRECTORY ARGV BRIEF).
ARGV is a list, and BRIEF the file its last argument names with @."
  (let* ((options (cadr (car (last (portal-fake-native-calls 'portal--open)))))
         (argv (append (json-parse-string (plist-get options :argv)) nil))
         (prompt (car (last argv))))
    (list (plist-get options :directory) argv
          (and (string-match "@\"\\([^\"]+\\)\"" prompt) (match-string 1 prompt)))))

(defun portal-tasks-view-test--read (file)
  "Return FILE's text."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun portal-tasks-view-test--brief-directory ()
  "Make and return this test's directory for briefs."
  (let ((directory (expand-file-name "briefs/" portal-tasks-view-test--directory)))
    (make-directory directory)
    directory))

(defun portal-tasks-view-test--briefs ()
  "Return the files in `temporary-file-directory', where briefs go."
  (directory-files temporary-file-directory t directory-files-no-dot-files-regexp))

(defun portal-tasks-view-test--implement (view title &optional new)
  "Show VIEW in the selected pane and implement its task TITLE, NEW if non-nil."
  (switch-to-buffer view)
  (portal-tasks-view-test--goto view title)
  (portal-tasks-implement new))

(ert-deftest portal-tasks-implement-follows-emacs-display-rules ()
  (dolist (placement '(side-window same-window base-action full-frame default))
    (portal-tasks-view-test--environment
      (let* ((temporary-file-directory (portal-tasks-view-test--brief-directory))
             (display-buffer-overriding-action nil)
             (display-buffer-base-action
              (and (eq placement 'base-action) '(display-buffer-same-window)))
             (display-buffer-alist
              (pcase placement
                ('side-window '(("\\`\\*claude: " display-buffer-in-side-window (side . right))))
                ('same-window '(("\\`\\*claude: " display-buffer-same-window)))
                ('full-frame '(("\\`\\*claude: " display-buffer-full-frame)))))
             (file (portal-tasks-view-test--project
                    "app" (portal-tasks-view-test--task "TODO Target" :id "target")))
             (view (portal-tasks-view-test--open file))
             (task-window (selected-window))
             previous)
        (split-window-below)
        ;; The same display rules govern starting, reusing, and forcing a run.
        (dolist (new '(nil nil t))
          (select-window task-window)
          (let ((terminal (portal-tasks-view-test--implement view "Target" new)))
            (should (eq (window-buffer) terminal))
            (should (plist-get (portal--inspect (portal-view-target)) :focused))
            (should (= (length (window-list))
                       (pcase placement ('side-window 3) ('full-frame 1) (_ 2))))
            (pcase placement
              ('side-window (should (eq (window-parameter nil 'window-side) 'right)))
              ((or 'same-window 'base-action 'full-frame)
               (should (eq (selected-window) task-window))))
            (when previous
              (if new (should-not (eq terminal previous)) (should (eq terminal previous))))
            (should (= (length (portal-view-buffers 'terminal)) (if new 2 1)))
            (should (buffer-live-p view))
            (setq previous terminal)))))))

(ert-deftest portal-tasks-implement-starts-claude-on-a-brief-of-one-task ()
  (portal-tasks-view-test--environment
    (let* ((temporary-file-directory (portal-tasks-view-test--brief-directory))
           (neighbor (mapconcat (lambda (n) (format "Neighbor line %d.\n" n))
                                (number-sequence 1 3000)))
           (file (portal-tasks-view-test--project
                  "it's a \"spaced\" app"
                  (portal-tasks-view-test--task "DONE Before" :id "before"
                                                :body (concat "Prerequisite body.\n" neighbor))
                  (portal-tasks-view-test--task
                   "TODO Target" :id "target" :depends "before"
                   :body (concat "Target body.\n*** Plan\nSee [[#before][Before]] and "
                                 "[[file:docs/x.md][x]].\n**** Detail\nDeep.\n"))
                  (portal-tasks-view-test--task "TODO After" :id "after" :body neighbor)))
           (root (file-name-directory file))
           (saved (portal-tasks-view-test--read file))
           (start (string-search "** TODO Target" saved))
           (subtree (substring saved start (string-search "** TODO After" saved)))
           (first-line (1+ (cl-count ?\n saved :end start)))
           (digest (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally file)
                     (secure-hash 'sha256 (current-buffer))))
           (portal-tasks-claude-program "claude probe")
           (portal-tasks-claude-arguments '("--model" "a 'b' \"c\""))
           (view (portal-tasks-view-test--open file))
           (source (find-buffer-visiting file)))
      ;; From a line of the task view.
      (let ((terminal (portal-tasks-view-test--implement view "Target")))
        (should (eq (window-buffer) terminal))
        (should (equal (buffer-name terminal) "*claude: target*"))
        (pcase-let ((`(,directory ,argv ,brief) (portal-tasks-view-test--launch)))
          ;; Claude starts at the project root with literal arguments.
          (should (equal directory root))
          (should (equal (butlast argv) '("claude probe" "--model" "a 'b' \"c\"")))
          (should (string-search (format "of task target in %s," file) (car (last argv))))
          (should (string-search "mark the task DONE in project.org" (car (last argv))))
          ;; The brief is a new read-only file: provenance, then exactly the
          ;; saved subtree, without its neighbors or prerequisites.
          (should (equal (portal-tasks-view-test--briefs) (list brief)))
          (should (= (file-modes brief) #o400))
          (let* ((text (portal-tasks-view-test--read brief))
                 (header (split-string (substring text 0 (string-search "\n\n" text)) "\n")))
            (should (equal (substring text (+ 2 (string-search "\n\n" text))) subtree))
            (should (member (concat "# Project: " root) header))
            (should (member (concat "# Source: " file) header))
            (should (member "# CUSTOM_ID: target" header))
            (should (member (format "# Lines: %d-%d" first-line
                                    (+ first-line (cl-count ?\n subtree) -1))
                            header))
            (should (member (concat "# Source SHA-256: " digest) header))
            (should-not (string-search "Neighbor" text))
            (should-not (string-search "Prerequisite" text)))
          ;; Starting changes no task.
          (should (equal (portal-tasks-view-test--read file) saved))
          (should-not (buffer-modified-p source))
          ;; Again, the task's terminal is shown; another run is explicit.
          (should (eq (portal-tasks-view-test--implement view "Target") terminal))
          (should (eq (window-buffer) terminal))
          (should (= (length (portal-fake-native-calls 'portal--open)) 1))
          (let ((again (portal-tasks-view-test--implement view "Target" t))
                (second (nth 2 (portal-tasks-view-test--launch))))
            (should-not (eq again terminal))
            (should-not (equal second brief))
            (should (equal (portal-tasks-view-test--read second)
                           (portal-tasks-view-test--read brief)))
            (should (eq (portal-tasks-view-test--implement view "Target") again))
            ;; A brief lasts as long as its terminal.
            (kill-buffer again)
            (should-not (file-exists-p second))
            (should (file-exists-p brief))
            (should (eq (portal-tasks-view-test--implement view "Target") terminal))
            (with-current-buffer terminal (portal-terminal-close))
            (should-not (portal-tasks-view-test--briefs)))))
      ;; From inside a task, in its detail or in project.org.
      (switch-to-buffer view)
      (portal-tasks-view-test--goto view "After")
      (portal-tasks-open)
      (goto-char (point-max))
      (should (equal (buffer-name (portal-tasks-implement)) "*claude: after*"))
      (let ((text (portal-tasks-view-test--read (nth 2 (portal-tasks-view-test--launch)))))
        (should (string-search "\n\n** TODO After :task:\n" text))
        (should (string-suffix-p "Neighbor line 3000.\n" text))
        (should-not (string-search "Target" text)))
      (switch-to-buffer source)
      (goto-char (point-min))
      (search-forward "Deep.")
      ;; The closed terminal's buffer keeps its name.
      (should (equal (buffer-name (portal-tasks-implement)) "*claude: target*<2>"))
      (should (string-search "\n\n** TODO Target :task:\n"
                             (portal-tasks-view-test--read (nth 2 (portal-tasks-view-test--launch))))))))

(ert-deftest portal-tasks-implement-starts-nothing-unless-actionable-and-saved ()
  (portal-tasks-view-test--environment
    (let* ((temporary-file-directory (portal-tasks-view-test--brief-directory))
           (file (portal-tasks-view-test--project
                  "app"
                  (portal-tasks-view-test--task "TODO First" :id "first" :body "Body.\n")
                  (portal-tasks-view-test--task "TODO Second" :id "second" :depends "first")
                  (portal-tasks-view-test--task "DONE Shipped" :id "shipped")
                  (portal-tasks-view-test--task "TODO Anonymous")
                  "** Notes\nNot a task.\n"))
           (view (portal-tasks-view-test--open file))
           (source (find-buffer-visiting file))
           (saved (portal-tasks-view-test--read file))
           (answer nil)
           (asked 0))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asked) answer)))
        (cl-flet ((refused (message)
                    (should (string-match-p message (cadr (should-error (portal-tasks-implement)
                                                                        :type 'user-error))))
                    (should-not (portal-fake-native-calls 'portal--open))
                    (should-not (portal-tasks-view-test--briefs))
                    (should (equal (portal-tasks-view-test--read file) saved))))
          (with-current-buffer source
            (goto-char (point-min))
            (search-forward "Body.")
            (insert " Unsaved."))
          ;; A task that is not actionable is refused before saving.
          (portal-tasks-toggle-all)
          (portal-tasks-view-test--goto view "Second")
          (refused "not actionable: waiting for first (TODO)")
          (portal-tasks-view-test--goto view "Shipped")
          (refused "not actionable: DONE")
          (portal-tasks-view-test--goto view "Anonymous")
          (refused "CUSTOM_ID of its own")
          (should (= asked 0))
          (switch-to-buffer source)
          (goto-char (point-min))
          (refused "Not in a task")
          (search-forward "Not a task.")
          (refused "Not in a task")
          ;; Only project.org's own task, not one elsewhere with its CUSTOM_ID.
          (find-file (expand-file-name "notes.org" (file-name-directory file)))
          (insert (portal-tasks-view-test--task "TODO Copy" :id "first"))
          (refused "CUSTOM_ID of its own")
          (set-buffer-modified-p nil)
          ;; Declining to save, or a failed save, keeps the edit unsaved.
          (switch-to-buffer view)
          (portal-tasks-view-test--goto view "First")
          (refused "not saved")
          (should (= asked 1))
          (setq answer t)
          (with-current-buffer source
            (add-hook 'write-contents-functions (lambda () (error "Disk full")) nil t))
          (should-error (portal-tasks-implement))
          (should-not (portal-fake-native-calls 'portal--open))
          (should-not (portal-tasks-view-test--briefs))
          (with-current-buffer source
            (kill-local-variable 'write-contents-functions)
            (should (buffer-modified-p))
            (should (string-search "Body. Unsaved." (buffer-string))))
          ;; A file changed on disk is a conflict to resolve first.
          (setq saved (string-replace "Body." "Changed." saved))
          (with-temp-file file (insert saved))
          (set-file-times file (time-subtract nil 60))
          (refused "changed on disk")
          (with-current-buffer source
            (should (string-search "Body. Unsaved." (buffer-string)))
            (revert-buffer t t)
            (goto-char (point-min))
            (search-forward "Changed.")
            (insert " Unsaved."))
          ;; Saving, when asked, saves the edit the brief then holds.
          (setq asked 0)
          (portal-tasks-refresh)
          (portal-tasks-view-test--goto view "First")
          (portal-tasks-implement)
          (should (= asked 1))
          (should-not (buffer-modified-p source))
          (should (string-search "Changed. Unsaved."
                                 (portal-tasks-view-test--read
                                  (nth 2 (portal-tasks-view-test--launch)))))
          ;; A terminal that fails to start leaves no brief.
          (let ((briefs (portal-tasks-view-test--briefs))
                (portal-fake-native-failures '(portal--open)))
            (should-error (portal-tasks-view-test--implement view "First" t))
            (should (equal (portal-tasks-view-test--briefs) briefs))
            (should (= (length (portal-view-buffers 'terminal)) 1)))
          ;; A save hook that edits the buffer again leaves text no brief
          ;; may hold, as it is not saved.
          (with-current-buffer source
            (goto-char (point-max))
            (insert "Edited.\n")
            (add-hook 'after-save-hook (lambda () (goto-char (point-max)) (insert "Stamp.\n"))
                      nil t))
          (let ((briefs (portal-tasks-view-test--briefs))
                (starts (length (portal-fake-native-calls 'portal--open))))
            (should (string-match-p "changed as it was saved"
                                    (cadr (should-error
                                           (portal-tasks-view-test--implement view "First" t)
                                           :type 'user-error))))
            (should (equal (portal-tasks-view-test--briefs) briefs))
            (should (= (length (portal-fake-native-calls 'portal--open)) starts))
            (with-current-buffer source
              (kill-local-variable 'after-save-hook)
              (should (buffer-modified-p))
              (should (string-suffix-p "Edited.\nStamp.\n" (buffer-string)))
              ;; So does one that changes the file on disk.
              (add-hook 'after-save-hook
                        (lambda () (set-file-times buffer-file-name (time-subtract nil 60)))
                        nil t))
            (should (string-match-p "changed as it was saved"
                                    (cadr (should-error
                                           (portal-tasks-view-test--implement view "First" t)
                                           :type 'user-error))))
            (should (equal (portal-tasks-view-test--briefs) briefs))
            (should (= (length (portal-fake-native-calls 'portal--open)) starts))
            (with-current-buffer source (kill-local-variable 'after-save-hook))))))))

(provide 'portal-tasks-view-tests)
;;; portal-tasks-view-tests.el ends here
