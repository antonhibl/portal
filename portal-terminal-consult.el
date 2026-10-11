;;; portal-terminal-consult.el --- Consult sources for Portal terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional; portal.el enables `portal-terminal-consult-mode' when Consult loads.
;; The terminal pickers then read with Consult, which adds preview and
;; narrowing, and `consult-buffer' and `consult-project-buffer' gain a hidden
;; group of terminals.  Tested with Consult 3.10.  The source helpers used
;; here, such as `consult--multi' and `consult--buffer-preview', are Consult's
;; internal API, so they stay in this file.

(require 'portal-terminal)

;; Consult is optional for Portal, so this file compiles and loads without it;
;; enabling the mode requires it.
(defvar consult-buffer-sources)
(defvar consult-project-buffer-sources)
(defvar consult-project-function)
(defvar consult--buffer-display)
(declare-function consult--buffer-preview "consult" ())
(declare-function consult--buffer-action "consult" (buffer &optional norecord))
(declare-function consult--project-root "consult" (&optional may-prompt))
(declare-function consult--multi "consult" (sources &rest options))

(defun portal-terminal-consult--preview ()
  "Return a Consult state function that previews terminal buffers.
Consult's buffer preview shows each in the window the minibuffer returns
to, without recording it as selected; the terminal's view follows it there.
A closed or quick terminal shows that window's own buffer instead: quick
terminals belong in their panel."
  (let ((preview (consult--buffer-preview)))
    (lambda (action buffer)
      (let ((entry (and (buffer-live-p buffer) (portal-terminal-metadata buffer))))
        (funcall preview action (and entry (not (plist-get entry :quick)) buffer))))))

(defun portal-terminal-consult--state ()
  "Return a Consult state function that previews terminals and selects one.
Consult's display variants, such as `consult-buffer-other-window', choose
where an ordinary terminal opens; a quick terminal opens in its panel."
  (let ((preview (portal-terminal-consult--preview)))
    (lambda (action buffer)
      (funcall preview action buffer)
      (when (and buffer (eq action 'return))
        (if (and (not (eq consult--buffer-display #'switch-to-buffer))
                 (buffer-live-p buffer)
                 (not (buffer-local-value 'portal-terminal--quick-root buffer)))
            (consult--buffer-action buffer)
          (portal-terminal--visit buffer))))))

(defun portal-terminal-consult--items (project)
  "Return Consult items for PROJECT's terminals, or for every terminal."
  (portal-terminal--candidates
   (portal-terminal--recent (portal-terminal-buffers project portal-terminal-choose-quick))))

(defvar portal-terminal-consult-source
  `( :name        "Terminal"
     :narrow      ?t
     :hidden      t
     :category    buffer
     :preview-key "M-."
     :annotate    ,#'portal-terminal--annotation
     :state       ,#'portal-terminal-consult--state
     :items       ,(lambda () (portal-terminal-consult--items nil)))
  "Consult source for every terminal, most recently selected first.
`portal-terminal-consult-mode' adds it to `consult-buffer-sources',
hidden until narrowed with its key.  The terminal pickers use its
`:narrow', `:preview-key' and `:name' too; set them with `consult-customize'.")

(defvar portal-terminal-consult-project-source
  `( :name        "Terminal"
     :narrow      ?t
     :hidden      t
     :category    buffer
     :preview-key "M-."
     :annotate    ,#'portal-terminal--annotation
     :state       ,#'portal-terminal-consult--state
     :enabled     ,(lambda () consult-project-function)
     :items       ,(lambda ()
                     (when-let* ((root (consult--project-root)))
                       (portal-terminal-consult--items root))))
  "Consult source for the terminals assigned to Consult's current project.
Assignment, not the shell's directory, decides: see
`portal-terminal-set-project'.
`portal-terminal-consult-mode' adds it to `consult-project-buffer-sources',
hidden until narrowed with its key.")

(defun portal-terminal-consult--read (prompt terminals actions initial)
  "Read one of TERMINALS or ACTIONS with Consult.
See `portal-terminal--reader' for PROMPT, TERMINALS, ACTIONS and INITIAL.
The terminals are `portal-terminal-consult-source', shown, and previewed
without being selected: the caller acts on the choice."
  (car (consult--multi
        (list `( :hidden nil :items ,terminals :state ,#'portal-terminal-consult--preview
                 ,@portal-terminal-consult-source)
              `( :name "New" :narrow ?n :annotate ignore :items ,actions))
        :prompt prompt
        :initial initial
        :require-match t
        :sort nil
        :keymap portal-terminal-choose-map)))

;;;###autoload
(define-minor-mode portal-terminal-consult-mode
  "Choose Portal terminals with Consult, and list them in its buffer commands.
`portal-terminal-choose' and `portal-terminal-choose-project' gain preview,
with \\`M-.' by default, and narrowing.  `consult-buffer' and
`consult-project-buffer' gain a Terminal group, hidden until narrowed with
\\`t': the project's is the terminals assigned to it.  Customize both with
`consult-customize' on `portal-terminal-consult-source' and
`portal-terminal-consult-project-source'."
  :global t
  :group 'portal-terminal
  (if portal-terminal-consult-mode
      (progn
        (require 'consult)
        (add-to-list 'consult-buffer-sources 'portal-terminal-consult-source t)
        (add-to-list 'consult-project-buffer-sources 'portal-terminal-consult-project-source t)
        (setq portal-terminal--reader #'portal-terminal-consult--read))
    (when (featurep 'consult)
      (setq consult-buffer-sources (remq 'portal-terminal-consult-source consult-buffer-sources)
            consult-project-buffer-sources
            (remq 'portal-terminal-consult-project-source consult-project-buffer-sources)))
    (setq portal-terminal--reader #'portal-terminal--completing-read)))

(provide 'portal-terminal-consult)
;;; portal-terminal-consult.el ends here
