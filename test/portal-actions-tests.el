;;; portal-actions-tests.el --- Hosted actions and terminal launch contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'url)
(require 'portal-fake-native)
(require 'portal)

(when-let* ((program (getenv "PORTAL_TEST_HOST")))
  (setq portal-server-program program))

(defmacro portal-actions-test--environment (&rest body)
  (declare (indent 0))
  `(let ((initial (buffer-list))
         (directory (file-truename (make-temp-file "portal-actions-" t)))
         (unread-command-events nil)
         (display-buffer-alist nil))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (progn
             (make-directory (expand-file-name ".git" directory))
             (make-directory (expand-file-name "tasks" directory))
             (with-temp-file (expand-file-name "tasks/task.md" directory)
               (insert "---\nid: task\nstatus: todo\n---\n# Task\n"))
             ,@body)
         (portal-stop-server)
         (dolist (buffer (cl-set-difference (buffer-list) initial)) (kill-buffer buffer))
         (delete-directory directory t)))))

(defun portal-actions-test--drain ()
  (while unread-command-events
    (let ((event (pop unread-command-events)))
      (should (eq (car event) 'portal-action))
      (portal-actions--dispatch event))))

(defun portal-actions-test--wait (predicate)
  (let ((deadline (+ (float-time) 8)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (portal-actions-test--drain))
    (should (funcall predicate))))

(defun portal-actions-test--http (url &optional data type)
  "Fetch URL, or POST DATA of TYPE to it, as a page of the app host would."
  (let* ((url-proxy-services nil)
         (url-request-method (if data "POST" "GET"))
         (url-request-data data)
         (url-request-extra-headers
          (when data `(("Content-Type" . ,(or type "application/x-www-form-urlencoded"))
                       ("Origin" . ,(format "http://127.0.0.1:%d" (url-port (url-generic-parse-url url)))))))
         result finished)
    (url-retrieve url (lambda (_status)
                        (setq result (buffer-string) finished t)
                        (kill-buffer (current-buffer))) nil t t)
    (portal-actions-test--wait (lambda () finished))
    result))

