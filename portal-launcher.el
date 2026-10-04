;;; portal-launcher.el --- A dedicated native launcher frame -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Opt-in and build-restricted: this moves Emacs's internal NS view. A native
;; defect can crash Emacs. Loading this file creates no frame or shortcut.
(require 'portal-global-shortcut)
(require 'portal-view)
(require 'subr-x)

(declare-function launcher "launcher" (&optional refresh))
(declare-function launcher--bang-for-input "launcher" (input))
(defvar launcher-bangs)

(declare-function portal--launcher-attach "portal-launcher" (title))
(declare-function portal--launcher-prepare "portal-launcher" ())
(declare-function portal--launcher-show "portal-launcher" (width height dx dy screen shadow radius))
(declare-function portal--launcher-hide "portal-launcher" (&optional restore-focus))
(declare-function portal--launcher-detach "portal-launcher" ())
(declare-function portal--launcher-inspect "portal-launcher" ())

(defgroup portal-launcher nil "An Emacs buffer in a native macOS panel." :group 'frames)

(defvar portal-launcher-mode nil)

(defcustom portal-launcher-command #'portal-launcher-applications
  "Interactive command run by the launcher shortcut and toggle.
The default uses the optional launcher.el package for apps and web searches.
Nil keeps the reusable buffer presentation.  A command runs synchronously
inside `portal-launcher-present', with the user's completion configuration.
Commands that deliberately select other frames require their own wrapper."
  :type '(choice (const :tag "Show a buffer" nil) function))

;;;###autoload
(defun portal-launcher-applications (&optional refresh)
  "Pick an application or web search with the optional launcher.el package.
This is the default command inside `portal-launcher-present'. With prefix
argument REFRESH, rebuild the package's Spotlight cache before prompting.
Use `launcher-refresh' to refresh separately. Accept a selected application
even when no text was typed. Empty results and bangs without a query cancel.
The user's completion reader, app identities and search settings are kept;
ordinary `launcher' invocations are unchanged."
  (interactive "P")
  (unless (require 'launcher nil t)
    (user-error "Install launcher.el from https://github.com/xiaoxinghu/launcher.el and add it to load-path (see Portal README)"))
  (let* ((reader completing-read-function)
         (completing-read-function
          (lambda (&rest arguments)
            ;; The reader's result includes a candidate accepted with Return
            ;; or arrow navigation, even when the search text stayed empty.
            (let* ((choice
                    (minibuffer-with-setup-hook
                        (lambda ()
                          ;; Stock completion binds Space to word completion,
                          ;; which eats the separator in "!g query". Keep Tab
                          ;; completion and any explicitly customized binding.
                          (when (eq (key-binding " ") #'minibuffer-complete-word)
                            (use-local-map (copy-keymap (current-local-map)))
                            (local-set-key " " #'self-insert-command)))
                      (let ((completing-read-function reader))
                        (apply reader arguments))))
                   (bang (launcher--bang-for-input choice)))
              (when (or (string-blank-p choice)
                        (assoc-string (string-trim choice) launcher-bangs)
                        (and bang (string-blank-p (substring choice (1+ (length (car bang)))))))
                (signal 'quit nil))
              choice))))
    (launcher refresh)))

(cl-defstruct (portal-launcher--session (:constructor portal-launcher--make-session))
  tag native-id teardown blurred)
(defvar portal-launcher--session nil "The active command session, or nil.")

(defconst portal-launcher--session-map
  (let ((map (make-sparse-keymap)))
    (define-key map [escape] #'portal-launcher-cancel)
    (define-key map (kbd "C-g") #'portal-launcher-cancel)
    map)
  "Keys active only while a launcher command is running.")

;; Until user configuration composes launchers, the mode registers this one
;; global shortcut, like any other client of `portal-global-shortcut-set'.
(defun portal-launcher--register (chord)
  "Make CHORD toggle the launcher, as the global shortcut `portal-launcher'."
  (portal-global-shortcut-set 'portal-launcher chord #'portal-launcher-toggle))

(defun portal-launcher--registered ()
  "Whether the launcher's global shortcut is set."
  (and (assq 'portal-launcher portal-global-shortcut--registrations) t))

(defun portal-launcher--set-shortcut (symbol value)
  "Set SYMBOL to VALUE, rebinding an enabled launcher atomically."
  (unless (and (stringp value) (> (length value) 0))
    (user-error "Launcher shortcut must be a nonempty chord string"))
  (when portal-launcher-mode
    (portal-launcher--register value))
  (set-default symbol value))

(defcustom portal-launcher-shortcut "Control-Option-Command-P"
  "Global physical-key chord registered while `portal-launcher-mode' is on.
The mode sets it as the global shortcut `portal-launcher', which toggles
the launcher; see `portal-global-shortcut-set' for the notation, such as
Control-Option-Command-P. Use Customize or `setopt' to rebind immediately;
a conflict retains the old value and registration. After `setq', enable the
mode again to apply it."
  :type 'string :set #'portal-launcher--set-shortcut)

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
  "Immutable parameters of the dedicated buffer launcher frame.
A minibuffer launcher's frame is minibuffer-only instead.")
(defvar portal-launcher--frame nil "The dedicated frame, or nil before creation.")
(defvar portal-launcher--return-window nil "Ordinary window selected before presentation.")
(defvar comp-installed-trampolines-h)

(defun portal-launcher--frame-role (kind)
  "Immutable parameters of a dedicated frame for KIND of presentation."
  (if (eq kind 'minibuffer)
      (cons '(minibuffer . only) (assq-delete-all 'minibuffer (copy-alist portal-launcher--role)))
    portal-launcher--role))

(defun portal-launcher--kind (frame)
  "The kind of presentation dedicated FRAME was made for."
  (if (eq (frame-parameter frame 'minibuffer) 'only) 'minibuffer 'buffer))

(defun portal-launcher--live-p (kind)
  "Whether the dedicated frame is live and made for KIND of presentation."
  (and (frame-live-p portal-launcher--frame)
       (eq (portal-launcher--kind portal-launcher--frame) kind)))

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
    (let ((role (portal-launcher--frame-role (portal-launcher--kind portal-launcher--frame))))
      (dolist (parameter parameters)
        (when (and (assq (car parameter) role)
                   (not (equal (cdr parameter) (cdr (assq (car parameter) role)))))
          (user-error "Launcher frame parameter %s is fixed" (car parameter))))
      ;; Even setting parent-frame to its existing nil calls an EmacsWindow-only
      ;; selector. Drop unchanged role parameters as well as rejecting changes.
      (funcall original frame
               (cl-remove-if (lambda (entry) (assq (car entry) role)) parameters)))))

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

(defun portal-launcher--delete-frame (original &optional frame force)
  "Unwind the session before ORIGINAL deletes launcher FRAME with FORCE."
  (if (and portal-launcher--session
           (eq (or frame (selected-frame)) portal-launcher--frame))
      (progn
        (setf (portal-launcher--session-teardown portal-launcher--session) 'delete)
        (portal-launcher-cancel))
    (funcall original frame force)))

(defun portal-launcher--hooks (install)
  "INSTALL or remove lifecycle hooks and the native-role guard."
  (if install
      (advice-add 'modify-frame-parameters :around #'portal-launcher--guard-parameters)
    (advice-remove 'modify-frame-parameters #'portal-launcher--guard-parameters))
  (if install
      (advice-add 'delete-frame :around #'portal-launcher--delete-frame)
    (advice-remove 'delete-frame #'portal-launcher--delete-frame))
  (if install
      (setf (alist-get "launcher-blur" portal-view-feature-record-handlers nil nil #'equal)
            #'portal-launcher--queue-blur)
    (setq portal-view-feature-record-handlers
          (assoc-delete-all "launcher-blur" portal-view-feature-record-handlers)))
  (dolist (entry '((delete-frame-functions . portal-launcher--before-delete)
                   (kill-emacs-hook . portal-launcher--shutdown)))
    (if install (add-hook (car entry) (cdr entry))
      (remove-hook (car entry) (cdr entry)))))

(defun portal-launcher--check-guard ()
  "Ensure native-compiled callers also go through the frame-role guard.
This uses the validated Emacs build's trampoline registry. Without its
trampoline, native-compiled built-in setters bypass Lisp advice."
  (when (and (featurep 'native-compile)
             (not (and (boundp 'comp-installed-trampolines-h)
                       (gethash 'modify-frame-parameters comp-installed-trampolines-h))))
    (user-error "Launcher needs the modify-frame-parameters native trampoline; enable native-comp-enable-subr-trampolines and a working native compiler, then retry"))
  (when (and (featurep 'native-compile)
             (not (gethash 'delete-frame comp-installed-trampolines-h)))
    (user-error "Launcher needs the delete-frame native trampoline; enable native-comp-enable-subr-trampolines and a working native compiler, then retry")))

(defun portal-launcher--shutdown ()
  "Release native launcher resources without aborting Emacs shutdown."
  (when (frame-live-p portal-launcher--frame)
    (portal--launcher-detach)
    (setq portal-launcher--frame nil))
  ;; Emacs will dispose of its frames, including any active minibuffer. Do not
  ;; cancel the command: that throw would abandon kill-emacs and later hooks.
  (let ((portal-launcher--session nil))
    (portal-launcher--disable)))

(defun portal-launcher--disable ()
  "Detach and delete the dedicated frame. Safe to call repeatedly."
  (when portal-launcher--session
    (setf (portal-launcher--session-teardown portal-launcher--session) 'disable)
    (portal-launcher-cancel))
  (when (frame-live-p portal-launcher--frame)
    ;; Let delete-frame validate deletion (e.g. an active minibuffer) before
    ;; its hook detaches. If it refuses, keep ownership and guards intact.
    (delete-frame portal-launcher--frame t))
  (portal-global-shortcut-remove 'portal-launcher)
  (portal-launcher--hooks nil)
  (portal-launcher--forget-blur)
  (setq portal-launcher-mode nil))

;;;###autoload
(define-minor-mode portal-launcher-mode
  "Opt in to Portal's build-restricted native launcher.
Enabling sets `portal-launcher-shortcut' as the global shortcut
`portal-launcher', without creating a frame. Repeated enable applies any
changed chord; disabling removes only that shortcut.
Disabling restores the native window before deleting the dedicated frame.
A native defect can crash the hosting Emacs; start in a disposable Emacs."
  :global t :group 'portal-launcher
  (if portal-launcher-mode
      (condition-case error
          (progn
            (portal-launcher--check-support)
            (portal-view--load)
            (unless (and (fboundp 'portal--launcher-attach)
                         (fboundp 'portal--launcher-prepare)
                         (fboundp 'portal--shortcut-set))
              (user-error "Rebuild Portal and restart Emacs for launcher support"))
            (portal-launcher--hooks t)
            (portal-launcher--check-guard)
            (unless (and (stringp portal-launcher-shortcut) (> (length portal-launcher-shortcut) 0))
              (user-error "Launcher shortcut must be a nonempty chord string"))
            (portal-launcher--register portal-launcher-shortcut))
        (error
         (unless (portal-launcher--registered) (portal-launcher--hooks nil))
         (setq portal-launcher-mode (portal-launcher--registered))
         (signal (car error) (cdr error))))
    (condition-case error
        (portal-launcher--disable)
      (error (setq portal-launcher-mode t) (signal (car error) (cdr error))))))

(defun portal-launcher--queue-blur (session &rest fields)
  "Queue a native focus-loss record for SESSION; reject malformed FIELDS.
The session records it as well, for `portal-launcher--dismiss-if-blurred'."
  (when (and portal-launcher--session (null fields) (stringp session)
             (string-match-p "\\`[0-9]+\\'" session)
             (eql (string-to-number session)
                  (portal-launcher--session-native-id portal-launcher--session)))
    (setf (portal-launcher--session-blurred portal-launcher--session) (string-to-number session))
    (setq unread-command-events
          (nconc unread-command-events
                 (list (list 'portal-launcher-blur (string-to-number session)))))))

(defun portal-launcher--blur (event)
  "Dismiss only the still-current command session named in EVENT."
  (interactive "e")
  (when (and portal-launcher--session
             (eql (cadr event) (portal-launcher--session-native-id portal-launcher--session)))
    (throw (portal-launcher--session-tag portal-launcher--session) 'blur)))

(defun portal-launcher--dismiss-if-blurred ()
  "Dismiss the session if it has lost focus.
Each command loop runs this as it starts and after each command, including
one that failed. A focus-loss event queued while Lisp was running is not
read as a special event, and Emacs's error report, in a buffer or a
minibuffer, discards it."
  (when-let* ((session portal-launcher--session)
              (id (portal-launcher--session-blurred session)))
    (portal-launcher--blur (list 'portal-launcher-blur id))))

(defun portal-launcher--forget-blur ()
  "Remove queued focus-loss events, which only their own session handles."
  (setq unread-command-events
        (cl-remove-if (lambda (event) (eq (car-safe event) 'portal-launcher-blur))
                      unread-command-events)))

;; Focus loss must also unwind a prompt reading a single event or using a
;; completion package's overriding map. The filter itself never unwinds Lisp.
(define-key special-event-map [portal-launcher-blur] #'portal-launcher--blur)

;;;###autoload
(defun portal-launcher-cancel ()
  "Cancel the entire launcher command, including every nested prompt."
  (interactive)
  (if portal-launcher--session
      (throw (portal-launcher--session-tag portal-launcher--session) 'cancel)
    (portal-launcher-hide)))

(defun portal-launcher--check-function (function)
  "Signal a `user-error' unless FUNCTION is a command or takes no arguments.
`func-arity' loads an autoloaded function that is not a command."
  (unless (and (functionp function)
               (or (commandp function)
                   (zerop (car (func-arity function)))))
    (user-error "Launcher needs a command or a function of no arguments, not %S" function)))

(defun portal-launcher--options (options)
  "Return presentation OPTIONS as (KIND MODE-LINE KEEP-OPEN).
Signal a `user-error' if they are invalid."
  (unless (and (cl-evenp (length options))
               (cl-loop for key in options by #'cddr
                        always (memq key '(:kind :mode-line :keep-open))))
    (user-error "Launcher options are :kind, :mode-line and :keep-open, each with a value, not %S"
                options))
  (let ((kind (if (plist-member options :kind) (plist-get options :kind) 'buffer))
        (mode-line (if (plist-member options :mode-line) (plist-get options :mode-line) t))
        (keep-open (plist-get options :keep-open)))
    (unless (memq kind '(buffer minibuffer))
      (user-error "Launcher :kind must be `buffer' or `minibuffer', not %S" kind))
    (unless (booleanp mode-line)
      (user-error "Launcher :mode-line must be t or nil, not %S" mode-line))
    (unless (booleanp keep-open)
      (user-error "Launcher :keep-open must be t or nil, not %S" keep-open))
    (when (and keep-open (eq kind 'minibuffer))
      (user-error "Launcher :keep-open needs :kind `buffer'; a minibuffer panel closes with its prompt"))
    (list kind mode-line keep-open)))

(defvar portal-launcher--mode-line-parameters nil
  "Launcher windows whose mode lines the presentation hid, as (WINDOW . VALUE).
VALUE is the window's earlier `mode-line-format' parameter.")

(defun portal-launcher--hide-mode-lines (frame)
  "Hide the mode lines of launcher FRAME's windows, including new ones.
A window parameter leaves the buffers' own `mode-line-format' unchanged;
each window's earlier parameter is kept to restore."
  (when (eq frame portal-launcher--frame)
    (dolist (window (window-list frame 'never))
      (unless (assq window portal-launcher--mode-line-parameters)
        (push (cons window (window-parameter window 'mode-line-format))
              portal-launcher--mode-line-parameters)
        (set-window-parameter window 'mode-line-format 'none)))))

(defun portal-launcher--restore-windows (windows)
  "Delete the buffer launcher's windows other than WINDOWS.
WINDOWS were its windows when the presentation's function started, or nil
if it never started.  One window always stays."
  (when (and windows (portal-launcher--live-p 'buffer))
    (let ((ignore-window-parameters t))
      (dolist (window (window-list portal-launcher--frame 'never))
        (unless (or (memq window windows)
                    (not (cdr (window-list portal-launcher--frame 'never))))
          (delete-window window))))))

;;;###autoload
(defun portal-launcher-present (&optional function &rest options)
  "Present FUNCTION in the launcher, hide it and return FUNCTION's value.
FUNCTION is an interactive command, called with `call-interactively' so it
sees any prefix argument, or a function of no arguments, called with
`funcall'. It defaults to `portal-launcher-command' and runs with the buffer
*Portal Launcher* current.

OPTIONS are keywords, each followed by its value:
:kind `buffer', the default, shows a buffer window above the panel's own
  minibuffer. Buffers that FUNCTION displays show in the panel, and windows
  it creates there are deleted when the panel hides; earlier ones stay.
  `minibuffer' makes the whole panel a minibuffer: its prompts and an inline
  completion UI, such as Vertico, start at the top, and unused lines stay
  empty below. Buffers that FUNCTION displays, including stock completion's
  *Completions* list, show nowhere, so commands that display buffers or need
  windows require `buffer'.
:mode-line nil hides the mode lines of the panel's windows, including ones
  that FUNCTION creates, without changing how their buffers look elsewhere.
  t, the default, shows each buffer's own. A minibuffer panel has none.
:keep-open t keeps a buffer panel open after FUNCTION returns, for a UI
  that FUNCTION set up there. Commands then run in the panel, with this
  call's display rules, keys and focus handling, until it is dismissed; the
  call returns nil then. An error in a later command is reported and the
  panel stays open. Its buffers belong to the caller and are not killed.
  nil, the default, hides the panel when FUNCTION returns. A minibuffer
  panel cannot stay open.
Both kinds have `portal-launcher-size'; a completion UI taller than the
panel is clipped at the bottom. An invalid FUNCTION or option signals an
error before anything is shown or an active session is cancelled.

A second invocation cancels the active session. Escape, C-g, errors and
focus loss unwind nested prompts before hiding; completion, display and
presentation settings are scoped to this call. Cancellation restores the
previous application's focus only if the panel still owns it. Success and
click-away never activate the previous app. Functions that catch arbitrary
throws or deliberately select other frames are outside this interface. Do
not invoke from an existing minibuffer."
  (interactive)
  (setq function (or function portal-launcher-command))
  (portal-launcher--check-function function)
  (pcase-let ((`(,kind ,mode-line ,keep-open) (portal-launcher--options options)))
    (when portal-launcher--session (portal-launcher-cancel))
    (when (active-minibuffer-window)
      (user-error "Finish the current minibuffer before presenting a launcher command"))
    (let* ((previous-window
            ;; An explicitly shown launcher may be selected, or replaced below.
            (if (and (eq (selected-frame) portal-launcher--frame)
                     (window-live-p portal-launcher--return-window))
                portal-launcher--return-window
              (selected-window)))
           (previous-frame (window-frame previous-window))
           (session (portal-launcher--make-session :tag (make-symbol "launcher-session")))
           (portal-launcher--session session)
           (emulation-mode-map-alists
            (cons `((portal-launcher--session . ,portal-launcher--session-map)) emulation-mode-map-alists))
           (enable-recursive-minibuffers t)
           (minibuffer-follows-selected-frame nil)
           ;; The panel keeps its native placement; Emacs must not fit it.
           (resize-mini-frames nil)
           (portal-launcher--mode-line-parameters nil)
           (windows nil)
           (outcome 'error))
      (unwind-protect
          (setq outcome
                (catch (portal-launcher--session-tag session)
                  (condition-case nil
                      (let ((buffer (get-buffer-create "*Portal Launcher*")))
                        (let ((portal-launcher--session nil))
                          (portal-launcher--show kind buffer mode-line))
                        (when (eq kind 'buffer)
                          (setq windows (window-list portal-launcher--frame 'never)))
                        (setf (portal-launcher--session-native-id session)
                              (plist-get (portal--launcher-inspect) :session))
                        (when (and (eq kind 'buffer) (not mode-line))
                          (add-hook 'window-buffer-change-functions #'portal-launcher--hide-mode-lines))
                        (add-hook 'post-command-hook #'portal-launcher--dismiss-if-blurred)
                        (let ((default-minibuffer-frame portal-launcher--frame)
                              (display-buffer-alist nil)
                              (display-buffer-overriding-action
                               (if (eq kind 'minibuffer)
                                   '((display-buffer-no-window) (allow-no-window . t))
                                 `((display-buffer-reuse-window display-buffer-pop-up-window)
                                   (reusable-frames . ,portal-launcher--frame)
                                   (inhibit-switch-frame . t))))
                              (pop-up-frames nil))
                          (let ((value (with-current-buffer buffer
                                         (if (commandp function)
                                             (call-interactively function)
                                           (funcall function)))))
                            (if (not keep-open)
                                (cons 'success value)
                              ;; The panel's commands run here, inside the
                              ;; session, until a dismissal throws. Leaving
                              ;; the recursive edit otherwise also cancels.
                              ;; Its command loop runs `post-command-hook'
                              ;; first, so focus lost during setup counts.
                              (recursive-edit)
                              'cancel))))
                    (quit 'cancel))))
        ;; This runs outside all minibuffers, even when cancellation came from
        ;; the innermost prompt. Clear ownership before deleting/disabling.
        (let ((inhibit-quit t) (portal-launcher--session nil))
          (unwind-protect
              (when (frame-live-p portal-launcher--frame)
                (portal--launcher-hide (not (or (consp outcome) (eq outcome 'blur))))
                (make-frame-invisible portal-launcher--frame t)
                (portal-launcher--restore-windows windows))
            (remove-hook 'window-buffer-change-functions #'portal-launcher--hide-mode-lines)
            (remove-hook 'post-command-hook #'portal-launcher--dismiss-if-blurred)
            (portal-launcher--forget-blur)
            (pcase-dolist (`(,window . ,value) portal-launcher--mode-line-parameters)
              (when (window-live-p window)
                (set-window-parameter window 'mode-line-format value)))
            (cond ((window-live-p previous-window) (select-window previous-window 'norecord))
                  ((frame-live-p previous-frame) (select-frame previous-frame 'norecord)))
            (setq portal-launcher--return-window nil)
            (pcase (portal-launcher--session-teardown session)
              ('delete (when (frame-live-p portal-launcher--frame)
                         (delete-frame portal-launcher--frame t)))
              ('disable (portal-launcher--disable))))))
      (when (consp outcome) (cdr outcome)))))

;;;###autoload
(defun portal-launcher-toggle ()
  "Toggle the launcher, running `portal-launcher-command' when configured."
  (interactive)
  (when portal-launcher--session (portal-launcher-cancel))
  (if (and portal-launcher-mode (plist-get (portal--launcher-inspect) :visible))
      (portal-launcher-hide)
    (if portal-launcher-command (portal-launcher-present)
      (portal-launcher-show
       (unless (portal-launcher--live-p 'buffer)
         (get-buffer-create "*Portal Launcher*"))))))

(defun portal-launcher--create (kind)
  "Create and attach one new dedicated frame for KIND, rolling back on failure."
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
                                    (portal-launcher--frame-role kind)
                                    portal-launcher-frame-parameters)))
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
With no BUFFER, reuse its content; the first show uses the current buffer,
as does the first after a minibuffer presentation replaced the frame.
Interactively prompt for a buffer. This explicitly opts in to
`portal-launcher-mode'. Size and presentation customizations apply each time."
  (interactive (list (read-buffer "Launcher buffer: " (current-buffer) t)))
  (portal-launcher--show 'buffer buffer t))

(defun portal-launcher--show (kind buffer mode-line)
  "Show the launcher for KIND of presentation and return its frame.
A buffer launcher shows BUFFER if non-nil, and hides its windows' mode
lines unless MODE-LINE. A frame made for the other kind is replaced."
  (when (and buffer (not (buffer-live-p (get-buffer buffer))))
    (user-error "Launcher buffer is not live: %s" buffer))
  (let ((placement (portal-launcher--placement))
        (buffer (if buffer (get-buffer buffer)
                  (unless (portal-launcher--live-p kind) (current-buffer)))))
    (unless portal-launcher-mode (portal-launcher-mode 1))
    ;; A frame's minibuffer role is fixed, so a new kind needs a new frame.
    ;; Delete before capturing focus: detaching forgets the captured app.
    (when (and (frame-live-p portal-launcher--frame) (not (portal-launcher--live-p kind)))
      (delete-frame portal-launcher--frame t))
    (portal--launcher-prepare)
    (unless (frame-live-p portal-launcher--frame) (portal-launcher--create kind))
    (unless (eq (selected-frame) portal-launcher--frame)
      (setq portal-launcher--return-window (selected-window)))
    (when (eq kind 'buffer)
      (when buffer (set-window-buffer (frame-selected-window portal-launcher--frame) buffer))
      (unless mode-line (portal-launcher--hide-mode-lines portal-launcher--frame)))
    (when portal-launcher-font
      (let ((frame-inhibit-implied-resize t))
        (set-frame-font portal-launcher-font nil (list portal-launcher--frame))))
    (condition-case error
        (progn
          (select-frame portal-launcher--frame 'norecord)
          (apply #'portal--launcher-show placement)
          (when portal-launcher--session
            (setf (portal-launcher--session-native-id portal-launcher--session)
                  (plist-get (portal--launcher-inspect) :session)))
          ;; Native visibility alone does not enable Emacs redisplay.
          (make-frame-visible portal-launcher--frame)
          (redisplay t)
          portal-launcher--frame)
      (error
       (unless portal-launcher--session (portal-launcher-hide))
       (signal (car error) (cdr error))))))

;;;###autoload
(defun portal-launcher-hide ()
  "Hide the launcher, retaining its frame, buffer and window state.
An active command session is cancelled before hiding its minibuffers."
  (interactive)
  (when portal-launcher--session (portal-launcher-cancel))
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
