;;; portal-toolbar.el --- Controls for native Portal views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-view)
(require 'json)
(require 'url-parse)
(require 'url-util)

(defgroup portal-toolbar nil "Native view controls." :group 'applications)
(declare-function portal--toolbar "portal" (enabled))
(declare-function portal--toolbar-theme "portal" (json))
(declare-function portal--toolbar-action "portal" (target action))
(declare-function portal--toolbar-label "portal" (target label))
(defvar portal-input--resume)
(defvar portal-web--url)
(defvar portal-web--preview)
(defvar portal-web--markdown)
(defvar portal-web--hosted-path)

(defcustom portal-toolbar t
  "Whether a native Portal view shows its toolbar over its pane's mode line.
The toolbar covers the mode line while the view has the keyboard, and the
mode line shows again when Emacs has it.  Changes apply immediately.  Quick
terminals, web views opened without a toolbar, and panes without a mode line
have none."
  :type 'boolean :group 'portal-toolbar)

(defface portal-toolbar-tint
  '((t :inherit success))
  "The color of a native view's toolbar while the view has the keyboard.
The toolbar's background mixes toward this face's foreground, and its dot
and label are drawn in it, where the pane's mode line shows while Emacs
has the keyboard.  Themes and users change it like any face; it reaches
native toolbars with the other theme colors."
  :group 'portal-toolbar)

(defcustom portal-toolbar-label-function #'portal-toolbar-default-label
  "Function naming what a native view's toolbar shows, after its dot.
It is called with no arguments in the view's buffer and returns a string,
or nil for the toolbar's own default: a web page's URL, which follows the
links and history the page navigates, and nothing for other views.  It
runs after each command and whenever the buffer list changes, so it should
be quick; the label reaches the native toolbar only when it differs from
the last one sent."
  :type 'function :group 'portal-toolbar)

(defun portal-toolbar--url-label (url)
  "Name URL for a toolbar: a file URL by its abbreviated path, others
without their scheme."
  (let ((parsed (url-generic-parse-url url)))
    (if (equal (url-type parsed) "file")
        ;; Decode as `browse-url-file-url' encodes.
        (abbreviate-file-name
         (decode-coding-string (url-unhex-string (url-filename parsed))
                               (or file-name-coding-system default-file-name-coding-system)))
      (string-remove-suffix "/" (replace-regexp-in-string "\\`[a-z]+://" "" url)))))

(defun portal-toolbar-default-label ()
  "Name what this buffer's view shows, where Emacs knows better than the view.
A Markdown or HTML render names its source file, abbreviated; a hosted app
its path; and a terminal its buffer name, which follows `rename-buffer'.
A web page returns nil: its toolbar names the URL on screen itself."
  (cond ((bound-and-true-p portal-web--markdown) (abbreviate-file-name portal-web--markdown))
        ((bound-and-true-p portal-web--preview) (portal-toolbar--url-label portal-web--preview))
        ((bound-and-true-p portal-web--hosted-path)
         (car (split-string portal-web--hosted-path "?")))
        ((bound-and-true-p portal-web--url) nil)
        (t (buffer-name))))

(defvar-local portal-toolbar--sent nil
  "The view target and label last sent for this buffer, as (TARGET . LABEL).
A new view in the same buffer has a new target, and gets its label again.")

(defun portal-toolbar--sync-labels (&rest _)
  "Send each Portal view's label to its toolbar, where it changed.
It runs after each command, which is when a new view's buffer is complete
and renames have happened; on buffer list changes, for renames outside a
command; and after native records, which change what a hosted app shows
or a terminal reports."
  (when (fboundp 'portal--toolbar-label)
    (dolist (buffer (portal-view-buffers))
      (with-current-buffer buffer
        (when-let* ((target portal-view--target)
                    (label (or (with-demoted-errors "Portal toolbar label: %S"
                                 (funcall portal-toolbar-label-function))
                               "")))
          (unless (equal (cons target label) portal-toolbar--sent)
            (portal--toolbar-label target label)
            (setq portal-toolbar--sent (cons target label))))))))

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
      (dolist (spec '(("background" mode-line-active :background mode-line)
                      ("border" vertical-border :foreground)
                      ("shadow" shadow :foreground)
                      ("foreground" default :foreground)
                      ("success" success :foreground)
                      ("accent" link :foreground)
                      ("tint" portal-toolbar-tint :foreground success)))
        (when-let* ((rgb (apply #'portal-toolbar--color (cdr spec))))
          (push (cons (car spec) rgb) colors)))
      (portal--toolbar-theme (if colors (json-encode colors) "{}")))))

(defun portal-toolbar--initialize ()
  "Configure the toolbar after loading the native module."
  (when (fboundp 'portal--toolbar)
    (portal--toolbar portal-toolbar)
    (portal-toolbar--theme)
    (add-hook 'post-command-hook #'portal-toolbar--sync-labels)
    (add-hook 'buffer-list-update-hook #'portal-toolbar--sync-labels)
    (add-hook 'portal-view-records-hook #'portal-toolbar--sync-labels)
    (portal-toolbar--sync-labels)))
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
