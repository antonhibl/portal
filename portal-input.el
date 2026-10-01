;;; portal-input.el --- Shared input ownership for native views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A native view is an app running in Emacs.  It gets the keys typed in it,
;; and a chord it does not use, a key that types a character pressed with
;; Control, Meta or Super, reaches Emacs: this file reads the rest of its key
;; sequence with the view's buffer's keymaps and runs the command, then gives
;; the view the keyboard back, unless keys typed meanwhile wait for Emacs.
;; Command-Escape returns to Emacs, and RET in the buffer re-enters the view.
;; The native core decides who gets each key (native/Core/input.c).

(require 'cl-lib)
(require 'portal-view)
(require 'portal-toolbar)

(defgroup portal-input nil "Input for Portal native views." :group 'applications)
(declare-function portal--input "portal" (target action &optional serial))
(declare-function evil-make-overriding-map "evil-core" (keymap &optional state copy))
(defvar portal-terminal--native-maps)
(defvaralias 'portal-terminal--resume 'portal-input--resume)
(defvar portal-input--resume nil)
(defvar portal-input--origin nil)
(defvar portal-input--serial nil)

(defvar portal-input-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "RET" #'portal-input-focus)
    (keymap-set map "s-<escape>" #'portal-input-unfocus)
    map)
  "Keys of a Portal view's buffer while Emacs has the keyboard.")
;; Keep the wrapper controls available in Evil states as well.
(with-eval-after-load 'evil
  (evil-make-overriding-map portal-input-mode-map))

(defconst portal-input--modifiers '((shift . 1) (control . 2) (meta . 4) (super . 8))
  "The native module's value of each modifier, as its chords carry them.")

(defun portal-input--chord (value)
  "Validate VALUE, a native binding's first chord, and return it as the core
reads it: a character and a sum of `portal-input--modifiers' values."
  (let* ((keys (kbd value))
         (event (and (= (length keys) 1) (aref keys 0)))
         (basic (and event (event-basic-type event)))
         (mods (and event (event-modifiers event))))
    (unless (and (integerp basic) (<= 32 basic 126) mods
                 (cl-every (lambda (mod) (memq mod '(control meta super shift))) mods))
      (error "A native binding's first chord must be one modified ASCII key, e.g. s-t or C-c"))
    (when (and (memq 'shift mods) (/= basic 32) (not (<= ?a basic ?z)))
      (error "Use the resulting punctuation, e.g. s-! instead of s-S-1"))
    (list (downcase (char-to-string basic))
          (cl-loop for (mod . value) in portal-input--modifiers
                   when (memq mod mods) sum value))))

(defun portal-input--event (character modifiers)
  "Return the Emacs event for CHARACTER typed with MODIFIERS, a sum of
`portal-input--modifiers' values.  Shift made CHARACTER, so it is a
modifier only on space, as in S-SPC."
  (event-convert-list
   (nconc (cl-loop for (modifier . value) in portal-input--modifiers
                   unless (or (zerop (logand modifiers value))
                              (and (eq modifier 'shift) (/= character ?\s)))
                   collect modifier)
          (list character))))

(define-minor-mode portal-input-mode
  "Enter a Portal view with RET; Command-Escape returns to Emacs."
  :lighter nil :keymap portal-input-mode-map)

(defun portal-input--target (&optional window)
  "Return the native target for WINDOW, defaulting to the selected window."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (when portal-input-mode (portal-view-target window)))))

(defun portal-input--action (action &optional target serial)
  "Perform ACTION on TARGET, checking handoff SERIAL when supplied."
  (when-let* ((target (or target (portal-input--target))))
    (when (fboundp 'portal--input)
      (portal--input target action (or serial 0)))))

(defun portal-input-focus ()
  "Give the selected Portal view keyboard focus."
  (interactive)
  (portal-view-focus))

(defun portal-input-unfocus ()
  "Return to Emacs and stay there; RET re-enters the selected Portal view."
  (interactive)
  (setq portal-input--resume nil)
  (portal-input--action "unfocus" portal-input--origin)
  (message "Emacs has keyboard focus; RET in a Portal buffer re-enters the app."))

(defun portal-input-send-trigger ()
  "Send the key that started this native binding's handoff to its view."
  (interactive)
  (unless portal-input--serial (user-error "No native binding key to send"))
  (portal-input--action "literal" portal-input--origin portal-input--serial))

(defun portal-input--queue (event)
  "Return a record handler that queues EVENT for the Emacs command loop.
The queued event is (EVENT (TARGET SERIAL KEY...)), with numbers."
  (lambda (target serial &rest keys)
    (setq unread-command-events
          (nconc unread-command-events
                 (list (list event (cons target (mapcar #'string-to-number
                                                        (cons serial keys)))))))))

(dolist (type '("binding" "key" "literal" "cancel"))
  (setf (alist-get type portal-view-record-handlers nil nil #'equal)
        (portal-input--queue (intern (concat "portal-input-" type)))))

(defvar-local portal-input--escaped 0
  "The serial of this view's latest handoff that the user ended, or 0.
Its escape record sets it; a view has one handoff at a time.")

(setf (alist-get "escape" portal-view-record-handlers nil nil #'equal)
      (let ((queue (portal-input--queue 'portal-input-escape)))
        (lambda (target serial &rest keys)
          (setq portal-input--escaped (max portal-input--escaped (string-to-number serial)))
          (apply queue target serial keys))))

(defun portal-input--select (event)
  "Select the pane showing the view clicked in EVENT, and give the view focus.
The click already gave the view the keyboard; this makes Emacs agree."
  (interactive "e")
  (let ((target (car (cadr event))))
    (when-let* ((window (portal-input--window target)))
      (select-window window)
      (portal-input--action "focus" target))))

(setf (alist-get "select" portal-view-record-handlers nil nil #'equal)
      (lambda (target)
        (setq unread-command-events
              (nconc unread-command-events (list (list 'portal-input-select (list target)))))))

(defun portal-input--connect ()
  "Load the module, which has the input bridge."
  (portal-view--load)
  (unless (fboundp 'portal--input)
    (user-error "Restart Emacs to load the rebuilt Portal input bridge")))

(defun portal-input--read (binding trigger target serial)
  "Read BINDING, a native binding's prefix map, after TRIGGER, from TARGET's
handoff SERIAL."
  (let* ((map (copy-keymap binding))
         (inhibit-quit nil)
         (overriding-terminal-local-map map)
         (overriding-local-map nil))
    (define-key map [t] #'undefined)
    (define-key map trigger #'portal-input-send-trigger)
    (define-key map (kbd "C-g") #'keyboard-quit)
    (define-key map [portal-input-cancel] #'keyboard-quit)
    (define-key map [portal-input-literal] #'portal-input-send-trigger)
    (define-key map [portal-input-escape] #'portal-input-unfocus)
    (when (portal-input--action "ack" target serial)
      (let ((keys (read-key-sequence-vector
                   (format "%s (C-g cancels) " (key-description trigger)))))
        (cons keys (lookup-key map keys))))))

(defun portal-input--read-sequence (trigger target serial)
  "Read the key sequence TRIGGER starts, from TARGET's handoff SERIAL, with the
current buffer's keymaps, as if typed there, and return it with its command."
  (when (portal-input--action "ack" target serial)
    (let ((inhibit-quit nil))
      (setq unread-command-events (append trigger unread-command-events))
      (let* ((keys (read-key-sequence-vector nil))
             (last (aref keys (1- (length keys)))))
        (pcase (car-safe last)
          ('portal-input-cancel (signal 'quit nil))
          ('portal-input-escape (cons keys #'portal-input-unfocus))
          (_ (cons keys (key-binding keys t))))))))

(defun portal-input--run (target serial trigger binding)
  "Run the command TRIGGER starts from TARGET, preserving input ownership
through SERIAL.  BINDING is a native binding's command or prefix map, or nil
for a chord the view did not use, read with the current buffer's keymaps."
  (let ((portal-input--origin target) (portal-input--serial serial)
        (portal-input--resume t)
        (origin (portal-view--target-buffer target)))
    (unwind-protect
        (condition-case err
            (let* ((resolved (cond ((keymapp binding)
                                    (portal-input--read binding trigger target serial))
                                   (binding (when (portal-input--action "ack" target serial)
                                              (cons trigger binding)))
                                   (t (portal-input--read-sequence trigger target serial))))
                   (keys (car resolved)) (command (cdr resolved)))
              (portal-input--action "command" target serial)
              (cond
               ((not keys) (setq portal-input--resume nil))
               ((and (commandp command) (not (eq command #'undefined)))
                (setq command (or (command-remapping command) command))
                (let ((last-command-event (aref keys (1- (length keys))))
                      (this-command command) (real-this-command command))
                  (command-execute command 'record)))
               (t (message "%s is undefined" (key-description keys)))))
          (quit (message "Portal command cancelled"))
          (error (setq portal-input--resume nil)
                 (message "Portal command: %s" (error-message-string err))))
      ;; Finishing fails once the handoff has ended.  Emacs hiding the view, as
      ;; showing another buffer in its pane does, ends it silently, and the
      ;; selected view resumes all the same.  The user ending it, or a later
      ;; handoff of the same view, sends an escape record first, which a busy
      ;; command has not read yet.
      (let ((ended (not (portal-input--action "finish" target serial))))
        (when ended (portal-view--read-records))
        (when (and portal-input--resume portal-input-mode
                   (not (and ended (buffer-live-p origin)
                             (>= (buffer-local-value 'portal-input--escaped origin) serial)))
                   (memq (current-buffer) (portal-view-buffers))
                   (not (active-minibuffer-window))
                   ;; Keys typed after the trigger that the command never
                   ;; read are Emacs's next command; checking takes them in.
                   (not (input-pending-p)))
          (portal-input-focus))))))

(defun portal-input--window (target)
  "Return the window showing native view TARGET, in any frame, or nil."
  (let (origin)
    (walk-windows (lambda (window)
                    (when (equal target (portal-input--target window)) (setq origin window)))
                  'no-minibuffer t)
    origin))

(defun portal-input--dispatch (event)
  "Dispatch EVENT in its originating native view's actual Emacs window."
  (interactive "e")
  (pcase-let ((`(,target ,serial . ,keys) (cadr event)))
    (when (portal-input--action "pending" target serial)
      (let ((origin (portal-input--window target)))
        (if (not origin)
            (portal-input--action "finish" target serial)
          (select-window origin)
          (if (eq (car event) 'portal-input-binding)
              (let ((trigger (vector (car keys))))
                (portal-input--run target serial trigger
                                   (lookup-key (if (bound-and-true-p portal-terminal--quick-root)
                                                   (cdr portal-terminal--native-maps)
                                                 (car portal-terminal--native-maps))
                                               trigger)))
            (portal-input--run target serial
                               (vector (portal-input--event (car keys) (cadr keys))) nil)))))))

(define-key global-map [portal-input-key] #'portal-input--dispatch)
(define-key global-map [portal-input-binding] #'portal-input--dispatch)
(define-key global-map [portal-input-escape] #'portal-input-unfocus)
(define-key global-map [portal-input-select] #'portal-input--select)
(provide 'portal-input)
;;; portal-input.el ends here
