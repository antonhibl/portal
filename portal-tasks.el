;;; portal-tasks.el --- Browse a project's saved Markdown tasks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A task buffer shows one task root in the task browser, a hosted app whose
;; list and detail pages the app host renders from the saved files.  Emacs
;; chooses the root and edits the files; browsing never writes them.

(require 'project)
(require 'url-util)
(require 'portal-project)
(require 'portal-web)

(defcustom portal-tasks-directory "tasks/"
  "The task root: a directory relative to the project root, or an absolute one.
Set it for one project in its .dir-locals.el."
  :type 'directory
  :safe #'stringp
  :group 'portal)

(defvar-local portal-tasks--root nil "The task root this buffer shows.")

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
view reads saved files: save a task in Emacs, then press g to reload."
  (interactive
   (list (when current-prefix-arg (read-directory-name "Task folder: "))))
  (let* ((root (portal-tasks--normalize
                (or root (portal-tasks--configured-root)
                    (read-directory-name "Task folder (not in a project): "))))
         (buffer (portal-web--find 'portal-tasks--root root)))
    (if buffer
        (switch-to-buffer buffer)
      (portal-web--visit
       nil (format "tasks %s" (abbreviate-file-name root))
       (lambda ()
         (setq portal-tasks--root root)
         (portal-web-open-hosted (concat "/tasks?root=" (url-hexify-string root))
                                 "navigation"))))
    (current-buffer)))

(provide 'portal-tasks)
;;; portal-tasks.el ends here
