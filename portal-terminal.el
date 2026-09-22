;;; portal-terminal.el --- Native Ghostty terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'windmove)

(defgroup portal-terminal nil
  "Native Ghostty terminals in Emacs panes."
  :group 'terminals)

(require 'portal-native
         (expand-file-name "portal-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(declare-function portal--terminal-open "portal-terminal" (title directory &optional theme quick))
(declare-function portal--terminal-theme "portal-terminal" (theme))
(declare-function portal--terminal-themes "portal-terminal" ())
(declare-function portal--terminal-layout "portal-terminal" (edges &optional id))
(declare-function portal--terminal-focus "portal-terminal" (&optional id))
(declare-function portal--terminal-unfocus "portal-terminal" (&optional id))
(declare-function portal--terminal-close "portal-terminal" (&optional id))
(declare-function portal--terminal-input "portal-terminal" (text enter &optional id))
(declare-function portal--terminal-state "portal-terminal" (&optional id))
(declare-function portal--terminal-prefix "portal-terminal" (character flags))
(declare-function portal--terminal-channel "portal-terminal" (process))
(declare-function portal--terminal-ack "portal-terminal" (id replay))
(declare-function portal--terminal-send-prefix "portal-terminal" (id))

(defvar portal-terminal--buffers nil "Terminal buffers in creation order.")
(defvar portal-terminal--channel nil)
(defvar portal-terminal--notification "")
(defvar portal-terminal--resume nil
  "Dynamically bound by prefix dispatch; commands may clear it to stay in Emacs.")
(defvar-local portal-terminal--id nil)
(defvar-local portal-terminal--frame nil)
(defvar-local portal-terminal--window nil)
(defvar-local portal-terminal--geometry nil)
(defvar-local portal-terminal--last-buffer nil)
(defvar-local portal-terminal--quick-root nil)
(defvar portal-terminal-quick-prefix-map)
(defvar portal-terminal--native-maps)
(declare-function portal-terminal-refresh-bindings "portal-terminal-bindings" ())
(declare-function portal-terminal--validate-native-prefix "portal-terminal-bindings" (description))
(declare-function portal-terminal-quick--display "portal-terminal-quick" (buffer))
(declare-function portal-terminal-quick--window "portal-terminal-quick" ())
(declare-function portal-terminal-quick-dismiss "portal-terminal-quick" ())

(defun portal-terminal--theme-changed (_symbol value operation _where)
  "Validate and apply theme VALUE to running terminals on OPERATION."
  (when (eq operation 'set)
    (unless (or (null value) (stringp value))
      (error "Terminal theme must be a theme name or nil"))
    (when (fboundp 'portal--terminal-theme)
      (portal--terminal-theme value))))

(defcustom portal-terminal-theme nil
  "Color theme for all Portal terminals.
Use an exact, case-sensitive name from `portal-terminal-themes', such as
\"Dracula\".  Nil follows native system appearance, using Alabaster in light
mode and Afterglow in dark mode.  Named themes stay fixed in both modes.
Changes with `setq' or Customize apply to running and future terminals
without restarting their shells.  May be set before loading Portal;
the name is validated when the native module is available."
  :type '(choice (const :tag "System appearance" nil) string)
  :group 'portal-terminal)
(add-variable-watcher 'portal-terminal-theme #'portal-terminal--theme-changed)

(defun portal-terminal-themes ()
  "Return the available terminal theme names from the bundled catalog."
  (portal-native--load)
  (portal--terminal-themes))

(defun portal-terminal--prefix-description (value)
  "Validate VALUE and return its native character and modifier mask."
  (let* ((keys (kbd value))
         (event (and (= (length keys) 1) (aref keys 0)))
         (basic (and event (event-basic-type event)))
         (mods (and event (event-modifiers event))))
    (unless (and (integerp basic) (<= 32 basic 126) mods
                 (cl-every (lambda (mod) (memq mod '(control meta super shift))) mods))
      (error "Terminal prefix must be one modified ASCII key, e.g. C-b, C-a or s-e"))
    (when (and (memq 'shift mods) (/= basic 32) (not (<= ?a basic ?z)))
      (error "Use the resulting punctuation, e.g. s-! instead of s-S-1"))
    (list (downcase (char-to-string basic))
          (cl-loop for (mod . bit) in '((shift . 17) (control . 18) (meta . 19) (super . 20))
                   when (memq mod mods) sum (ash 1 bit)))))

(defun portal-terminal--prefix-changed (_symbol value operation _where)
  "Apply a prefix VALUE to running native terminals on OPERATION."
  (when (eq operation 'set)
    (let ((description (portal-terminal--prefix-description value)))
      (when (fboundp 'portal-terminal--validate-native-prefix)
        (portal-terminal--validate-native-prefix description))
      (when (fboundp 'portal--terminal-prefix)
        (apply #'portal--terminal-prefix description)))))

(defcustom portal-terminal-prefix "C-b"
  "Native terminal leader, in `kbd' notation.
Use one modified ASCII key.  C-b follows tmux; C-a is another common choice.
Meta means the native Option key, Super means Command.  Changes apply live.
Press the prefix twice to send the actual prefix keystroke to the terminal."
  :type 'string
  :group 'portal-terminal)
(add-variable-watcher 'portal-terminal-prefix #'portal-terminal--prefix-changed)

(defcustom portal-terminal-prefix-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("c" . portal-terminal-new)
                       ("\"" . portal-terminal-split-below)
                       ("%" . portal-terminal-split-right)
                       ("o" . portal-terminal-next-pane)
                       ("<up>" . windmove-up) ("<down>" . windmove-down)
                       ("<left>" . windmove-left) ("<right>" . windmove-right)
                       ("n" . portal-terminal-next)
                       ("p" . portal-terminal-previous)
                       ("l" . portal-terminal-last)
                       ("w" . portal-terminal-choose)
                       ("," . portal-terminal-rename)
                       ("x" . portal-terminal-kill-pane)
                       ("z" . portal-terminal-zoom)
                       ("d" . portal-terminal-unfocus)
                       (":" . portal-terminal-command-prompt)
                       ("?" . portal-terminal-help)))
      (keymap-set map (car binding) (cdr binding)))
    (dotimes (index 10)
      (define-key map (number-to-string index) #'portal-terminal-select-index))
    map)
  "Commands read by Emacs after `portal-terminal-prefix'.
Defaults follow tmux where there is an Emacs counterpart: terminal buffers
are windows, Emacs windows are panes.  This is not a tmux session manager.
Use `keymap-set' to add commands, including ordinary Emacs commands and
nested prefix maps.  Commands resume a selected terminal after returning;
call `portal-terminal-unfocus' to stay in Emacs instead.
C-g cancels.  The current leader repeated sends a literal leader key."
  :type 'keymap
  :group 'portal-terminal)

(define-derived-mode portal-terminal-mode special-mode "Ghostty"
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
                                                  #'portal-terminal-unfocus)
                                      map))
                    '(:eval (format "  %s prefix · Command-Escape · RET to enter"
                                    portal-terminal-prefix)))))
(keymap-set portal-terminal-mode-map "RET" #'portal-terminal-focus)
(keymap-set portal-terminal-mode-map "C-c C-k" #'portal-terminal-close)

(defun portal-terminal--frame-buffers (&optional frame)
  "Return live terminal buffers owned by FRAME, defaulting to this frame."
  (let ((frame (or frame (selected-frame))))
    (cl-remove-if-not
     (lambda (buffer)
       (and (buffer-live-p buffer)
            (buffer-local-value 'portal-terminal--id buffer)
            (eq (buffer-local-value 'portal-terminal--frame buffer) frame)))
     portal-terminal--buffers)))

(defun portal-terminal--regular-buffers ()
  "Return this frame's ordinary terminals, excluding quick shells."
  (cl-remove-if (lambda (buffer)
                  (buffer-local-value 'portal-terminal--quick-root buffer))
                (portal-terminal--frame-buffers)))

(defun portal-terminal--sync (frame)
  "Place each terminal in its chosen pane of FRAME, or hide it."
  (dolist (buffer (portal-terminal--frame-buffers frame))
    (with-current-buffer buffer
      (let* ((windows (get-buffer-window-list buffer nil frame))
             (window (or (and (memq (frame-selected-window frame) windows)
                              (frame-selected-window frame))
                         (and (memq portal-terminal--window windows)
                              portal-terminal--window)
                         (car windows)))
             (edges (if window (vconcat (window-inside-pixel-edges window)) []))
             (geometry (cons (frame-pixel-height frame) edges)))
        (unless (equal geometry portal-terminal--geometry)
          (portal--terminal-layout edges portal-terminal--id)
          (setq portal-terminal--geometry geometry))
        (setq portal-terminal--window window)))))

(defun portal-terminal--frame-deleted (frame)
  "End every terminal owned by deleted FRAME."
  (dolist (buffer (portal-terminal--frame-buffers frame))
    (with-current-buffer buffer (portal-terminal-close))))

(defun portal-terminal--receive (_process text)
  "Queue native prefix notifications from TEXT for the Emacs command loop.
The process filter never runs interactive commands or reads keyboard input."
  (setq portal-terminal--notification
        (portal-native--consume-lines portal-terminal--notification text
                                      #'portal-terminal--receive-line)))

(defun portal-terminal--receive-line (line)
  "Queue one complete native terminal notification LINE."
  (when (string-match "\\`\\(cancel \\|escape \\|literal \\|binding \\)?\\([0-9]+\\)\\(?: \\([0-9]+\\)\\)?\\'" line)
    (let ((kind (match-string 1 line))
          (id (string-to-number (match-string 2 line)))
          (key (when (match-string 3 line)
                 (string-to-number (match-string 3 line)))))
      (setq unread-command-events
            (nconc unread-command-events
                   (list (list (cond ((equal kind "cancel ") 'portal-terminal-cancel)
                                     ((equal kind "escape ") 'portal-terminal-escape)
                                     ((equal kind "binding ") 'portal-terminal-binding)
                                     ((equal kind "literal ") 'portal-terminal-literal)
                                     (t 'portal-terminal-prefix))
                               (list id key))))))))

(defun portal-terminal--connect ()
  "Load the native module and establish its event channel."
  (portal-native--load)
  (unless (process-live-p portal-terminal--channel)
    (setq portal-terminal--notification ""
          portal-terminal--channel
          (make-pipe-process :name "portal-terminal-events" :noquery t
                             :coding 'utf-8-unix :filter #'portal-terminal--receive))
    (portal--terminal-channel portal-terminal--channel))
  (apply #'portal--terminal-prefix
         (portal-terminal--prefix-description portal-terminal-prefix))
  (portal-terminal-refresh-bindings))

;;;###autoload
(defun portal-terminal (&optional new)
  "Open or return to a native Ghostty terminal in the current frame.
With prefix argument NEW, always start a new shell.  Hidden shells persist."
  (interactive "P")
  (let ((buffer (car (portal-terminal--regular-buffers))))
    (if (and buffer (not new))
        (progn (portal-terminal--switch buffer) (portal-terminal-focus))
      (portal-terminal-new))))

;;;###autoload
(defun portal-terminal-new ()
  "Create an independent native terminal in the selected Emacs pane."
  (interactive)
  (when (window-parameter nil 'portal-terminal-quick)
    (user-error "Dismiss the quick terminal before opening an ordinary terminal"))
  (portal-terminal--new))

(defun portal-terminal--new (&optional quick-root)
  "Create a shell, optionally belonging to QUICK-ROOT's scratch terminal."
  (when (file-remote-p default-directory)
    (user-error "Start in a local directory; run ssh inside the terminal for remote shells"))
  (portal-terminal--connect)
  (let ((directory (expand-file-name default-directory))
        (frame (selected-frame))
        (previous (current-buffer))
        (buffer (generate-new-buffer
                 (if quick-root
                     (format "*portal-quick:%s*" (abbreviate-file-name quick-root))
                   "*portal-terminal*")))
        ready)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (portal-terminal-mode)
            (setq default-directory directory
                  portal-terminal--quick-root quick-root
                  portal-terminal--frame frame
                  portal-terminal--last-buffer previous))
          (if quick-root
              (portal-terminal-quick--display buffer)
            (switch-to-buffer buffer))
          (let ((inhibit-read-only t))
            (insert "Native Ghostty terminal\n\n"
                    "RET or a click focuses Ghostty. Command-Escape returns to Emacs.\n"
                    "Use the configured prefix then ? for terminal commands.\n"
                    "This buffer has one live view, which follows its selected pane.\n"))
          (redisplay t)
          (setq portal-terminal--id
                (portal-native--call-with-frame frame #'portal--terminal-open
                                               directory portal-terminal-theme (and quick-root t)))
          (setq portal-terminal--buffers (append portal-terminal--buffers (list buffer)))
          (add-hook 'window-state-change-functions #'portal-terminal--sync)
          (add-hook 'window-selection-change-functions #'portal-terminal--sync)
          (add-hook 'delete-frame-functions #'portal-terminal--frame-deleted)
          (add-hook 'kill-emacs-hook #'portal-terminal-close-all)
          (add-hook 'kill-buffer-hook #'portal-terminal-close nil t)
          (add-hook 'change-major-mode-hook #'portal-terminal-close nil t)
          (portal-terminal-focus)
          (setq ready t))
      (unless ready
        (with-current-buffer buffer (portal-terminal-close))
        (kill-buffer buffer)))
    buffer))

;;;###autoload
(defun portal-terminal-focus ()
  "Give this buffer's native terminal keyboard focus."
  (interactive)
  (unless portal-terminal--id (user-error "No terminal in this buffer"))
  (unless (eq (selected-frame) portal-terminal--frame)
    (user-error "This terminal belongs to another frame"))
  (redisplay t)
  (portal-terminal--sync portal-terminal--frame)
  (portal--terminal-focus portal-terminal--id))

(defun portal-terminal-unfocus ()
  "Stay in Emacs, keeping every terminal session alive.  RET re-enters."
  (interactive)
  (setq portal-terminal--resume nil)
  (dolist (buffer (portal-terminal--frame-buffers))
    (let ((id (buffer-local-value 'portal-terminal--id buffer)))
      (portal--terminal-ack id nil)
      (portal--terminal-unfocus id)))
  (message "Emacs has keyboard focus; RET in a terminal buffer re-enters Ghostty."))

;;;###autoload
(defun portal-terminal-close ()
  "End this buffer's native shell.  Other terminal sessions keep running."
  (interactive)
  (when portal-terminal--id
    (when (and portal-terminal--quick-root
               (eq portal-terminal--frame (selected-frame))
               (eq (get-buffer-window (current-buffer))
                   (portal-terminal-quick--window))
               (get-buffer-window (current-buffer)))
      (save-current-buffer (portal-terminal-quick-dismiss)))
    (portal--terminal-close portal-terminal--id)
    (setq portal-terminal--buffers (delq (current-buffer) portal-terminal--buffers))
    (remove-hook 'kill-buffer-hook #'portal-terminal-close t)
    (remove-hook 'change-major-mode-hook #'portal-terminal-close t)
    (setq portal-terminal--id nil portal-terminal--geometry nil
          portal-terminal--window nil portal-terminal--frame nil))
  (unless portal-terminal--buffers
    (remove-hook 'window-state-change-functions #'portal-terminal--sync)
    (remove-hook 'window-selection-change-functions #'portal-terminal--sync)
    (remove-hook 'delete-frame-functions #'portal-terminal--frame-deleted)
    (remove-hook 'kill-emacs-hook #'portal-terminal-close-all)
    (when (processp portal-terminal--channel)
      (portal--terminal-channel nil)
      (delete-process portal-terminal--channel)
      (setq portal-terminal--channel nil))))

(defun portal-terminal-close-all ()
  "End all native shells, for Emacs shutdown or explicit cleanup."
  (interactive)
  (dolist (buffer (copy-sequence portal-terminal--buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (portal-terminal-close)))))

(defun portal-terminal--read-prefix (binding trigger id)
  "Read a sequence in BINDING after native TRIGGER from session ID."
  (let* ((map (copy-keymap binding))
         (inhibit-quit nil)
         (overriding-terminal-local-map map)
         (overriding-local-map nil))
    (define-key map [t] #'undefined)
    (define-key map trigger #'portal-terminal-send-prefix)
    (define-key map (kbd "C-g") #'keyboard-quit)
    (define-key map [portal-terminal-cancel] #'keyboard-quit)
    (define-key map [portal-terminal-literal] #'portal-terminal-send-prefix)
    (define-key map [portal-terminal-escape] #'portal-terminal-unfocus)
    (define-key map [header-line mouse-1] #'portal-terminal-unfocus)
    (when (portal--terminal-ack id t)
      (let ((keys (read-key-sequence-vector
                   (format "Ghostty %s (C-g: cancel): " (key-description trigger)))))
        (cons keys (lookup-key map keys))))))

(defun portal-terminal--dispatch (event)
  "Execute a native binding or read a prefix requested by EVENT.
Runs in the Emacs command loop, never inside a native callback or pipe filter."
  (interactive "e")
  (let* ((id (caadr event))
         (key (and (eq (car event) 'portal-terminal-binding) (cadadr event)))
         (buffer (cl-find id portal-terminal--buffers
                          :key (lambda (buffer) (buffer-local-value 'portal-terminal--id buffer))))
         (portal-terminal--resume t))
    (unwind-protect
        (when (and (buffer-live-p buffer)
                   (window-live-p (buffer-local-value 'portal-terminal--window buffer)))
          (select-window (buffer-local-value 'portal-terminal--window buffer))
          (portal--terminal-unfocus id)
          (condition-case err
              (let* ((trigger (if key (vector key) (vconcat (kbd portal-terminal-prefix))))
                     (binding (if key
                                  (lookup-key (if portal-terminal--quick-root
                                                  (cdr portal-terminal--native-maps)
                                                (car portal-terminal--native-maps)) trigger)
                                (if portal-terminal--quick-root
                                    portal-terminal-quick-prefix-map portal-terminal-prefix-map)))
                     (resolved (if (keymapp binding)
                                   (portal-terminal--read-prefix binding trigger id)
                                 ;; Release buffered typing for commands that read a minibuffer.
                                 (when (portal--terminal-ack id t)
                                   (cons trigger binding))))
                     (keys (car resolved))
                     (command (cdr resolved)))
                (portal--terminal-ack id nil)
                (cond
                 ((not keys) (setq portal-terminal--resume nil))
                 ((and (commandp command) (not (eq command #'undefined)))
                  (let ((last-command-event (aref keys (1- (length keys))))
                        (this-command command)
                        (real-this-command command))
                    (command-execute command 'record)))
                 (t (message "No terminal command for %s" (key-description keys)))))
            (quit (message "Terminal prefix cancelled"))
            (error (setq portal-terminal--resume nil)
                   (message "Terminal command: %s" (error-message-string err)))))
      (portal--terminal-ack id nil)
      ;; Minibuffer commands finish before native focus resumes. Errors and
      ;; commands selecting ordinary buffers leave the editor in control.
      (when (and portal-terminal--resume portal-terminal--id
                 (not (active-minibuffer-window)))
        (portal-terminal-focus)))))
(define-key global-map [portal-terminal-prefix] #'portal-terminal--dispatch)
(define-key global-map [portal-terminal-binding] #'portal-terminal--dispatch)

(defun portal-terminal-send-prefix ()
  "Send the captured native leader keystroke literally to this shell."
  (interactive)
  (portal--terminal-send-prefix portal-terminal--id))

(defun portal-terminal--switch (buffer)
  "Select terminal BUFFER and remember the previously selected terminal."
  (when (window-parameter nil 'portal-terminal-quick)
    (user-error "Dismiss the quick terminal before switching ordinary terminals"))
  (let ((previous (current-buffer)))
    (switch-to-buffer buffer)
    (unless (eq previous buffer) (setq portal-terminal--last-buffer previous))))

(defun portal-terminal-next (&optional previous)
  "Select the next terminal in creation order, or PREVIOUS when non-nil."
  (interactive)
  (let* ((buffers (portal-terminal--regular-buffers))
         (index (or (cl-position (current-buffer) buffers) 0)))
    (unless buffers (user-error "No terminal buffers"))
    (portal-terminal--switch (nth (mod (+ index (if previous -1 1)) (length buffers)) buffers))))
(defun portal-terminal-previous ()
  "Select the previous terminal buffer."
  (interactive) (portal-terminal-next t))
(defun portal-terminal-last ()
  "Select the last terminal used in this pane."
  (interactive)
  (unless (memq portal-terminal--last-buffer (portal-terminal--regular-buffers))
    (user-error "No previous terminal"))
  (portal-terminal--switch portal-terminal--last-buffer))
(defun portal-terminal-select-index ()
  "Select terminal 0 through 9 in creation order."
  (interactive)
  (let ((buffer (nth (- last-command-event ?0) (portal-terminal--regular-buffers))))
    (unless buffer (user-error "No terminal at that index"))
    (portal-terminal--switch buffer)))
(defun portal-terminal-choose ()
  "Choose a terminal in this frame with Emacs completion."
  (interactive)
  (portal-terminal--switch
   (get-buffer (completing-read "Terminal: " (mapcar #'buffer-name (portal-terminal--regular-buffers)) nil t))))
(defun portal-terminal-rename (name)
  "Rename the current terminal buffer to NAME."
  (interactive (list (read-string "Terminal name: " (buffer-name))))
  (when portal-terminal--quick-root
    (user-error "Quick terminals are named by their project"))
  (rename-buffer name t))
(defun portal-terminal-next-pane ()
  "Select the next Emacs pane, as tmux prefix o does."
  (interactive) (other-window 1))
(defun portal-terminal--split (side)
  "Split toward SIDE and start a new independent shell there."
  (let ((configuration (current-window-configuration)))
    (condition-case err
        (progn (select-window (split-window nil nil side)) (portal-terminal-new))
      (error (set-window-configuration configuration) (signal (car err) (cdr err))))))
(defun portal-terminal-split-below ()
  "Split the pane top/bottom and start a shell in the bottom pane."
  (interactive) (portal-terminal--split 'below))
(defun portal-terminal-split-right ()
  "Split the pane left/right and start a shell in the right pane."
  (interactive) (portal-terminal--split 'right))
(defun portal-terminal-kill-pane ()
  "Confirm, end this shell and remove its Emacs pane when possible."
  (interactive)
  (when (y-or-n-p (format "Kill terminal %s and its running shell? " (buffer-name)))
    (let ((window (selected-window)))
      (kill-buffer (current-buffer))
      (unless (one-window-p t) (delete-window window)))))
(defun portal-terminal-zoom ()
  "Toggle the selected pane between its layout and a full-frame view."
  (interactive)
  (let ((configuration (frame-parameter nil 'portal-terminal-zoom)))
    (if configuration
        (progn (set-frame-parameter nil 'portal-terminal-zoom nil)
               (set-window-configuration configuration))
      (set-frame-parameter nil 'portal-terminal-zoom (current-window-configuration))
      (delete-other-windows))))
(defun portal-terminal-command-prompt ()
  "Run M-x and stay in Emacs afterward."
  (interactive)
  (portal-terminal-unfocus)
  (call-interactively #'execute-extended-command))
(defun portal-terminal-help ()
  "Show the current prefix map, including user customizations."
  (interactive)
  (portal-terminal-unfocus)
  (with-help-window "*Ghostty bindings*"
    (princ (format "Ghostty prefix: %s\n\n" portal-terminal-prefix))
    (princ "Repeat the prefix to send it literally. C-g cancels a pending prefix.\n")
    (princ "Command-Escape or the header button returns to Emacs. RET re-enters.\n\n")
    (princ (substitute-command-keys "\\{portal-terminal-prefix-map}"))))

(provide 'portal-terminal)
(require 'portal-terminal-bindings
         (expand-file-name "portal-terminal-bindings"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal-quick
         (expand-file-name "portal-terminal-quick"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
;;; portal-terminal.el ends here
