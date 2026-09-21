;;; portal-terminal-quick.el --- Project scratch terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'project)
(require 'portal-terminal)

(declare-function portal--terminal-ack "portal-terminal" (id replay))
(declare-function portal--terminal-unfocus "portal-terminal" (&optional id))

(defcustom portal-terminal-quick-height 0.5
  "Initial quick panel height as a fraction of the frame.
Manual resizing is remembered in each frame until it is deleted."
  :type 'float
  :group 'portal-terminal)

(defcustom portal-terminal-quick-directory "~/"
  "Starting directory when no file or Dired editing context is available."
  :type 'directory
  :group 'portal-terminal)

(defvar portal-terminal-quick-prefix-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("q" . portal-terminal-quick-dismiss)
                       ("d" . portal-terminal-unfocus)
                       ("r" . portal-terminal-quick-reset)
                       ("k" . portal-terminal-quick-forget)
                       (":" . portal-terminal-command-prompt)
                       ("?" . portal-terminal-quick-help)))
      (keymap-set map (car binding) (cdr binding)))
    map)
  "Restricted native prefix commands for quick terminals.
Ordinary terminal naming, creation and cycling belong to regular terminals.")

(defun portal-terminal-quick--remember-context (&optional frame)
  "Remember FRAME's most recently selected file or Dired directory."
  (let ((frame (or frame (selected-frame))))
    (with-current-buffer (window-buffer (frame-selected-window frame))
      (when (or buffer-file-name (derived-mode-p 'dired-mode))
        (set-frame-parameter frame 'portal-terminal-quick-context default-directory)))))
(add-hook 'post-command-hook #'portal-terminal-quick--remember-context)
(add-hook 'window-selection-change-functions #'portal-terminal-quick--remember-context)

(defun portal-terminal-quick--root ()
  "Resolve the current editing project's canonical root without prompting."
  (portal-terminal-quick--remember-context)
  (let ((directory (or (frame-parameter nil 'portal-terminal-quick-context)
                       portal-terminal-quick-directory)))
    (when (file-remote-p directory)
      (user-error "Quick terminals require a local project; use ssh inside a terminal"))
    (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
           (project (project-current nil default-directory)))
      (file-name-as-directory
       (file-truename (if project (project-root project) default-directory))))))

(defun portal-terminal-quick--buffer (root)
  "Return this frame's existing quick terminal for ROOT."
  (cl-find root (portal-terminal--frame-buffers)
           :key (lambda (buffer) (buffer-local-value 'portal-terminal--quick-root buffer))
           :test #'equal))

(defun portal-terminal-quick--window ()
  "Return the selected frame's quick panel, if any."
  (cl-find-if (lambda (window) (window-parameter window 'portal-terminal-quick))
              (window-list nil 'no-minibuffer)))

(defun portal-terminal-quick--display (buffer)
  "Show BUFFER in the dedicated quick panel, preserving the editing window."
  (unless (portal-terminal-quick--window)
    (set-frame-parameter nil 'portal-terminal-quick-return-window (selected-window)))
  (let ((window
         (display-buffer-in-side-window
          buffer `((side . bottom) (slot . -1)
                   (window-height . ,(or (frame-parameter nil 'portal-terminal-quick-height)
                                         portal-terminal-quick-height))
                   (dedicated . t)
                   (window-parameters . ((portal-terminal-quick . t)
                                         (no-other-window . t)))))))
    (select-window window)))

;;;###autoload
(defun portal-terminal-toggle ()
  "Show or dismiss this frame's project scratch terminal.
A visible quick panel is always dismissed, even from another editing window.
Otherwise reuse the project's shell or start one at its root.  Reopening never
changes the shell's directory or sends it input.  Hidden processes keep running.
No global keybinding is installed; bind this command in your configuration."
  (interactive)
  (if (portal-terminal-quick--window)
      (portal-terminal-quick-dismiss)
    (portal-terminal-quick--show (portal-terminal-quick--root))))

(defun portal-terminal-quick--show (root)
  "Show ROOT's scratch shell, creating it only when absent."
  (let ((buffer (portal-terminal-quick--buffer root)))
    (condition-case err
        (if buffer
            (progn (portal-terminal-quick--display buffer) (portal-terminal-focus))
          (unless (file-directory-p root)
            (user-error "Quick terminal directory no longer exists: %s" root))
          (let ((default-directory root)) (portal-terminal--new root)))
      (error (portal-terminal-quick-dismiss)
             (signal (car err) (cdr err))))))

;;;###autoload
(defun portal-terminal-quick-dismiss ()
  "Dismiss the quick panel without changing or ending its shell."
  (interactive)
  (when-let* ((window (portal-terminal-quick--window)))
    (let ((return (frame-parameter nil 'portal-terminal-quick-return-window))
          (buffer (window-buffer window)))
      (set-frame-parameter nil 'portal-terminal-quick-height (window-total-height window))
      (setq portal-terminal--resume nil)
      (when-let* ((id (buffer-local-value 'portal-terminal--id buffer)))
        (portal--terminal-ack id nil)
        (portal--terminal-unfocus id))
      (delete-window window)
      (when (and (window-live-p return) (eq (window-frame return) (selected-frame)))
        (select-window return))
      (portal-terminal--sync (selected-frame)))))

(defun portal-terminal-quick--target ()
  "Return the visible quick shell's root, or the current editing project root."
  (if-let* ((window (portal-terminal-quick--window)))
      (buffer-local-value 'portal-terminal--quick-root (window-buffer window))
    (portal-terminal-quick--root)))

(defun portal-terminal-quick--forget (root)
  "End ROOT's scratch shell after confirmation.  Return non-nil on success."
  (if-let* ((buffer (portal-terminal-quick--buffer root)))
      (when (yes-or-no-p (format "Terminate quick terminal for %s and its running shell? " root))
        (when (get-buffer-window buffer) (portal-terminal-quick-dismiss))
        (kill-buffer buffer))
    t))

;;;###autoload
(defun portal-terminal-quick-forget ()
  "Terminate the current project's quick shell and discard its state.
When a panel is visible, target that panel's project.  Ask for confirmation."
  (interactive)
  (portal-terminal-quick--forget (portal-terminal-quick--target)))

;;;###autoload
(defun portal-terminal-quick-reset ()
  "Replace the project's quick shell with a fresh shell at its root.
When a panel is visible, target that panel's project.  Ask before termination."
  (interactive)
  (let ((root (portal-terminal-quick--target)))
    (unless (file-directory-p root)
      (user-error "Quick terminal directory no longer exists: %s" root))
    (when (portal-terminal-quick--forget root)
      (portal-terminal-quick--show root))))

(defun portal-terminal-quick-help ()
  "Show the quick terminal's restricted prefix commands."
  (interactive)
  (portal-terminal-unfocus)
  (with-help-window "*Quick terminal bindings*"
    (princ (format "Quick terminal: %s prefix. M-x portal-terminal-toggle shows or dismisses.\n\n"
                   portal-terminal-prefix))
    (princ (substitute-command-keys "\\{portal-terminal-quick-prefix-map}"))))

(provide 'portal-terminal-quick)
;;; portal-terminal-quick.el ends here
