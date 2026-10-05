;;; portal-tasks-view-gui-tests.el --- Task views redrawn by redisplay -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Redisplay runs the window change functions that redraw a task view shown
;; again; batch Emacs runs none.  org-ql comes from `build/elpa' (see
;; docs/testing.md).  No native view is involved.
(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'portal)

(defun portal-tasks-view-gui--tasks (view)
  "Return the titles of the tasks VIEW lists."
  (with-current-buffer view
    (save-excursion
      (goto-char (point-min))
      (let (titles)
        (while (not (eobp))
          (when-let* ((marker (get-text-property (point) 'org-hd-marker)))
            (push (org-with-point-at marker (org-get-heading t t t t)) titles))
          (forward-line))
        (nreverse titles)))))

(defun portal-tasks-view-gui--set (source keyword)
  "Give the first task in SOURCE KEYWORD, leaving SOURCE unsaved."
  (with-current-buffer source
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "^\\*\\* ")
      (let ((org-inhibit-logging t)) (org-todo keyword)))))

(ert-deftest portal-tasks-view-gui-redraws-when-shown-again ()
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "portal-tasks-view-gui-" t))))
         (file (expand-file-name "project.org" root))
         (initial-buffers (buffer-list)))
    (save-window-excursion
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".git" root))
            (with-temp-file file
              (insert "* Area\n"
                      "** TODO First :task:\n:PROPERTIES:\n:CUSTOM_ID: first\n:END:\n"
                      "** TODO Second :task:\n"
                      ":PROPERTIES:\n:CUSTOM_ID: second\n:DEPENDS_ON: first\n:END:\n"))
            (delete-other-windows)
            (find-file file)
            (let* ((source (current-buffer))
                   (view (portal-tasks))
                   (other (split-window)))
              (redisplay t)
              (should (equal (portal-tasks-view-gui--tasks view) '("First")))
              ;; An edit made elsewhere leaves the view as it was drawn...
              (select-window other)
              (switch-to-buffer source)
              (redisplay t)
              (portal-tasks-view-gui--set source "DONE")
              (redisplay t)
              (should (equal (portal-tasks-view-gui--tasks view) '("First")))
              ;; ...until its pane is selected again,
              (select-window (get-buffer-window view))
              (redisplay t)
              (should (equal (portal-tasks-view-gui--tasks view) '("Second")))
              ;; or a pane shows it again.
              (switch-to-buffer source)
              (redisplay t)
              (portal-tasks-view-gui--set source "TODO")
              (switch-to-buffer view)
              (redisplay t)
              (should (equal (portal-tasks-view-gui--tasks view) '("First")))))
        ;; Views go first, as one shown again would visit its file again.
        (dolist (buffer (sort (cl-set-difference (buffer-list) initial-buffers)
                              :key (lambda (buffer)
                                     (if (buffer-local-value 'portal-tasks--file buffer) 0 1))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory root t)))))

(defun portal-tasks-view-gui--at (view)
  "Return the title of the task on the line at point in VIEW's selected pane."
  (with-current-buffer view
    (when-let* ((marker (get-text-property (line-beginning-position) 'org-hd-marker)))
      (org-with-point-at marker (org-get-heading t t t t)))))

(defun portal-tasks-view-gui--hidden-p (buffer text)
  "Return non-nil if Org folds away TEXT in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (search-forward text)
        (invisible-p (match-beginning 0))))))

(ert-deftest portal-tasks-view-gui-detail-and-back-keep-the-task ()
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "portal-tasks-view-gui-" t))))
         (file (expand-file-name "project.org" root))
         (initial-buffers (buffer-list)))
    (save-window-excursion
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".git" root))
            (with-temp-file file
              (insert "* Area\n"
                      "** TODO First :task:\n:PROPERTIES:\n:CUSTOM_ID: first\n:END:\nFirst's body.\n"
                      "** TODO Second :task:\n:PROPERTIES:\n:CUSTOM_ID: second\n:END:\n"
                      "Second's body.\n"
                      "** TODO Third :task:\n:PROPERTIES:\n:CUSTOM_ID: third\n:END:\n"))
            (delete-other-windows)
            (find-file file)
            (org-overview)
            (let* ((source (current-buffer))
                   (view (portal-tasks))
                   (other (split-window)))
              (set-window-buffer other source)
              (redisplay t)
              (with-current-buffer view
                (goto-char (point-min))
                (forward-line 1)
                (set-window-point (selected-window) (point)))
              (should (equal (portal-tasks-view-gui--at view) "Second"))
              ;; RET shows the whole task, while the file's pane keeps its folds.
              (execute-kbd-macro (kbd "RET"))
              (redisplay t)
              (should (eq (buffer-base-buffer (window-buffer)) source))
              (should-not (portal-tasks-view-gui--hidden-p (window-buffer) "Second's body."))
              (should (portal-tasks-view-gui--hidden-p source "Second's body."))
              (should (eq (window-buffer other) source))
              ;; An edit there redraws the view on Back, still on the task.
              (goto-char (point-max))
              (execute-kbd-macro (kbd "RET N o t e d ."))
              (execute-kbd-macro (kbd "M-,"))
              (redisplay t)
              (should (eq (window-buffer) view))
              (should (equal (portal-tasks-view-gui--at view) "Second"))
              (should (equal (portal-tasks-view-gui--tasks view) '("First" "Second" "Third")))
              (should (portal-tasks-view-gui--hidden-p source "Second's body."))))
        (dolist (buffer (sort (cl-set-difference (buffer-list) initial-buffers)
                              :key (lambda (buffer)
                                     (if (buffer-local-value 'portal-tasks--file buffer) 0 1))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory root t)))))

;;; portal-tasks-view-gui-tests.el ends here
