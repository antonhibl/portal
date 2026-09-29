;;; portal-terminal-choose-tests.el --- Choosing and ending terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)

;; The pickers with Emacs's own completion, against the fake native module.
;; A stand-in `completing-read' answers each prompt, as the tests say, after
;; checking what it was offered.  The Consult adapter has its own suite.

(defvar portal-choose-test--directory nil "This test's temporary directory.")

(defmacro portal-choose-test--environment (&rest body)
  "Run BODY in one window from a file buffer in project one/app.
The directory holds projects one/app and two/app, and loose, in none.
Kill every buffer BODY made, and delete the directory, afterwards."
  (declare (indent 0))
  `(let* ((portal-choose-test--directory (file-truename (make-temp-file "portal-choose-" t)))
          (context (frame-parameter nil 'portal-project-context))
          (return (frame-parameter nil 'portal-terminal-quick-return-window))
          (initial-buffers (buffer-list))
          (portal-terminal-confirm-kill nil))
     (portal-fake-native-reset)
     (dolist (folder '("one/app/.git" "one/app/src" "two/app/.git" "loose"))
       (make-directory (portal-choose-test--path folder) t))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (portal-choose-test--visit "one/app/src/file.el")
                  ,@body)
         (portal-terminal-quick-dismiss)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (set-frame-parameter nil 'portal-terminal-quick-return-window return)
         (delete-directory portal-choose-test--directory t)))
     (should-not (portal-view-buffers))))

(defun portal-choose-test--path (name)
  "Return NAME in this test's directory; a trailing slash makes it a directory."
  (expand-file-name name portal-choose-test--directory))

(defun portal-choose-test--visit (file)
  "Show a buffer visiting FILE, in this test's directory, as the editing context."
  (switch-to-buffer (get-buffer-create (concat "choose-" (file-name-nondirectory file))))
  (setq buffer-file-name (portal-choose-test--path file)
        default-directory (file-name-directory buffer-file-name))
  (portal-project--remember)
  (current-buffer))

(defun portal-choose-test--open (folder)
  "Start a terminal in FOLDER from the current window and return its buffer."
  (let ((default-directory (file-name-as-directory (portal-choose-test--path folder))))
    (portal-terminal-new)
    (current-buffer)))

(defmacro portal-choose-test--answering (answer &rest body)
  "Run BODY while each terminal prompt is answered by calling ANSWER.
ANSWER gets the prompt, the terminals offered as (STRING . BUFFER), the
New entries' strings, the initial input and the default, in that order,
and returns what `completing-read' would."
  (declare (indent 1))
  `(cl-letf* ((answer ,answer)
              ((symbol-function 'completing-read)
               (lambda (prompt collection _predicate _require initial _history default)
                 (let* ((all (all-completions "" collection))
                        (terminals (delq nil (mapcar (lambda (candidate)
                                                       (when-let* ((buffer (get-text-property
                                                                            0 'portal-terminal candidate)))
                                                         (cons candidate buffer)))
                                                     all))))
                   (should (eq (completion-metadata-get (completion-metadata "" collection nil)
                                                        'category)
                               'portal-terminal))
                   (funcall answer prompt terminals
                            (cl-remove-if (lambda (candidate) (assoc candidate terminals)) all)
                            initial default)))))
     ,@body))

(ert-deftest portal-terminal-choose-orders-by-recent-selection ()
  (portal-choose-test--environment
    (let* ((file (current-buffer))
           (first (portal-choose-test--open "one/app"))
           (second (portal-choose-test--open "one/app/src"))
           (other (portal-choose-test--open "two/app"))
           offered)
      (portal-choose-test--answering
          (lambda (_prompt terminals _new _initial default)
            (setq offered (mapcar #'cdr terminals))
            ;; The most recent terminal is the default, and RET picks it.
            (should (equal default (caar terminals)))
            default)
        ;; Selecting records a terminal; previewing without recording does not.
        (switch-to-buffer first)
        (switch-to-buffer second 'norecord)
        (switch-to-buffer file)
        (portal-terminal-choose)
        (should (equal offered (list first other second)))
        (should (eq (current-buffer) first))
        ;; The current terminal comes last, as the one to switch away from.
        (portal-terminal-choose)
        (should (equal offered (list other second first)))
        (should (eq (current-buffer) other))
        (should (eq (car (buffer-list)) other)))
      ;; Cycling keeps creation order, whatever was selected.
      (portal-terminal-next)
      (should (eq (current-buffer) first))
      (portal-terminal-next)
      (should (eq (current-buffer) second)))))

(ert-deftest portal-terminal-choose-project-by-assignment-and-widening ()
  (portal-choose-test--environment
    (let* ((file (current-buffer))
           (one (portal-choose-test--path "one/app/"))
           (first (portal-choose-test--open "one/app"))
           (second (portal-choose-test--open "one/app/src"))
           (other (portal-choose-test--open "two/app"))
           (prompts nil) (inputs nil) (offered nil) (answers nil))
      ;; Shells that moved stay with the project they are assigned to.
      (portal-fake-native-report (buffer-local-value 'portal-view--target second)
                                 :pwd temporary-file-directory)
      (portal-fake-native-report (buffer-local-value 'portal-view--target other)
                                 :pwd (portal-choose-test--path "one/app/src"))
      (switch-to-buffer file)
      (portal-choose-test--answering
          (lambda (prompt terminals new initial _default)
            (push prompt prompts)
            (push initial inputs)
            (push (list (mapcar #'cdr terminals) new) offered)
            (funcall (pop answers) terminals new))
        (setq answers (list (lambda (terminals _new) (car (rassq second terminals)))))
        (portal-terminal-choose-project)
        (should (eq (current-buffer) second))
        (should (equal (car prompts) "Terminal in app: "))
        (should (equal (car offered) (list (list second first)
                                           '("New terminal in app" "New named terminal in app…"))))
        ;; From a terminal, its own project, not the one its shell is in now.
        (switch-to-buffer other)
        (setq answers (list (lambda (terminals _new) (caar terminals))))
        (portal-terminal-choose-project)
        (should (equal (car prompts) "Terminal in app: "))
        (should (equal (car (car offered)) (list other)))
        ;; M-a widens to every project and back, keeping the input.
        (switch-to-buffer file)
        (setq answers (list (lambda (_terminals _new)
                              (with-temp-buffer (insert "api")
                                                (portal-terminal-choose-toggle-scope)))
                            (lambda (_terminals _new)
                              (with-temp-buffer (insert "api dev")
                                                (portal-terminal-choose-toggle-scope)))
                            (lambda (terminals _new) (car (rassq first terminals)))))
        (setq prompts nil inputs nil offered nil)
        (portal-terminal-choose-project)
        (should (equal (reverse prompts) '("Terminal in app: " "Terminal: " "Terminal in app: ")))
        (should (equal (reverse inputs) '(nil "api" "api dev")))
        (should (equal (sort (car (nth 1 offered)) :key #'buffer-name)
                       (sort (list first second other) :key #'buffer-name)))
        (should (eq (current-buffer) first))
        (should (equal (lookup-key portal-terminal-choose-map (kbd "M-a"))
                       #'portal-terminal-choose-toggle-scope))
        ;; New terminals start at the project's root and belong to it.
        (switch-to-buffer file)
        (setq answers (list (lambda (_terminals new) (car new))))
        (portal-terminal-choose-project)
        (should (equal (plist-get (portal-terminal-metadata) :directory) one))
        (should (equal (plist-get (portal-terminal-metadata) :project) one))
        ;; Another live project is also called app, so the name tells them apart.
        (should (equal (buffer-name) "*terminal: one/app*"))
        (switch-to-buffer file)
        (setq answers (list (lambda (_terminals new) (cadr new))))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) " server ")))
          (portal-terminal-choose))
        (should (equal (buffer-name) "*server: one/app*"))
        (should (equal (plist-get (portal-terminal-metadata) :project) one))
        ;; Only a listed entry is accepted: input never starts a shell.
        (let ((count (length (portal-terminal-buffers))))
          (setq answers (list (lambda (_terminals _new) "api dev")))
          (should-error (portal-terminal-choose) :type 'user-error)
          (should (= (length (portal-terminal-buffers)) count)))))))

(ert-deftest portal-terminal-choose-outside-a-project-and-with-no-terminals ()
  (portal-choose-test--environment
    (let ((loose (portal-choose-test--path "loose/"))
          offered)
      (portal-choose-test--visit "loose/file.el")
      (should-error (portal-terminal-choose-project) :type 'user-error)
      (portal-choose-test--answering
          (lambda (prompt terminals new _initial default)
            (should (equal prompt "Terminal: "))
            (setq offered (list terminals new default))
            (car new))
        (portal-terminal-choose))
      ;; With no terminal yet, the picker offers only to start one, there.
      (let ((place (abbreviate-file-name (directory-file-name loose))))
        (should (equal offered (list nil (list (format "New terminal in %s" place)
                                              (format "New named terminal in %s…" place))
                                     nil))))
      (should (equal (plist-get (portal-terminal-metadata) :directory) loose))
      (should-not (plist-get (portal-terminal-metadata) :project))
      ;; Nothing chosen does nothing.
      (switch-to-buffer "choose-file.el")
      (portal-choose-test--answering (lambda (&rest _) "")
        (should-error (let ((portal-view--buffers nil)) (portal-terminal-choose))
                      :type 'user-error)))))

(ert-deftest portal-terminal-choose-from-a-quick-panel ()
  (portal-choose-test--environment
    (let* ((editing (selected-window))
           (first (portal-choose-test--open "one/app"))
           (second (portal-choose-test--open "two/app"))
           seen)
      (switch-to-buffer first)
      (portal-terminal-toggle)
      (let ((quick (current-buffer)) (panel (selected-window)))
        (should (window-parameter panel 'portal-terminal-quick))
        ;; The picker reads for the editing window; cancelling returns to the panel.
        (portal-choose-test--answering
            (lambda (prompt terminals &rest _)
              (setq seen (list prompt (selected-window) (mapcar #'cdr terminals)))
              ;; ERT stops at a real quit, which the graphical suite sends.
              (error "Cancelled"))
          (should-error (portal-terminal-choose-project)))
        (should (equal seen (list "Terminal in app: " editing (list first))))
        (should (eq (selected-window) panel))
        (should (eq (window-buffer editing) first))
        ;; A choice opens there, and the panel stays.
        (portal-choose-test--answering
            (lambda (_prompt terminals &rest _) (car (rassq second terminals)))
          (portal-terminal-choose))
        (should (eq (selected-window) editing))
        (should (eq (window-buffer editing) second))
        (should (eq (window-buffer panel) quick))
        (portal-view-sync)
        (should (equal (portal-view-target panel) (buffer-local-value 'portal-view--target quick)))
        ;; Quick terminals are listed only on request, and open in their panel.
        (portal-choose-test--answering
            (lambda (_prompt terminals &rest _)
              (should-not (rassq quick terminals))
              (caar terminals))
          (portal-terminal-choose))
        (portal-terminal-quick-dismiss)
        (let ((portal-terminal-choose-quick t))
          (portal-choose-test--answering
              (lambda (_prompt terminals &rest _) (car (rassq quick terminals)))
            (portal-terminal-choose)))
        (should (window-parameter (selected-window) 'portal-terminal-quick))
        (should (eq (current-buffer) quick))
        (should (plist-get (portal--inspect (portal-view-target)) :focused))
        (should (equal (portal-terminal--annotation quick) "  quick"))))))

(ert-deftest portal-terminal-select-reads-live-terminals-only ()
  (portal-choose-test--environment
    (let* ((file (current-buffer))
           (first (portal-choose-test--open "one/app"))
           (second (portal-choose-test--open "two/app"))
           offered)
      (switch-to-buffer file)
      (portal-terminal-select (buffer-name first))
      (should (eq (current-buffer) first))
      (portal-terminal-select second)
      (should (eq (current-buffer) second))
      ;; Interactively, only terminals are offered, the current one first.
      (let ((completing-read-function
             (lambda (_prompt collection predicate _require _initial _history default &rest _)
               (setq offered (list (sort (all-completions "" collection predicate)) default))
               (buffer-name first))))
        (call-interactively #'portal-terminal-select))
      (should (equal offered (list (sort (list (buffer-name first) (buffer-name second)))
                                   (buffer-name second))))
      (should (eq (current-buffer) first))
      (should-error (portal-terminal-select file) :type 'user-error)
      (with-current-buffer second (portal-terminal-close))
      (should-error (portal-terminal-select second) :type 'user-error)
      (kill-buffer second)
      (should-error (portal-terminal-select second) :type 'user-error)
      (should (eq (current-buffer) first)))))

(ert-deftest portal-terminal-kill-asks-while-its-program-runs ()
  (portal-choose-test--environment
    (let* ((portal-terminal-confirm-kill t)
           (first (portal-choose-test--open "one/app"))
           (second (portal-choose-test--open "one/app"))
           (third (portal-choose-test--open "two/app"))
           (asked nil) (answer nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt asked) answer)))
        ;; Every way of killing asks while the program runs; refusing keeps it.
        (should-not (kill-buffer first))
        (should (equal asked (list (format "Kill terminal %s and its running shell? "
                                           (buffer-name first)))))
        (should (memq first (portal-terminal-buffers)))
        (setq answer t)
        (should (kill-buffer first))
        (should (equal (portal-terminal-buffers) (list second third)))
        ;; An exited program, or a shell already closed, goes without asking.
        (setq asked nil)
        (portal-fake-native-report (buffer-local-value 'portal-view--target second) :exited t)
        (kill-buffer second)
        (should-not asked)
        (let ((closed (portal-choose-test--open "one/app")))
          (with-current-buffer closed (portal-terminal-close))
          (kill-buffer closed))
        (should-not asked)
        (let ((portal-terminal-confirm-kill nil))
          (kill-buffer (portal-choose-test--open "one/app")))
        (should-not asked)
        ;; C-b x asks once, and keeps the pane when refused.
        (switch-to-buffer third)
        (let ((window (split-window-right)))
          (select-window window)
          (setq answer nil)
          (portal-terminal-kill-pane)
          (should (= (length asked) 1))
          (should (window-live-p window))
          (should (buffer-live-p third))
          (setq answer t)
          (portal-terminal-kill-pane)
          (should (= (length asked) 2))
          (should-not (window-live-p window))
          (should-not (buffer-live-p third)))
        ;; Quick terminals keep their own question, asked once.
        (setq asked nil)
        (portal-terminal-toggle)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (portal-terminal-quick-forget))
        (should-not asked)
        (should-not (portal-view-buffers))))))

;;; portal-terminal-choose-tests.el ends here
