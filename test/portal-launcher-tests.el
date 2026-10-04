;;; portal-launcher-tests.el --- Launcher policy checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-launcher)

(ert-deftest portal-launcher-load-is-inert ()
  (should-not (featurep 'launcher))
  (should-not portal-launcher-mode)
  (should-not portal-launcher--frame)
  (should-not portal-global-shortcut--registrations)
  (should-not (memq #'portal-launcher--before-delete delete-frame-functions))
  (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters)))

(ert-deftest portal-launcher-missing-application-package-explains-setup ()
  ;; This suite runs in -Q without the optional package on load-path.
  (should-not (locate-library "launcher"))
  (should (string-match-p
           "Install launcher.el.*load-path"
           (error-message-string (should-error (portal-launcher-applications) :type 'user-error)))))

(ert-deftest portal-launcher-rejects-unsupported-before-loading ()
  (let ((emacs-repository-version "unvalidated")
        (frames (frame-list)))
    (cl-letf (((symbol-function 'portal-view--load) (lambda () (ert-fail "Loaded native code"))))
      (should-error (portal-launcher-show) :type 'user-error)
      (should-not portal-launcher-mode)
      (should (equal frames (frame-list))))))

(ert-deftest portal-launcher-rejects-invalid-input-before-enabling ()
  (dolist (size '(nil (199 420) (720 99) (720) (720 420 3) (720 . 420) (720 420.5)))
    (let ((portal-launcher-size size))
      (should-error (portal-launcher-show) :type 'user-error)))
  (let ((portal-launcher-offset '(0))) (should-error (portal-launcher-show) :type 'user-error))
  (let ((portal-launcher-screen -1)) (should-error (portal-launcher-show) :type 'user-error))
  (let ((portal-launcher-corner-radius -1)) (should-error (portal-launcher-show) :type 'user-error))
  (should-error (portal-launcher-show "missing launcher test buffer") :type 'user-error)
  (should-not portal-launcher-mode))

(ert-deftest portal-launcher-requires-guard-for-native-callers ()
  (skip-unless (featurep 'native-compile))
  (let ((comp-installed-trampolines-h (make-hash-table)))
    (should-error (portal-launcher--check-guard) :type 'user-error)
    (puthash 'modify-frame-parameters t comp-installed-trampolines-h)
    (should-error (portal-launcher--check-guard) :type 'user-error)
    (puthash 'delete-frame t comp-installed-trampolines-h)
    (should-not (portal-launcher--check-guard))))

(ert-deftest portal-launcher-failed-enable-removes-partial-hooks ()
  (skip-unless (featurep 'native-compile))
  (let ((comp-installed-trampolines-h (make-hash-table))
        (native-comp-enable-subr-trampolines nil))
    (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
              ((symbol-function 'portal-view--load) #'ignore)
              ((symbol-function 'portal--launcher-attach) #'ignore)
              ((symbol-function 'portal--launcher-prepare) #'ignore)
              ((symbol-function 'portal--shortcut-set) #'ignore))
      (should-error (portal-launcher-mode 1) :type 'user-error)
      (should-not portal-launcher-mode)
      (should-not portal-launcher--frame)
      (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters))
      (should-not (memq #'portal-launcher--before-delete delete-frame-functions)))))

(ert-deftest portal-launcher-role-guard-is-atomic-and-scoped ()
  (let ((portal-launcher--frame (selected-frame)) passed)
    (dolist (change '((undecorated . nil) (fullscreen . fullboth) (parent-frame . other)
                      (tool-bar-lines . 1) (no-focus-on-map . nil) (minibuffer . nil)))
      (should-error
       (portal-launcher--guard-parameters
        (lambda (&rest _) (ert-fail "Mutated frame")) nil
        (list '(background-color . "red") change))
       :type 'user-error))
    (portal-launcher--guard-parameters
     (lambda (_frame parameters) (setq passed parameters)) nil
     '((parent-frame . nil) (undecorated . t) (font . "Menlo 18") (ns-appearance . dark)))
    (should (equal passed '((font . "Menlo 18") (ns-appearance . dark)))))
  (let ((portal-launcher--frame (selected-frame)) passed)
    (cl-letf (((symbol-function 'portal-launcher--kind) (lambda (_frame) 'minibuffer)))
      (should-error
       (portal-launcher--guard-parameters
        (lambda (&rest _) (ert-fail "Mutated frame")) nil '((minibuffer . t)))
       :type 'user-error)
      (portal-launcher--guard-parameters
       (lambda (_frame parameters) (setq passed parameters)) nil
       '((minibuffer . only) (undecorated . t) (font . "Menlo 18"))))
    (should (equal passed '((font . "Menlo 18")))))
  ;; Each kind's role is the buffer role but for the minibuffer.
  (dolist (kind '(minibuffer minibuffer buffer))
    (should (equal (assq-delete-all 'minibuffer (copy-alist (portal-launcher--frame-role kind)))
                   (assq-delete-all 'minibuffer (copy-alist portal-launcher--role)))))
  (should (equal (assq 'minibuffer (portal-launcher--frame-role 'minibuffer)) '(minibuffer . only)))
  (should (equal (assq 'minibuffer portal-launcher--role) '(minibuffer . t)))
  (let (portal-launcher--frame)
    (should (equal
             (portal-launcher--guard-parameters (lambda (_frame parameters) parameters)
                                                nil '((fullscreen . fullboth)))
             '((fullscreen . fullboth))))))

(ert-deftest portal-launcher-disable-removes-hooks-without-a-frame ()
  (let ((native-comp-enable-subr-trampolines nil))
    (unwind-protect
        (progn
          (portal-launcher--hooks t)
          (portal-launcher--hooks t)
          (portal-launcher-mode -1)
          (portal-launcher-mode -1)
          (should-not (memq #'portal-launcher--before-delete delete-frame-functions))
          (should-not (memq #'portal-launcher--shutdown kill-emacs-hook))
          (should-not (advice-member-p #'portal-launcher--guard-parameters #'modify-frame-parameters)))
      (portal-launcher--hooks nil))))

(defmacro portal-launcher-test--registration (&rest body)
  "Exercise Lisp enable/rebind with a native registration stand-in.
NATIVE-CHORD is the chord native code has, \"\" once released; macOS
refuses the chord \"conflict\".  OTHER is another global shortcut."
  (declare (indent 0))
  `(let ((portal-launcher-mode nil)
         (portal-global-shortcut--registrations nil)
         (portal-view-feature-record-handlers nil)
         (kill-emacs-hook nil)
         (portal-launcher-shortcut "Control-Option-Command-P")
         (native-comp-enable-subr-trampolines nil)
         (unread-command-events nil)
         native-chord (token 0))
     (cl-letf (((symbol-function 'portal-launcher--check-support) #'ignore)
               ((symbol-function 'portal-launcher--check-guard) #'ignore)
               ((symbol-function 'portal-view--load) #'ignore)
               ((symbol-function 'portal--launcher-attach) #'ignore)
               ((symbol-function 'portal--launcher-prepare) #'ignore)
               ((symbol-function 'portal--shortcut-chord) #'identity)
               ((symbol-function 'portal--shortcut-set)
                (lambda (_replacing chord)
                  (when (equal chord "conflict") (error "Shortcut conflict"))
                  (unless (equal chord "other") (setq native-chord chord))
                  (cl-incf token)))
               ((symbol-function 'portal--shortcut-remove)
                (lambda (id)
                  (when (eql id (portal-launcher-test--id)) (setq native-chord ""))
                  t)))
       (portal-global-shortcut-set 'other "other" #'ignore)
       (unwind-protect (progn ,@body)
         (portal-launcher-mode -1)
         ;; Disabling releases the launcher's chord and no other shortcut.
         (should (member native-chord '(nil "")))
         (should (assq 'other portal-global-shortcut--registrations))))))

(defun portal-launcher-test--id ()
  "The native ID of the launcher's global shortcut, or nil."
  (cadr (assq 'portal-launcher portal-global-shortcut--registrations)))

(ert-deftest portal-launcher-registration-and-customization-are-atomic ()
  (portal-launcher-test--registration
    (portal-launcher-mode 1)
    (portal-launcher-mode 1)
    (should (equal (mapcar #'car portal-global-shortcut--registrations) '(other portal-launcher)))
    (should (equal (nth 3 (assq 'portal-launcher portal-global-shortcut--registrations))
                   #'portal-launcher-toggle))
    (let ((first (portal-launcher-test--id)))
      (should-error (portal-launcher--set-shortcut 'portal-launcher-shortcut "conflict"))
      (should (equal portal-launcher-shortcut "Control-Option-Command-P"))
      (should (= first (portal-launcher-test--id)))
      (let ((portal-launcher-shortcut "conflict"))
        (should-error (portal-launcher-mode 1))
        (should portal-launcher-mode)
        (should (= first (portal-launcher-test--id))))
      (portal-launcher--set-shortcut 'portal-launcher-shortcut "Control-Option-Command-L")
      (should-not (= first (portal-launcher-test--id)))
      (should (equal native-chord "Control-Option-Command-L")))
    (portal-launcher-mode -1)
    (should-not (portal-launcher-test--id))
    (should (equal native-chord ""))
    (portal-launcher-mode -1)
    (portal-launcher-mode 1)
    (should (portal-launcher-test--id))))

(ert-deftest portal-launcher-failed-first-registration-leaves-disabled ()
  (portal-launcher-test--registration
    (let ((portal-launcher-shortcut "conflict"))
      (should-error (portal-launcher-mode 1))
      (should-not portal-launcher-mode)
      (should-not (portal-launcher-test--id))
      (should-not (assoc "launcher-blur" portal-view-feature-record-handlers))
      (should-not (memq #'portal-launcher--before-delete delete-frame-functions)))))

(ert-deftest portal-launcher-shortcut-is-a-global-shortcut ()
  (portal-launcher-test--registration
    (portal-launcher-mode 1)
    (let ((invocations 0) (portal-view--pending ""))
      (cl-letf (((symbol-function 'portal-launcher-toggle)
                 (lambda () (interactive) (cl-incf invocations))))
        (cl-flet ((press ()
                    (portal-view--receive nil (format "shortcut %s\n" (portal-launcher-test--id)))
                    (pop unread-command-events)))
          ;; No Portal view exists; the record still reaches the command loop.
          (let ((event (press)))
            (should (= invocations 0))
            (portal-global-shortcut--run event)
            (should (= invocations 1)))
          ;; A press from before a rebind, or a disable, is ignored.
          (let ((event (press)))
            (portal-launcher--set-shortcut 'portal-launcher-shortcut "Control-Option-Command-L")
            (portal-global-shortcut--run event)
            (should (= invocations 1)))
          (let ((event (press)))
            (portal-launcher-mode -1)
            (portal-global-shortcut--run event)
            (portal-launcher-mode 1)
            (portal-global-shortcut--run event)
            (should (= invocations 1)))
          (portal-global-shortcut--run (press))
          (should (= invocations 2)))))))

(ert-deftest portal-launcher-failed-deletion-retains-registration ()
  (portal-launcher-test--registration
    (portal-launcher-mode 1)
    (let ((portal-launcher--frame (selected-frame))
          (before (portal-launcher-test--id)))
      (cl-letf (((symbol-function 'delete-frame) (lambda (&rest _) (error "Active minibuffer"))))
        (should-error (portal-launcher-mode -1)))
      (should portal-launcher-mode)
      (should (= before (portal-launcher-test--id)))
      (should-not (equal native-chord "")))))

(ert-deftest portal-launcher-command-validation-precedes-native-work ()
  (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (ert-fail "Presented invalid command")))
            ((symbol-function 'portal-launcher-cancel) (lambda () (ert-fail "Cancelled the session"))))
    (dolist (command (list nil 'identity 42 "string" (lambda (_x) nil)))
      (let ((portal-launcher-command command))
        (should-error (portal-launcher-present) :type 'user-error)))
    ;; Invalid options, even with a valid function, change nothing; an active
    ;; session would be cancelled before anything is shown.
    (let ((portal-launcher--session (portal-launcher--make-session :tag (make-symbol "active"))))
      (dolist (options '((:kind) (:kind nil) (:kind window) (:kind minibuffer :mode-line)
                         (:mode-line none) (:mode-line 0) (:size 3) (minibuffer)))
        (should-error (apply #'portal-launcher-present #'ignore options) :type 'user-error))
      (should-error (portal-launcher-present (lambda (_x) nil) :kind 'minibuffer) :type 'user-error))))

(ert-deftest portal-launcher-options-default-to-a-buffer-with-mode-lines ()
  (should (equal (portal-launcher--options nil) '(buffer t)))
  (should (equal (portal-launcher--options '(:kind minibuffer)) '(minibuffer t)))
  (should (equal (portal-launcher--options '(:mode-line nil :kind buffer)) '(buffer nil)))
  (should (equal (portal-launcher--options '(:kind minibuffer :mode-line nil)) '(minibuffer nil))))

(defmacro portal-launcher-test--session (&rest body)
  "Exercise real session unwinding with only the native frame stubbed."
  (declare (indent 0))
  `(let ((portal-launcher--frame (selected-frame))
         (native-comp-enable-subr-trampolines nil)
         (portal-launcher--session nil) (unread-command-events nil)
         (hidden nil) (shown nil) (session-id 10) (deleted 0) (disabled 0))
     (cl-letf (((symbol-function 'portal-launcher--show)
                (lambda (kind _buffer mode-line) (push (list kind mode-line) shown)))
               ((symbol-function 'portal--launcher-inspect) (lambda () (list :session session-id)))
               ((symbol-function 'portal--launcher-hide) (lambda (&optional restore) (push restore hidden)))
               ((symbol-function 'make-frame-invisible) #'ignore)
               ((symbol-function 'delete-frame) (lambda (&rest _) (cl-incf deleted)))
               ((symbol-function 'portal-launcher--disable) (lambda () (cl-incf disabled))))
       ,@body)))

(ert-deftest portal-launcher-command-success-error-and-quit ()
  (portal-launcher-test--session
    (let ((old-rules display-buffer-alist)
          (old-maps emulation-mode-map-alists))
      (should (= 42 (portal-launcher-present (lambda () (interactive) 42))))
      (should (equal hidden '(nil)))
      (should-error (portal-launcher-present (lambda () (interactive) (error "Command failed"))))
      (should (equal hidden '(t nil)))
      (should-not (portal-launcher-present (lambda () (interactive) (signal 'quit nil))))
      (should (equal hidden '(t t nil)))
      (should (eq old-rules display-buffer-alist))
      (should (eq old-maps emulation-mode-map-alists))
      (should-not portal-launcher--session))))

(ert-deftest portal-launcher-calls-commands-and-functions ()
  (portal-launcher-test--session
    (should (eq 'value (portal-launcher-present (lambda () 'value))))
    (should (equal "*Portal Launcher*" (portal-launcher-present (lambda () (buffer-name)) :kind 'minibuffer)))
    ;; A command reads the caller's prefix argument; a plain function is not
    ;; called interactively.
    (let ((current-prefix-arg '(4)))
      (should (equal '(4) (portal-launcher-present (lambda (arg) (interactive "P") arg))))
      (should (equal '((4) nil) (portal-launcher-present
                               (lambda (&optional arg) (list current-prefix-arg arg))
                               :kind 'minibuffer))))
    (let ((portal-launcher-command #'portal-launcher-test--command))
      (should (eq 'command (portal-launcher-present nil :kind 'buffer :mode-line nil))))
    (should (equal shown '((buffer nil) (minibuffer t) (buffer t) (minibuffer t) (buffer t))))
    (should (equal hidden '(nil nil nil nil nil)))
    (should-not portal-launcher--session)))

(ert-deftest portal-launcher-loads-autoloads-to-check-arguments ()
  ;; An autoloaded function that is not a command is called at once, so it
  ;; is loaded to count its arguments before anything is shown or cancelled.
  (let* ((directory (make-temp-file "portal-launcher-lazy" t))
         (load-path (cons directory load-path)))
    (unwind-protect
        (progn
          (dolist (library '(("portal-launcher-test-lazy-1" . "(x) x")
                             ("portal-launcher-test-lazy-0" . "() 'lazy")))
            (with-temp-file (expand-file-name (concat (car library) ".el") directory)
              (insert ";;; -*- lexical-binding: t; -*-\n"
                      (format "(defun %s--run %s)\n(provide '%s)\n"
                              (car library) (cdr library) (car library))))
            (autoload (intern (concat (car library) "--run")) (car library)))
          (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (ert-fail "Presented")))
                    ((symbol-function 'portal-launcher-cancel) (lambda () (ert-fail "Cancelled"))))
            (let ((portal-launcher--session (portal-launcher--make-session :tag (make-symbol "active"))))
              (should-error (portal-launcher-present 'portal-launcher-test-lazy-1--run)
                            :type 'user-error)))
          (portal-launcher-test--session
            (should (autoloadp (symbol-function 'portal-launcher-test-lazy-0--run)))
            (should (eq 'lazy (portal-launcher-present 'portal-launcher-test-lazy-0--run)))))
      (dolist (name '(portal-launcher-test-lazy-1 portal-launcher-test-lazy-0))
        (fmakunbound (intern (format "%s--run" name)))
        (setq features (delq name features)))
      (delete-directory directory t))))

(defun portal-launcher-test--command ()
  (interactive)
  'command)

(ert-deftest portal-launcher-presentation-settings-are-scoped ()
  (portal-launcher-test--session
    (let ((resize-mini-frames 'user-setting)
          (window-buffer-change-functions (list #'ignore))
          (frame (selected-frame))
          (other (get-buffer-create " *launcher test*")))
      ;; A minibuffer presentation displays no buffer, here or elsewhere.
      (should (equal '(nil nil 1)
                     (portal-launcher-present
                      (lambda ()
                        (list (display-buffer other) resize-mini-frames
                              (length (window-list frame 'never))))
                      :kind 'minibuffer)))
      (should-not (get-buffer-window other t))
      ;; A buffer presentation hides new windows' mode lines through the
      ;; session's redisplay hook, then deletes them and clears the parameter.
      (should (equal '((none none) (portal-launcher--hide-mode-lines ignore))
                     (portal-launcher-present
                      (lambda ()
                        (let ((window (display-buffer other)))
                          (run-hook-with-args 'window-buffer-change-functions frame)
                          (list (mapcar (lambda (window) (window-parameter window 'mode-line-format))
                                        (list (selected-window) window))
                                window-buffer-change-functions)))
                      :mode-line nil)))
      (should (equal '(ignore) window-buffer-change-functions))
      (should (eq resize-mini-frames 'user-setting))
      (should (= 1 (length (window-list frame 'never))))
      (should-not (window-parameter (selected-window) 'mode-line-format))
      ;; With mode lines, the hook is absent and new windows still go.
      (should (equal '(nil (ignore))
                     (portal-launcher-present
                      (lambda ()
                        (list (window-parameter (display-buffer other) 'mode-line-format)
                              window-buffer-change-functions)))))
      (should (= 1 (length (window-list frame 'never))))
      ;; Errors and cancellation restore the same state.
      (dolist (ending (list (lambda () (error "Command failed")) (lambda () (signal 'quit nil))
                            #'portal-launcher-cancel))
        (ignore-errors
          (portal-launcher-present
           (lambda () (display-buffer other) (funcall ending)) :mode-line nil)))
      (should (equal '(ignore) window-buffer-change-functions))
      (should (= 1 (length (window-list frame 'never))))
      (should-not (window-parameter (selected-window) 'mode-line-format))
      ;; A window's own mode-line parameter outlasts either setting.
      (set-window-parameter (selected-window) 'mode-line-format '("custom"))
      (should (eq 'none (portal-launcher-present
                         (lambda ()
                           (run-hook-with-args 'window-buffer-change-functions frame)
                           (window-parameter (selected-window) 'mode-line-format))
                         :mode-line nil)))
      (should (equal '("custom") (window-parameter (selected-window) 'mode-line-format)))
      (should (equal '("custom") (portal-launcher-present
                                  (lambda () (window-parameter (selected-window) 'mode-line-format)))))
      (should (equal '("custom") (window-parameter (selected-window) 'mode-line-format)))
      (set-window-parameter (selected-window) 'mode-line-format nil)
      ;; A layout from before the call stays; only the call's windows go,
      ;; and a show that fails deletes nothing.
      (let ((kept (split-window)))
        (portal-launcher-present (lambda () (display-buffer other) (split-window)) :mode-line nil)
        (should (= 2 (length (window-list frame 'never))))
        (should (window-live-p kept))
        (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (error "Cannot present"))))
          (should-error (portal-launcher-present #'ignore)))
        (should (window-live-p kept))
        (should-not (window-parameter kept 'mode-line-format))
        (delete-window kept))
      (kill-buffer other))))

(ert-deftest portal-launcher-second-invocation-unwinds-the-command ()
  (portal-launcher-test--session
    (dolist (dismiss '(portal-launcher-present portal-launcher-toggle portal-launcher-hide portal-launcher-cancel))
      (portal-launcher-present
       (lambda () (interactive) (funcall dismiss) (ert-fail "Command survived dismissal"))))
    (should (equal hidden '(t t t t)))))

(ert-deftest portal-launcher-blur-is-queued-and-session-scoped ()
  (portal-launcher-test--session
    (portal-launcher-present
     (lambda ()
       (interactive)
       (dolist (value '(nil "9" "-10" "10x" "10\n")) (portal-launcher--queue-blur value))
       (portal-launcher--queue-blur "10" "extra")
       (should-not unread-command-events)
       (portal-launcher--queue-blur "10")
       (should (equal unread-command-events '((portal-launcher-blur 10))))
       (portal-launcher--blur '(portal-launcher-blur 9))
       (portal-launcher--blur (pop unread-command-events))
       (ert-fail "Command survived focus loss")))
    (should (equal hidden '(nil)))
    (cl-incf session-id)
    (should (eq 'new (portal-launcher-present
                     (lambda () (interactive) (portal-launcher--blur '(portal-launcher-blur 10)) 'new))))
    (portal-launcher--queue-blur "11")
    (should-not unread-command-events)))

(ert-deftest portal-launcher-session-defers-deletion-until-unwound ()
  (portal-launcher-test--session
    (portal-launcher-present
     (lambda ()
       (interactive)
       (portal-launcher--delete-frame (lambda (&rest _) (ert-fail "Deleted during command")))
       (ert-fail "Continued after delete request")))
    (should (= deleted 1))
    (should (= disabled 0))
    (should (equal hidden '(t)))))

(ert-deftest portal-launcher-show-failure-restores-session-bindings ()
  (portal-launcher-test--session
    (cl-letf (((symbol-function 'portal-launcher--show) (lambda (&rest _) (error "Cannot present"))))
      (should-error (portal-launcher-present (lambda () (interactive) (ert-fail "Ran without panel")))))
    (should-not portal-launcher--session)
    (should (equal hidden '(t)))))

(ert-deftest portal-launcher-shutdown-preserves-exit-and-later-hooks ()
  ;; A real kill-emacs in another process catches nonlocal exits that a
  ;; mocked kill-emacs or an isolated run-hooks would miss.
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory) nil t nil
            "--batch" "-Q" "-L" (file-name-directory (locate-library "portal-launcher"))
            "--eval"
            (prin1-to-string
             '(progn
                (require 'portal-launcher)
                (let ((native-comp-enable-subr-trampolines nil)
                      (portal-launcher-mode t)
                      (portal-global-shortcut--registrations
                       (list (list 'portal-launcher 1 "Control-Option-Command-P"
                                   #'portal-launcher-toggle)))
                      (portal-launcher--frame (selected-frame))
                      (frame (selected-frame))
                      (detached 0) (released 0) (deleted 0))
                  (cl-letf (((symbol-function 'portal-launcher--show) #'ignore)
                            ((symbol-function 'portal--launcher-inspect) (lambda () '(:session 1)))
                            ((symbol-function 'portal--launcher-hide) #'ignore)
                            ((symbol-function 'make-frame-invisible) #'ignore)
                            ((symbol-function 'portal--launcher-detach) (lambda () (cl-incf detached)))
                            ((symbol-function 'portal--shortcut-remove)
                             (lambda (id) (when (eql id 1) (cl-incf released))))
                            ((symbol-function 'delete-frame) (lambda (&rest _) (cl-incf deleted))))
                    (portal-launcher--hooks t)
                    (add-hook 'kill-emacs-hook
                              (lambda ()
                                (princ (format "later-hook: %S\n"
                                               (list detached released deleted
                                                     portal-launcher-mode
                                                     portal-global-shortcut--registrations
                                                     (and (frame-live-p frame) t)))))
                              90)
                    (portal-launcher-present (lambda () (interactive) (kill-emacs 23)))
                    ;; Reaching here means the launcher swallowed shutdown.
                    (setq kill-emacs-hook nil)
                    (kill-emacs 99))))))))
      (should (= status 23))
      (should (string-match-p "later-hook: (1 1 0 nil nil t)" (buffer-string))))))

(provide 'portal-launcher-tests)
