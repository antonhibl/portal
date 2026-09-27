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
                     ((symbol-function 'portal-server-send) #'ignore)
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
  (concat "/tasks?root=" (url-hexify-string (directory-file-name root))
          "&context=" (url-hexify-string portal-view--target)))

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
           (detail (concat list "&task=epic%2Ffix%20search%20%C3%A9&view=execution&show=all")))
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

;; Operations.

(defun portal-tasks-test--bytes (file)
  "Return FILE's bytes, as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun portal-tasks-test--plan (file status)
  "Return the edit the app host plans to give FILE STATUS."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (goto-char (point-min))
    (re-search-forward "^status: \\(todo\\|done\\)")
    (list :file file :start (1- (match-beginning 1)) :end (1- (match-end 1))
          :text status :before (secure-hash 'sha256 (current-buffer)))))

(defconst portal-tasks-test--refresh '("{\"type\":\"refresh\"}")
  "The bridge message that refreshes a task page in place.")

(ert-deftest portal-tasks-status-edits-save-only-the-planned-bytes ()
  (portal-tasks-test--environment
    (setq host portal-tasks-test--host)
    (let* ((root (directory-file-name directory))
           (file (expand-file-name "fix search é/content.md" root))
           (text (encode-coding-string
                  "\uFEFF---\r\ntitle: Café\r\nstatus: todo # keep\r\n---\r\n# Fix\r\nstatus: todo\r\n"
                  'utf-8)))
      (make-directory (file-name-directory file))
      (let ((coding-system-for-write 'no-conversion))
        (write-region text nil file))
      (let ((visiting (find-file-noselect file))
            (target (progn (portal-tasks root) (portal-view-target))))
        (setq portal-fake-native-log nil)
        (should (equal (portal-tasks--status-action (portal-tasks-test--plan file "done"))
                       (list :file file)))
        ;; The BOM, CRLF line ends, comment and body keep their bytes.
        (should (equal (portal-tasks-test--bytes file)
                       (string-replace "todo # keep" "done # keep" text)))
        ;; A buffer visiting the file unmodified shows what was saved.
        (with-current-buffer visiting
          (should-not (buffer-modified-p))
          (should (string-search "status: done # keep" (buffer-string))))
        ;; The page refreshes in place, and loads no other page.
        (should (equal (portal-fake-native-calls 'portal--web-send)
                       (list (cons target portal-tasks-test--refresh))))
        (should-not (portal-fake-native-calls 'portal--web-load))
        (kill-buffer visiting)))))

(ert-deftest portal-tasks-status-edits-refuse-unsaved-changed-and-unwritable-files ()
  (portal-tasks-test--environment
    (setq host portal-tasks-test--host)
    (let* ((root (directory-file-name directory))
           (file (expand-file-name "task.md" root))
           (text "---\nstatus: todo\n---\n# Task\n")
           (changed (concat text "Saved elsewhere.\n"))
           (outside (make-temp-file "portal-outside-" nil ".md" text)))
      (unwind-protect
          (progn
            (with-temp-file file (insert text))
            (let ((plan (portal-tasks-test--plan file "done"))
                  (visiting (find-file-noselect file)))
              (portal-tasks root)
              ;; Unsaved changes stay unsaved, and nothing is written.
              (with-current-buffer visiting
                (goto-char (point-max))
                (insert "Unsaved.\n"))
              (should (string-search "unsaved changes"
                                     (cadr (should-error (portal-tasks--status-action plan)
                                                         :type 'user-error))))
              (should (equal (portal-tasks-test--bytes file) text))
              (should (buffer-modified-p visiting))
              (should (string-search "Unsaved." (with-current-buffer visiting (buffer-string))))
              (kill-buffer visiting)
              ;; A file that changed since the plan is left as it is.
              (with-temp-file file (insert changed))
              (should (string-search "changed on disk"
                                     (cadr (should-error (portal-tasks--status-action plan)
                                                         :type 'user-error))))
              (should (equal (portal-tasks-test--bytes file) changed))
              ;; A failed save is an error, and changes nothing.
              (setq plan (portal-tasks-test--plan file "done"))
              (set-file-modes file #o444)
              (unwind-protect
                  (should-error (portal-tasks--status-action plan) :type 'file-error)
                (set-file-modes file #o644))
              (should (equal (portal-tasks-test--bytes file) changed))
              ;; Only a file in the view's root is written.
              (should-error (portal-tasks--status-action
                             (plist-put (portal-tasks-test--plan outside "done") :file outside))
                            :type 'user-error)
              (should (equal (portal-tasks-test--bytes outside) text))
              (should (portal-tasks--status-action plan))
              (should (equal (portal-tasks-test--bytes file)
                             (string-replace "todo" "done" changed)))))
        (delete-file outside)))))

(ert-deftest portal-tasks-edit-opens-the-source-in-another-pane ()
  (portal-tasks-test--environment
    (setq host portal-tasks-test--host)
    (let* ((display-buffer-alist nil)
           (root (directory-file-name directory))
           (file (expand-file-name "task.md" root)))
      (with-temp-file file (insert "---\nstatus: todo\n---\n# Task\n"))
      (let ((visiting (find-file-noselect file)))
        (with-current-buffer visiting
          (goto-char (point-max))
          (insert "Draft.\n"))
        (let* ((tasks (portal-tasks root))
               (target (portal-view-target))
               (origin (selected-window)))
          (portal-view-sync)
          (portal-input-focus)
          (should (plist-get (portal--inspect target) :focused))
          (setq portal-fake-native-log nil)
          (should (equal (portal-tasks--edit-action (list :file file)) (list :file file)))
          ;; The buffer is reused with its unsaved text, and Emacs has the keyboard.
          (should (eq (current-buffer) visiting))
          (should (buffer-modified-p))
          (should (string-search "Draft." (buffer-string)))
          (should-not (eq (selected-window) origin))
          (should (eq (window-buffer origin) tasks))
          (should-not (plist-get (portal--inspect target) :focused))
          ;; The task page and its history stay as they were.
          (should-not (portal-fake-native-calls 'portal--web-load))
          (portal-preview-return)
          (should (eq (current-buffer) tasks))
          (should-error (portal-tasks--edit-action (list :file "/etc/hosts")) :type 'user-error)
          (with-current-buffer visiting (set-buffer-modified-p nil)))))))

(defun portal-tasks-test--save (file)
  "Change FILE in a buffer and save it, as a user would."
  (make-directory (file-name-directory file) t)
  (with-current-buffer (find-file-noselect file)
    (insert "Saved.\n")
    (save-buffer)
    (kill-buffer)))

(ert-deftest portal-tasks-saving-in-a-root-refreshes-its-loaded-view ()
  (portal-tasks-test--environment
    (let* ((one (expand-file-name "one" directory))
           (two (expand-file-name "two" directory)))
      (make-directory one)
      (make-directory two)
      (let ((target (progn (portal-tasks one) (portal-view-target))))
        (portal-tasks two)
        ;; A view still waiting for the app host will load saved files anyway.
        (portal-tasks-test--save (expand-file-name "task.md" one))
        (should-not (portal-fake-native-calls 'portal--web-send))
        (setq host portal-tasks-test--host)
        (run-hooks 'portal-server-ready-hook)
        (setq portal-fake-native-log nil)
        ;; Only the view of the root holding the file refreshes, at any depth.
        (portal-tasks-test--save (expand-file-name "group/task.md" one))
        (portal-tasks-test--save (expand-file-name "notes.md" directory))
        (should (equal (portal-fake-native-calls 'portal--web-send)
                       (list (cons target portal-tasks-test--refresh))))
        (should-not (portal-fake-native-calls 'portal--web-load))))))

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
              (should (string-match-p "Fix search</span></a>" page))
              (should (string-match-p "Follow up</span><span class=\"waits\">after 1</span>" page))
              (should-not (string-match-p "Shipped" page)))
            ;; Saving a status change shows on reload; browsing writes nothing.
            (with-temp-file (expand-file-name "fix-search.md" tasks)
              (insert "---\nstatus: done\n---\n# Fix search\n"))
            (call-interactively (key-binding "g"))
            (let ((page (funcall fetch)))
              (should-not (string-match-p "Fix search</span>" page))
              (should (string-match-p "<li[^>]*><a [^>]*><span class=\"rank\">1</span><span class=\"title\">Follow up</span></a>" page)))
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
