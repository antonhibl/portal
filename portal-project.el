;;; portal-project.el --- The project being edited -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Quick terminals and the task browser act on the project being edited, even
;; when run from a terminal, a web view or another auxiliary buffer.  Each
;; frame remembers the directory of the file or Dired buffer selected last.

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
