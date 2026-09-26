;;; portal-toolbar.el --- Controls for native Portal views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-view)
(require 'json)

(defgroup portal-toolbar nil "Native view controls." :group 'applications)
(declare-function portal--toolbar "portal" (enabled))
(declare-function portal--toolbar-theme "portal" (json))
(declare-function portal--toolbar-action "portal" (target action))
(defvar portal-input--resume)

(defcustom portal-toolbar t
  "Whether native Portal views reserve a 28 pixel toolbar at the top.
Changes apply immediately.  Quick terminals, and web views opened without a
toolbar, have no strip."
  :type 'boolean :group 'portal-toolbar)

(defun portal-toolbar--changed (_symbol value operation _where)
  "Apply a new toolbar VALUE on variable OPERATION."
  (when (and (memq operation '(set let unlet)) (fboundp 'portal--toolbar))
    (portal--toolbar value)))
(add-variable-watcher 'portal-toolbar #'portal-toolbar--changed)

(defun portal-toolbar--color (face attribute &optional fallback)
  "Read FACE ATTRIBUTE as native RGB, optionally trying FALLBACK face."
  (let* ((value (face-attribute face attribute nil t))
         (rgb (and (stringp value) (color-values value))))
    (or (when rgb (vconcat (mapcar (lambda (n) (/ n 65535.0)) rgb)))
        (when fallback (portal-toolbar--color fallback attribute)))))

(defun portal-toolbar--theme (&rest _)
  "Send current Emacs face colors to native toolbars."
  (when (fboundp 'portal--toolbar-theme)
    (let (colors)
      (dolist (spec '(("background" header-line :background mode-line-inactive)
                      ("border" vertical-border :foreground)
                      ("shadow" shadow :foreground)
                      ("foreground" default :foreground)
                      ("success" success :foreground)
                      ("accent" link :foreground)
                      ("warning" warning :foreground)))
        (when-let* ((rgb (apply #'portal-toolbar--color (cdr spec))))
          (push (cons (car spec) rgb) colors)))
      (portal--toolbar-theme (if colors (json-encode colors) "{}")))))

(defun portal-toolbar--initialize ()
  "Configure the toolbar after loading the native module."
  (when (fboundp 'portal--toolbar)
    (portal--toolbar portal-toolbar)
    (portal-toolbar--theme)))
(add-hook 'portal-view-load-hook #'portal-toolbar--initialize)
(add-hook 'enable-theme-functions #'portal-toolbar--theme)
(add-hook 'disable-theme-functions #'portal-toolbar--theme)
(portal-toolbar--initialize)

(defun portal-toolbar--action (action &optional terminal)
  "Perform ACTION in the selected pane's Portal view and return its state.
The state is authoritative.  The view must be a web view, or a terminal
when TERMINAL is non-nil."
  (let ((target (portal-view-target)))
    (unless (and target (fboundp 'portal--toolbar-action))
      (user-error "No native Portal view in this pane"))
    (when (if terminal (not (string-prefix-p "terminal:" target))
            (not (string-prefix-p "web:" target)))
      (user-error (if terminal "Select a Portal terminal" "Select a Portal web view")))
    (json-parse-string (portal--toolbar-action target action) :object-type 'alist
                       :false-object nil :null-object nil)))

(defun portal-zoom-in ()
  "Increase this web view's zoom to the next step; return its percentage."
  (interactive)
  (alist-get 'value (portal-toolbar--action "increase")))
(defun portal-zoom-out ()
  "Decrease this web view's zoom to the previous step; return its percentage."
  (interactive)
  (alist-get 'value (portal-toolbar--action "decrease")))
(defun portal-zoom-reset ()
  "Reset this web view's zoom to 100%; return its percentage."
  (interactive)
  (alist-get 'value (portal-toolbar--action "reset")))
(defun portal-toggle-toc ()
  "Toggle this preview's table of contents; return whether it is open."
  (interactive)
  (alist-get 'toc (portal-toolbar--action "toc")))
(defun portal-find ()
  "Focus the native find field in this web view's toolbar."
  (interactive)
  (portal-toolbar--action "find")
  (setq portal-input--resume nil))
(defun portal-terminal-text-size-increase ()
  "Increase this terminal's text size by one point; return the size."
  (interactive)
  (alist-get 'value (portal-toolbar--action "increase" t)))
(defun portal-terminal-text-size-decrease ()
  "Decrease this terminal's text size by one point; return the size."
  (interactive)
  (alist-get 'value (portal-toolbar--action "decrease" t)))
(defun portal-terminal-text-size-reset ()
  "Reset this terminal's configured text size; return the size."
  (interactive)
  (alist-get 'value (portal-toolbar--action "reset" t)))

(provide 'portal-toolbar)
;;; portal-toolbar.el ends here
