;;; portal-tasks-tests.el --- Task browser buffers against the fake module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real buffers, windows and project detection drive `portal-tasks'; only
;; the native module is replaced.  Most tests simulate the app host; one runs
;; the real one, from PORTAL_TEST_HOST when set.
(require 'ert)
(require 'cl-lib)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal)

(when-let* ((program (getenv "PORTAL_TEST_HOST")))
  (setq portal-server-program program))

(defconst portal-tasks-test--host "http://127.0.0.1:1/0123abcd")

(defmacro portal-tasks-test--environment (&rest body)
  "Run BODY with a simulated app host in one fresh window.
DIRECTORY is a fresh folder with no project around it.  Setting HOST
makes the app host ready."
  (declare (indent 0))
  `(let ((initial-buffers (buffer-list))
         (context (frame-parameter nil 'portal-project-context))
         (directory (file-name-as-directory (file-truename (make-temp-file "portal-tasks-" t))))
         (host nil))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'portal-start-server) #'ignore)
                     ((symbol-function 'portal-server-url) (lambda () host)))
             (set-frame-parameter nil 'portal-project-context nil)
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*scratch*"))
             ,@body)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (kill-buffer buffer))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory directory t)))
     (should-not (portal-view-buffers))
     (should-not (portal-fake-native-targets))))

(defun portal-tasks-test--project (directory name &optional dir-locals)
  "Make project NAME in DIRECTORY, with DIR-LOCALS; return its root."
  (let ((root (file-name-as-directory (expand-file-name name directory))))
    (make-directory (expand-file-name ".git" root) t)
    (make-directory (expand-file-name "src" root) t)
    (when dir-locals
      (with-temp-file (expand-file-name ".dir-locals.el" root)
        (prin1 dir-locals (current-buffer))))
    root))

