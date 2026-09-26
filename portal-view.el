;;; portal-view.el --- The shared Portal view lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A buffer has at most one Portal view.  The view appears in the selected pane
;; that shows the buffer, in any frame, and is hidden, not ended, while no pane
;; shows it (docs/adr/0001).  This file makes every native lifecycle call,
;; addressing each view by its native target, such as "terminal:1"
;; (docs/adr/0002).  It also owns the one pipe that carries every native
;; notification to Emacs, as records of the form "TYPE TARGET FIELD...".

(require 'cl-lib)

(declare-function portal--open "portal-view" (kind options))
(declare-function portal--place "portal-view" (target edges title))
(declare-function portal--hide "portal-view" (target))
(declare-function portal--close "portal-view" (target))
(declare-function portal--channel "portal-view" (process))
(declare-function portal--input "portal-input" (target action &optional serial))

(defconst portal-view--module-file
  (expand-file-name "build/portal.bundle/Contents/MacOS/portal.dylib"
                    (file-name-directory
                     (or load-file-name
                         (bound-and-true-p byte-compile-current-file)
                         buffer-file-name)))
  "The single native module used by all Portal features.")

(defvar portal-view-load-hook nil "Hook run after the native module loads.")

(defvar portal-view-record-handlers nil
  "How to handle each type of native record, as (\"TYPE\" . FUNCTION).
The native module sends each record as a line \"TYPE TARGET FIELD...\".
FUNCTION is called with TARGET and each FIELD string as arguments, with
TARGET's buffer current.  It runs inside a process filter, so it must
never prompt; it queues commands through `unread-command-events'.
Records for unknown targets, or of types with no handler, are dropped.")

(defvar portal-view--channel nil "The pipe process that receives native records.")
(defvar portal-view--pending "" "The start of a record whose end is still to come.")
(defvar portal-input--target-function)

(defvar portal-view--buffers nil "Buffers with a Portal view, in creation order.")
(defvar-local portal-view--target nil "This buffer's native target.")
(defvar-local portal-view--window nil "The window showing this buffer's view, or nil.")
(defvar-local portal-view--geometry nil
  "The placement last sent to the native view, or nil while it is hidden.
The form is (FRAME FRAME-PIXEL-HEIGHT EDGES).")

(defun portal-view--load ()
  "Load the native module and connect its record pipe, before any native view."
  (unless (featurep 'portal-native-module)
    (unless (and (eq window-system 'ns) (fboundp 'module-load))
      (user-error "Portal needs graphical macOS Emacs with module support"))
    (when (fboundp 'portal--bind)
      (user-error "Restart Emacs to replace the old Portal native modules"))
    (module-load portal-view--module-file)
    (run-hooks 'portal-view-load-hook))
  (unless (fboundp 'portal--web-load)
    (user-error "Restart Emacs to load the rebuilt Portal native module"))
  (unless (process-live-p portal-view--channel)
    (setq portal-view--pending ""
          portal-view--channel (make-pipe-process :name "portal-view-records" :noquery t
                                                  :coding 'utf-8-unix
                                                  :filter #'portal-view--receive))
    (portal--channel portal-view--channel)))

(defun portal-view--consume-lines (pending text receiver)
  "Deliver complete lines from PENDING and TEXT to RECEIVER; return the tail.
Pipes carry short records, independently of OS read boundaries.
RECEIVER must queue interactive work for the command loop, not run it here."
  (let ((input (concat pending text)) (start 0))
    (while (string-match "\n" input start)
      (let ((end (match-beginning 0)))
        (funcall receiver (substring input start end))
        (setq start (1+ end))))
    (substring input start)))

(defun portal-view--receive (_process text)
  "Dispatch each native record completed by TEXT."
  (setq portal-view--pending
        (portal-view--consume-lines portal-view--pending text #'portal-view--dispatch)))

(defun portal-view--dispatch (record)
  "Call RECORD's handler with its target's buffer current.
Errors are only reported: the records after this one must still arrive."
  (with-demoted-errors "Portal record: %S"
    (pcase-let* ((`(,type ,target . ,fields) (split-string record " "))
                 (handler (cdr (assoc type portal-view-record-handlers)))
                 (buffer (and handler target (portal-view--target-buffer target))))
      (when buffer
        (with-current-buffer buffer
          (apply handler target fields))))))

(defun portal-view--target-buffer (target)
  "Return the live buffer whose view is TARGET, or nil."
  (or (cl-find target (portal-view-buffers) :test #'equal
               :key (lambda (buffer) (buffer-local-value 'portal-view--target buffer)))
      ;; Excalidraw editors do not use `portal-view-open' yet,
      ;; so find the window that shows them through `portal-input'.
      (cl-loop for window in (window-list-1 nil 'nomini t)
               when (with-current-buffer (window-buffer window)
                      (and (bound-and-true-p portal-input--target-function)
                           (equal target (funcall portal-input--target-function window))))
               return (window-buffer window))))

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
KIND is a symbol, `terminal' or `web'.  OPTIONS is a plist for that kind.
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
