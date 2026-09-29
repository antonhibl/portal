;;; portal-terminal-quick.el --- Project scratch terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'project)
(require 'portal-project)
(require 'portal-terminal)

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

(defun portal-terminal-quick--root ()
  "Resolve the current editing project's canonical root without prompting.
Outside a project, the editing directory stands in for the root."
  (let ((directory (or (portal-project-context) portal-terminal-quick-directory)))
    (when (file-remote-p directory)
      (user-error "Quick terminals require a local project; use ssh inside a terminal"))
    (or (portal-project-root directory)
        (file-name-as-directory (file-truename (expand-file-name directory))))))

(defun portal-terminal-quick--buffer (root)
  "Return the existing quick terminal for ROOT."
  (cl-find root (portal-view-buffers 'terminal)
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
  "Show or dismiss the project's scratch terminal in this frame's quick panel.
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
    (let ((return (frame-parameter nil 'portal-terminal-quick-return-window)))
      (set-frame-parameter nil 'portal-terminal-quick-height (window-total-height window))
      (setq portal-terminal--resume nil)
      (delete-window window)
      (when (and (window-live-p return) (eq (window-frame return) (selected-frame)))
        (select-window return))
      ;; Hiding the view also returns keyboard focus to Emacs.
      (portal-view-sync))))

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
