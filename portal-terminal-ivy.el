;;; portal-terminal-ivy.el --- Ivy for Portal terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional; portal.el enables `portal-terminal-ivy-mode' when Ivy loads.
;; The terminal pickers then read with Ivy.  Candidates keep their order,
;; most recently selected first, and show whether a terminal is quick or has
;; exited.  Ivy's other actions, on \\`M-o', act on the terminal at point
;; and keep the minibuffer: rename it, open Dired or another shell in its
;; directory, copy that directory, reassign its project, or end it.  They
;; are the Embark adapter's actions, whose file loads without Embark.  Tested
;; with Ivy 0.15.1.

(require 'portal-terminal)
(require 'portal-terminal-choose)
(require 'portal-terminal-embark)

;; Ivy is optional for Portal, so this file compiles and loads without it;
;; enabling the mode requires it.
(declare-function ivy-read "ivy" (prompt collection &rest arguments))
(declare-function ivy-set-actions "ivy" (caller actions))
(declare-function ivy-configure "ivy" (caller &rest properties))

(defvar portal-terminal-ivy--entries nil
  "The candidates and values that the picker reads now, as (STRING . VALUE).")

(defun portal-terminal-ivy--value (candidate)
  "Return the terminal buffer, `new' or `named' that CANDIDATE names."
  (cdr (assoc candidate portal-terminal-ivy--entries)))

(defun portal-terminal-ivy--display (candidate)
  "Return CANDIDATE as the picker shows it: with whether it is quick or exited."
  (let ((value (portal-terminal-ivy--value candidate)))
    (concat candidate (or (and (bufferp value) (portal-terminal--annotation value)) ""))))

(defun portal-terminal-ivy--act (action)
  "Return an Ivy action that calls ACTION with a terminal candidate's name.
A New entry is not a terminal, so it has no such actions."
  (lambda (candidate)
    (let ((value (portal-terminal-ivy--value candidate)))
      (if (bufferp value)
          (funcall action (buffer-name value))
        (message "Not a terminal: %s" (substring-no-properties candidate))))))

(defun portal-terminal-ivy--read (prompt terminals actions initial)
  "Read one of TERMINALS or ACTIONS with Ivy.
See `portal-terminal--reader' for PROMPT, TERMINALS, ACTIONS and INITIAL.
Return `handled' when one of Ivy's other actions acted instead: the
caller then does nothing more."
  (let* ((portal-terminal-ivy--entries (append terminals actions))
         (choice 'handled))
    (ivy-read prompt (mapcar #'car portal-terminal-ivy--entries)
              :require-match t
              :initial-input initial
              :preselect (caar terminals)
              :keymap portal-terminal-choose-map
              :caller 'portal-terminal-choose
              :action (lambda (candidate) (setq choice (portal-terminal-ivy--value candidate))))
    choice))

;;;###autoload
(define-minor-mode portal-terminal-ivy-mode
  "Choose Portal terminals with Ivy.
`portal-terminal-choose' and `portal-terminal-choose-project' read with
Ivy, keeping their order, scope toggle and New entries.  \\`M-o' offers
terminal actions: r renames, d opens Dired in its directory, c starts
another shell there, W copies the directory, p reassigns its project and
k ends it."
  :global t
  :group 'portal-terminal
  (if portal-terminal-ivy-mode
      (progn
        (require 'ivy)
        (ivy-configure 'portal-terminal-choose
          :display-transformer-fn #'portal-terminal-ivy--display)
        (ivy-set-actions
         'portal-terminal-choose
         `(("r" ,(portal-terminal-ivy--act #'portal-terminal-embark-rename) "rename")
           ("d" ,(portal-terminal-ivy--act #'portal-terminal-embark-dired) "dired")
           ("c" ,(portal-terminal-ivy--act #'portal-terminal-embark-new) "new shell here")
           ("W" ,(portal-terminal-ivy--act #'portal-terminal-embark-copy-directory) "copy directory")
           ("p" ,(portal-terminal-ivy--act #'portal-terminal-embark-set-project) "set project")
           ("k" ,(portal-terminal-ivy--act #'portal-terminal-embark-kill) "kill")))
        (setq portal-terminal--reader #'portal-terminal-ivy--read))
    (when (eq portal-terminal--reader #'portal-terminal-ivy--read)
      (setq portal-terminal--reader #'portal-terminal--completing-read))))

(provide 'portal-terminal-ivy)
;;; portal-terminal-ivy.el ends here
