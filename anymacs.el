;;; anymacs.el --- A Swift native-view experiment -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(defconst anymacs--module-file
  (expand-file-name "build/anymacs.dylib"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Location of the native module built by build.sh.")

(declare-function anymacs--bind "anymacs" (title))
(declare-function anymacs--set-layout "anymacs" (layout))
(declare-function anymacs--destroy "anymacs" ())
(declare-function anymacs--native-views "anymacs" ())

;; One buffer's content, with a native presentation in each of its host panes.
(defvar anymacs--buffer nil "Buffer owning the shared native content.")
(defvar anymacs--frame nil "Frame hosting the native presentations.")
(defvar anymacs--panes nil "Alist mapping displayed Emacs windows to native IDs.")
(defvar anymacs--next-id 0 "Last allocated native pane ID in this session.")
(defvar anymacs--geometry nil
  "Last sent geometry: frame height paired with the native layout vector.
Nil means no layout has been sent yet.")

(define-derived-mode anymacs-mode special-mode "Anymacs"
  "Major mode for the native green rectangle demonstration."
  (setq-local cursor-type nil))

(keymap-set anymacs-mode-map "q" #'anymacs-hide)

;; Host binding and presentation geometry.
(defun anymacs--bind-frame (frame)
  "Identify FRAME to AppKit without depending on asynchronous focus changes."
  (let ((title (frame-parameter frame 'title))
        (token (make-temp-name "anymacs-host-")))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'title token)
          (anymacs--bind token))
      (set-frame-parameter frame 'title title))))

(defun anymacs--update-layout ()
  "Reconcile all panes showing the buffer with their native presentations."
  (let* ((panes
          (mapcar (lambda (window)
                    (or (assq window anymacs--panes)
                        (cons window (setq anymacs--next-id
                                           (1+ anymacs--next-id)))))
                  (get-buffer-window-list anymacs--buffer nil anymacs--frame)))
         ;; Window enumeration can change order with focus; native IDs do not.
         (panes (sort panes (lambda (a b) (< (cdr a) (cdr b)))))
         (layout (vconcat
                  (apply #'append
                         (mapcar (lambda (pane)
                                   (cons (cdr pane)
                                         (window-inside-pixel-edges (car pane))))
                                 panes))))
         ;; An unflipped AppKit host also needs the frame's height.
         (geometry (cons (frame-pixel-height anymacs--frame) layout)))
    (unless (equal geometry anymacs--geometry)
      ;; Send the complete layout, including an empty one when hidden.
      (anymacs--set-layout layout)
      (setq anymacs--geometry geometry))
    (setq anymacs--panes panes)))

(defun anymacs--sync (frame)
  "Update native presentations after FRAME's window layout changes."
  (when (and anymacs--frame (eq frame anymacs--frame))
    (condition-case err
        (if (and (frame-live-p frame) (buffer-live-p anymacs--buffer))
            (anymacs--update-layout)
          (anymacs-hide))
      (error
       ;; A failing redisplay callback must not leave a stale overlay behind.
       (anymacs-hide)
       (signal (car err) (cdr err))))))

(defun anymacs--frame-deleted (frame)
  "Stop tracking when the host FRAME is deleted."
  (when (eq frame anymacs--frame)
    (anymacs-hide)))

;; Public lifecycle.  All hook registration is owned by these two commands.
;;;###autoload
(defun anymacs-show ()
  "Display Swift-drawn green rectangles in *anymacs-green*.
Each window showing the buffer in the current frame gets its own native view.
All views share the buffer's native content."
  (interactive)
  (unless (and (eq window-system 'ns) (fboundp 'module-load))
    (user-error "Anymacs needs graphical macOS Emacs with module support"))
  (unless (fboundp 'anymacs--bind)
    (module-load anymacs--module-file))
  (unless (fboundp 'anymacs--set-layout)
    (user-error "Restart Emacs to load the rebuilt Anymacs module"))
  (anymacs-hide)
  (let (ready)
    (unwind-protect
        (progn
          (switch-to-buffer (get-buffer-create "*anymacs-green*"))
          (unless (derived-mode-p 'anymacs-mode)
            (anymacs-mode))
          (redisplay t)
          (setq anymacs--buffer (current-buffer)
                anymacs--frame (selected-frame))
          (anymacs--bind-frame anymacs--frame)
          ;; Attach before registering redisplay callbacks, so errors reach
          ;; the caller instead of being swallowed by redisplay's safe_call.
          (anymacs--sync anymacs--frame)
          (add-hook 'kill-buffer-hook #'anymacs-hide nil t)
          (add-hook 'change-major-mode-hook #'anymacs-hide nil t)
          (add-hook 'window-state-change-functions #'anymacs--sync)
          (add-hook 'delete-frame-functions #'anymacs--frame-deleted)
          (setq ready t)
          (message "Swift native views attached. Press q or M-x anymacs-hide to remove them."))
      (unless ready (anymacs-hide)))))

;;;###autoload
(defun anymacs-hide ()
  "Release all native views and content, and stop tracking window changes."
  (interactive)
  (remove-hook 'window-state-change-functions #'anymacs--sync)
  (remove-hook 'delete-frame-functions #'anymacs--frame-deleted)
  (when (buffer-live-p anymacs--buffer)
    (with-current-buffer anymacs--buffer
      (remove-hook 'kill-buffer-hook #'anymacs-hide t)
      (remove-hook 'change-major-mode-hook #'anymacs-hide t)))
  (setq anymacs--buffer nil
        anymacs--frame nil
        anymacs--panes nil
        anymacs--next-id 0
        anymacs--geometry nil)
  (when (fboundp 'anymacs--destroy)
    (anymacs--destroy)))

(provide 'anymacs)
;;; anymacs.el ends here
