;;; portal-tasks.el --- Browse a project's saved Markdown tasks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A task buffer shows one task root in the task browser, a hosted app whose
;; list and detail pages the app host renders from the saved files.  Emacs
;; chooses the root and owns the files: the page's Complete, Reopen and Edit
;; in Emacs buttons reach it as hosted app actions, and it saves every change.
;; Saving a file in the root refreshes the page in place.

(require 'project)
(require 'url-util)
(require 'portal-project)
(require 'portal-web)
(require 'portal-terminal)

(defcustom portal-tasks-claude-program
  (or (executable-find "claude") (expand-file-name "~/.local/bin/claude"))
  "Claude Code executable used by the task detail's Implement button."
  :type 'file :group 'portal)

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
(defun portal-tasks (&optional root)
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
while a buffer has unsaved changes to FILE, and a buffer visiting it
unmodified is reverted to the saved file."
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
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (unless (and (equal (secure-hash 'sha256 (current-buffer)) (plist-get arguments :before))
                   (<= end (buffer-size)))
        (user-error "The task file changed on disk; try again"))
      (delete-region (1+ start) (1+ end))
      (goto-char (1+ start))
      (insert (encode-coding-string text 'utf-8))
      (let ((coding-system-for-write 'no-conversion))
        (write-region nil nil file nil 'silent)))
    (when buffer
      (with-current-buffer buffer
        (with-demoted-errors "Could not revert the task buffer: %S"
          (revert-buffer t t t))))
    (portal-tasks--refresh file)
    (list :file file)))

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

(defun portal-tasks--saved ()
  "Refresh the task views that show this buffer's just-saved file."
  (when buffer-file-name (portal-tasks--refresh buffer-file-name)))

(add-hook 'after-save-hook #'portal-tasks--saved)

(provide 'portal-tasks)
;;; portal-tasks.el ends here
