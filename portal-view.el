;;; portal-view.el --- The shared Portal view lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A buffer has at most one Portal view.  The view appears in the selected pane
;; that shows the buffer, in any frame, and is hidden, not ended, while no pane
;; shows it (docs/adr/0001).  This file makes every native lifecycle call,
;; addressing each view by its native target, such as "terminal:1"
;; (docs/adr/0002).

(require 'cl-lib)

(declare-function portal--open "portal-view" (kind options))
(declare-function portal--place "portal-view" (target edges title))
(declare-function portal--hide "portal-view" (target))
(declare-function portal--close "portal-view" (target))
(declare-function portal--input "portal-input" (target action &optional serial))

(defconst portal-view--module-file
  (expand-file-name "build/portal.bundle/Contents/MacOS/portal.dylib"
                    (file-name-directory
                     (or load-file-name
                         (bound-and-true-p byte-compile-current-file)
                         buffer-file-name)))
  "The single native module used by all Portal features.")

(defvar portal-view-load-hook nil "Hook run after the native module loads.")

(defvar portal-view--buffers nil "Buffers with a Portal view, in creation order.")
(defvar-local portal-view--target nil "This buffer's native target.")
(defvar-local portal-view--window nil "The window showing this buffer's view, or nil.")
(defvar-local portal-view--geometry nil
  "The placement last sent to the native view, or nil while it is hidden.
The form is (FRAME FRAME-PIXEL-HEIGHT EDGES).")

(defun portal-view--load ()
  "Load the native module once, before opening any native view."
  (unless (featurep 'portal-native-module)
    (unless (and (eq window-system 'ns) (fboundp 'module-load))
      (user-error "Portal needs graphical macOS Emacs with module support"))
    (when (fboundp 'portal--bind)
      (user-error "Restart Emacs to replace the old Portal native modules"))
    (module-load portal-view--module-file)
    (run-hooks 'portal-view-load-hook))
  (unless (fboundp 'portal--open)
    (user-error "Restart Emacs to load the rebuilt Portal native module")))

(defun portal-view--with-frame-title (frame function)
  "Call FUNCTION with a unique title that FRAME carries during the call.
The native module finds FRAME's window by this title."
  (let ((title (frame-parameter frame 'title))
        (token (make-temp-name "portal-host-")))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'title token)
          (funcall function token))
      (set-frame-parameter frame 'title title))))

(defun portal-view--hooks (install)
  "INSTALL the global hooks, or remove them when INSTALL is nil."
  (dolist (entry '((window-state-change-functions . portal-view-sync)
                   (window-selection-change-functions . portal-view-sync)
                   (delete-frame-functions . portal-view--frame-deleted)
                   (kill-emacs-hook . portal-view--close-all)))
    (if install
        (add-hook (car entry) (cdr entry))
      (remove-hook (car entry) (cdr entry)))))

(defun portal-view-open (kind options)
  "Open a Portal view of KIND for the current buffer and return its target.
KIND is a symbol, such as `terminal'.  OPTIONS is a plist for that kind.
The view follows the selected pane showing the buffer, in any frame, is
hidden while no pane shows it, and ends when the buffer is killed or
changes major mode."
  (when portal-view--target (error "This buffer already has a Portal view"))
  (portal-view--load)
  (let ((target (portal--open (symbol-name kind) options))
        ready)
    (unwind-protect
        (progn
          (setq portal-view--target target)
          (unless portal-view--buffers (portal-view--hooks t))
          (setq portal-view--buffers (append portal-view--buffers (list (current-buffer))))
          (add-hook 'kill-buffer-hook #'portal-view-close 90 t)
          (add-hook 'change-major-mode-hook #'portal-view-close 90 t)
          (portal-view--sync-buffer (current-buffer))
          (setq ready t))
      (unless ready (portal-view-close)))
    target))

(defun portal-view-close ()
  "End the current buffer's Portal view, if it has one."
  (when-let* ((target portal-view--target))
    (setq portal-view--buffers (delq (current-buffer) portal-view--buffers)
          portal-view--target nil
          portal-view--window nil
          portal-view--geometry nil)
    (remove-hook 'kill-buffer-hook #'portal-view-close t)
    (remove-hook 'change-major-mode-hook #'portal-view-close t)
    (unless portal-view--buffers (portal-view--hooks nil))
    (portal--close target)))

(defun portal-view-target (&optional window)
  "Return the target of the Portal view shown in WINDOW, or nil.
WINDOW defaults to the selected window.  Other windows showing the same
buffer show only its text, so they have no target."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (and (eq window portal-view--window) portal-view--target))))

(defun portal-view-buffers (&optional kind)
  "Return the buffers that have a Portal view, in creation order.
With KIND, a symbol such as `terminal', return only views of that kind."
  (let ((prefix (and kind (format "%s:" kind))))
    ;; Always a fresh list: closing a view while iterating edits the original.
    (cl-loop for buffer in portal-view--buffers
             when (and (buffer-live-p buffer)
                       (or (null prefix)
                           (string-prefix-p prefix (buffer-local-value 'portal-view--target buffer))))
             collect buffer)))

(defun portal-view--sync-buffer (buffer)
  "Place BUFFER's view in its chosen window, or hide it when no window shows it.
The chosen window is the selected window, then the view's current window,
then any other window showing BUFFER, in any frame.  Placing the view in
another frame moves it there.  Nothing is sent when nothing moved."
  (with-current-buffer buffer
    (let* ((windows (get-buffer-window-list buffer nil t))
           (window (cond ((memq (selected-window) windows) (selected-window))
                         ((memq portal-view--window windows) portal-view--window)
                         (t (car windows))))
           (frame (and window (window-frame window)))
           (geometry (and window (list frame (frame-pixel-height frame)
                                       (vconcat (window-inside-pixel-edges window))))))
      (unless (equal geometry portal-view--geometry)
        (if geometry
            (portal-view--with-frame-title
             frame (lambda (title) (portal--place portal-view--target (nth 2 geometry) title)))
          (portal--hide portal-view--target))
        (setq portal-view--geometry geometry))
      (setq portal-view--window window))))

(defun portal-view-sync (&optional _frame)
  "Place or hide each Portal view to match the windows showing its buffer.
Window change hooks call this with the frame that changed, but a change in
one frame can move a view out of another, so every view is synced.  Call it
directly where the hooks do not run, such as in batch Emacs."
  (mapc #'portal-view--sync-buffer (portal-view-buffers)))

(defun portal-view-focus ()
  "Give the current buffer's Portal view keyboard focus."
  (unless portal-view--target (user-error "No Portal view in this buffer"))
  (redisplay t)
  (portal-view--sync-buffer (current-buffer))
  (unless (portal--input portal-view--target "focus")
    (user-error "No visible Portal view to focus")))

(defun portal-view--frame-deleted (frame)
  "Hide the views in FRAME, which is being deleted, keeping their sessions.
The next sync places each one wherever its buffer is still shown."
  (dolist (buffer (portal-view-buffers))
    (with-current-buffer buffer
      (when (eq frame (car portal-view--geometry))
        (portal--hide portal-view--target)
        (setq portal-view--geometry nil
              portal-view--window nil)))))

(defun portal-view--close-all ()
  "End every Portal view, for Emacs shutdown."
  (dolist (buffer (portal-view-buffers))
    (with-current-buffer buffer (portal-view-close))))

(provide 'portal-view)
;;; portal-view.el ends here