(defun portal-tasks-test--edit (file)
  "Select a buffer visiting FILE, without reading it, as a command would."
  (switch-to-buffer (generate-new-buffer (file-name-nondirectory file)))
  (setq buffer-file-name file
        default-directory (file-name-directory file))
  (run-hooks 'post-command-hook))

(defun portal-tasks-test--auxiliary (directory)
  "Select a new auxiliary buffer, as a terminal is, in DIRECTORY."
  (switch-to-buffer (generate-new-buffer "*auxiliary*"))
  (special-mode)
  (setq default-directory directory))

(defun portal-tasks-test--path (root)
  "Return the app host path of ROOT's task list."
  (concat "/tasks?root=" (url-hexify-string (directory-file-name root))))

(defun portal-tasks-test--url (&optional target)
  "Return the URL TARGET, by default the selected pane's view, loaded last."
  (plist-get (portal--inspect (or target (portal-view-target))) :url))

(defun portal-tasks-test--message (target type url)
  "Send TARGET's view's bridge message TYPE about URL, as the view does."
  (with-current-buffer "*scratch*"
    (portal-fake-native-post target (json-serialize (list :type type :url url)))
    (portal-fake-native-send (format "bridge %s\n" target))))

(defun portal-tasks-test--page (target path)
  "Send a `page' message: TARGET's view now shows app host PATH."
  (portal-tasks-test--message target "page" (concat portal-tasks-test--host path)))

(ert-deftest portal-tasks-is-a-command-once-portal-is-loaded ()
  (should (commandp #'portal-tasks))
  (should (custom-variable-p 'portal-tasks-directory))
  (should (equal (default-value 'portal-tasks-directory) "tasks/"))
  (should (funcall (get 'portal-tasks-directory 'safe-local-variable) "backlog/")))

(ert-deftest portal-tasks-opens-at-once-and-loads-when-the-app-host-is-ready ()
  (portal-tasks-test--environment
    (let ((project (portal-tasks-test--project directory "one")))
      (portal-tasks-test--edit (expand-file-name "src/main.el" project))
      (let* ((buffer (portal-tasks))
             (target (portal-view-target))
             (root (expand-file-name "tasks" project)))
        (should (eq buffer (current-buffer)))
        (should (eq major-mode 'portal-web-mode))
        (should (equal portal-tasks--root root))
        (should (equal (buffer-name) (format "*portal: tasks %s*" (abbreviate-file-name root))))
        (let ((options (plist-get (portal--inspect target) :options)))
          (should (equal (plist-get options :toolbar) "navigation"))
          (should (plist-get options :hosted)))
        ;; The missing root is not created; the app host explains it.
        (should-not (file-exists-p root))
        (should (equal (portal-tasks-test--url) "about:blank"))
        (setq host portal-tasks-test--host)
        (run-hooks 'portal-server-ready-hook)
        (should (equal (portal-tasks-test--url)
                       (concat portal-tasks-test--host (portal-tasks-test--path root))))))))

(ert-deftest portal-tasks-choose-the-root-of-the-project-being-edited ()
  (portal-tasks-test--environment
    (setq host portal-tasks-test--host)
    (let* ((one (portal-tasks-test--project directory "one"))
           (two (portal-tasks-test--project directory "two" '((nil . ((portal-tasks-directory . "work/todo/"))))))
           (link (expand-file-name "link" directory)))
      (make-symbolic-link (directory-file-name one) link)
      ;; A symbolic link in the path resolves; the task root need not exist.
      (portal-tasks-test--edit (expand-file-name "src/a.el" link))
      (let ((first (portal-tasks)))
        (should (equal portal-tasks--root (expand-file-name "tasks" one)))
        ;; An auxiliary buffer elsewhere uses the last file's project, and
        ;; browsing a root again keeps its buffer, view and page.
        (portal-tasks-test--auxiliary "/")
        (setq portal-fake-native-log nil)
        (should (eq (portal-tasks) first))
        (should-not portal-fake-native-log)
        ;; The other project's directory-local option wins, even from an
        ;; auxiliary buffer; both roots have their own view.
        (portal-tasks-test--edit (expand-file-name "src/b.el" two))
        (portal-tasks-test--auxiliary "/")
        (let ((second (portal-tasks)))
          (should-not (eq second first))
          (should (equal portal-tasks--root (expand-file-name "work/todo" two)))
          (should (equal (portal-tasks-test--url)
                         (concat host (portal-tasks-test--path (expand-file-name "work/todo" two)))))
          (should (= (length (portal-view-buffers 'web)) 2))
          (should (buffer-live-p first))
          ;; An absolute option is used as it is.
          (let ((portal-tasks-directory (expand-file-name "shared" link)))
            (portal-tasks-test--edit (expand-file-name "src/c.el" one))
            (should (equal (buffer-local-value 'portal-tasks--root (portal-tasks))
                           (expand-file-name "shared" one))))
          ;; A prefix argument chooses the root.
          (portal-tasks-test--edit (expand-file-name "src/d.el" two))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _) (file-name-as-directory link))))
            (let ((current-prefix-arg '(4)))
              (call-interactively #'portal-tasks)))
          (should (equal portal-tasks--root (directory-file-name one)))
          (should (= (length (portal-view-buffers 'web)) 4)))))))

(ert-deftest portal-tasks-prompt-outside-a-project-and-reject-remote-roots ()
  (portal-tasks-test--environment
    (let ((prompts 0)
          (folder (expand-file-name "loose" directory)))
      (portal-tasks-test--edit (expand-file-name "notes.txt" directory))
      (cl-letf (((symbol-function 'read-directory-name)
                 (lambda (&rest _) (cl-incf prompts) folder)))
        (portal-tasks)
        (should (= prompts 1))
        (should (equal portal-tasks--root folder)))
      (should-error (portal-tasks "/ssh:example:/work/tasks") :type 'user-error)
      (portal-tasks-test--edit "/ssh:example:/work/src/main.el")
      (should-error (portal-tasks) :type 'user-error)
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-tasks-keep-the-page-on-screen-for-reload-and-restart ()
  (portal-tasks-test--environment
    (setq host portal-tasks-test--host)
    (let* ((root (directory-file-name directory))
           (buffer (portal-tasks root))
           (target (portal-view-target))
           (list (portal-tasks-test--path root))
           (detail (concat list "&task=fix%20search%20%C3%A9&show=all")))
      ;; Following a link, or going back or forward, commits another page.
      (portal-tasks-test--page target (concat detail "#notes"))
      (should (equal portal-web--hosted-path detail))
      (should (eq (current-buffer) buffer))
      (setq portal-fake-native-log nil)
      (call-interactively (key-binding "g"))
      (should (equal portal-fake-native-log `((portal--web-load ,target ,(concat host detail)))))
      ;; Pages of other apps change nothing.
      (portal-tasks-test--page target "/hello")
      (should (equal portal-web--hosted-path detail))
      ;; A restarted app host loads the page on screen with its new token.
      (setq host "http://127.0.0.1:2/4567ef")
      (call-interactively (key-binding "g"))
      (should (equal (portal-tasks-test--url target) (concat host detail)))
      (portal-tasks-test--page target list)
      (should (equal portal-web--hosted-path list))
      (switch-to-buffer "*scratch*")
      (should (eq (portal-tasks root) buffer))
      (should (equal (portal-tasks-test--url target) (concat host detail))))))

(ert-deftest portal-tasks-hand-attachments-to-another-pane ()
  (portal-tasks-test--environment
    (setq host portal-tasks-test--host)
    (let* ((display-buffer-alist nil)
           (file (expand-file-name "fix search/mockup notes.txt" directory))
           (buffer (portal-tasks (directory-file-name directory)))
           (target (portal-view-target))
           (origin (selected-window)))
      (make-directory (file-name-directory file))
      (with-temp-file file (insert "one\ntwo\nthree\n"))
      (portal-view-sync)
      (portal-input-focus)
      (should (plist-get (portal--inspect target) :focused))
      (portal-tasks-test--message
       target "follow"
       (format "file://%s#L2" (url-hexify-string file (cons ?/ url-unreserved-chars))))
      (while unread-command-events
        (let ((event (pop unread-command-events)))
          (funcall (lookup-key global-map (vector (car event))) event)))
      (should (equal buffer-file-name file))
      (should (= (line-number-at-pos) 2))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) buffer))
      (should-not (plist-get (portal--inspect target) :focused))
      ;; The task page and its history stay as they were.
      (should (= (length (portal-fake-native-calls 'portal--web-load)) 2))
      (portal-preview-return)
      (should (eq (current-buffer) buffer))
      (kill-buffer (get-file-buffer file)))))

(defun portal-tasks-test--wait (predicate)
  "Allow asynchronous process work until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(ert-deftest portal-tasks-with-the-real-app-host ()
  (skip-unless (file-executable-p portal-server-program))
  (let ((initial-buffers (buffer-list))
        (directory (file-truename (make-temp-file "portal-tasks-" t)))
        (url-proxy-services nil))
    (portal-fake-native-reset)
    (save-window-excursion
      (unwind-protect
          (let* ((project (portal-tasks-test--project directory "project"))
                 (tasks (expand-file-name "tasks" project))
                 (fetch (lambda ()
                          (let ((response (url-retrieve-synchronously (portal-tasks-test--url) t t 3)))
                            (unwind-protect (with-current-buffer response
                                              (decode-coding-string (buffer-string) 'utf-8))
                              (kill-buffer response))))))
            (make-directory tasks)
            (with-temp-file (expand-file-name "fix-search.md" tasks)
              (insert "---\nstatus: todo\n---\n# Fix search\n"))
            (with-temp-file (expand-file-name "shipped.md" tasks)
              (insert "---\nstatus: done\n---\n# Shipped\n"))
            (with-temp-file (expand-file-name "follow-up.md" tasks)
              (insert "---\nstatus: todo\ndepends_on: [fix-search]\n---\n# Follow up\n"))
            (should-not (portal-server-url))
            (portal-tasks-test--edit (expand-file-name "src/main.el" project))
            (portal-tasks)
            (portal-tasks-test--wait #'portal-server-url)
            (should (equal (portal-tasks-test--url)
                           (concat (portal-server-url) (portal-tasks-test--path tasks))))
            (let ((page (funcall fetch)))
              (should (string-match-p "Fix search</span><span class=\"readiness readiness-ready\">Ready" page))
              (should (string-match-p "Follow up</span><span class=\"readiness readiness-blocked\">Blocked by Fix search" page))
              (should-not (string-match-p "Shipped" page)))
            ;; Saving a status change shows on reload; browsing writes nothing.
            (with-temp-file (expand-file-name "fix-search.md" tasks)
              (insert "---\nstatus: done\n---\n# Fix search\n"))
            (call-interactively (key-binding "g"))
            (let ((page (funcall fetch)))
              (should-not (string-match-p "Fix search</span>" page))
              (should (string-match-p "<span class=\"rank\">1</span><span class=\"status status-todo\">todo</span><span class=\"title\">Follow up</span><span class=\"readiness readiness-ready\">Ready" page)))
            (with-temp-file (expand-file-name "follow-up.md" tasks)
              (insert "---\nstatus: done\n---\n# Follow up\n"))
            (call-interactively (key-binding "g"))
            (should (string-match-p "No unfinished tasks" (funcall fetch)))
            (should (equal (directory-files tasks nil "\\`[^.]")
                           '("fix-search.md" "follow-up.md" "shipped.md"))))
        (let ((process portal--server-process))
          (portal-stop-server)
          (when process (portal-tasks-test--wait (lambda () (not (process-live-p process))))))
        (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
          (kill-buffer buffer))
        (delete-directory directory t)))))

;;; portal-tasks-tests.el ends here
