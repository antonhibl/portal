;;; portal-launcher.el --- A dedicated native launcher frame -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Opt-in and build-restricted: this moves Emacs's internal NS view. A native
;; defect can crash Emacs. Loading this file creates no frame or shortcut.
(require 'portal-view)

(declare-function portal--launcher-attach "portal-launcher" (title))
(declare-function portal--launcher-show "portal-launcher" (width height dx dy screen shadow radius))
(declare-function portal--launcher-hide "portal-launcher" ())
(declare-function portal--launcher-detach "portal-launcher" ())
(declare-function portal--launcher-inspect "portal-launcher" ())

(defgroup portal-launcher nil "An Emacs buffer in a native macOS panel." :group 'frames)

(defcustom portal-launcher-size '(720 420)
  "Launcher width and height in AppKit logical points, at least 200 by 100.
Apply changes with `portal-launcher-show'. The panel is clamped to the
monitor's usable area. Retina backing scale does not change these units."
  :type '(list integer integer))

(defcustom portal-launcher-offset '(0 0)
  "Offset right and down from the usable monitor area's center, in points.
The native origin is rounded down to whole points, then clamped onscreen."
  :type '(list integer integer))

(defcustom portal-launcher-screen nil
  "Monitor index in AppKit screen order, or nil for the pointer's monitor.
A disconnected index falls back to the pointer's monitor. Placement is
recomputed on every show and when the display arrangement changes."
  :type '(choice (const :tag "Pointer monitor" nil) natnum))

(defcustom portal-launcher-font nil
  "Font for the launcher, or nil to use the new frame's default font.
A non-nil value is applied on every `portal-launcher-show'."
  :type '(choice (const nil) string))

(defcustom portal-launcher-shadow t
  "Whether the native panel has a shadow. Apply with `portal-launcher-show'."
  :type 'boolean)

(defcustom portal-launcher-corner-radius 14
  "Panel corner radius in logical points. Apply with `portal-launcher-show'."
  :type 'natnum)

(defcustom portal-launcher-frame-parameters
  '((internal-border-width . 16) (left-fringe . 0) (right-fringe . 0)
    (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil))
  "Additional initial frame parameters, such as colors and internal borders.
The launcher's fixed role parameters cannot be overridden. To apply changes,
disable `portal-launcher-mode', then show again. Fonts and appearance may
also be changed directly on the live launcher frame."
  :type '(alist :key-type symbol :value-type sexp))

(defconst portal-launcher--revision "a360712c9d272d950d8d8255ef74570f7e90b7d9")
(defconst portal-launcher--role
  '((undecorated . t) (fullscreen . nil) (parent-frame . nil)
    (tool-bar-lines . 0) (menu-bar-lines . 0) (tab-bar-lines . 0)
    (minibuffer . t) (no-focus-on-map . t) (no-accept-focus . nil)
    (no-other-frame . t) (z-group . nil))
  "Immutable parameters of the dedicated launcher frame.")
(defvar portal-launcher--frame nil "The dedicated frame, or nil before creation.")
(defvar portal-launcher--return-window nil "Ordinary window selected before presentation.")
(defvar portal-launcher-mode nil)
(defvar comp-installed-trampolines-h)

(defun portal-launcher--check-support ()
  "Refuse unvalidated builds before creating or modifying any frame."
  (unless (and (eq system-type 'darwin) (eq window-system 'ns)
               (equal emacs-version "31.1")
               (equal emacs-repository-version portal-launcher--revision))
    (user-error "Portal launcher requires GNU Emacs NS 31.1 revision %s (this build is unvalidated)"
                portal-launcher--revision)))

(defun portal-launcher--guard-parameters (original frame parameters)
  "Keep launcher FRAME's native role fixed before ORIGINAL sees PARAMETERS."
  (if (not (and portal-launcher--frame
                (eq (or frame (selected-frame)) portal-launcher--frame)))
      (funcall original frame parameters)
    (dolist (parameter parameters)
      (when (and (assq (car parameter) portal-launcher--role)
                 (not (equal (cdr parameter)
                             (cdr (assq (car parameter) portal-launcher--role)))))
        (user-error "Launcher frame parameter %s is fixed" (car parameter))))
    ;; Even setting parent-frame to its existing nil calls an EmacsWindow-only
    ;; selector. Drop unchanged role parameters as well as rejecting changes.
    (funcall original frame
             (cl-remove-if (lambda (entry) (assq (car entry) portal-launcher--role)) parameters))))

(defun portal-launcher--restore-selection ()
  "Restore the ordinary window only if the launcher still owns selection."
  (when (and (eq (selected-frame) portal-launcher--frame)
             (window-live-p portal-launcher--return-window))
    (select-window portal-launcher--return-window 'norecord))
  (setq portal-launcher--return-window nil))

(defun portal-launcher--before-delete (frame)
  "Restore FRAME's original EmacsWindow before Emacs releases its NS view."
  (when (eq frame portal-launcher--frame)
    (portal--launcher-detach)
    (portal-launcher--restore-selection)
    (setq portal-launcher--frame nil)))

(defun portal-launcher--hooks (install)
  "INSTALL or remove lifecycle hooks and the native-role guard."
  (if install
      (advice-add 'modify-frame-parameters :around #'portal-launcher--guard-parameters)
    (advice-remove 'modify-frame-parameters #'portal-launcher--guard-parameters))
  (dolist (entry '((delete-frame-functions . portal-launcher--before-delete)
                   (kill-emacs-hook . portal-launcher--disable)))
    (if install (add-hook (car entry) (cdr entry))
      (remove-hook (car entry) (cdr entry)))))

(defun portal-launcher--check-guard ()
  "Ensure native-compiled callers also go through the frame-role guard.
This uses the validated Emacs build's trampoline registry. Without its
trampoline, native-compiled built-in setters bypass Lisp advice."
  (when (and (featurep 'native-compile)
             (not (and (boundp 'comp-installed-trampolines-h)
                       (gethash 'modify-frame-parameters comp-installed-trampolines-h))))
    (user-error "Launcher needs the modify-frame-parameters native trampoline; enable native-comp-enable-subr-trampolines and a working native compiler, then retry")))

(defun portal-launcher--disable ()
  "Detach and delete the dedicated frame. Safe to call repeatedly."
  (when (frame-live-p portal-launcher--frame)
    ;; Let delete-frame validate deletion (e.g. an active minibuffer) before
    ;; its hook detaches. If it refuses, keep ownership and guards intact.
    (delete-frame portal-launcher--frame t))
  (portal-launcher--hooks nil)
  (setq portal-launcher-mode nil))

;;;###autoload
(define-minor-mode portal-launcher-mode
  "Opt in to Portal's build-restricted native launcher.
Enabling loads the existing Portal module but creates no frame or shortcut.
Disabling restores the native window before deleting the dedicated frame.
A native defect can crash the hosting Emacs; start in a disposable Emacs."
  :global t :group 'portal-launcher
  (if portal-launcher-mode
      (condition-case error
          (progn
            (portal-launcher--check-support)
            (portal-view--load)
            (unless (fboundp 'portal--launcher-attach)
              (user-error "Rebuild Portal and restart Emacs for launcher support"))
            (portal-launcher--hooks t)
            (portal-launcher--check-guard))
        (error
         (unless (frame-live-p portal-launcher--frame) (portal-launcher--hooks nil))
         (setq portal-launcher-mode (and (frame-live-p portal-launcher--frame) t))
         (signal (car error) (cdr error))))
    (condition-case error
        (portal-launcher--disable)
      (error (setq portal-launcher-mode t) (signal (car error) (cdr error))))))

(defun portal-launcher--create ()
  "Create and attach one new dedicated frame, rolling back on failure."
  (dolist (parameter portal-launcher-frame-parameters)
    (when (or (assq (car parameter) portal-launcher--role)
              (memq (car parameter) '(visibility name title window-system)))
      (user-error "Launcher initial parameter %s is managed by Portal" (car parameter))))
  (let ((previous (selected-window)) ready)
    (unwind-protect
        (progn
          (setq portal-launcher--frame
                (make-frame (append '((name . "Portal launcher") (title . "Portal launcher")
                                      (visibility . nil) (width . 80) (height . 20))
                                    portal-launcher--role portal-launcher-frame-parameters)))
          (portal-view--with-frame-title portal-launcher--frame #'portal--launcher-attach)
          (setq ready t))
      (when (window-live-p previous) (select-window previous 'norecord))
      (unless ready
        (when (frame-live-p portal-launcher--frame)
          (delete-frame portal-launcher--frame t))
        (setq portal-launcher--frame nil)))))

(defun portal-launcher--placement ()
  "Return validated native presentation arguments without modifying a frame."
  (unless (and (proper-list-p portal-launcher-size) (= (length portal-launcher-size) 2)
               (cl-every #'integerp portal-launcher-size)
               (>= (car portal-launcher-size) 200) (>= (cadr portal-launcher-size) 100)
               (proper-list-p portal-launcher-offset) (= (length portal-launcher-offset) 2)
               (cl-every #'integerp portal-launcher-offset)
               (or (null portal-launcher-screen) (natnump portal-launcher-screen))
               (natnump portal-launcher-corner-radius))
    (user-error "Invalid launcher size, offset, screen or corner radius"))
  (append portal-launcher-size portal-launcher-offset
          (list (or portal-launcher-screen -1) portal-launcher-shadow portal-launcher-corner-radius)))

;;;###autoload
(defun portal-launcher-show (&optional buffer)
  "Show BUFFER in the dedicated launcher and return its frame.
With no BUFFER, reuse its content; the first show uses the current buffer.
Interactively prompt for a buffer. This explicitly opts in to
`portal-launcher-mode'. Size and presentation customizations apply each time."
  (interactive (list (read-buffer "Launcher buffer: " (current-buffer) t)))
  (when (and buffer (not (buffer-live-p (get-buffer buffer))))
    (user-error "Launcher buffer is not live: %s" buffer))
  (let ((placement (portal-launcher--placement))
        (buffer (if buffer (get-buffer buffer)
                  (unless (frame-live-p portal-launcher--frame) (current-buffer)))))
    (unless portal-launcher-mode (portal-launcher-mode 1))
    (unless (frame-live-p portal-launcher--frame) (portal-launcher--create))
    (unless (eq (selected-frame) portal-launcher--frame)
      (setq portal-launcher--return-window (selected-window)))
    (when buffer (set-window-buffer (frame-selected-window portal-launcher--frame) buffer))
    (when portal-launcher-font
      (let ((frame-inhibit-implied-resize t))
        (set-frame-font portal-launcher-font nil (list portal-launcher--frame))))
    (condition-case error
        (progn
          (select-frame portal-launcher--frame 'norecord)
          (apply #'portal--launcher-show placement)
          ;; Native visibility alone does not enable Emacs redisplay.
          (make-frame-visible portal-launcher--frame)
          (redisplay t)
          portal-launcher--frame)
      (error (portal-launcher-hide) (signal (car error) (cdr error))))))

;;;###autoload
(defun portal-launcher-hide ()
  "Hide the launcher, retaining its frame, buffer and window state.
Active launcher minibuffers must be finished or cancelled first; command
session dismissal is a separate feature."
  (interactive)
  (when (frame-live-p portal-launcher--frame)
    (when (and (active-minibuffer-window)
               (eq (window-frame (active-minibuffer-window)) portal-launcher--frame))
      (user-error "Finish or cancel the launcher's minibuffer before hiding it"))
    (portal--launcher-hide)
    (make-frame-invisible portal-launcher--frame t)
    (portal-launcher--restore-selection)))

(defun portal-launcher-resize (width height)
  "Set the launcher's WIDTH and HEIGHT in logical points and show it again."
  (interactive (list (read-number "Width (points): " (car portal-launcher-size))
                     (read-number "Height (points): " (cadr portal-launcher-size))))
  (let ((portal-launcher-size (list width height))) (portal-launcher-show))
  (setq portal-launcher-size (list width height)))

(defun portal-launcher-unload-function ()
  "Restore native ownership before unloading this feature."
  (portal-launcher--disable)
  nil)

(provide 'portal-launcher)
;;; portal-launcher.el ends here
