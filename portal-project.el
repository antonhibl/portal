;;; portal-project.el --- The project being edited -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Quick terminals act on the project being edited, even when run from a
;; terminal, a web view or another auxiliary buffer.  Each frame remembers the
;; directory of the file or Dired buffer selected last.  Terminals record the
;; project they belong to by its canonical root.

(require 'project)

(defcustom portal-project-function #'portal-project-el-root
  "Function that returns the root of the project containing a directory.
It is called with a local directory name and returns a directory name, or
nil outside a project.  It must not prompt.  The default uses `project.el';
Projectile users can choose `projectile-project-root'."
  :type 'function
  :group 'portal)

(defun portal-project-el-root (directory)
  "Return the `project.el' root of DIRECTORY's project, or nil."
  (when-let* ((project (project-current nil directory)))
    (project-root project)))

(defun portal-project-root (directory)
  "Return the canonical root of the project containing DIRECTORY, or nil.
`portal-project-function' finds the project; the root is returned as a true
local directory name, so two spellings of one root compare equal."
  (unless (file-remote-p directory)
    (let ((default-directory (file-name-as-directory (expand-file-name directory))))
      (when-let* ((root (funcall portal-project-function default-directory)))
        (unless (file-remote-p root)
          (file-name-as-directory (file-truename root)))))))

(defun portal-project--remember (&optional frame)
  "Remember FRAME's most recently selected file or Dired directory."
  (let ((frame (or frame (selected-frame))))
    (with-current-buffer (window-buffer (frame-selected-window frame))
      (when (or buffer-file-name (derived-mode-p 'dired-mode))
        (set-frame-parameter frame 'portal-project-context default-directory)))))
(add-hook 'post-command-hook #'portal-project--remember)
(add-hook 'window-selection-change-functions #'portal-project--remember)

(defun portal-project-context ()
  "Return the directory of the selected frame's editing context, or nil.
It is the directory of the file or Dired buffer selected last in the frame."
  (portal-project--remember)
  (frame-parameter nil 'portal-project-context))

(provide 'portal-project)
;;; portal-project.el ends here
