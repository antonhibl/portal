;;; portal-tasks.el --- A project's tasks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The task view lists the tasks in a project's project.org with org-ql,
;; which needs that package; see "The task view" below.

;; A task browser buffer shows one root of saved Markdown tasks in the task
;; browser, a hosted app whose list and detail pages the app host renders from
;; the saved files.  Emacs chooses the root and owns the files: the page's
;; Complete, Reopen and Edit in Emacs buttons reach it as hosted app actions,
;; and it saves every change.  Saving a file in the root refreshes the page in
;; place.

(require 'project)
(require 'url-util)
(require 'portal-project)
(require 'portal-web)
(require 'portal-terminal)

(defcustom portal-tasks-claude-program "claude"
  "Claude Code program used by the task detail's Implement button.
The terminal's initialized shell resolves the name on its PATH.
An explicit executable path is also accepted."
  :type 'string :group 'portal)

(defcustom portal-tasks-claude-arguments '("--dangerously-skip-permissions")
  "Arguments for task implementation, before the project-relative initial prompt."
  :type '(repeat string) :group 'portal)

(defcustom portal-tasks-directory "tasks/"
  "The task root: a directory relative to the project root, or an absolute one.
Set it for one project in its .dir-locals.el."
  :type 'directory
  :safe #'stringp
  :group 'portal)

(defvar-local portal-tasks--root nil "The task root this buffer shows.")
(defvar-local portal-tasks--project nil "The project root captured when this task view opened.")

(defun portal-tasks--project-root (root)
  "Find ROOT's project, or the editing project for an external task folder."
  (let* ((context (portal-project-context))
         (project (or (project-current nil (file-name-as-directory root))
                      (and context (not (file-remote-p context))
                           (project-current nil context)))))
    (when project (file-truename (project-root project)))))

(defun portal-tasks--configured-root ()
  "Return the configured task root of the project being edited, or nil.
Read `portal-tasks-directory' as that project's directory-local variables
set it, even from an auxiliary buffer."
  (let ((context (portal-project-context)))
    (when (and context (file-remote-p context))
      (user-error "The task browser requires a local project"))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory (expand-file-name (or context "~/"))))
      (when context (hack-dir-local-variables-non-file-buffer))
      (if (file-name-absolute-p portal-tasks-directory)
          portal-tasks-directory
        (when-let* ((project (and context (project-current nil default-directory))))
          (expand-file-name portal-tasks-directory (project-root project)))))))

(defun portal-tasks--normalize (directory)
  "Return DIRECTORY as an absolute local path, with existing symlinks resolved."
  (let ((path (expand-file-name directory)))
    (when (file-remote-p path)
      (user-error "Choose a local task folder: %s" path))
    (directory-file-name (file-truename path))))

;;;###autoload
(defun portal-tasks-browser (&optional root)
  "Browse the saved Markdown tasks in ROOT, by default the current project's.
The project is the one being edited, even from a terminal or other auxiliary
buffer, and `portal-tasks-directory' names its task root.  Outside a project,
prompt for one.  With a prefix argument, choose the task root.
Each task root has one buffer, and browsing it again keeps its page.  The
view shows saved files, and refreshes when Emacs saves one in the root; g
reloads it, picking up changes made outside Emacs."
  (interactive
   (list (when current-prefix-arg (read-directory-name "Task folder: "))))
  (let* ((root (portal-tasks--normalize
                (or root (portal-tasks--configured-root)
                    (read-directory-name "Task folder (not in a project): "))))
         (buffer (portal-web--find 'portal-tasks--root root)))
    (if buffer
        (switch-to-buffer buffer)
      (let ((project (portal-tasks--project-root root)))
        (portal-web--visit
         nil (format "tasks %s" (abbreviate-file-name root))
         (lambda ()
           (setq portal-tasks--root root portal-tasks--project project)
           (portal-actions-enable
            (list :app "tasks" :root root :project project
                  :program portal-tasks-claude-program :args (vconcat portal-tasks-claude-arguments))
            '(("terminal.open" . portal-terminal-open-action)
              ("task.status" . portal-tasks--status-action)
              ("task.edit" . portal-tasks--edit-action)))
           (portal-web-open-hosted (concat "/tasks?root=" (url-hexify-string root))
                                   "navigation")))))
    (current-buffer)))

(defun portal-tasks--source (file)
  "Return FILE, a task source the app host found, if it is in this view's root."
  (unless (and (stringp file) (file-name-absolute-p file) (file-regular-p file)
               (file-in-directory-p file portal-tasks--root))
    (user-error "The task source is not a file in this task folder"))
  file)

(defun portal-tasks--edit-action (arguments)
  "Visit the task source in ARGUMENTS in another pane, and give Emacs the keyboard.
A buffer already visiting it is reused as it is, unsaved changes and all."
  (let ((file (portal-tasks--source (plist-get arguments :file))))
    (portal-web--hand-off file)
    (list :file file)))

(defun portal-tasks--status-action (arguments)
  "Save the status edit the app host planned in ARGUMENTS.
Bytes START to END of FILE become TEXT, provided FILE still has the SHA-256
BEFORE the plan was made from, so no other text changes.  Nothing is written
while a buffer has unsaved changes to FILE or FILE is read-only.  FILE is
replaced whole, so a failed write leaves it as it was, and a buffer visiting
it unmodified is reverted to the saved file."
  (let* ((file (portal-tasks--source (plist-get arguments :file)))
         (start (plist-get arguments :start))
         (end (plist-get arguments :end))
         (text (plist-get arguments :text))
         (buffer (find-buffer-visiting file))
         (lock (file-locked-p file)))
    (unless (and (natnump start) (natnump end) (<= start end) (stringp text))
      (error "Invalid task status edit"))
    (when (and buffer (buffer-modified-p buffer))
      (user-error "%s has unsaved changes; save it in Emacs, then try again"
                  (buffer-name buffer)))
    (when (stringp lock)
      (user-error "%s is being edited by %s" (file-name-nondirectory file) lock))
    (unless (file-writable-p file)
      (user-error "%s is read-only" (file-name-nondirectory file)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (unless (and (equal (secure-hash 'sha256 (current-buffer)) (plist-get arguments :before))
                   (<= end (buffer-size)))
        (user-error "The task file changed on disk; try again"))
      (delete-region (1+ start) (1+ end))
      (goto-char (1+ start))
      (insert (encode-coding-string text 'utf-8))
      (portal-tasks--replace file (plist-get arguments :before)))
    (when buffer
      (with-current-buffer buffer
        (with-demoted-errors "Could not revert the task buffer: %S"
          (revert-buffer t t t))))
    (portal-tasks--refresh file)
    (list :file file)))

(defun portal-tasks--hash (file)
  "Return the SHA-256 of FILE's bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun portal-tasks--replace (file before)
  "Replace FILE, whose bytes have SHA-256 BEFORE, with the current buffer's bytes.
The bytes go to a new file beside FILE and reach the disk, and then it takes
FILE's modes, extended attributes and name, as `file-precious-flag' saves
do.  A failed write leaves FILE as it was.  FILE is checked for BEFORE again
just before the rename, so a save elsewhere is lost only if it lands between
that check and the rename, the window every editor's save has."
  (let ((temp (make-temp-file (expand-file-name ".portal-" (file-name-directory file)))))
    (unwind-protect
        (let ((coding-system-for-write 'no-conversion)
              (write-region-inhibit-fsync nil))
          (write-region nil nil temp nil 'silent)
          (set-file-modes temp (file-modes file))
          (ignore-errors
            (set-file-extended-attributes temp (file-extended-attributes file)))
          (unless (equal (portal-tasks--hash file) before)
            (user-error "The task file changed on disk; try again"))
          (rename-file temp file t))
      (when (file-exists-p temp) (delete-file temp)))))

(defun portal-tasks--refresh (file)
  "Have each task view whose root holds FILE refresh its page from saved files.
The page refreshes in place, keeping its history, reading position and focus,
and a hidden page refreshes once it is shown."
  (dolist (buffer (portal-view-buffers 'web))
    (with-current-buffer buffer
      (when (and portal-tasks--root portal-web--url
                 (file-in-directory-p file portal-tasks--root))
        (with-demoted-errors "Could not refresh a task view: %S"
          (portal-web-send '(:type "refresh")))))))

;;; The task view

;; `portal-tasks' lists the headings with a local task tag in a project's
;; project.org.  org-ql selects them and formats each as an agenda line, so
;; Org's agenda keys act on the task on a line.  Portal decides which tasks
;; are actionable: org-ql's `blocked' does not read DEPENDS_ON.  A task names
;; its prerequisites there by CUSTOM_ID, in project.org or its Org archives,
;; where finished tasks may have moved.

(declare-function org-ql-select "org-ql" (buffers-or-files query &rest keys))
(declare-function org-ql-view--format-element "org-ql-view" (element))
(declare-function org-agenda-mode "org-agenda" ())
(declare-function org-agenda-finalize "org-agenda" ())
(declare-function org-agenda-reset-markers "org-agenda" ())
(declare-function org-all-archive-files "org-archive" ())
(declare-function org-element-property "org-element-ast"
                  (property node &optional dflt force-undefer))
(declare-function org-fold-show-context "org-fold" (&optional key))
(declare-function org-timestamp-to-time "org" (timestamp &optional end))
(declare-function org-today "org" ())
(defvar org-agenda-mode-map)
(defvar org-priority-default)

(defvar-local portal-tasks--file nil "The project.org this task view lists.")
(defvar-local portal-tasks--all nil "Whether this task view lists every task.")
(defvar-local portal-tasks--drawn nil
  "What this task view was drawn from: the day, and each source and its tick.")

(defconst portal-tasks--groups
  '((actionable . "Actionable") (blocked . "Blocked")
    (deferred . "Deferred") (closed . "Closed"))
  "Task states, in the order all tasks lists them, with their headings.")

(defvar-keymap portal-tasks-view-map
  :doc "Keys of a task view, over Org's agenda keys."
  "g" #'portal-tasks-refresh
  "r" #'portal-tasks-refresh
  "v" #'portal-tasks-toggle-all
  "q" #'quit-window)
(with-eval-after-load 'org-agenda
  (set-keymap-parent portal-tasks-view-map org-agenda-mode-map))

;;;###autoload
(defun portal-tasks ()
  "List the actionable tasks in the current project's project.org.
The project is the one being edited, even from an auxiliary buffer; from a
terminal, it is the terminal's.  Tasks are the headings with a local task
tag.  One is actionable when it is TODO, the tasks its DEPENDS_ON property
names by CUSTOM_ID are all DONE, and it is not scheduled after today.  The
view orders them by priority, then nearest deadline, then file order.
\\<portal-tasks-view-map>
\\[portal-tasks-toggle-all] switches to all tasks, which says why each one is not
actionable and links to its blockers.  Org's agenda keys act on the task
on a line.

The view reads the file's buffer, saved or not.  It is redrawn when shown
again after a change, when the file is saved, and on \\[portal-tasks-refresh].
Each pane keeps its task.  Each project has one view, which keeps its
choice of tasks.  This needs the org-ql package."
  (interactive)
  (unless (and (require 'org-ql nil t) (require 'org-ql-view nil t))
    (user-error "The task view needs the org-ql package"))
  (require 'org-archive)
  (let* ((file (portal-tasks--project-file))
         (buffer (or (seq-find (lambda (buffer)
                                 (equal (buffer-local-value 'portal-tasks--file buffer) file))
                               (buffer-list))
                     (portal-tasks--create file))))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer (portal-tasks--update))
    buffer))

(defun portal-tasks--project-file ()
  "Return the project.org of the project being edited, or signal an error.
A task view's is its own, and a terminal's is its project's."
  (or portal-tasks--file
      (let* ((terminal (portal-terminal-metadata))
             (root (if terminal
                       (plist-get terminal :project)
                     (portal-project-root (or (portal-project-context) default-directory))))
             (file (and root (expand-file-name "project.org" root))))
        (cond ((not root)
               (user-error (if terminal "This terminal belongs to no project" "Not in a project")))
              ((not (file-exists-p file))
               (user-error "%s has no project.org" (abbreviate-file-name root)))
              (t file)))))

(defun portal-tasks--create (file)
  "Return a new task view of FILE, listing its actionable tasks."
  (with-current-buffer
      (generate-new-buffer
       (format "*tasks: %s*"
               (abbreviate-file-name (directory-file-name (file-name-directory file)))))
    (org-agenda-mode)
    (use-local-map portal-tasks-view-map)
    (setq buffer-read-only t
          default-directory (file-name-directory file)
          portal-tasks--file file)
    (add-hook 'window-buffer-change-functions #'portal-tasks--shown nil t)
    (add-hook 'window-selection-change-functions #'portal-tasks--shown nil t)
    (current-buffer)))

(defun portal-tasks--check ()
  "Signal an error unless the current buffer is a task view."
  (unless portal-tasks--file
    (user-error "Not a task view; use M-x portal-tasks")))

(defun portal-tasks-refresh ()
  "Redraw this task view from its file's buffer, keeping each pane's task."
  (interactive)
  (portal-tasks--draw))

(defun portal-tasks-toggle-all ()
  "Switch this task view between actionable and all tasks.
Each pane keeps its task."
  (interactive)
  (portal-tasks--check)
  (setq portal-tasks--all (not portal-tasks--all))
  (portal-tasks--draw))

(defun portal-tasks--shown (window)
  "Redraw the task view in WINDOW if it changed since it was drawn.
It runs when WINDOW starts showing the view, and when it is selected or
deselected; by then WINDOW may show another buffer, which is left alone."
  (let ((buffer (window-buffer window)))
    (when (buffer-local-value 'portal-tasks--file buffer)
      (with-current-buffer buffer
        (with-demoted-errors "Could not refresh the task view: %S"
          (portal-tasks--update))))))

(defun portal-tasks--state (sources)
  "Return today and each of SOURCES, buffers, with its modification tick."
  (cons (org-today)
        (mapcar (lambda (buffer)
                  (cons buffer (and (buffer-live-p buffer) (buffer-chars-modified-tick buffer))))
                sources)))

(defun portal-tasks--update ()
  "Redraw this task view if the day or a source changed since it was drawn."
  (unless (and portal-tasks--drawn
               (equal portal-tasks--drawn
                      (portal-tasks--state (mapcar #'car (cdr portal-tasks--drawn)))))
    (portal-tasks--draw)))

(defun portal-tasks--draw ()
  "Draw this task view from its file's buffer, keeping the task in each pane."
  (portal-tasks--check)
  (let* ((source (or (find-buffer-visiting portal-tasks--file)
                     (find-file-noselect portal-tasks--file)))
         (archives (portal-tasks--archives source))
         (tasks (portal-tasks--judge-all source archives))
         (windows (get-buffer-window-list nil nil t))
         (places (mapcar #'portal-tasks--place (cons (point) (mapcar #'window-point windows))))
         (inhibit-read-only t))
    (erase-buffer)
    (portal-tasks--insert tasks)
    (org-agenda-finalize)
    ;; It would forget every agenda's markers when this view is killed;
    ;; org-ql's are its own.
    (remove-hook 'kill-buffer-hook #'org-agenda-reset-markers t)
    (setq header-line-format
          (string-replace "%" "%%" (format "%s in %s"
                                           (if portal-tasks--all "All tasks" "Actionable tasks")
                                           (abbreviate-file-name portal-tasks--file))))
    (goto-char (portal-tasks--find (car places)))
    (cl-mapc (lambda (window place) (set-window-point window (portal-tasks--find place)))
             windows (cdr places))
    (setq portal-tasks--drawn (portal-tasks--state (cons source archives)))))

(defun portal-tasks--archives (source)
  "Return buffers visiting the Org archive files of SOURCE, other than itself."
  (with-current-buffer source
    (mapcar (lambda (file) (or (find-buffer-visiting file) (find-file-noselect file)))
            (seq-remove (lambda (file) (file-equal-p file buffer-file-name))
                        (org-all-archive-files)))))

(defun portal-tasks--select (buffer)
  "Return BUFFER's tasks in file order, as org-ql elements with markers."
  (org-ql-select buffer '(tags-local "task") :action 'element-with-markers))

(defun portal-tasks--prerequisites (task)
  "Return the CUSTOM_IDs TASK's DEPENDS_ON property names, each once."
  (delete-dups (split-string (or (org-element-property :DEPENDS_ON task) ""))))

(defun portal-tasks--judge-all (source archives)
  "Return SOURCE's tasks, each judged, in the order the view lists them.
Prerequisites are found in SOURCE and ARCHIVES.  See `portal-tasks--judge'."
  (let* ((tasks (portal-tasks--select source))
         (all (append tasks (seq-mapcat #'portal-tasks--select archives)))
         (ids (make-hash-table :test #'equal))
         (edges (make-hash-table :test #'equal))
         (today (org-today))
         (default (buffer-local-value 'org-priority-default source)))
    (dolist (task (reverse all))
      (when-let* ((id (org-element-property :CUSTOM_ID task)))
        (push task (gethash id ids))))
    ;; Archived tasks keep their prerequisites, so archiving a task in a
    ;; cycle leaves the cycle.
    (dolist (task all)
      (let ((id (org-element-property :CUSTOM_ID task)))
        (when (and id (not (cdr (gethash id ids))))
          (puthash id (portal-tasks--prerequisites task) edges))))
    (seq-sort (lambda (a b) (portal-tasks--before-p a b default))
              (mapcar (lambda (task) (portal-tasks--judge task ids edges today)) tasks))))

(defun portal-tasks--judge (task ids edges today)
  "Return TASK, an org-ql element, with its state and why it is not actionable.
The plist has the `:element', its `:state', actionable, blocked, deferred
or closed, and its `:reasons', strings that link to the tasks they name.
IDS maps each CUSTOM_ID to the tasks that have it, EDGES each unique one,
archived or not, to its prerequisites, and TODAY is the day's number.  A task
with a done keyword is closed.  Others are blocked by a missing or shared
CUSTOM_ID, a keyword other than TODO, a prerequisite that is missing, not
unique or not DONE, or a dependency cycle; a task blocked by nothing but
scheduled after TODAY is deferred."
  (let* ((id (org-element-property :CUSTOM_ID task))
         (keyword (org-element-property :todo-keyword task))
         (scheduled (org-element-property :scheduled task))
         (cycle (and id (seq-filter (lambda (prerequisite)
                                      (portal-tasks--reaches-p prerequisite id edges))
                                    (gethash id edges))))
         blockers)
    (if (eq (org-element-property :todo-type task) 'done)
        (list :element task :state 'closed)
      (cond ((not id) (push "no CUSTOM_ID" blockers))
            ((cdr (gethash id ids)) (push (format "CUSTOM_ID %s is not unique" id) blockers)))
      (unless (equal keyword "TODO")
        (push (if keyword (format "%s, not TODO" keyword) "no TODO keyword") blockers))
      (dolist (prerequisite (portal-tasks--prerequisites task))
        (pcase (gethash prerequisite ids)
          ('nil (push (format "no task %s" prerequisite) blockers))
          (`(,target)
           (let ((state (org-element-property :todo-keyword target)))
             (unless (equal state "DONE")
               (push (format "waiting for %s (%s)" (portal-tasks--link prerequisite target)
                             (or state "no keyword"))
                     blockers))))
          (_ (push (format "%s is not unique" prerequisite) blockers))))
      (when cycle
        (push (concat "dependency cycle through "
                      (mapconcat (lambda (prerequisite)
                                   (portal-tasks--link prerequisite
                                                       (car (gethash prerequisite ids))))
                                 cycle ", "))
              blockers))
      (let ((later (and scheduled
                        (> (time-to-days (org-timestamp-to-time scheduled)) today)
                        (format "scheduled %s" (org-element-property :raw-value scheduled)))))
        (list :element task
              :state (cond (blockers 'blocked) (later 'deferred) (t 'actionable))
              :reasons (nreverse (if later (cons later blockers) blockers)))))))

(defun portal-tasks--reaches-p (from to edges)
  "Return non-nil if the task FROM is TO or depends on it through EDGES."
  (let ((seen (make-hash-table :test #'equal))
        (pending (list from)))
    (catch 'found
      (while pending
        (let ((id (pop pending)))
          (when (equal id to) (throw 'found t))
          (unless (gethash id seen)
            (puthash id t seen)
            (setq pending (append (gethash id edges) pending))))))))

(defun portal-tasks--before-p (a b default)
  "Return non-nil if task A comes before B by priority, then nearest deadline.
A task without a priority has DEFAULT, as in Org.  Equal tasks keep file order."
  (let ((priority-a (or (org-element-property :priority (plist-get a :element)) default))
        (priority-b (or (org-element-property :priority (plist-get b :element)) default)))
    (if (/= priority-a priority-b)
        (< priority-a priority-b)
      (let ((deadline-a (org-element-property :deadline (plist-get a :element)))
            (deadline-b (org-element-property :deadline (plist-get b :element))))
        (and deadline-a
             (or (not deadline-b)
                 (time-less-p (org-timestamp-to-time deadline-a)
                              (org-timestamp-to-time deadline-b))))))))

(defun portal-tasks--link (id task)
  "Return ID as a button that goes to TASK's heading."
  (buttonize id #'portal-tasks--visit (org-element-property :org-hd-marker task)
             "Go to this task"))

(defun portal-tasks--visit (marker)
  "Go to the task heading at MARKER, as RET does for the task on a line."
  (unless (marker-buffer marker)
    (user-error "That task's buffer was killed; press g"))
  (pop-to-buffer-same-window (marker-buffer marker))
  (unless (<= (point-min) marker (point-max)) (widen))
  (goto-char marker)
  (org-fold-show-context 'agenda))

(defun portal-tasks--insert (tasks)
  "Insert the lines of TASKS this view lists."
  (let ((actionable (seq-filter (lambda (task) (eq (plist-get task :state) 'actionable)) tasks)))
    (cond ((not tasks)
           (insert (propertize "No headings in this file have a task tag.\n" 'face 'shadow)))
          (portal-tasks--all
           (pcase-dolist (`(,state . ,heading) portal-tasks--groups)
             (when-let* ((group (seq-filter (lambda (task) (eq (plist-get task :state) state))
                                            tasks)))
               (insert (propertize (format "%s (%d)" heading (length group))
                                   'face 'org-agenda-structure)
                       "\n")
               (dolist (task group) (insert (portal-tasks--line task) "\n")))))
          (actionable
           (dolist (task actionable) (insert (portal-tasks--line task) "\n")))
          (t (insert (propertize
                      (substitute-command-keys
                       (concat "No actionable tasks.  \\<portal-tasks-view-map>"
                               "\\[portal-tasks-toggle-all] lists every task.\n"))
                      'face 'shadow))))))

(defun portal-tasks--line (task)
  "Return TASK's agenda line, saying before its tags why it is not actionable."
  (let ((line (org-ql-view--format-element (plist-get task :element)))
        (reasons (plist-get task :reasons)))
    (if (not reasons)
        line
      (let ((note (concat " — " (string-join reasons "; ")))
            (end (if (string-match "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*\\'" line)
                     (match-beginning 0)
                   (length line))))
        (add-face-text-property 0 (length note) 'shadow t note)
        (concat (substring line 0 end) note (substring line end))))))

(defun portal-tasks--place (position)
  "Return where POSITION is in this view: its task's heading, and its line."
  (save-excursion
    (goto-char position)
    (let ((marker (get-text-property (line-beginning-position) 'org-hd-marker)))
      (cons (and (markerp marker) (marker-position marker)) (line-number-at-pos)))))

(defun portal-tasks--find (place)
  "Return the start of the line of PLACE's task, or else of its line."
  (save-excursion
    (goto-char (point-min))
    (or (and (car place)
             (cl-loop for marker = (get-text-property (point) 'org-hd-marker)
                      when (and (markerp marker) (eql (marker-position marker) (car place)))
                      return (point)
                      while (zerop (forward-line))))
        (progn (goto-char (point-min))
               (forward-line (1- (cdr place)))
               (point)))))

(defun portal-tasks--saved ()
  "Refresh the task views and task browser pages drawn from this saved buffer."
  (when buffer-file-name (portal-tasks--refresh buffer-file-name))
  (let ((buffer (current-buffer)))
    (dolist (view (buffer-list))
      (when (assq buffer (cdr (buffer-local-value 'portal-tasks--drawn view)))
        (with-current-buffer view
          (with-demoted-errors "Could not refresh the task view: %S"
            (portal-tasks--update)))))))

(add-hook 'after-save-hook #'portal-tasks--saved)

(provide 'portal-tasks)
;;; portal-tasks.el ends here
