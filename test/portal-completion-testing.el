;;; portal-completion-testing.el --- Typing into a real minibuffer in batch -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Shared by the Consult and Embark adapter suites.  Real Consult, Vertico
;; and Orderless, as released on GNU ELPA, drive the adapters against the
;; fake native module.  A keyboard macro types into a real minibuffer, which
;; batch Emacs opens while executing one, so Consult's narrowing, preview and
;; lookup, and Embark's targets and actions, all run.  <f11> probes the state
;; from inside the minibuffer.  Batch Emacs does not redisplay, so probes
;; sync views.  The graphical suite checks native focus with real keys.

(require 'ert)
(require 'project)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)
(require 'consult)
(require 'vertico)
(require 'orderless)
(require 'portal-terminal-consult)

(defvar portal-completion-test--directory nil "This test's temporary directory.")

(defmacro portal-completion-test--environment (&rest body)
  "Run BODY with the adapter, Vertico and Orderless on, from a file in one/app.
The directory holds projects one/app and two/app.  Kill every buffer BODY
made, delete the directory, and turn the modes off afterwards."
  (declare (indent 0))
  `(let* ((portal-completion-test--directory (file-truename (make-temp-file "portal-completion-" t)))
          (context (frame-parameter nil 'portal-project-context))
          (initial-buffers (buffer-list))
          (portal-terminal-confirm-kill nil)
          ;; Projects these tests visit stay out of the user's project list.
          (project-list-file (portal-completion-test--path "projects.eld"))
          (project--list 'unset)
          (completion-styles '(orderless basic))
          (completion-category-defaults nil)
          ;; Only buffers, so no test reads recent files or bookmarks.
          (consult-buffer-sources '(consult-source-buffer consult-source-hidden-buffer))
          (consult-project-buffer-sources '(consult-source-project-buffer)))
     (portal-fake-native-reset)
     (dolist (folder '("one/app/.git" "one/app/api" "two/app/.git"))
       (make-directory (portal-completion-test--path folder) t))
     (save-window-excursion
       (unwind-protect
           (progn (portal-terminal-consult-mode)
                  (vertico-mode)
                  (delete-other-windows)
                  (switch-to-buffer (get-buffer-create "consult-file.el"))
                  (setq buffer-file-name (portal-completion-test--path "one/app/file.el")
                        default-directory (file-name-directory buffer-file-name))
                  ,@body)
         (vertico-mode -1)
         (portal-terminal-consult-mode -1)
         (portal-terminal-quick-dismiss)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory portal-completion-test--directory t)))
     (should-not (portal-view-buffers))
     (should (eq portal-terminal--reader #'portal-terminal--completing-read))))

(defun portal-completion-test--path (name)
  "Return NAME in this test's directory."
  (expand-file-name name portal-completion-test--directory))

(defun portal-completion-test--open (folder &rest facts)
  "Start a terminal in FOLDER, have it report FACTS, and return its buffer."
  (let ((default-directory (file-name-as-directory (portal-completion-test--path folder))))
    (portal-terminal-new)
    (when facts
      (apply #'portal-fake-native-report portal-view--target facts))
    (current-buffer)))

(defvar portal-completion-test--probe #'ignore "Function the probe key calls.")
(defvar portal-completion-test--probes nil "What the probe key recorded, newest first.")

(defun portal-completion-test--record ()
  "Record what `portal-completion-test--probe' returns now."
  (interactive)
  (push (funcall portal-completion-test--probe) portal-completion-test--probes))

(defun portal-completion-test--type (command keys &optional probe)
  "Run COMMAND and type KEYS, in `kbd' notation, into a real minibuffer.
Each <f11> in KEYS records what PROBE returns.  Return the records, in order.
An error ends the keys, as it ends a keyboard macro."
  (let ((map (make-sparse-keymap))
        (global (current-global-map))
        (portal-completion-test--probe (or probe #'ignore)))
    (setq portal-completion-test--probes nil)
    (keymap-set map "<f12>" command)
    (keymap-set map "<f11>" #'portal-completion-test--record)
    (set-keymap-parent map global)
    (use-global-map map)
    (unwind-protect
        (execute-kbd-macro (vconcat (kbd "<f12>") (kbd keys)))
      (use-global-map global))
    (should-not (active-minibuffer-window))
    (reverse portal-completion-test--probes)))

(defun portal-completion-test--value (candidate)
  "Return the value Consult keeps for CANDIDATE: a buffer, or a New action."
  (cdr (get-text-property 0 'multi-category candidate)))

(defun portal-completion-test--matches ()
  "Return the candidates the minibuffer shows for its input."
  (let* ((input (minibuffer-contents))
         (matches (completion-all-completions input minibuffer-completion-table
                                              minibuffer-completion-predicate (length input))))
    (when (consp matches) (setcdr (last matches) nil))
    matches))

(defun portal-completion-test--shown ()
  "Return the values of the candidates the minibuffer shows for its input."
  (mapcar #'portal-completion-test--value (portal-completion-test--matches)))

(provide 'portal-completion-testing)
;;; portal-completion-testing.el ends here