(ert-deftest portal-actions-real-host-launches-once-from-the-originating-project ()
  (skip-unless (file-executable-p portal-server-program))
  (portal-actions-test--environment
   (let ((portal-tasks-claude-program "/bin/echo"))
     (portal-tasks (expand-file-name "tasks" directory)))
   (portal-actions-test--wait #'portal-server-url)
   (let* ((source (current-buffer))
          (target portal-view--target)
          (url (concat portal-web--url "&task=task&view=execution&show=all"))
          (page (portal-actions-test--http url)))
     (should (string-match "name=\"request\" value=\"\\([^\"]+\\)\"" page))
     (let ((data (concat "request=" (match-string 1 page)))
           (post (concat (portal-server-url) "/tasks/implement")))
       ;; Editing another project must not retarget an outstanding form.
       (switch-to-buffer (get-buffer-create "*elsewhere*"))
       (setq default-directory "/")
       (should (string-search "Claude terminal opened" (portal-actions-test--http post data)))
       (let* ((terminals (portal-view-buffers 'terminal))
              (terminal (car terminals)))
         (should (= (length terminals) 1))
         (should (equal (buffer-local-value 'default-directory terminal)
                        (file-name-as-directory directory)))
         (should (buffer-live-p source))
         (should (portal--inspect target))
         (let* ((state (portal--inspect (buffer-local-value 'portal-view--target terminal)))
                (argv (json-parse-string (plist-get (plist-get state :options) :argv)
                                         :array-type 'list)))
           (with-temp-buffer
             (should (= 0 (apply #'call-process (car argv) nil t nil (cdr argv))))
             (should (equal (string-trim (buffer-string))
                            "--dangerously-skip-permissions implement @tasks/task.md"))))
         (portal-actions-test--http post data)
         (should (= (length (portal-view-buffers 'terminal)) 1))))
     ;; Restart requires re-registration, but keeps the page's instance context.
     (with-current-buffer source
       (portal-restart-server)
       (portal-web-reload)
       (portal-actions-test--wait #'portal-server-url)
       (should (string-search "name=\"request\""
                              (portal-actions-test--http (concat portal-web--url "&task=task"))))))))

(ert-deftest portal-actions-real-host-changes-and-opens-tasks-through-emacs ()
  (skip-unless (file-executable-p portal-server-program))
  (portal-actions-test--environment
   (let ((root (expand-file-name "tasks" directory))
         (file (expand-file-name "tasks/task.md" directory)))
     (portal-tasks root)
     (portal-actions-test--wait #'portal-server-url)
     (let* ((tasks (current-buffer))
            (target portal-view--target)
            (act (lambda (&rest body)
                   (with-current-buffer tasks
                     (portal-actions-test--http
                      (concat (portal-server-url) "/tasks/action")
                      (json-serialize (append (list :root root :context target :task "task") body))
                      "application/json"))))
            (page (portal-actions-test--http (concat portal-web--url "&task=task"))))
       (should (string-search "data-op=\"status\" data-status=\"done\">Complete</button>" page))
       (should (string-match-p "\n\n{}\\'" (funcall act :action "status" :status "done")))
       (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                      "---\nid: task\nstatus: done\n---\n# Task\n"))
       ;; Repeating the request leaves the task done.
       (should (string-match-p "\n\n{}\\'" (funcall act :action "status" :status "done")))
       (should (string-search "status: done" (with-temp-buffer (insert-file-contents file) (buffer-string))))
       ;; Unsaved changes in Emacs stop a change, and the page says why.
       (with-current-buffer (find-file-noselect file)
         (insert "Draft.\n")
         (should (string-search "unsaved changes" (funcall act :action "status" :status "todo")))
         (should (buffer-modified-p))
         (set-buffer-modified-p nil))
       (should (string-search "status: done" (with-temp-buffer (insert-file-contents file) (buffer-string))))
       ;; Edit in Emacs shows the source beside the task page.
       (should (string-match-p "\n\n{}\\'" (funcall act :action "edit")))
       (should (equal (buffer-file-name (window-buffer (selected-window))) file))
       (should (get-buffer-window tasks))))))

(ert-deftest portal-actions-rejects-closed-expired-and-unsupported-requests ()
  (portal-actions-test--environment
   (let* ((process (make-process :name "action-test" :command '("cat") :filter #'ignore :noquery t))
          (portal--server-process process)
          (portal-server-request-function #'portal-actions--receive)
          replies)
     (unwind-protect
         (cl-letf (((symbol-function 'portal-server-send) (lambda (reply &optional _) (push reply replies)))
                   ((symbol-function 'portal-start-server) #'ignore))
           (process-put process 'url "http://127.0.0.1:1/abcd")
           (process-put process 'requests (make-hash-table :test #'equal))
           (portal-tasks (expand-file-name "tasks" directory))
           (let* ((source (current-buffer))
                  (target portal-view--target)
                  (request (list :type "request" :id "one" :context target
                                 :operation "unsupported" :arguments nil
                                 :deadline (+ (* 1000 (float-time)) 10000)))
                  (json (concat (json-serialize request) "\n")))
             ;; Partial and batched records, including replay, queue only once.
             (portal--server-filter process (substring json 0 5))
             (should-not unread-command-events)
             (portal--server-filter process (concat (substring json 5) json))
             (should (= (length unread-command-events) 1))
             (portal-actions-test--drain)
             (should (string-search "does not support" (plist-get (car replies) :error)))
             (setq request (plist-put request :id "two"))
             (setq request (plist-put request :operation "terminal.open"))
             (portal-actions--receive process request)
             (kill-buffer source)
             (portal-actions-test--drain)
             (should (string-search "closed" (plist-get (car replies) :error)))
             (setq request (plist-put request :deadline 0))
             (portal-actions--receive process request)
             (portal-actions-test--drain)
             (should (string-search "expired" (plist-get (car replies) :error)))
             (should-not (portal-view-buffers 'terminal))))
       (delete-process process)))))

(ert-deftest portal-terminal-start-preserves-literal-arguments-and-cleans-up-failure ()
  (portal-actions-test--environment
   (let* ((arguments '("-c" "import json,sys; print(json.dumps(sys.argv[1:]))"
                       "implement @tasks/space ' é.md" "$(touch SHOULD_NOT_EXIST)" "`pwd`" ""))
          (buffer (portal-terminal-start directory "/usr/bin/python3" arguments))
          (options (plist-get (portal--inspect (buffer-local-value 'portal-view--target buffer)) :options))
          (argv (json-parse-string (plist-get options :argv) :array-type 'list)))
     (with-temp-buffer
       (should (= 0 (apply #'call-process (car argv) nil t nil (cdr argv))))
       (should (equal (append (json-parse-string (buffer-string)) nil) (nthcdr 2 arguments))))
     (should-not (file-exists-p (expand-file-name "SHOULD_NOT_EXIST" directory)))
     (should-error (portal-terminal-start directory "" nil) :type 'user-error)
     (let ((portal-fake-native-failures '(portal--open)))
       (should-error (portal-terminal-start directory "/bin/echo" '("hello"))))
     (should (= (length (portal-view-buffers 'terminal)) 1)))))

(ert-deftest portal-terminal-start-leaves-program-lookup-to-the-shell ()
  (portal-actions-test--environment
   (let ((exec-path '("/usr/bin" "/bin"))
         (process-environment '("PATH=/usr/bin:/bin" "PORTAL_VALUE=from-lisp")))
     (should-not (executable-find "portal-startup-cli"))
     (let* ((buffer (portal-terminal-start directory "portal-startup-cli" '("literal argument")))
            (options (plist-get (portal--inspect (buffer-local-value 'portal-view--target buffer)) :options)))
       (should (equal (json-parse-string (plist-get options :argv))
                      ["portal-startup-cli" "literal argument"]))
       (should-not (plist-member options :environment))))))
