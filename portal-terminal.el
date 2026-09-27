;;; portal-terminal.el --- Native Ghostty terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'windmove)

(defgroup portal-terminal nil
  "Native Ghostty terminals in Emacs panes."
  :group 'terminals)

(require 'portal-input
         (expand-file-name "portal-input"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(declare-function portal--terminal-theme "portal-terminal" (theme))
(declare-function portal--terminal-themes "portal-terminal" ())

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
  (portal-view--load)
  (portal--terminal-themes))

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
  (setq-local portal-input--map-function
              (lambda () (if portal-terminal--quick-root portal-terminal-quick-prefix-map
                           portal-terminal-prefix-map)))
  (add-hook 'kill-buffer-hook #'portal-terminal--dismiss-quick nil t)
  (portal-input-mode 1))
(keymap-set portal-terminal-mode-map "RET" #'portal-terminal-focus)
(keymap-set portal-terminal-mode-map "C-c C-k" #'portal-terminal-close)

(defun portal-terminal--regular-buffers ()
  "Return the ordinary terminals in creation order, excluding quick shells."
  (cl-remove-if (lambda (buffer)
                  (buffer-local-value 'portal-terminal--quick-root buffer))
                (portal-view-buffers 'terminal)))

(defun portal-terminal--connect ()
  "Connect shared input and refresh terminal-specific native bindings."
  (portal-input--connect)
  (portal-terminal-refresh-bindings))

;;;###autoload
(defun portal-terminal (&optional new)
  "Open or return to a native Ghostty terminal in the selected pane.
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

(defun portal-terminal--new (&optional quick-root command name elsewhere argv)
  "Create a terminal, optionally for QUICK-ROOT or with startup COMMAND.
NAME names its buffer.  ELSEWHERE displays it in another pane.
ARGV is a JSON array of a program and literal arguments to run through
the user's shell, instead of COMMAND."
  (when (file-remote-p default-directory)
    (user-error "Start in a local directory; run ssh inside the terminal for remote shells"))
  (portal-terminal--connect)
  (let ((directory (expand-file-name default-directory))
        (previous (current-buffer))
        (buffer (generate-new-buffer
                 (if quick-root
                     (format "*portal-quick:%s*" (abbreviate-file-name quick-root))
                   (or name "*portal-terminal*"))))
        ready)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (portal-terminal-mode)
            (setq default-directory directory
                  portal-terminal--quick-root quick-root
                  portal-terminal--last-buffer previous)
            (let ((inhibit-read-only t))
              (insert "Native Ghostty terminal\n\n"
                      "RET or a click focuses Ghostty. Command-Escape returns to Emacs.\n"
                      "Use the configured prefix then ? for terminal commands.\n"
                      "This buffer has one live view, which follows its selected pane.\n")))
          (if quick-root
              (portal-terminal-quick--display buffer)
            (if elsewhere
                (pop-to-buffer buffer '(nil (inhibit-same-window . t)
                                            (reusable-frames . visible)))
              (switch-to-buffer buffer)))
          (redisplay t)
          (with-current-buffer buffer
            (portal-view-open 'terminal (list :directory directory
                                              :command command
                                              :argv argv
                                              :theme portal-terminal-theme
                                              :quick (and quick-root t)))
            (portal-terminal-focus))
          (setq ready t))
      (unless ready (kill-buffer buffer)))
    buffer))

(defun portal-terminal-start (directory program arguments &optional name)
  "Start PROGRAM with ARGUMENTS in DIRECTORY in a new terminal in another pane.
Return its buffer.  NAME optionally names the buffer.  Arguments are literal
strings.  The native terminal starts the user's interactive login shell,
which loads its startup files and resolves PROGRAM on its PATH.
Lisp-side `process-environment' changes are not exported to the terminal.
A missing program is reported by the shell inside the terminal."
  (unless (and (stringp directory) (file-name-absolute-p directory)
               (not (file-remote-p directory)) (file-directory-p directory))
    (user-error "Choose an existing local terminal directory"))
  (unless (and (stringp program) (> (length program) 0) (sequencep arguments)
               (seq-every-p (lambda (s) (and (stringp s) (not (string-search "\0" s)))) arguments)
               (not (string-search "\0" program)))
    (user-error "Terminal program and arguments must be strings without NUL"))
  (let* ((default-directory (file-name-as-directory directory))
         (configuration (current-window-configuration)))
    (condition-case err
        (portal-terminal--new
         nil nil name t (json-serialize (vconcat (list program) arguments)))
      (error (set-window-configuration configuration)
             (portal-view-sync)
             (signal (car err) (cdr err))))))

(defun portal-terminal-open-action (arguments)
  "Handle a hosted app's terminal.open operation with JSON ARGUMENTS.
The originating view gives up the keyboard, which the new terminal takes."
  (portal-input--action "unfocus" portal-view--target)
  (setq portal-input--resume nil)
  (let ((buffer (portal-terminal-start
                 (plist-get arguments :directory) (plist-get arguments :program)
                 (plist-get arguments :args) (plist-get arguments :name))))
    (list :target (buffer-local-value 'portal-view--target buffer))))

;;;###autoload
(defun portal-terminal-focus ()
  "Give this buffer's native terminal keyboard focus."
  (interactive)
  (unless (memq (current-buffer) (portal-view-buffers 'terminal))
    (user-error "No terminal in this buffer"))
  (portal-view-focus))

(defalias 'portal-terminal-unfocus #'portal-input-unfocus)

;;;###autoload
(defun portal-terminal-close ()
  "End this buffer's native shell.  Other terminal sessions keep running."
  (interactive)
  (portal-terminal--dismiss-quick)
  (portal-view-close))

(defun portal-terminal--dismiss-quick ()
  "Dismiss the quick panel when it shows this buffer."
  (when-let* ((window (get-buffer-window (current-buffer))))
    (when (and portal-terminal--quick-root (eq window (portal-terminal-quick--window)))
      (save-current-buffer (portal-terminal-quick-dismiss)))))

(defun portal-terminal-close-all ()
  "End all native shells, for Emacs shutdown or explicit cleanup."
  (interactive)
  (dolist (buffer (portal-view-buffers 'terminal))
    (with-current-buffer buffer (portal-terminal-close))))

(defalias 'portal-terminal--dispatch #'portal-input--dispatch)
(defalias 'portal-terminal-send-prefix #'portal-input-send-prefix)

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
  "Choose a terminal with Emacs completion."
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
(defalias 'portal-terminal-command-prompt #'execute-extended-command)
(defalias 'portal-terminal-help #'portal-input-help)

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
