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
  (cl-letf (((symbol-function 'portal-launcher-show) (lambda (&rest _) (ert-fail "Presented invalid command"))))
    (dolist (command '(nil identity 42))
      (let ((portal-launcher-command command))
        (should-error (portal-launcher-present) :type 'user-error)))))

(defmacro portal-launcher-test--session (&rest body)
  "Exercise real session unwinding with only the native frame stubbed."
  (declare (indent 0))
  `(let ((portal-launcher--frame (selected-frame))
         (native-comp-enable-subr-trampolines nil)
         (portal-launcher--session nil) (unread-command-events nil)
         (hidden nil) (session-id 10) (deleted 0) (disabled 0))
     (cl-letf (((symbol-function 'portal-launcher-show) #'ignore)
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
    (cl-letf (((symbol-function 'portal-launcher-show) (lambda (&rest _) (error "Cannot present"))))
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
                  (cl-letf (((symbol-function 'portal-launcher-show) #'ignore)
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
