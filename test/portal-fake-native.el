;;; portal-fake-native.el --- In-memory Portal native module for batch tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Stands in for the native module at the `portal-view.el' seam, so batch
;; Emacs can drive real buffers, windows and frames without AppKit.  Load it
;; before Portal; never load it into an Emacs that uses the real module.

(require 'cl-lib)
(require 'subr-x)

(defvar portal-fake-native--views (make-hash-table :test #'equal)
  "Open views: target to a plist of :options, :frame, :edges and :visible.")
(defvar portal-fake-native--next-id 0 "Last view ID.  IDs are never reused.")
(defvar portal-fake-native-log nil "Lifecycle calls, newest first, as (NAME ARGS...).")
(defvar portal-fake-native-failures nil
  "Exports that signal an error, such as `portal--open' or `portal--place'.")

(defun portal-fake-native-reset ()
  "Forget every view and logged call."
  (clrhash portal-fake-native--views)
  (setq portal-fake-native-log nil))

(defun portal-fake-native-calls (name)
  "Return the argument lists of each logged call to NAME, oldest first."
  (mapcar #'cdr (reverse (cl-remove name portal-fake-native-log :key #'car :test-not #'eq))))

(defun portal-fake-native-targets ()
  "Return the targets of the open views."
  (hash-table-keys portal-fake-native--views))

(defun portal-fake-native--call (name &rest arguments)
  "Log a call to NAME with ARGUMENTS, and fail when the test asks."
  (push (cons name arguments) portal-fake-native-log)
  (when (memq name portal-fake-native-failures)
    (error "Fake %s failure" name)))

(defun portal-fake-native--view (target)
  "Return TARGET's state, or signal as the native module does."
  (or (gethash target portal-fake-native--views)
      (error "No Portal view %s" target)))

(defun portal--open (kind options)
  (portal-fake-native--call 'portal--open kind options)
  (let ((target (format "%s:%d" kind (cl-incf portal-fake-native--next-id))))
    (puthash target (list :options options :frame nil :edges nil :visible nil)
             portal-fake-native--views)
    target))

(defun portal--place (target edges title)
  (portal-fake-native--call 'portal--place target edges title)
  (let ((view (portal-fake-native--view target))
        (frame (cl-find title (frame-list)
                        :key (lambda (frame) (frame-parameter frame 'title)) :test #'equal)))
    (unless frame (error "Cannot find the requested native Emacs frame"))
    (setq view (plist-put view :frame frame))
    (setq view (plist-put view :edges (append edges nil)))
    (puthash target (plist-put view :visible t) portal-fake-native--views)
    t))

(defun portal--hide (target)
  (portal-fake-native--call 'portal--hide target)
  (let ((view (portal-fake-native--view target)))
    (puthash target (plist-put (plist-put view :edges nil) :visible nil)
             portal-fake-native--views)
    t))

(defun portal--close (target)
  (portal-fake-native--call 'portal--close target)
  (portal-fake-native--view target)
  (remhash target portal-fake-native--views)
  t)

(defun portal--inspect (target)
  (copy-sequence (gethash target portal-fake-native--views)))

;; Input exports, so terminal commands run unchanged.  Focus needs a shown view.
(defun portal--input (target action &optional _serial)
  (and (equal action "focus")
       (plist-get (gethash target portal-fake-native--views) :visible)))
(defun portal--input-channel (_process) t)
(defun portal--input-prefix (_character _flags) t)
(defun portal--terminal-bindings (_json) t)
(defun portal--terminal-theme (_theme) t)

(provide 'portal-native-module)
(provide 'portal-fake-native)
;;; portal-fake-native.el ends here
