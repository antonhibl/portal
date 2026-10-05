;;; portal-launcher.el --- A dedicated native launcher frame -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Opt-in and build-restricted: this moves Emacs's internal NS view. A native
;; defect can crash Emacs. Loading this file creates no frame or shortcut.
;; Presenting claims no chord and Portal chooses no command: user
;; configuration composes launchers from `portal-launcher-present' and, when
;; a chord should invoke one from any application, `portal-global-shortcut-set'.
(require 'portal-view)
(require 'subr-x)

(declare-function portal--launcher-attach "portal-launcher" (title))
(declare-function portal--launcher-prepare "portal-launcher" ())
(declare-function portal--launcher-show "portal-launcher" (width height dx dy screen shadow radius))
(declare-function portal--launcher-fit "portal-launcher" (session height))
(declare-function portal--launcher-hide "portal-launcher" (&optional restore-focus))
(declare-function portal--launcher-detach "portal-launcher" ())
(declare-function portal--launcher-inspect "portal-launcher" ())

(defgroup portal-launcher nil "An Emacs buffer in a native macOS panel." :group 'frames)

(defvar portal-launcher-mode nil)

(cl-defstruct (portal-launcher--session (:constructor portal-launcher--make-session))
  tag native-id teardown blurred
  ;; nil for a fixed size; for an automatic height, the last height asked
  ;; of the native panel, or t before the first.
  fit)
(defvar portal-launcher--session nil "The active command session, or nil.")

(defconst portal-launcher--session-map
  (let ((map (make-sparse-keymap)))
    (define-key map [escape] #'portal-launcher-cancel)
    (define-key map (kbd "C-g") #'portal-launcher-cancel)
    map)
  "Keys active only while a launcher command is running.")

(defcustom portal-launcher-size nil
  "Launcher width and height in AppKit logical points, or nil.
nil, the default, gives a minibuffer panel width 720 and an automatic
height, and a buffer panel 720 by 420. (WIDTH auto) gives a minibuffer
panel WIDTH and an automatic height; a buffer panel cannot fit its
content, so presenting or showing one signals an error. (WIDTH HEIGHT)
fixes both dimensions for both kinds of panel. WIDTH is an integer of at
least 200 and HEIGHT one of at least 100.

An automatic height follows what the minibuffer displays: its prompt,
input and completion rows, including group titles and messages inline in
the minibuffer, with the frame's internal borders. It changes as these
change, never below 100 points. The width and top edge stay where the
panel opened; only the bottom edge moves, and stops at the bottom of the
usable area. Each presentation reads this value, including a `let'
binding of it. The panel is clamped to the monitor's usable area.
Retina backing scale does not change these units."
  :type '(choice (const :tag "Fit minibuffer panels; buffer panels 720 by 420" nil)
                 (list :tag "Size" (integer :tag "Width")
                       (choice (const :tag "Fit minibuffer content" auto)
                               (integer :tag "Height")))))

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
  (portal-launcher--hooks nil)
  (portal-launcher--forget-blur)
  (setq portal-launcher-mode nil))

;;;###autoload
(define-minor-mode portal-launcher-mode
  "Portal's build-restricted native launcher panel.
Presenting or showing the panel enables this mode, which validates the
Emacs build and installs the panel's frame guards and lifecycle hooks.
Enabling creates no frame and registers no global shortcut; an init file
need not enable it. Disabling cancels an active presentation, restores the
native window, deletes the dedicated frame and removes the guards, and
leaves every global shortcut set. A native defect can crash the hosting
Emacs; start in a disposable Emacs."
  :global t :group 'portal-launcher
  (if portal-launcher-mode
      (condition-case error
          (progn
            (portal-launcher--check-support)
            (portal-view--load)
            (unless (and (fboundp 'portal--launcher-attach)
                         (fboundp 'portal--launcher-prepare))
              (user-error "Rebuild Portal and restart Emacs for launcher support"))
            (portal-launcher--hooks t)
            (portal-launcher--check-guard))
        (error
         ;; A live panel keeps its guards: its frame must detach on deletion.
         (unless (frame-live-p portal-launcher--frame)
           (portal-launcher--hooks nil)
           (setq portal-launcher-mode nil))
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
(defun portal-launcher-present (function &rest options)
  "Present FUNCTION in the launcher, hide it and return FUNCTION's value.
FUNCTION is an interactive command, called with `call-interactively' so it
sees any prefix argument, or a function of no arguments, called with
`funcall'. It runs with the buffer *Portal Launcher* current.

Presenting registers no global shortcut. To invoke a launcher, define a
command that calls this function with its options, then run it with M-x,
bind it to a key or set it as a global shortcut with
`portal-global-shortcut-set'.

OPTIONS are keywords, each followed by its value:
:kind `buffer', the default, shows a buffer window above the panel's own
  minibuffer. Buffers that FUNCTION displays show in the panel, and windows
  it creates there are deleted when the panel hides; earlier ones stay.
  `minibuffer' makes the whole panel a minibuffer: its prompts and an inline
  completion UI, such as Vertico, start at the top. Buffers that FUNCTION
  displays, including stock completion's *Completions* list, show nowhere,
  so commands that display buffers or need windows require `buffer'.
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
`portal-launcher-size' sets each kind's size. By default, a minibuffer
panel's height follows what it displays, as that changes, with its top
edge fixed; a buffer panel is 720 by 420 points. Content taller than the
panel, at a fixed height or the bottom of the screen, is clipped at the
bottom. An invalid FUNCTION, option or launcher setting signals an error
before anything is shown or an active session is cancelled.

A second invocation, such as the same global shortcut pressed again,
cancels the active session and presents nothing, so a command bound to a
chord toggles its panel. Escape, C-g, errors and focus loss unwind nested
prompts before hiding; completion, display and presentation settings are
scoped to this call. Cancellation restores the previous application's
focus only if the panel still owns it. Success and click-away never
activate the previous app. Functions that catch arbitrary throws or
deliberately select other frames are outside this interface. Do not invoke
from an existing minibuffer."
  (portal-launcher--check-function function)
  (pcase-let* ((`(,kind ,mode-line ,keep-open) (portal-launcher--options options))
               (fit (eq 'auto (nth 1 (portal-launcher--placement kind)))))
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
           (session (portal-launcher--make-session :tag (make-symbol "launcher-session") :fit fit))
           (portal-launcher--session session)
           (emulation-mode-map-alists
            (cons `((portal-launcher--session . ,portal-launcher--session-map)) emulation-mode-map-alists))
           (enable-recursive-minibuffers t)
           (minibuffer-follows-selected-frame nil)
           ;; Emacs's own fitting would move and resize the natively placed
           ;; panel. An automatic height fits it natively instead.
           (resize-mini-frames (and fit #'portal-launcher--fit))
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
                        (when fit (add-hook 'post-command-hook #'portal-launcher--refit))
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
            (remove-hook 'post-command-hook #'portal-launcher--refit)
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

(defun portal-launcher--size (kind)
  "Return the (WIDTH HEIGHT) of KIND of panel that `portal-launcher-size' sets.
HEIGHT is `auto' for a minibuffer panel that fits its content. Signal a
`user-error' if the setting is invalid, or automatic for a buffer panel."
  (let ((size (or portal-launcher-size (list 720 (if (eq kind 'minibuffer) 'auto 420)))))
    (unless (and (proper-list-p size) (= (length size) 2)
                 (integerp (car size)) (>= (car size) 200)
                 (or (eq (cadr size) 'auto)
                     (and (integerp (cadr size)) (>= (cadr size) 100))))
      (user-error "Launcher size is nil, (WIDTH auto) or (WIDTH HEIGHT), at least 200 by 100, not %S"
                  size))
    (when (and (eq (cadr size) 'auto) (not (eq kind 'minibuffer)))
      (user-error "Only a minibuffer launcher fits its content; give buffer panels a numeric height, not %S"
                  size))
    size))

(defun portal-launcher--placement (kind)
  "Return validated native arguments to present KIND, without modifying a frame.
The height is `auto' for a minibuffer panel that fits its content."
  (let ((size (portal-launcher--size kind)))
    (unless (and (proper-list-p portal-launcher-offset) (= (length portal-launcher-offset) 2)
                 (cl-every #'integerp portal-launcher-offset)
                 (or (null portal-launcher-screen) (natnump portal-launcher-screen))
                 (natnump portal-launcher-corner-radius))
      (user-error "Invalid launcher offset, screen or corner radius"))
    (append size portal-launcher-offset
            (list (or portal-launcher-screen -1) portal-launcher-shadow portal-launcher-corner-radius))))

(defun portal-launcher--fitted-height (frame)
  "Return the native height that fits what minibuffer-only FRAME displays.
This measures the minibuffer as Emacs displays it at its current width,
so wrapped lines and overlay strings, such as an inline completion UI's
candidates, count. The frame's other rows, such as its internal borders,
count once. The result is at least the native minimum of 100 points; on
NS, Emacs's frame pixels are the panel's logical points."
  (let* ((window (minibuffer-window frame))
         ;; The panel cannot be taller than the display: measure no further.
         (text (cdr (window-text-pixel-size window nil nil nil (display-pixel-height frame)))))
    (max 100 (+ text (- (frame-pixel-height frame) (window-body-height window t))))))

(defun portal-launcher--fit (frame)
  "Fit the presentation's automatic minibuffer panel FRAME to its content.
As `resize-mini-frames' during that presentation, Emacs calls this while
it redisplays a minibuffer-only frame's active minibuffer that may have
changed, after the commands, timers and completion UI that changed it.
It only asks the native panel for a new height, never redisplaying or
presenting, and only when that height differs from the last one asked.
Emacs then redisplays the frame at the new size, whose content is the
same. An echo area message, which briefly replaces the minibuffer's
buffer, keeps the input's height; messages inline in the minibuffer fit.
`portal-launcher--refit' calls this after commands as well."
  (when-let* ((session portal-launcher--session)
              (last (portal-launcher--session-fit session))
              (id (portal-launcher--session-native-id session))
              ((eq frame portal-launcher--frame))
              ((frame-live-p frame))
              ((frame-visible-p frame))
              ((minibufferp (window-buffer (minibuffer-window frame))))
              (height (portal-launcher--fitted-height frame))
              ((not (eql height last))))
    (setf (portal-launcher--session-fit session) height)
    (portal--launcher-fit id height)))

(defun portal-launcher--refit ()
  "Fit an automatic minibuffer panel after a command, or as a prompt starts.
Redisplay fits content that changed, but can miss a nested prompt
starting or ending: Emacs compares the minibuffer window's record of
the last buffer it showed with the next buffer's changes. A command
loop runs this as each prompt starts, and the command that read an
inner prompt ends with this in the outer one."
  (portal-launcher--fit portal-launcher--frame))

;;;###autoload
(defun portal-launcher-show (&optional buffer)
  "Show BUFFER in the dedicated launcher and return its frame.
With no BUFFER, reuse its content; the first show uses the current buffer,
as does the first after a minibuffer presentation replaced the frame.
Interactively prompt for a buffer. This enables `portal-launcher-mode',
which registers no shortcut. Size and presentation customizations apply
each time."
  (interactive (list (read-buffer "Launcher buffer: " (current-buffer) t)))
  (portal-launcher--show 'buffer buffer t))

(defun portal-launcher--show (kind buffer mode-line)
  "Show the launcher for KIND of presentation and return its frame.
A buffer launcher shows BUFFER if non-nil, and hides its windows' mode
lines unless MODE-LINE. A frame made for the other kind is replaced."
  (when (and buffer (not (buffer-live-p (get-buffer buffer))))
    (user-error "Launcher buffer is not live: %s" buffer))
  (let ((placement (portal-launcher--placement kind))
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
          ;; Open at the height of what the minibuffer shows now, normally
          ;; the minimum: the prompt comes later. This first placement
          ;; fixes the top edge, so later content grows the panel down.
          (when (eq (nth 1 placement) 'auto)
            (setf (nth 1 placement) (portal-launcher--fitted-height portal-launcher--frame)))
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

(defun portal-launcher--check-resize ()
  "Refuse to resize during a minibuffer presentation."
  (when (and portal-launcher--session (portal-launcher--live-p 'minibuffer))
    (user-error "A minibuffer launcher cannot become a buffer panel; resize after it closes")))

(defun portal-launcher-resize (width height)
  "Fix the launcher at WIDTH by HEIGHT logical points and show it again.
This sets `portal-launcher-size' for both kinds of panel, so minibuffer
panels stop fitting their content until it is nil or (WIDTH auto) again.
Showing uses the buffer launcher, as `portal-launcher-show' does, so
during a minibuffer presentation this signals an error and changes
nothing. Interactively, prompt with the current numeric dimensions, or
720 by 420."
  (interactive
   (progn
     (portal-launcher--check-resize)
     (let ((size portal-launcher-size))
       (list (read-number "Width (points): " (if (integerp (car-safe size)) (car size) 720))
             (read-number "Height (points): "
                          (if (integerp (car-safe (cdr-safe size))) (cadr size) 420))))))
  (portal-launcher--check-resize)
  (let ((portal-launcher-size (list width height))) (portal-launcher-show))
  (setq portal-launcher-size (list width height)))

(defun portal-launcher-unload-function ()
  "Restore native ownership before unloading this feature."
  (portal-launcher--disable)
  nil)

(provide 'portal-launcher)
;;; portal-launcher.el ends here
