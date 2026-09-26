;;; portal-excalidraw.el --- Local drawings in persistent web editors -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'json)
(require 'portal-input)
(require 'portal-native)
(require 'portal-server)

(declare-function portal--editor-open "portal" (title url))
(declare-function portal--editor-layout "portal" (title id edges))
(declare-function portal--editor-send "portal" (id json))
(declare-function portal--editor-events "portal" (id))
(declare-function portal--editor-focus "portal" (id))
(declare-function portal--editor-close "portal" (id))
(declare-function portal--editor-channel "portal" (process))

(defvar portal-excalidraw--buffers nil)
(defvar portal-excalidraw--channel nil)
(defvar portal-excalidraw--notification "")
(defvar-local portal-excalidraw--id nil)
(defvar-local portal-excalidraw--window nil)
(defvar-local portal-excalidraw--geometry nil)
(defvar-local portal-excalidraw--ready nil)
(defvar-local portal-excalidraw--error nil)
(defvar-local portal-excalidraw--saved nil)
(defvar-local portal-excalidraw--request 0)
(defvar-local portal-excalidraw--reply nil)
(defvar-local portal-excalidraw--flushing nil)

(defconst portal-excalidraw--empty
  "{\"type\":\"excalidraw\",\"version\":2,\"source\":\"portal\",\"elements\":[],\"appState\":{},\"files\":{}}\n")

(defun portal-excalidraw--validate (text)
  "Validate drawing TEXT without modifying the current buffer."
  (let ((scene (json-parse-string text :object-type 'plist)))
    (unless (and (equal (plist-get scene :type) "excalidraw")
                 (vectorp (plist-get scene :elements)))
      (user-error "This is not an Excalidraw drawing"))))

(defvar portal-excalidraw-command-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "s" #'portal-excalidraw-save)
    (keymap-set map "r" #'portal-excalidraw-reopen)
    map)
  "Drawing commands below the shared Portal prefix and m.")

;;;###autoload
(define-derived-mode portal-excalidraw-mode fundamental-mode "Excalidraw"
  "Edit a local Excalidraw document in a persistent native webview.
The buffer contains the drawing's JSON for normal Emacs saving and auto-save.
The Portal prefix followed by C-x C-s saves.  Command-Escape returns to Emacs,
and RET returns to the drawing.  One live editor follows this buffer's pane."
  (when (and buffer-file-name (file-remote-p buffer-file-name))
    (user-error "Excalidraw currently supports local files only"))
  (when (= (buffer-size) 0)
    (let ((modified (buffer-modified-p)))
      (insert portal-excalidraw--empty)
      (set-buffer-modified-p modified)))
  (portal-excalidraw--validate (buffer-string))
  (setq-local buffer-read-only t)
  (setq-local buffer-undo-list t)
  (setq-local cursor-type nil)
  (setq-local require-final-newline t)
  (setq-local buffer-file-coding-system 'utf-8-unix)
  (setq-local buffer-offer-save t)
  (setq-local portal-input--target-function
              (lambda (window) (when (and portal-excalidraw--id (eq window portal-excalidraw--window))
                                 (format "editor:%d" portal-excalidraw--id))))
  (setq-local portal-input--focus-function #'portal-excalidraw-focus)
  (setq-local portal-input--map-function (lambda () portal-excalidraw-command-map))
  (portal-input-mode 1)
  (setq portal-excalidraw--saved (unless (buffer-modified-p) (buffer-string)))
  ;; Emacs deliberately catches before-save-hook errors and may still write.
  ;; This hook must abort the write if a fresh scene cannot be obtained.
  (add-hook 'write-contents-functions #'portal-excalidraw--prepare-write nil t)
  (add-hook 'after-save-hook #'portal-excalidraw--did-save nil t)
  (add-hook 'kill-buffer-query-functions #'portal-excalidraw--query-kill nil t)
  (add-hook 'kill-buffer-hook #'portal-excalidraw--close nil t)
  (add-hook 'change-major-mode-hook #'portal-excalidraw--leave-mode nil t)
  (setq-local revert-buffer-function #'portal-excalidraw--revert)
  (portal-excalidraw--start)
  (when auto-save-default (auto-save-mode 1)))

(keymap-set portal-excalidraw-mode-map "RET" #'portal-excalidraw-focus)
(keymap-set portal-excalidraw-mode-map "C-c C-r" #'portal-excalidraw-reopen)
(define-key portal-excalidraw-mode-map [remap save-buffer] #'portal-excalidraw-save)
(define-key portal-excalidraw-mode-map [remap undo] #'ignore)
(add-to-list 'auto-mode-alist '("\\.excalidraw\\'" . portal-excalidraw-mode))

;;;###autoload
(defun portal-excalidraw (&optional file)
  "Create a new drawing, or open local FILE with a prefix argument.
The first save of a new drawing asks for a filename."
  (interactive (list (when current-prefix-arg (read-file-name "Drawing: " nil nil nil))))
  (if file
      (find-file file)
    (switch-to-buffer (generate-new-buffer "untitled.excalidraw"))
    (portal-excalidraw-mode)))

(defun portal-excalidraw--start ()
  "Register the current document and start its local editor asynchronously."
  (portal-input--connect)
  (unless (process-live-p portal-excalidraw--channel)
    (setq portal-excalidraw--notification ""
          portal-excalidraw--channel
          (make-pipe-process :name "portal-editor-events" :noquery t
                             :coding 'utf-8-unix :filter #'portal-excalidraw--receive))
    (portal--editor-channel portal-excalidraw--channel))
  (cl-pushnew (current-buffer) portal-excalidraw--buffers)
  (add-hook 'window-state-change-functions #'portal-excalidraw--sync)
  (add-hook 'window-selection-change-functions #'portal-excalidraw--sync)
  (add-hook 'delete-frame-functions #'portal-excalidraw--frame-deleted)
  (add-hook 'kill-emacs-hook #'portal-excalidraw--close-all)
  (portal-start-server)
  (when (portal-server-url) (portal-excalidraw--open)))

(defun portal-excalidraw--open ()
  "Create the current buffer's editor once the host is ready."
  (unless portal-excalidraw--id
    (setq portal-excalidraw--id
          (portal-native--call-with-frame
           (selected-frame) #'portal--editor-open
           (concat (portal-server-url) "/excalidraw/")))
    (portal-excalidraw--sync (selected-frame))))

(defun portal-excalidraw--host-ready ()
  "Open documents waiting for the local host; preserve existing live editors."
  (dolist (buffer portal-excalidraw--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (portal-excalidraw--open)))))
(add-hook 'portal-server-ready-hook #'portal-excalidraw--host-ready)

(defun portal-excalidraw--sync (_frame)
  "Move each document's one editor to its selected pane, or hide it."
  (dolist (buffer portal-excalidraw--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when portal-excalidraw--id
          (let* ((windows (get-buffer-window-list buffer nil t))
                 (window (or (and (memq (selected-window) windows) (selected-window))
                             (and (memq portal-excalidraw--window windows) portal-excalidraw--window)
                             (car windows)))
                 (frame (if window (window-frame window) (selected-frame)))
                 (edges (if window (vconcat (window-inside-pixel-edges window)) []))
                 (geometry (list frame (frame-pixel-height frame) edges)))
            (unless (equal geometry portal-excalidraw--geometry)
              (portal-native--call-with-frame frame #'portal--editor-layout portal-excalidraw--id edges)
              (setq portal-excalidraw--geometry geometry))
            (setq portal-excalidraw--window window)))))))

(defun portal-excalidraw--frame-deleted (frame)
  "Hide editors attached to FRAME while preserving their document buffers."
  (dolist (buffer portal-excalidraw--buffers)
    (with-current-buffer buffer
      (when (and portal-excalidraw--id (window-live-p portal-excalidraw--window)
                 (eq (window-frame portal-excalidraw--window) frame))
        (portal-native--call-with-frame frame #'portal--editor-layout portal-excalidraw--id [])
        (setq portal-excalidraw--geometry nil portal-excalidraw--window nil)))))

(defun portal-excalidraw--send (message)
  "Send MESSAGE to the current document's editor."
  (portal--editor-send portal-excalidraw--id (json-serialize message)))

(defun portal-excalidraw--receive (_process text)
  "Drain native editor notifications, deferring commands to Emacs's input loop."
  (setq portal-excalidraw--notification
        (portal-view--consume-lines portal-excalidraw--notification text
                                    #'portal-excalidraw--receive-line)))

(defun portal-excalidraw--receive-line (line)
  "Process the pending messages for the session identified by LINE."
  (when (string-match-p "\\`[0-9]+\\'" line)
    (let* ((id (string-to-number line))
           (buffer (cl-find-if (lambda (buffer)
                                 (and (buffer-live-p buffer)
                                      (eql id (buffer-local-value 'portal-excalidraw--id buffer))))
                               portal-excalidraw--buffers)))
      (when buffer
        (with-current-buffer buffer
          (condition-case err
              (mapc #'portal-excalidraw--message
                    (json-parse-string (portal--editor-events id) :object-type 'plist))
            (error (setq portal-excalidraw--error (error-message-string err))
                   (message "Drawing: %s" portal-excalidraw--error))))))))

(defun portal-excalidraw--scene (json &optional initial)
  "Replace the buffer with validated JSON; INITIAL establishes its baseline."
  (portal-excalidraw--validate json)
  (let* ((text (concat (string-trim-right json) "\n"))
         (modified (buffer-modified-p))
         (inhibit-read-only t))
    (unless (equal text (buffer-string))
      (erase-buffer)
      (insert text))
    (when (and initial (not modified)) (setq portal-excalidraw--saved text))
    (set-buffer-modified-p (not (equal text portal-excalidraw--saved)))))

(defun portal-excalidraw--message (message)
  "Handle one MESSAGE for the current buffer.  Never prompt in this function."
  (pcase (plist-get message :type)
    ("ready"
     (portal-excalidraw--send (list :type "load" :json (buffer-string)
                                  :name (file-name-base (or buffer-file-name (buffer-name))))))
    ("loaded"
     (portal-excalidraw--scene (plist-get message :json) t)
     (setq portal-excalidraw--ready t portal-excalidraw--error nil))
    ("dirty" (set-buffer-modified-p t))
    ("change" (portal-excalidraw--scene (plist-get message :json)))
    ("snapshot"
     (when (eql (plist-get message :request) portal-excalidraw--request)
       (portal-excalidraw--scene (plist-get message :json))
       (setq portal-excalidraw--reply portal-excalidraw--request)))
    ("error"
     (setq portal-excalidraw--error (plist-get message :message))
     (message "Drawing: %s" portal-excalidraw--error))
    ("save"
     (setq unread-command-events
           (nconc unread-command-events
                  (list (list 'portal-excalidraw-command
                              (list (current-buffer) (plist-get message :type)))))))))

(defun portal-excalidraw--dispatch (event)
  "Run an editor command EVENT in the correct document buffer."
  (interactive "e")
  (pcase-let ((`(,buffer ,kind) (cadr event)))
    (when (buffer-live-p buffer)
      (pop-to-buffer buffer)
      (when (equal kind "save")
        (portal-excalidraw-save)
        (when (eq (current-buffer) buffer) (portal-excalidraw-focus))))))
(define-key global-map [portal-excalidraw-command] #'portal-excalidraw--dispatch)

(defun portal-excalidraw--wait (predicate)
  "Service native events until PREDICATE succeeds, or report a bounded failure."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (not portal-excalidraw--error)
                (< (float-time) deadline))
      (accept-process-output nil 0.01)
      (redisplay t))
    (when portal-excalidraw--error (user-error "%s" portal-excalidraw--error))
    (unless (funcall predicate) (user-error "Timed out waiting for the drawing editor"))))

(defun portal-excalidraw--flush ()
  "Synchronize the current scene before Emacs saves, reverts, or closes it."
  (unless portal-excalidraw--flushing
    (let ((portal-excalidraw--flushing t))
      (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
      (cl-incf portal-excalidraw--request)
      (setq portal-excalidraw--reply nil)
      (portal-excalidraw--send (list :type "snapshot" :request portal-excalidraw--request))
      (portal-excalidraw--wait (lambda () (eql portal-excalidraw--reply portal-excalidraw--request))))))

;;;###autoload
(defun portal-excalidraw-save (&optional arg)
  "Save the latest scene through Emacs; ARG is passed to `save-buffer'."
  (interactive "p")
  (condition-case err
      (progn
        (portal-excalidraw--flush)
        (when (or (not buffer-file-name) (not (file-exists-p buffer-file-name)))
          (set-buffer-modified-p t))
        (let ((portal-excalidraw--flushing t)) (save-buffer arg)))
    (error
     (when portal-excalidraw--id
       (portal-excalidraw--send (list :type "error" :message (error-message-string err))))
     (signal (car err) (cdr err)))))

(defun portal-excalidraw--did-save ()
  "Acknowledge only a successful Emacs file write."
  (setq portal-excalidraw--saved (buffer-string))
  (when portal-excalidraw--ready
    (portal-excalidraw--send (list :type "saved" :json portal-excalidraw--saved))))

(defun portal-excalidraw--prepare-write ()
  "Require a fresh scene, then let Emacs perform its normal file write."
  (portal-excalidraw--flush)
  nil)

(defun portal-excalidraw--query-kill ()
  "Flush edits still in flight before the buffer is killed."
  (let ((modified (buffer-modified-p)))
    (when (and portal-excalidraw--ready (not portal-excalidraw--error))
      (portal-excalidraw--flush))
    (or (not (buffer-modified-p)) (and buffer-file-name modified)
        (yes-or-no-p "Drawing has new unsaved changes; discard them? "))))

(defun portal-excalidraw--leave-mode ()
  "Synchronize before switching to a text mode, then release the editor."
  (when (and portal-excalidraw--ready (not portal-excalidraw--error))
    (portal-excalidraw--flush))
  (portal-excalidraw--close))

(defun portal-excalidraw--close ()
  "Release this document's native view; other documents remain alive."
  (when portal-excalidraw--id (portal--editor-close portal-excalidraw--id))
  (setq portal-excalidraw--id nil portal-excalidraw--ready nil portal-excalidraw--geometry nil)
  (setq portal-excalidraw--buffers (delq (current-buffer) portal-excalidraw--buffers))
  (unless portal-excalidraw--buffers
    (remove-hook 'window-state-change-functions #'portal-excalidraw--sync)
    (remove-hook 'window-selection-change-functions #'portal-excalidraw--sync)
    (remove-hook 'delete-frame-functions #'portal-excalidraw--frame-deleted)
    (remove-hook 'kill-emacs-hook #'portal-excalidraw--close-all)
    (when (processp portal-excalidraw--channel)
      (portal--editor-channel nil)
      (delete-process portal-excalidraw--channel)
      (setq portal-excalidraw--channel nil))))

(defun portal-excalidraw--close-all ()
  "Release native editor resources on Emacs exit."
  (dolist (buffer (copy-sequence portal-excalidraw--buffers))
    (when (buffer-live-p buffer) (with-current-buffer buffer (portal-excalidraw--close)))))

(defun portal-excalidraw-focus ()
  "Focus this drawing's editor."
  (interactive)
  (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
  (redisplay t)
  (portal-excalidraw--sync (selected-frame))
  (portal--editor-focus portal-excalidraw--id))

(defun portal-excalidraw-reopen ()
  "Recreate the editor from buffered data, resetting its undo history.
Use after a host restart or a WebKit crash.
Unsaved buffered edits are retained."
  (interactive)
  (when (and portal-excalidraw--ready (not portal-excalidraw--error))
    (portal-excalidraw--flush))
  (portal-excalidraw--close)
  (setq portal-excalidraw--error nil)
  (portal-excalidraw--start))

(defun portal-excalidraw--revert (_ignore-auto noconfirm)
  "Reload the saved drawing, asking before discarding edits unless NOCONFIRM."
  (unless buffer-file-name (user-error "This drawing has no file yet"))
  (when (or noconfirm (yes-or-no-p "Replace this drawing with the file on disk? "))
    (let ((text (with-temp-buffer (insert-file-contents buffer-file-name) (buffer-string))))
      (portal-excalidraw--validate text)
      (portal-excalidraw--close)
      (let ((inhibit-read-only t)) (erase-buffer) (insert text))
      (set-visited-file-modtime)
      (set-buffer-modified-p nil)
      (setq portal-excalidraw--saved text portal-excalidraw--error nil)
      (portal-excalidraw--start))))

(provide 'portal-excalidraw)
;;; portal-excalidraw.el ends here
