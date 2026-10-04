;;; portal-global-shortcut-tests.el --- Named global shortcuts in batch Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Runs the real Lisp module on the real C core: PORTAL_TEST_MODULE names
;; the module built with test/portal-fake-backend.c, whose hot keys accept
;; any chord but F19, which another application has.  Tests feed "shortcut
;; ID" records to the pipe's filter, as the core sends them for a press, and
;; run what the filter queued through the command loop's key lookup.
;; test/portal-shortcuts-tests.c covers presses and the core itself.

(require 'ert)

(let ((file (getenv "PORTAL_TEST_MODULE")))
  (unless (and file (file-exists-p file))
    (error "Set PORTAL_TEST_MODULE to the fake-backend module"))
  (module-load file))

(require 'portal-global-shortcut)
(declare-function portal--shortcuts "portal-global-shortcut" ())

(defmacro portal-global-shortcut-tests--with (&rest body)
  "Run BODY with no shortcut set, the native module standing in for macOS's.
Afterwards, check that BODY changed no frame or window, and remove every
shortcut."
  (declare (indent 0))
  `(let ((unread-command-events nil)
         (portal-view--pending "")
         (frames (frame-list))
         (window (selected-window)))
     (should-not portal-global-shortcut--registrations)
     (should-not (portal--shortcuts))
     (cl-letf (((symbol-function 'portal-view--load) #'ignore))
       (unwind-protect
           (progn ,@body
                  (should (equal frames (frame-list)))
                  (should (eq window (selected-window))))
         (portal-global-shortcut--remove-all)))
     (should-not (portal--shortcuts))
     (should-not (assoc "shortcut" portal-view-feature-record-handlers))
     (should-not (memq #'portal-global-shortcut--remove-all kill-emacs-hook))))

(defun portal-global-shortcut-tests--id (name)
  "The native ID of the shortcut NAME."
  (cadr (assq name portal-global-shortcut--registrations)))

(defun portal-global-shortcut-tests--press (&rest names)
  "Send the records the core sends when the chords of NAMES are pressed."
  (portal-view--receive
   nil (mapconcat (lambda (name)
                    (format "shortcut %s\n" (if (symbolp name)
                                                (portal-global-shortcut-tests--id name)
                                              name)))
                  names)))

(defun portal-global-shortcut-tests--run ()
  "Run the queued events through the command loop's key lookup, in order.
Return the errors they signalled.  Reading takes `unread-command-events'
before a macro's own events, so each event runs from a macro alone."
  (let ((events unread-command-events) errors)
    (setq unread-command-events nil)
    (dolist (event events (nreverse errors))
      (condition-case error (execute-kbd-macro (vector event))
        (error (push error errors))))))

(defun portal-global-shortcut-tests--state ()
  "What Lisp and the core know of the shortcuts."
  (list (copy-tree portal-global-shortcut--registrations) (portal--shortcuts)))

(ert-deftest portal-global-shortcut-loading-sets-nothing ()
  (should-not portal-global-shortcut--registrations)
  (should-not (portal--shortcuts))
  (should-not (assoc "shortcut" portal-view-feature-record-handlers))
  (should-not (memq #'portal-global-shortcut--remove-all kill-emacs-hook))
  (should (eq (lookup-key global-map [portal-global-shortcut]) #'portal-global-shortcut--run)))

(ert-deftest portal-global-shortcut-two-names-call-their-own-functions ()
  (portal-global-shortcut-tests--with
    (let* ((calls nil)
           (plain (let ((label 'plain)) (lambda () (push label calls))))
           (command (lambda (prefix) (interactive "p") (push (list 'command prefix) calls))))
      (should (eq (portal-global-shortcut-set 'plain "Control-Option-Command-1" plain) 'plain))
      (should (eq (portal-global-shortcut-set 'command "control-option-command-2" command)
                  'command))
      (should (equal (mapcar (lambda (shortcut) (plist-get shortcut :chord)) (portal--shortcuts))
                     '("Control-Option-Command-1" "Control-Option-Command-2")))
      (should (equal (mapcar #'caddr portal-global-shortcut--registrations)
                     '("Control-Option-Command-1" "Control-Option-Command-2")))
      (portal-global-shortcut-tests--press 'command 'plain)
      ;; The filter only queues; the command loop calls the functions.
      (should-not calls)
      (should (= (length unread-command-events) 2))
      (portal-global-shortcut-tests--run)
      (should (equal calls '(plain (command 1))))
      (portal-global-shortcut-tests--press 'plain)
      (portal-global-shortcut-tests--run)
      (should (equal calls '(plain plain (command 1)))))))

(ert-deftest portal-global-shortcut-setting-again-replaces ()
  (portal-global-shortcut-tests--with
    (let* ((calls nil)
           (first (lambda () (push 'first calls)))
           (second (lambda () (push 'second calls))))
      ;; Repeating a configuration leaves one registration.
      (dotimes (_ 5) (portal-global-shortcut-set 'a "Control-Option-Command-A" first))
      (should (= (length (portal--shortcuts)) 1))
      (should (= (length portal-global-shortcut--registrations) 1))
      ;; A new function on the same chord gets a new ID: a press from before
      ;; the change, queued or still in the pipe, is ignored.
      (let ((old (portal-global-shortcut-tests--id 'a)))
        (portal-global-shortcut-tests--press 'a)
        (portal-global-shortcut-set 'a "command-control-option-a" second)
        (should-not (eql old (portal-global-shortcut-tests--id 'a)))
        (portal-global-shortcut-tests--press old)
        (portal-global-shortcut-tests--run)
        (should-not calls)
        (portal-global-shortcut-tests--press 'a)
        (portal-global-shortcut-tests--run)
        (should (equal calls '(second))))
      ;; A new chord releases the old one, which another name can then take.
      (let ((old (portal-global-shortcut-tests--id 'a)))
        (portal-global-shortcut-set 'a "Control-Option-Command-B" first)
        (portal-global-shortcut-set 'b "Control-Option-Command-A" second)
        (should (equal (mapcar (lambda (shortcut) (plist-get shortcut :chord)) (portal--shortcuts))
                       '("Control-Option-Command-B" "Control-Option-Command-A")))
        (portal-global-shortcut-tests--press old 'a)
        (portal-global-shortcut-tests--run)
        (should (equal calls '(first second)))))))

(ert-deftest portal-global-shortcut-invalid-changes-keep-every-shortcut ()
  (portal-global-shortcut-tests--with
    (portal-global-shortcut-set 'a "Control-Option-Command-A" #'ignore)
    (portal-global-shortcut-set 'b "Control-Option-Command-B" #'ignore)
    (let ((before (portal-global-shortcut-tests--state)))
      (dolist (name '(a c))
        ;; Invalid arguments, checked before any native call.
        (dolist (function (list nil 'portal-global-shortcut-tests--undefined
                                (lambda (argument) argument) "keyboard macro" [?a] 'when))
          (should-error (portal-global-shortcut-set name "Control-Option-Command-C" function)
                        :type 'user-error))
        (dolist (chord '(nil 42 Control-Option-Command-C))
          (should-error (portal-global-shortcut-set name chord #'ignore) :type 'user-error))
        ;; Invalid notation and chords that are not this name's to take.
        (dolist (chord '("P" "Shift-P" "Hyper-P" "Control-Control-P" "Control-F21" "Control-!"
                         "Control-P Q" ""))
          (should-error (portal-global-shortcut-set name chord #'ignore)))
        (should (equal (cadr (should-error (portal-global-shortcut-set
                                            name "command-control-option-b" #'ignore)))
                       (format-message
                        "Global shortcut Control-Option-Command-B is already set as `b'")))
        (should (equal (cadr (should-error (portal-global-shortcut-set name "Control-F19" #'ignore)))
                       "Cannot register shortcut Control-F19: Another application has this chord"))
        (should (equal before (portal-global-shortcut-tests--state))))
      (dolist (name (list nil "a" 3))
        (should-error (portal-global-shortcut-set name "Control-Option-Command-C" #'ignore)
                      :type 'user-error))
      (should (equal before (portal-global-shortcut-tests--state))))))

(ert-deftest portal-global-shortcut-accepts-commands-and-functions-of-no-arguments ()
  (portal-global-shortcut-tests--with
    (let ((calls nil))
      (defalias 'portal-global-shortcut-tests--command
        (lambda (&optional argument)
          (interactive (list 'interactive))
          (push argument calls)))
      (dolist (function (list 'portal-global-shortcut-tests--command
                              (lambda (&optional argument) (push argument calls))
                              (lambda (&rest arguments) (push arguments calls))
                              #'ignore))
        (portal-global-shortcut-set 'a "Control-Option-Command-A" function)
        (portal-global-shortcut-tests--press 'a)
        (portal-global-shortcut-tests--run))
      (should (equal calls '(nil nil interactive))))))

(ert-deftest portal-global-shortcut-error-keeps-every-shortcut ()
  (portal-global-shortcut-tests--with
    (let ((calls 0))
      (portal-global-shortcut-set 'broken "Control-Option-Command-E" (lambda () (error "Broken")))
      (portal-global-shortcut-set 'working "Control-Option-Command-W" (lambda () (cl-incf calls)))
      (dotimes (_ 2)
        (portal-global-shortcut-tests--press 'broken 'working)
        ;; The error is reported, without reaching the command loop, whose
        ;; report would discard the press of WORKING waiting behind it.
        (let (messages)
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest arguments)
                       (push (apply #'format-message format arguments) messages))))
            (should-not (portal-global-shortcut-tests--run)))
          (should (equal (delete "" messages)
                         (list (format-message "Global shortcut `broken': Broken"))))))
      ;; With `debug-on-error', it is the debugger's.
      (portal-global-shortcut-tests--press 'broken)
      (let ((debug-on-error t) (debugger (lambda (&rest _) (throw 'debugged t))))
        (should (catch 'debugged (portal-global-shortcut-tests--run) nil)))
      (should (= calls 2))
      (should (equal (mapcar #'car portal-global-shortcut--registrations) '(broken working)))
      (should (= (length (portal--shortcuts)) 2)))))

(ert-deftest portal-global-shortcut-ignores-stale-and-malformed-records ()
  (portal-global-shortcut-tests--with
    (let ((calls nil))
      (portal-global-shortcut-set 'a "Control-Option-Command-A" (lambda () (push 'a calls)))
      (portal-global-shortcut-set 'b "Control-Option-Command-B" (lambda () (push 'b calls)))
      (let ((a (portal-global-shortcut-tests--id 'a)))
        ;; A record split across reads still arrives; malformed ones do not.
        (portal-view--receive nil (format "shortcut %s" a))
        (portal-view--receive nil "\nshortcut\nshortcut x\nshortcut -1\nshortcut 99999\n")
        (portal-view--receive nil (format "shortcut %s extra\nshortcut %s.0\n" a a))
        (should (equal unread-command-events `((portal-global-shortcut (,a)))))
        ;; Removing a shortcut drops its waiting presses, even when the same
        ;; name and chord are set again.
        (portal-global-shortcut-tests--press 'b)
        (should (eq (portal-global-shortcut-remove 'a) t))
        (portal-global-shortcut-set 'a "Control-Option-Command-A" (lambda () (push 'new calls)))
        (portal-global-shortcut-tests--press a)
        (portal-global-shortcut-tests--run)
        (should (equal calls '(b)))
        (portal-global-shortcut-tests--press 'a)
        (portal-global-shortcut-tests--run)
        (should (equal calls '(new b)))))))

(ert-deftest portal-global-shortcut-drops-a-press-while-one-waits ()
  (portal-global-shortcut-tests--with
    (let ((calls 0))
      (portal-global-shortcut-set 'a "Control-Option-Command-A" (lambda () (cl-incf calls)))
      (portal-global-shortcut-set 'b "Control-Option-Command-B" #'ignore)
      (portal-global-shortcut-tests--press 'a 'b 'a)
      (portal-global-shortcut-tests--press 'a)
      (should (= (length unread-command-events) 2))
      (portal-global-shortcut-tests--run)
      (should (= calls 1))
      (portal-global-shortcut-tests--press 'a)
      (portal-global-shortcut-tests--run)
      (should (= calls 2)))))

(ert-deftest portal-global-shortcut-removal-is-independent ()
  (portal-global-shortcut-tests--with
    (let ((calls nil))
      (portal-global-shortcut-set 'a "Control-Option-Command-A" (lambda () (push 'a calls)))
      (portal-global-shortcut-set 'b "Control-Option-Command-B" (lambda () (push 'b calls)))
      (should (eq (portal-global-shortcut-remove 'a) t))
      (should-not (portal-global-shortcut-remove 'a))
      (should-not (portal-global-shortcut-remove 'never-set))
      (should (equal (mapcar (lambda (shortcut) (plist-get shortcut :chord)) (portal--shortcuts))
                     '("Control-Option-Command-B")))
      (portal-global-shortcut-tests--press 'b)
      (portal-global-shortcut-tests--run)
      (should (equal calls '(b)))
      ;; Its chord is free again.
      (portal-global-shortcut-set 'c "Control-Option-Command-A" #'ignore)
      (should (eq (portal-global-shortcut-remove 'b) t))
      (should (eq (portal-global-shortcut-remove 'c) t))
      (should-not (assoc "shortcut" portal-view-feature-record-handlers)))))

(ert-deftest portal-global-shortcut-unloading-releases-every-shortcut ()
  (portal-global-shortcut-tests--with
    (portal-global-shortcut-set 'a "Control-Option-Command-A" #'ignore)
    (portal-global-shortcut-set 'b "Control-Option-Command-B" #'ignore)
    (unwind-protect
        (progn
          (unload-feature 'portal-global-shortcut t)
          (should-not (portal--shortcuts))
          (should-not (assoc "shortcut" portal-view-feature-record-handlers))
          (should-not (lookup-key global-map [portal-global-shortcut])))
      (require 'portal-global-shortcut))))

(ert-deftest portal-global-shortcut-exit-releases-every-shortcut ()
  ;; A real kill-emacs in another process runs the actual exit hooks.
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory) nil t nil
            "--batch" "-Q" "-L" (file-name-directory (locate-library "portal-global-shortcut"))
            "--eval"
            (prin1-to-string
             '(progn
                (module-load (getenv "PORTAL_TEST_MODULE"))
                (require 'portal-global-shortcut)
                (fset 'portal-view--load #'ignore)
                (portal-global-shortcut-set 'a "Control-Option-Command-A" #'ignore)
                (portal-global-shortcut-set 'b "Control-Option-Command-B" (lambda ()))
                (add-hook 'kill-emacs-hook
                          (lambda ()
                            (princ (format "later-hook: %S\n"
                                           (list (length (portal--shortcuts))
                                                 portal-global-shortcut--registrations))))
                          90)
                (princ (format "before: %S\n" (length (portal--shortcuts))))
                (kill-emacs 23))))))
      (should (= status 23))
      (should (string-match-p "before: 2\nlater-hook: (0 nil)" (buffer-string))))))

(provide 'portal-global-shortcut-tests)
;;; portal-global-shortcut-tests.el ends here
