;;; portal-input.el --- Shared input ownership for native views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'cl-lib)
(require 'portal-native)

(defgroup portal-input nil "Input for Portal native views." :group 'applications)
(declare-function portal--input "portal" (target action &optional serial))
(declare-function portal--input-channel "portal" (process))
(declare-function portal--input-prefix "portal" (character flags))
(declare-function portal-terminal--validate-native-prefix "portal-terminal-bindings" (description))
(declare-function evil-make-overriding-map "evil-core" (keymap &optional state copy))
(defvar portal-input--channel nil)
(defvar portal-input--notification "")
(defvar portal-terminal--native-maps)
(defvar portal-input--help-map)
(defvaralias 'portal-terminal--resume 'portal-input--resume)
(defvar portal-input--resume nil)
(defvar portal-input--origin nil)
(defvar portal-input--serial nil)
(defvar-local portal-input--target-function nil "Function returning WINDOW's native target, or nil.")
(defvar-local portal-input--focus-function nil "Function to synchronize and focus this buffer's view.")
(defvar-local portal-input--map-function nil "Function returning this view's feature command map.")
(defvar portal-input-mode-map (make-sparse-keymap))
(defvaralias 'portal-terminal-prefix 'portal-input-prefix)

(defun portal-input--prefix-description (value)
  "Validate VALUE and return its native character and modifier mask."
  (let* ((keys (kbd value))
         (event (and (= (length keys) 1) (aref keys 0)))
         (basic (and event (event-basic-type event)))
         (mods (and event (event-modifiers event))))
    (unless (and (integerp basic) (<= 32 basic 126) mods
                 (cl-every (lambda (mod) (memq mod '(control meta super shift))) mods))
      (error "Portal prefix must be one modified ASCII key, e.g. C-b, C-a or s-e"))
    (when (and (memq 'shift mods) (/= basic 32) (not (<= ?a basic ?z)))
      (error "Use the resulting punctuation, e.g. s-! instead of s-S-1"))
    (list (downcase (char-to-string basic))
          (cl-loop for (mod . bit) in '((shift . 17) (control . 18) (meta . 19) (super . 20))
                   when (memq mod mods) sum (ash 1 bit)))))

(defalias 'portal-terminal--prefix-description #'portal-input--prefix-description)

(defun portal-input--prefix-changed (_symbol value operation _where)
  "Validate and apply prefix VALUE on OPERATION."
  (when (eq operation 'set)
    (let ((description (portal-input--prefix-description value)))
      (when (fboundp 'portal-terminal--validate-native-prefix)
        (portal-terminal--validate-native-prefix description))
      (when (fboundp 'portal--input-prefix)
        (apply #'portal--input-prefix description))
      (setcdr portal-input-mode-map nil)
      (keymap-set portal-input-mode-map value #'portal-input-command)
      (keymap-set portal-input-mode-map "RET" #'portal-input-focus)
      (keymap-set portal-input-mode-map "s-<escape>" #'portal-input-unfocus)
      ;; Keep the wrapper controls available in Evil states as well.
      (with-eval-after-load 'evil
        (evil-make-overriding-map portal-input-mode-map)))))

(defcustom portal-input-prefix "C-b"
  "Prefix shared by Portal native views and their Emacs wrapper buffers.
One modified ASCII key; Meta means Option and Super means Command.
Repeat it in a native view to send it literally.  Changes apply live.
The old name `portal-terminal-prefix' remains an alias."
  :type 'string :group 'portal-input)
(add-variable-watcher 'portal-input-prefix #'portal-input--prefix-changed)
(portal-input--prefix-changed nil portal-input-prefix 'set nil)

(defcustom portal-command-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("d" . portal-input-unfocus) ("o" . other-window)
                       (":" . execute-extended-command) ("M-x" . execute-extended-command)
                       ("?" . portal-input-help)))
      (keymap-set map (car binding) (cdr binding)))
    map)
  "Commands shared by every Portal view after `portal-input-prefix'.
C-x, C-c and C-h use the current Emacs bindings.  m opens the feature map.
Shared bindings take precedence over feature-specific compatibility shortcuts."
  :type 'keymap :group 'portal-input)

(define-minor-mode portal-input-mode
  "Use Portal's shared prefix and focus controls in this wrapper buffer."
  :lighter nil :keymap portal-input-mode-map
  (when portal-input-mode
    (setq-local header-line-format '(:eval (portal-input--header)))))

(defun portal-input--target (&optional window)
  "Return the native target for WINDOW, defaulting to the selected window."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (when (and portal-input-mode portal-input--target-function)
        (funcall portal-input--target-function window)))))

(defun portal-input--action (action &optional target serial)
  "Perform ACTION on TARGET, checking handoff SERIAL when supplied."
  (when-let* ((target (or target (portal-input--target))))
    (when (fboundp 'portal--input)
      (portal--input target action (or serial 0)))))

(defun portal-input-focus ()
  "Give the selected Portal view keyboard focus."
  (interactive)
  (unless portal-input--focus-function (user-error "No Portal view in this buffer"))
  (funcall portal-input--focus-function))

(defun portal-input-unfocus ()
  "Return to Emacs and stay there; RET re-enters the selected Portal view."
  (interactive)
  (setq portal-input--resume nil)
  (portal-input--action "unfocus" portal-input--origin)
  (message "Emacs has keyboard focus; RET in a Portal buffer re-enters the app."))

(defun portal-input-passthrough ()
  "Pass Portal shortcuts to this app until Command-Escape returns to Emacs."
  (interactive)
  (unless (portal-input--action "passthrough") (user-error "No visible Portal view"))
  (setq portal-input--resume nil)
  (message "Portal passthrough; Command-Escape returns to Emacs."))

(defun portal-input-send-prefix ()
  "Send the captured prefix literally to the originating native view."
  (interactive)
  (unless portal-input--serial (user-error "Enter the app with RET before sending a literal prefix"))
  (portal-input--action "literal" portal-input--origin portal-input--serial))

(defun portal-input--header ()
  "Show the current owner and the same escape hatch on every surface."
  (let ((target (portal-input--target (or (get-buffer-window (current-buffer) t) (selected-window)))))
    (concat " " (propertize " Return to Emacs " 'face 'mode-line-highlight 'mouse-face 'highlight
                            'local-map (let ((map (make-sparse-keymap)))
                                         (define-key map [header-line mouse-1] #'portal-input-unfocus) map))
            (format "  Portal: %s · %s prefix · Command-Escape · RET to enter"
                    (cond ((portal-input--action "passthrough-p" target) "Passthrough")
                          ((portal-input--action "pending" target) "Command")
                          ((portal-input--action "focused" target) "App") (t "Emacs"))
                    portal-input-prefix))))

(defun portal-input--map ()
  "Compose the shared map, current Emacs gateways, and feature shortcuts."
  (let* ((local (when portal-input--map-function (funcall portal-input--map-function)))
         (map (make-sparse-keymap)))
    (set-keymap-parent map (make-composed-keymap (delq nil (list portal-command-map local))))
    (when local (keymap-set map "m" local))
    (dolist (key '("C-x" "C-c" "C-h"))
      (when-let* ((binding (key-binding (kbd key)))) (keymap-set map key binding)))
    map))

(defun portal-input-help ()
  "Show shared and feature bindings, including user customization."
  (interactive)
  (let ((local (when portal-input--map-function (funcall portal-input--map-function))))
    (portal-input-unfocus)
    (with-help-window "*Portal bindings*"
      (princ (format "Portal prefix: %s\n\n" portal-input-prefix))
      (princ "Repeat the prefix to send it literally; C-g cancels a pending prefix.\n")
      (princ "Command-Escape returns to Emacs; RET re-enters the app.\n")
      (princ "C-x, C-c, C-h: your existing Emacs bindings. m: feature commands.\n")
      (princ "M-x portal-input-passthrough releases the prefix until Command-Escape.\n\n")
      (princ (substitute-command-keys "\\{portal-command-map}"))
      (when local
        (princ "\nFeature commands (also available directly unless shared above):\n")
        (let ((portal-input--help-map local))
          (princ (substitute-command-keys "\\{portal-input--help-map}")))))))

(defun portal-input--receive (_process text)
  "Queue native notifications for the Emacs command loop."
  (setq portal-input--notification
        (portal-native--consume-lines
         portal-input--notification text
         (lambda (line)
           (when (string-match "\\`\\(prefix\\|binding\\|literal\\|cancel\\|escape\\) \\([a-z]+:[0-9]+\\) \\([0-9]+\\) \\([0-9]+\\)\\'" line)
             (setq unread-command-events
                   (nconc unread-command-events
                          (list (list (intern (concat "portal-input-" (match-string 1 line)))
                                      (list (match-string 2 line)
                                            (string-to-number (match-string 3 line))
                                            (string-to-number (match-string 4 line))))))))))))

(defun portal-input--connect ()
  "Load the module and establish the shared input notification channel."
  (portal-native--load)
  (unless (fboundp 'portal--input)
    (user-error "Restart Emacs to load the rebuilt Portal input bridge"))
  (unless (process-live-p portal-input--channel)
    (setq portal-input--notification ""
          portal-input--channel
          (make-pipe-process :name "portal-input-events" :noquery t
                             :coding 'utf-8-unix :filter #'portal-input--receive))
    (portal--input-channel portal-input--channel))
  (apply #'portal--input-prefix (portal-input--prefix-description portal-input-prefix)))

(defun portal-input--read (binding trigger target serial)
  "Read BINDING after TRIGGER from TARGET's handoff SERIAL."
  (let* ((map (copy-keymap binding))
         (inhibit-quit nil)
         (overriding-terminal-local-map map)
         (overriding-local-map nil))
    (define-key map [t] #'undefined)
    (define-key map trigger #'portal-input-send-prefix)
    (define-key map (kbd "C-g") #'keyboard-quit)
    (define-key map [portal-input-cancel] #'keyboard-quit)
    (define-key map [portal-input-literal] #'portal-input-send-prefix)
    (define-key map [portal-input-escape] #'portal-input-unfocus)
    (define-key map [header-line mouse-1] #'portal-input-unfocus)
    (when (or (null serial) (portal-input--action "ack" target serial))
      (let ((keys (read-key-sequence-vector (format "Portal %s (? help, C-g cancel): "
                                                   (key-description trigger)))))
        (cons keys (lookup-key map keys))))))

(defun portal-input--run (target serial trigger binding)
  "Execute BINDING from TARGET, preserving input ownership through SERIAL."
  (let ((portal-input--origin target) (portal-input--serial serial)
        (portal-input--resume (and serial t)))
    (unwind-protect
        (condition-case err
            (let* ((resolved (if (keymapp binding)
                                 (portal-input--read binding trigger target serial)
                               (when (or (null serial) (portal-input--action "ack" target serial))
                                 (cons trigger binding))))
                   (keys (car resolved)) (command (cdr resolved)))
              (portal-input--action "command" target serial)
              (cond
               ((not keys) (setq portal-input--resume nil))
               ((and (commandp command) (not (eq command #'undefined)))
                (setq command (or (command-remapping command) command))
                (let ((last-command-event (aref keys (1- (length keys))))
                      (this-command command) (real-this-command command))
                  (command-execute command 'record)))
               (t (message "No Portal command for %s" (key-description keys)))))
          (quit (message "Portal command cancelled"))
          (error (setq portal-input--resume nil)
                 (message "Portal command: %s" (error-message-string err))))
      (let ((valid (or (null serial) (portal-input--action "finish" target serial))))
        (when (and valid portal-input--resume portal-input-mode
                   portal-input--focus-function (not (active-minibuffer-window)))
          (portal-input-focus))))))

(defun portal-input-command ()
  "Read a Portal command while Emacs owns this wrapper buffer."
  (interactive)
  (portal-input--run (portal-input--target) nil (vconcat (kbd portal-input-prefix)) (portal-input--map)))

(defun portal-input--dispatch (event)
  "Dispatch EVENT in its originating native view's actual Emacs window."
  (interactive "e")
  (pcase-let ((`(,target ,serial ,key) (cadr event)))
    (when (portal-input--action "pending" target serial)
      (let (origin)
        (walk-windows (lambda (window)
                        (when (equal target (portal-input--target window)) (setq origin window)))
                      'no-minibuffer t)
        (if (not origin)
            (portal-input--action "finish" target serial)
          (select-window origin)
          (let* ((binding-event (eq (car event) 'portal-input-binding))
                 (trigger (if binding-event (vector key) (vconcat (kbd portal-input-prefix))))
                 (binding (if binding-event
                              (lookup-key (if (bound-and-true-p portal-terminal--quick-root)
                                              (cdr portal-terminal--native-maps)
                                            (car portal-terminal--native-maps)) trigger)
                            (portal-input--map))))
            (portal-input--run target serial trigger binding)))))))

(define-key global-map [portal-input-prefix] #'portal-input--dispatch)
(define-key global-map [portal-input-binding] #'portal-input--dispatch)
(define-key global-map [portal-input-escape] #'portal-input-unfocus)
(provide 'portal-input)
;;; portal-input.el ends here
