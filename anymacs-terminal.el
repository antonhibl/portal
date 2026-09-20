;;; anymacs-terminal.el --- Native Ghostty terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'windmove)

(defgroup anymacs-terminal nil
  "Native Ghostty terminals in Emacs panes."
  :group 'terminals)

(require 'anymacs-native
         (expand-file-name "anymacs-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(declare-function anymacs--terminal-open "anymacs-terminal" (title directory))
(declare-function anymacs--terminal-layout "anymacs-terminal" (edges &optional id))
(declare-function anymacs--terminal-focus "anymacs-terminal" (&optional id))
(declare-function anymacs--terminal-unfocus "anymacs-terminal" (&optional id))
(declare-function anymacs--terminal-close "anymacs-terminal" (&optional id))
(declare-function anymacs--terminal-input "anymacs-terminal" (text enter &optional id))
(declare-function anymacs--terminal-state "anymacs-terminal" (&optional id))
(declare-function anymacs--terminal-prefix "anymacs-terminal" (character flags))
(declare-function anymacs--terminal-channel "anymacs-terminal" (process))
(declare-function anymacs--terminal-ack "anymacs-terminal" (id replay))
(declare-function anymacs--terminal-send-prefix "anymacs-terminal" (id))

(defvar anymacs-terminal--buffers nil "Terminal buffers in creation order.")
(defvar anymacs-terminal--channel nil)
(defvar anymacs-terminal--notification "")
(defvar anymacs-terminal--resume nil
  "Dynamically bound by prefix dispatch; commands may clear it to stay in Emacs.")
(defvar-local anymacs-terminal--id nil)
(defvar-local anymacs-terminal--frame nil)
(defvar-local anymacs-terminal--window nil)
(defvar-local anymacs-terminal--geometry nil)
(defvar-local anymacs-terminal--last-buffer nil)

(defun anymacs-terminal--prefix-description (value)
  "Validate VALUE and return its native character and modifier mask."
  (let* ((keys (kbd value))
         (event (and (= (length keys) 1) (aref keys 0)))
         (basic (and event (event-basic-type event)))
         (mods (and event (event-modifiers event))))
    (unless (and (integerp basic) (<= 32 basic 126) mods
                 (cl-every (lambda (mod) (memq mod '(control meta super shift))) mods))
      (error "Terminal prefix must be one modified ASCII key, e.g. C-b, C-a or s-e"))
    (list (downcase (char-to-string basic))
          (cl-loop for (mod . bit) in '((shift . 17) (control . 18) (meta . 19) (super . 20))
                   when (memq mod mods) sum (ash 1 bit)))))

(defun anymacs-terminal--prefix-changed (_symbol value operation _where)
  "Apply a prefix VALUE to running native terminals on OPERATION."
  (when (eq operation 'set)
    (let ((description (anymacs-terminal--prefix-description value)))
      (when (fboundp 'anymacs--terminal-prefix)
        (apply #'anymacs--terminal-prefix description)))))

(defcustom anymacs-terminal-prefix "C-b"
  "Native terminal leader, in `kbd' notation.
Use one modified ASCII key.  C-b follows tmux; C-a is another common choice.
Meta means the native Option key, Super means Command.  Changes apply live.
Press the prefix twice to send the actual prefix keystroke to the terminal."
  :type 'string
  :group 'anymacs-terminal)
(add-variable-watcher 'anymacs-terminal-prefix #'anymacs-terminal--prefix-changed)

(defcustom anymacs-terminal-prefix-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("c" . anymacs-terminal-new)
                       ("\"" . anymacs-terminal-split-below)
                       ("%" . anymacs-terminal-split-right)
                       ("o" . anymacs-terminal-next-pane)
                       ("<up>" . windmove-up) ("<down>" . windmove-down)
                       ("<left>" . windmove-left) ("<right>" . windmove-right)
                       ("n" . anymacs-terminal-next)
                       ("p" . anymacs-terminal-previous)
                       ("l" . anymacs-terminal-last)
                       ("w" . anymacs-terminal-choose)
                       ("," . anymacs-terminal-rename)
                       ("x" . anymacs-terminal-kill-pane)
                       ("z" . anymacs-terminal-zoom)
                       ("d" . anymacs-terminal-unfocus)
                       (":" . anymacs-terminal-command-prompt)
                       ("?" . anymacs-terminal-help)))
      (keymap-set map (car binding) (cdr binding)))
    (dotimes (index 10)
      (define-key map (number-to-string index) #'anymacs-terminal-select-index))
    map)
  "Commands read by Emacs after `anymacs-terminal-prefix'.
Defaults follow tmux where there is an Emacs counterpart: terminal buffers
are windows, Emacs windows are panes.  This is not a tmux session manager.
Use `keymap-set' to add commands, including ordinary Emacs commands and
nested prefix maps.  Commands resume a selected terminal after returning;
call `anymacs-terminal-unfocus' to stay in Emacs instead.
C-g cancels.  The current leader repeated sends a literal leader key."
  :type 'keymap
  :group 'anymacs-terminal)

(define-derived-mode anymacs-terminal-mode special-mode "Ghostty"
  "A real native Ghostty surface occupies this buffer's displayed pane.
RET focuses Ghostty.  The configurable leader dispatches Emacs commands.
Command-Escape always returns focus to Emacs.  Scrollback belongs to Ghostty."
  (setq-local cursor-type nil)
  ;; Outside the native view, so the escape hatch never depends on its keymap.
  (setq-local header-line-format
              (list " " (propertize " Return to Emacs "
                                    'face 'mode-line-highlight
                                    'mouse-face 'highlight
                                    'help-echo "Return keyboard focus to Emacs; keep the shell running"
                                    'local-map
                                    (let ((map (make-sparse-keymap)))
                                      (define-key map [header-line mouse-1]
                                                  #'anymacs-terminal-unfocus)
                                      map))
                    '(:eval (format "  %s prefix · Command-Escape · RET to enter"
                                    anymacs-terminal-prefix)))))
(keymap-set anymacs-terminal-mode-map "RET" #'anymacs-terminal-focus)
(keymap-set anymacs-terminal-mode-map "C-c C-k" #'anymacs-terminal-close)

(defun anymacs-terminal--frame-buffers (&optional frame)
  "Return live terminal buffers owned by FRAME, defaulting to this frame."
  (let ((frame (or frame (selected-frame))))
    (cl-remove-if-not
     (lambda (buffer)
       (and (buffer-live-p buffer)
            (buffer-local-value 'anymacs-terminal--id buffer)
            (eq (buffer-local-value 'anymacs-terminal--frame buffer) frame)))
     anymacs-terminal--buffers)))

(defun anymacs-terminal--sync (frame)
  "Place each terminal in its chosen pane of FRAME, or hide it."
  (dolist (buffer (anymacs-terminal--frame-buffers frame))
    (with-current-buffer buffer
      (let* ((windows (get-buffer-window-list buffer nil frame))
             (window (or (and (memq (frame-selected-window frame) windows)
                              (frame-selected-window frame))
                         (and (memq anymacs-terminal--window windows)
                              anymacs-terminal--window)
                         (car windows)))
             (edges (if window (vconcat (window-inside-pixel-edges window)) []))
             (geometry (cons (frame-pixel-height frame) edges)))
        (unless (equal geometry anymacs-terminal--geometry)
          (anymacs--terminal-layout edges anymacs-terminal--id)
          (setq anymacs-terminal--geometry geometry))
        (setq anymacs-terminal--window window)))))

(defun anymacs-terminal--frame-deleted (frame)
  "End every terminal owned by deleted FRAME."
  (dolist (buffer (anymacs-terminal--frame-buffers frame))
    (with-current-buffer buffer (anymacs-terminal-close))))

(defun anymacs-terminal--receive (_process text)
  "Queue native prefix notifications from TEXT for the Emacs command loop.
The process filter never runs interactive commands or reads keyboard input."
  (setq anymacs-terminal--notification (concat anymacs-terminal--notification text))
  (while (string-match "\\`\\(cancel \\|escape \\|literal \\)?\\([0-9]+\\)\n" anymacs-terminal--notification)
    (let ((kind (match-string 1 anymacs-terminal--notification))
          (id (string-to-number (match-string 2 anymacs-terminal--notification))))
      (setq anymacs-terminal--notification
            (substring anymacs-terminal--notification (match-end 0)))
      (setq unread-command-events
            (nconc unread-command-events
                   (list (list (cond ((equal kind "cancel ") 'anymacs-terminal-cancel)
                                     ((equal kind "escape ") 'anymacs-terminal-escape)
                                     ((equal kind "literal ") 'anymacs-terminal-literal)
                                     (t 'anymacs-terminal-prefix))
                               (list id))))))))

(defun anymacs-terminal--connect ()
  "Load the native module and establish its event channel."
  (anymacs-native--load)
  (unless (process-live-p anymacs-terminal--channel)
    (setq anymacs-terminal--notification ""
          anymacs-terminal--channel
          (make-pipe-process :name "anymacs-terminal-events" :noquery t
                             :coding 'utf-8-unix :filter #'anymacs-terminal--receive))
    (anymacs--terminal-channel anymacs-terminal--channel))
  (apply #'anymacs--terminal-prefix
         (anymacs-terminal--prefix-description anymacs-terminal-prefix)))

;;;###autoload
(defun anymacs-terminal (&optional new)
  "Open or return to a native Ghostty terminal in the current frame.
With prefix argument NEW, always start a new shell.  Hidden shells persist."
  (interactive "P")
  (let ((buffer (car (anymacs-terminal--frame-buffers))))
    (if (and buffer (not new))
        (progn (switch-to-buffer buffer) (anymacs-terminal-focus))
      (anymacs-terminal-new))))

;;;###autoload
(defun anymacs-terminal-new ()
  "Create an independent native terminal in the selected Emacs pane."
  (interactive)
  (when (file-remote-p default-directory)
    (user-error "Start in a local directory; run ssh inside the terminal for remote shells"))
  (anymacs-terminal--connect)
  (let ((directory (expand-file-name default-directory))
        (frame (selected-frame))
        (previous (current-buffer))
        (buffer (generate-new-buffer "*anymacs-terminal*"))
        ready)
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (anymacs-terminal-mode)
          (setq default-directory directory
                anymacs-terminal--frame frame
                anymacs-terminal--last-buffer previous)
          (let ((inhibit-read-only t))
            (insert "Native Ghostty terminal\n\n"
                    "RET or a click focuses Ghostty. Command-Escape returns to Emacs.\n"
                    "Use the configured prefix then ? for terminal commands.\n"
                    "This buffer has one live view, which follows its selected pane.\n"))
          (redisplay t)
          (setq anymacs-terminal--id
                (anymacs-native--call-with-frame frame #'anymacs--terminal-open directory))
          (setq anymacs-terminal--buffers (append anymacs-terminal--buffers (list buffer)))
          (add-hook 'window-state-change-functions #'anymacs-terminal--sync)
          (add-hook 'window-selection-change-functions #'anymacs-terminal--sync)
          (add-hook 'delete-frame-functions #'anymacs-terminal--frame-deleted)
          (add-hook 'kill-emacs-hook #'anymacs-terminal-close-all)
          (add-hook 'kill-buffer-hook #'anymacs-terminal-close nil t)
          (add-hook 'change-major-mode-hook #'anymacs-terminal-close nil t)
          (anymacs-terminal-focus)
          (setq ready t))
      (unless ready
        (with-current-buffer buffer (anymacs-terminal-close))
        (kill-buffer buffer)))))

;;;###autoload
(defun anymacs-terminal-focus ()
  "Give this buffer's native terminal keyboard focus."
  (interactive)
  (unless anymacs-terminal--id (user-error "No terminal in this buffer"))
  (unless (eq (selected-frame) anymacs-terminal--frame)
    (user-error "This terminal belongs to another frame"))
  (redisplay t)
  (anymacs-terminal--sync anymacs-terminal--frame)
  (anymacs--terminal-focus anymacs-terminal--id))

(defun anymacs-terminal-unfocus ()
  "Stay in Emacs, keeping every terminal session alive.  RET re-enters."
  (interactive)
  (setq anymacs-terminal--resume nil)
  (dolist (buffer (anymacs-terminal--frame-buffers))
    (let ((id (buffer-local-value 'anymacs-terminal--id buffer)))
      (anymacs--terminal-ack id nil)
      (anymacs--terminal-unfocus id)))
  (message "Emacs has keyboard focus; RET in a terminal buffer re-enters Ghostty."))

;;;###autoload
(defun anymacs-terminal-close ()
  "End this buffer's native shell.  Other terminal sessions keep running."
  (interactive)
  (when anymacs-terminal--id
    (anymacs--terminal-close anymacs-terminal--id)
    (setq anymacs-terminal--buffers (delq (current-buffer) anymacs-terminal--buffers))
    (remove-hook 'kill-buffer-hook #'anymacs-terminal-close t)
    (remove-hook 'change-major-mode-hook #'anymacs-terminal-close t)
    (setq anymacs-terminal--id nil anymacs-terminal--geometry nil
          anymacs-terminal--window nil anymacs-terminal--frame nil))
  (unless anymacs-terminal--buffers
    (remove-hook 'window-state-change-functions #'anymacs-terminal--sync)
    (remove-hook 'window-selection-change-functions #'anymacs-terminal--sync)
    (remove-hook 'delete-frame-functions #'anymacs-terminal--frame-deleted)
    (remove-hook 'kill-emacs-hook #'anymacs-terminal-close-all)
    (when (processp anymacs-terminal--channel)
      (anymacs--terminal-channel nil)
      (delete-process anymacs-terminal--channel)
      (setq anymacs-terminal--channel nil))))

(defun anymacs-terminal-close-all ()
  "End all native shells, for Emacs shutdown or explicit cleanup."
  (interactive)
  (dolist (buffer (copy-sequence anymacs-terminal--buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (anymacs-terminal-close)))))

(defun anymacs-terminal--dispatch (event)
  "Read and execute the Lisp prefix command requested by native EVENT."
  (interactive "e")
  (let* ((id (caadr event))
         (buffer (cl-find id anymacs-terminal--buffers
                          :key (lambda (buffer) (buffer-local-value 'anymacs-terminal--id buffer))))
         (anymacs-terminal--resume t))
    (unwind-protect
        (when (and (buffer-live-p buffer)
                   (window-live-p (buffer-local-value 'anymacs-terminal--window buffer)))
          (select-window (buffer-local-value 'anymacs-terminal--window buffer))
          (anymacs--terminal-unfocus id)
          (condition-case err
              (let* ((map (copy-keymap anymacs-terminal-prefix-map))
                     (keys (let ((inhibit-quit nil)
                                 (overriding-terminal-local-map map)
                                 (overriding-local-map nil))
                             (define-key map [t] #'undefined)
                             (define-key map (kbd anymacs-terminal-prefix)
                                         #'anymacs-terminal-send-prefix)
                             (define-key map (kbd "C-g") #'keyboard-quit)
                             (define-key map [anymacs-terminal-cancel] #'keyboard-quit)
                             (define-key map [anymacs-terminal-literal] #'anymacs-terminal-send-prefix)
                             (define-key map [anymacs-terminal-escape] #'anymacs-terminal-unfocus)
                             (define-key map [header-line mouse-1] #'anymacs-terminal-unfocus)
                             (when (anymacs--terminal-ack id t)
                               (read-key-sequence-vector
                                (format "Ghostty %s (?: help, C-g: cancel): " anymacs-terminal-prefix)))))
                     (command (and keys (lookup-key map keys))))
                (anymacs--terminal-ack id nil)
                (cond
                 ((not keys) (setq anymacs-terminal--resume nil))
                 ((and (commandp command) (not (eq command #'undefined)))
                    (let ((last-command-event (aref keys (1- (length keys))))
                          (this-command command)
                          (real-this-command command))
                      (command-execute command 'record)))
                 (t
                  (message "No terminal command for %s; %s ? shows bindings"
                           (key-description keys) anymacs-terminal-prefix))))
            (quit (message "Terminal prefix cancelled"))
            (error (setq anymacs-terminal--resume nil)
                   (message "Terminal command: %s" (error-message-string err)))))
      (anymacs--terminal-ack id nil)
      ;; Minibuffer commands finish before this point.  Selecting ordinary
      ;; buffers leaves Emacs in charge; errors also leave a recoverable editor.
      (when (and anymacs-terminal--resume anymacs-terminal--id
                 (not (active-minibuffer-window)))
        (anymacs-terminal-focus)))))
(define-key global-map [anymacs-terminal-prefix] #'anymacs-terminal--dispatch)

(defun anymacs-terminal-send-prefix ()
  "Send the captured native leader keystroke literally to this shell."
  (interactive)
  (anymacs--terminal-send-prefix anymacs-terminal--id))

(defun anymacs-terminal--switch (buffer)
  "Select terminal BUFFER and remember the previously selected terminal."
  (let ((previous (current-buffer)))
    (switch-to-buffer buffer)
    (unless (eq previous buffer) (setq anymacs-terminal--last-buffer previous))))

(defun anymacs-terminal-next (&optional previous)
  "Select the next terminal in creation order, or PREVIOUS when non-nil."
  (interactive)
  (let* ((buffers (anymacs-terminal--frame-buffers))
         (index (or (cl-position (current-buffer) buffers) 0)))
    (unless buffers (user-error "No terminal buffers"))
    (anymacs-terminal--switch (nth (mod (+ index (if previous -1 1)) (length buffers)) buffers))))
(defun anymacs-terminal-previous ()
  "Select the previous terminal buffer."
  (interactive) (anymacs-terminal-next t))
(defun anymacs-terminal-last ()
  "Select the last terminal used in this pane."
  (interactive)
  (unless (memq anymacs-terminal--last-buffer (anymacs-terminal--frame-buffers))
    (user-error "No previous terminal"))
  (anymacs-terminal--switch anymacs-terminal--last-buffer))
(defun anymacs-terminal-select-index ()
  "Select terminal 0 through 9 in creation order."
  (interactive)
  (let ((buffer (nth (- last-command-event ?0) (anymacs-terminal--frame-buffers))))
    (unless buffer (user-error "No terminal at that index"))
    (anymacs-terminal--switch buffer)))
(defun anymacs-terminal-choose ()
  "Choose a terminal in this frame with Emacs completion."
  (interactive)
  (anymacs-terminal--switch
   (get-buffer (completing-read "Terminal: " (mapcar #'buffer-name (anymacs-terminal--frame-buffers)) nil t))))
(defun anymacs-terminal-rename (name)
  "Rename the current terminal buffer to NAME."
  (interactive (list (read-string "Terminal name: " (buffer-name))))
  (rename-buffer name t))
(defun anymacs-terminal-next-pane ()
  "Select the next Emacs pane, as tmux prefix o does."
  (interactive) (other-window 1))
(defun anymacs-terminal--split (side)
  "Split toward SIDE and start a new independent shell there."
  (let ((configuration (current-window-configuration)))
    (condition-case err
        (progn (select-window (split-window nil nil side)) (anymacs-terminal-new))
      (error (set-window-configuration configuration) (signal (car err) (cdr err))))))
(defun anymacs-terminal-split-below ()
  "Split the pane top/bottom and start a shell in the bottom pane."
  (interactive) (anymacs-terminal--split 'below))
(defun anymacs-terminal-split-right ()
  "Split the pane left/right and start a shell in the right pane."
  (interactive) (anymacs-terminal--split 'right))
(defun anymacs-terminal-kill-pane ()
  "Confirm, end this shell and remove its Emacs pane when possible."
  (interactive)
  (when (y-or-n-p (format "Kill terminal %s and its running shell? " (buffer-name)))
    (let ((window (selected-window)))
      (kill-buffer (current-buffer))
      (unless (one-window-p t) (delete-window window)))))
(defun anymacs-terminal-zoom ()
  "Toggle the selected pane between its layout and a full-frame view."
  (interactive)
  (let ((configuration (frame-parameter nil 'anymacs-terminal-zoom)))
    (if configuration
        (progn (set-frame-parameter nil 'anymacs-terminal-zoom nil)
               (set-window-configuration configuration))
      (set-frame-parameter nil 'anymacs-terminal-zoom (current-window-configuration))
      (delete-other-windows))))
(defun anymacs-terminal-command-prompt ()
  "Run M-x and stay in Emacs afterward."
  (interactive)
  (anymacs-terminal-unfocus)
  (call-interactively #'execute-extended-command))
(defun anymacs-terminal-help ()
  "Show the current prefix map, including user customizations."
  (interactive)
  (anymacs-terminal-unfocus)
  (with-help-window "*Ghostty bindings*"
    (princ (format "Ghostty prefix: %s\n\n" anymacs-terminal-prefix))
    (princ "Repeat the prefix to send it literally. C-g cancels a pending prefix.\n")
    (princ "Command-Escape or the header button returns to Emacs. RET re-enters.\n\n")
    (princ (substitute-command-keys "\\{anymacs-terminal-prefix-map}"))))

(provide 'anymacs-terminal)
;;; anymacs-terminal.el ends here
