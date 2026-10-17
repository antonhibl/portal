;;; portal-terminal-ivy-tests.el --- The Ivy adapter -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real Ivy drives the adapter against the fake native module.  A keyboard
;; macro types into a real minibuffer, which batch Emacs opens while
;; executing one, so Ivy's filtering, actions and the scope toggle all run.
;; The suite skips itself when Ivy is not on the load path.
(require 'ert)
(require 'project)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)
(require 'ivy nil t)
(require 'portal-terminal-ivy)

(defvar portal-ivy-test--directory nil "This test's temporary directory.")

(defmacro portal-ivy-test--environment (&rest body)
  "Run BODY with the Ivy adapter on, from a file in project one/app.
The directory holds projects one/app and two/app.  Kill every buffer BODY
made, delete the directory, and turn the adapter off afterwards."
  (declare (indent 0))
  `(progn
     (skip-unless (featurep 'ivy))
     (let* ((portal-ivy-test--directory (file-truename (make-temp-file "portal-ivy-" t)))
            (context (frame-parameter nil 'portal-project-context))
            (initial-buffers (buffer-list))
            (portal-terminal-confirm-kill nil)
            (project-list-file (portal-ivy-test--path "projects.eld"))
            (project--list 'unset))
       (portal-fake-native-reset)
       (dolist (folder '("one/app/.git" "one/app/api" "two/app/.git"))
         (make-directory (portal-ivy-test--path folder) t))
       (save-window-excursion
         (unwind-protect
             (progn (portal-terminal-ivy-mode)
                    (ivy-mode)
                    (delete-other-windows)
                    (switch-to-buffer (get-buffer-create "ivy-file.el"))
                    (setq buffer-file-name (portal-ivy-test--path "one/app/file.el")
                          default-directory (file-name-directory buffer-file-name))
                    (portal-project--remember)
                    ,@body)
           (ivy-mode -1)
           (portal-terminal-ivy-mode -1)
           (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
             (when (buffer-live-p buffer) (kill-buffer buffer)))
           (set-frame-parameter nil 'portal-project-context context)
           (delete-directory portal-ivy-test--directory t)))
       (should (eq portal-terminal--reader #'portal-terminal--completing-read))
       (should-not (portal-view-buffers)))))

(defun portal-ivy-test--path (name)
  "Return NAME in this test's directory."
  (expand-file-name name portal-ivy-test--directory))

(defun portal-ivy-test--open (folder &optional title)
  "Start a terminal in FOLDER, with TITLE if non-nil, and return its buffer."
  (let ((default-directory (file-name-as-directory (portal-ivy-test--path folder))))
    (portal-terminal-new)
    (when title
      (portal-fake-native-report portal-view--target :title title))
    (current-buffer)))

(defun portal-ivy-test--type (command keys)
  "Run COMMAND interactively while typing KEYS, then return to the file buffer.
KEYS is in `kbd' notation."
  (let ((origin (current-buffer)))
    (execute-kbd-macro (vconcat (kbd "M-x") (symbol-name command) (kbd "RET") (kbd keys)))
    (prog1 (current-buffer)
      (switch-to-buffer origin))))

(ert-deftest portal-terminal-ivy-reads-and-selects-terminals ()
  (portal-ivy-test--environment
    (let* ((file (current-buffer))
           (server (portal-ivy-test--open "one/app" "npm run dev"))
           (api (portal-ivy-test--open "one/app/api"))
           (other (portal-ivy-test--open "two/app")))
      (switch-to-buffer file)
      (should (eq portal-terminal--reader #'portal-terminal-ivy--read))
      ;; Any part of a candidate matches, such as a terminal's title.
      (should (eq (portal-ivy-test--type 'portal-terminal-choose "npm RET") server))
      ;; RET on no input takes the most recently selected terminal.
      (should (eq (portal-ivy-test--type 'portal-terminal-choose "RET") server))
      ;; The project picker lists the project's terminals; M-a widens it,
      ;; keeping the input.
      (switch-to-buffer file)
      (should (eq (portal-ivy-test--type 'portal-terminal-choose-project "two M-a RET") other))
      (should (eq (portal-ivy-test--type 'portal-terminal-choose "api RET") api)))))

(ert-deftest portal-terminal-ivy-starts-new-terminals ()
  (portal-ivy-test--environment
    (let ((file (current-buffer)))
      (portal-ivy-test--open "two/app")
      (switch-to-buffer file)
      (let ((new (portal-ivy-test--type 'portal-terminal-choose "New SPC terminal SPC in RET")))
        (should (memq new (portal-view-buffers 'terminal)))
        (should (equal (buffer-local-value 'default-directory new)
                       (portal-ivy-test--path "one/app/"))))
      (switch-to-buffer file)
      (let ((named (portal-ivy-test--type 'portal-terminal-choose
                                          "named RET server RET")))
        ;; Both projects are called app, so the name says which.
        (should (string-prefix-p "*server: one/app*" (buffer-name named)))))))

(ert-deftest portal-terminal-ivy-acts-on-terminals-with-m-o ()
  (portal-ivy-test--environment
    (let* ((file (current-buffer))
           (server (portal-ivy-test--open "one/app" "npm run dev")))
      (portal-ivy-test--open "two/app")
      (switch-to-buffer file)
      ;; Renaming acts on the terminal at point and selects nothing.
      (should (eq (portal-ivy-test--type 'portal-terminal-choose
                                         "npm M-o r C-a C-k web RET")
                  file))
      (should (equal (buffer-name server) "web"))
      ;; Copying its directory.
      (portal-ivy-test--type 'portal-terminal-choose "web M-o W")
      (should (equal (current-kill 0) (portal-ivy-test--path "one/app/")))
      ;; Ending it.
      (portal-ivy-test--type 'portal-terminal-choose "web M-o k")
      (should-not (buffer-live-p server))
      ;; A New entry is not a terminal.
      (portal-ivy-test--type 'portal-terminal-choose "named M-o r")
      (should (= (length (portal-view-buffers 'terminal)) 1))
      ;; Quick and exited terminals say so.
      (let ((done (portal-ivy-test--open "one/app/api")))
        (portal-fake-native-report (buffer-local-value 'portal-view--target done) :exited t)
        (let ((portal-terminal-ivy--entries (portal-terminal--candidates (list done))))
          (should (string-suffix-p "exited"
                                   (substring-no-properties
                                    (portal-terminal-ivy--display
                                     (caar portal-terminal-ivy--entries))))))))))

(provide 'portal-terminal-ivy-tests)
;;; portal-terminal-ivy-tests.el ends here
