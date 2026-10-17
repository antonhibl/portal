;;; portal-web-tests.el --- Web buffers against the fake module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real buffers and windows drive `portal-web.el'; only the native module is
;; replaced.  Most tests simulate the app host; one runs the real one, from
;; PORTAL_TEST_HOST when set.  Batch Emacs never runs window change hooks, so
;; tests sync.
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

(defmacro portal-web-test--environment (&rest body)
  "Run BODY in one fresh window, then kill its buffers and check cleanup."
  (declare (indent 0))
  `(let ((initial-buffers (buffer-list)))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*scratch*"))
             ,@body)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (kill-buffer buffer))))
     (should-not (portal-view-buffers))
     (should-not (portal-fake-native-targets))))

(defun portal-web-test--state (&optional target)
  "Inspect TARGET, by default the selected pane's view."
  (portal--inspect (or target (portal-view-target))))

(defun portal-web-test--toolbar (&optional target)
  "Return the toolbar TARGET opened with."
  (plist-get (plist-get (portal-web-test--state target) :options) :toolbar))

(ert-deftest portal-web-appearance-starts-new-views-and-changes-open-ones ()
  (portal-web-test--environment
    (let ((original portal-web-appearance))
      (unwind-protect
          (progn
            ;; The system's appearance passes no option.
            (setq portal-web-appearance nil)
            (portal-open-url "https://example.com/")
            (let ((system (portal-view-target)))
              (should-not (plist-member (plist-get (portal-web-test--state) :options)
                                        :appearance))
              (setq portal-fake-native-log nil)
              (setopt portal-web-appearance 'dark)
              (should (equal (portal-fake-native-calls 'portal--web-appearance) '(("dark"))))
              (portal-open-url "https://example.com/")
              (should (equal (plist-get (plist-get (portal-web-test--state) :options) :appearance)
                             "dark"))
              (should (equal (plist-get (plist-get (portal-web-test--state) :options) :toolbar)
                             "navigation"))
              (should-not (equal (portal-view-target) system)))
            ;; An unknown appearance changes nothing.
            (setq portal-fake-native-log nil)
            (should-error (setq portal-web-appearance 'sepia))
            (should-error (setq portal-web-appearance "light"))
            (should (eq portal-web-appearance 'dark))
            (should-error (portal-web-set-appearance 'sepia))
            (should-not (portal-fake-native-calls 'portal--web-appearance))
            ;; The command sets the option; "system" is nil.
            (portal-web-set-appearance 'light)
            (should (eq portal-web-appearance 'light))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "system")))
              (call-interactively #'portal-web-set-appearance))
            (should-not portal-web-appearance)
            (should (equal (portal-fake-native-calls 'portal--web-appearance)
                           '(("light") (nil)))))
        (setq portal-web-appearance original)))))

(ert-deftest portal-web-open-url-opens-a-new-buffer-each-time ()
  (portal-web-test--environment
    (portal-open-url "https://example.com/page")
    (let ((first (current-buffer))
          (first-target (portal-view-target)))
      (portal-open-url "https://example.com/page")
      (let ((second-target (portal-view-target)))
        (should-not (eq (current-buffer) first))
        (should (equal (buffer-name first) "*portal: example.com*"))
        (should (equal (buffer-name) "*portal: example.com*<2>"))
        (should (eq major-mode 'portal-web-mode))
        (should portal-input-mode)
        (should (string-prefix-p "web:" second-target))
        (should-not (equal first-target second-target))
        (should (equal (portal-view-buffers 'web) (list first (current-buffer))))
        (dolist (target (list first-target second-target))
          (should (equal (plist-get (portal-web-test--state target) :url)
                         "https://example.com/page"))
          (should (equal (portal-web-test--toolbar target) "navigation")))
        (portal-view-sync)
        (should-not (plist-get (portal-web-test--state first-target) :visible))
        (should (plist-get (portal-web-test--state second-target) :visible))))
    (should (equal (buffer-name (progn (portal-open-url "data:text/html,<p>x</p>")
                                       (current-buffer)))
                   "*portal: data*"))
    (dolist (url '("" "relative/path" "javascript:alert(1)" "https://" 42))
      (should-error (portal-open-url url) :type 'user-error))
    (should (= (length (portal-fake-native-calls 'portal--open)) 3))))

(ert-deftest portal-web-view-appears-only-in-the-selected-pane ()
  (portal-web-test--environment
    (portal-open-url "about:blank")
    (let* ((target (portal-view-target))
           (origin (selected-window))
           (other (split-window-right)))
      (should (eq (window-buffer other) (current-buffer)))
      (portal-view-sync)
      (should (equal (portal-view-target origin) target))
      (should-not (portal-view-target other))
      (should (equal (plist-get (portal-web-test--state target) :edges)
                     (window-inside-pixel-edges origin)))
      (select-window other)
      (portal-view-sync)
      (should (equal (portal-view-target other) target))
      (should-not (portal-view-target origin))
      (should (equal (plist-get (portal-web-test--state target) :edges)
                     (window-inside-pixel-edges other)))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-web-render-html-reuses-its-buffer-and-g-reloads ()
  (portal-web-test--environment
    (let* ((directory (make-temp-file "portal-web-" t))
           (file (expand-file-name "Résumé #%?.html" directory))
           (other (expand-file-name "other.html" directory))
           (url (browse-url-file-url file)))
      (unwind-protect
          (progn
            (with-temp-file file (insert "<title>Page</title>"))
            (with-temp-file other (insert "<title>Other</title>"))
            (with-temp-buffer
              (setq buffer-file-name file)
              (call-interactively #'portal-render-html))
            (set-buffer (window-buffer))
            (let ((buffer (current-buffer))
                  (target (portal-view-target)))
              (should (equal (buffer-name) "*portal: Résumé #%?.html*"))
              (should (equal (plist-get (portal-web-test--state) :url) url))
              (should (equal (portal-web-test--toolbar) "contents"))
              (switch-to-buffer "*scratch*")
              (let ((default-directory directory))
                (portal-render-html "Résumé #%?.html"))
              (should (eq (current-buffer) buffer))
              (should (equal (portal-view-target) target))
              (should (equal (portal-fake-native-calls 'portal--web-load)
                             (list (list target url) (list target url))))
              (setq portal-fake-native-log nil)
              (call-interactively (key-binding "g"))
              (should (equal portal-fake-native-log `((portal--web-load ,target ,url))))
              ;; Another file gets its own buffer.
              (portal-render-html other)
              (should-not (eq (current-buffer) buffer))
              (should (= (length (portal-fake-native-calls 'portal--open)) 1))))
        (delete-directory directory t)))
    (dolist (input '("" "relative/missing.html" "/ssh:host:/index.html" "javascript:alert(1)"))
      (should-error (portal-render-html input) :type 'user-error))))

(ert-deftest portal-web-render-html-only-reuses-preview-buffers ()
  (portal-web-test--environment
    (let* ((file (make-temp-file "portal-web-" nil ".html" "<title>Page</title>"))
           (url (browse-url-file-url file)))
      (unwind-protect
          (progn
            (portal-open-url url)
            (let ((page (current-buffer)))
              (switch-to-buffer (generate-new-buffer "client"))
              (portal-web-open url "none")
              (let ((client (current-buffer)))
                (portal-render-html file)
                (let ((preview (current-buffer)))
                  (should-not (memq preview (list page client)))
                  (should (equal (portal-web-test--toolbar) "contents"))
                  (switch-to-buffer page)
                  (portal-render-html file)
                  (should (eq (current-buffer) preview))
                  (should (= (length (portal-fake-native-calls 'portal--open)) 3))))))
        (delete-file file)))))

(ert-deftest portal-web-quit-window-hides-and-kill-buffer-releases ()
  (portal-web-test--environment
    (portal-open-url "about:blank")
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (eq (key-binding "q") #'quit-window))
      (call-interactively (key-binding "q"))
      (portal-view-sync)
      (should-not (eq (window-buffer) buffer))
      (should (buffer-live-p buffer))
      (should (portal-web-test--state target))
      (should-not (plist-get (portal-web-test--state target) :visible))
      (should-not (portal-fake-native-calls 'portal--close))
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (plist-get (portal-web-test--state target) :visible))
      (should (= (length (portal-fake-native-calls 'portal--web-load)) 1))
      (kill-buffer buffer)
      (should (equal (portal-fake-native-calls 'portal--close) (list (list target))))
      (should-not (portal-web-test--state target)))))

(ert-deftest portal-web-open-gives-any-buffer-a-web-view ()
  (portal-web-test--environment
    (switch-to-buffer (generate-new-buffer "client"))
    (should-error (portal-web-open "relative" "none") :type 'user-error)
    (should-not portal-fake-native-log)
    (let ((target (portal-web-open "about:blank" "none")))
      (should (equal (portal-view-target) target))
      (should (eq major-mode 'fundamental-mode))
      ;; The shared prefix and RET reach the view.
      (should (equal (portal-input--target) target))
      (should (eq (key-binding (kbd "RET")) #'portal-input-focus))
      (should (equal (portal-web-test--toolbar) "none"))
      (should (equal (plist-get (portal-web-test--state) :url) "about:blank"))
      (should (equal (portal-view-buffers 'web) (list (current-buffer)))))
    (switch-to-buffer (generate-new-buffer "plain"))
    (should-error (portal-web-reload) :type 'user-error)
    ;; A view that fails to open leaves the buffer as it was.
    (let ((targets (portal-fake-native-targets)))
      (dolist (failure '(portal--open portal--place portal--web-load))
        (let ((portal-fake-native-failures (list failure)))
          (should-error (portal-web-open "about:blank" "navigation")))
        (should-not portal-input-mode)
        (should-not (memq (current-buffer) (portal-view-buffers)))
        (should (equal (portal-fake-native-targets) targets))))
    ;; The buffer can still open a view afterwards.
    (should (equal (portal-web-open "about:blank" "navigation") (portal-view-target)))))

(ert-deftest portal-web-hosted-apps-open-at-once-and-load-when-the-app-host-is-ready ()
  (portal-web-test--environment
    (let ((file (make-temp-file "portal-web-" nil ".md" "# Notes\n"))
          (host nil)
          (starts 0))
      (unwind-protect
          (cl-letf (((symbol-function 'portal-start-server) (lambda () (cl-incf starts)))
                    ((symbol-function 'portal-server-url) (lambda () host)))
            (portal-hello)
            (let ((hello (current-buffer))
                  (hello-target (portal-view-target)))
              (should (equal (buffer-name) "*portal: hello*"))
              (should (equal (portal-web-test--toolbar) "navigation"))
              (portal-render-markdown file)
              (let ((markdown (current-buffer))
                    (markdown-target (portal-view-target))
                    (markdown-url (concat "http://127.0.0.1:1/token/markdown?path="
                                          (url-hexify-string file))))
                (should (equal (buffer-name) (format "*portal: %s*" (file-name-nondirectory file))))
                (should (equal (portal-web-test--toolbar) "markdown"))
                ;; Both views open at once, before the app host is ready.
                (should (= starts 2))
                (dolist (target (list hello-target markdown-target))
                  (should (plist-get (plist-get (portal-web-test--state target) :options) :hosted))
                  (should (equal (plist-get (portal-web-test--state target) :url) "about:blank")))
                (setq host "http://127.0.0.1:1/token")
                (run-hooks 'portal-server-ready-hook)
                (should (equal (plist-get (portal-web-test--state hello-target) :url)
                               "http://127.0.0.1:1/token/hello"))
                (should (equal (plist-get (portal-web-test--state markdown-target) :url)
                               markdown-url))
                ;; Previewing the same file again reuses its buffer.
                (switch-to-buffer hello)
                (setq portal-fake-native-log nil)
                (portal-render-markdown file)
                (should (eq (current-buffer) markdown))
                (should (equal portal-fake-native-log
                               `((portal--web-load ,markdown-target ,markdown-url))))
                ;; A restarted host leaves loaded apps alone; g loads from it.
                (setq host "http://127.0.0.1:2/other"
                      portal-fake-native-log nil)
                (run-hooks 'portal-server-ready-hook)
                (should-not portal-fake-native-log)
                (call-interactively (key-binding "g"))
                (should (= starts 4))
                (should (equal (plist-get (portal-web-test--state markdown-target) :url)
                               (replace-regexp-in-string "1/token" "2/other" markdown-url)))
                (should (equal (plist-get (portal-web-test--state hello-target) :url)
                               "http://127.0.0.1:1/token/hello"))
                (should (= (length (portal-fake-native-targets)) 2)))))
        (delete-file file)))))

(ert-deftest portal-web-about-passes-the-portal-and-emacs-versions ()
  (portal-web-test--environment
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token"))
              ((symbol-function 'portal-build-version) (lambda () "1.2.3"))
              (emacs-version "31.1 (test)"))
      (portal-about)
      (let ((about (current-buffer)) (target (portal-view-target)))
        (should (equal (buffer-name) "*portal: about*"))
        (should (equal (portal-web-test--toolbar) "none"))
        (should (equal (plist-get (portal-web-test--state target) :url)
                       "http://127.0.0.1:1/token/about?portal=1.2.3&emacs=31.1%20%28test%29"))
        ;; Asking again shows the same page.
        (switch-to-buffer "*scratch*")
        (portal-about)
        (should (eq (current-buffer) about))
        (should (= (length (portal-fake-native-targets)) 1))))))

(ert-deftest portal-web-hosted-app-stays-when-the-app-host-cannot-start ()
  (portal-web-test--environment
    (let ((host nil))
      (cl-letf (((symbol-function 'portal-start-server)
                 (lambda () (unless host (user-error "Build the Portal UI host"))))
                ((symbol-function 'portal-server-url) (lambda () host)))
        (should-error (portal-hello) :type 'user-error)
        (let ((target (portal-view-target)))
          (should (equal (buffer-name) "*portal: hello*"))
          (should (equal (plist-get (portal-web-test--state target) :url) "about:blank"))
          ;; Once the host can start, g loads the app in the same view.
          (setq host "http://127.0.0.1:1/token")
          (call-interactively (key-binding "g"))
          (should (equal (plist-get (portal-web-test--state target) :url)
                         "http://127.0.0.1:1/token/hello"))
          (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))))

(ert-deftest portal-web-open-hosted-gives-any-buffer-a-hosted-app ()
  (portal-web-test--environment
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
      (switch-to-buffer (generate-new-buffer "client"))
      (let ((target (portal-web-open-hosted "/hello" "none")))
        (should (equal (portal-view-target) target))
        (should (eq major-mode 'fundamental-mode))
        (should (equal (portal-web-test--toolbar) "none"))
        (should (equal (portal-fake-native-calls 'portal--web-load)
                       `((,target "about:blank") (,target "http://127.0.0.1:1/token/hello"))))))))

(ert-deftest portal-web-bridge-passes-an-apps-messages-to-its-buffer-in-order ()
  (portal-web-test--environment
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
      (switch-to-buffer (generate-new-buffer "client"))
      (let ((target (portal-web-open-hosted "/app" "none"))
            received)
        (setq portal-web-bridge-function
              (lambda (message) (push (cons (buffer-name) message) received)))
        (portal-fake-native-post target "{\"type\":\"first\",\"n\":1}" "{\"type\":\"second\"}")
        (with-current-buffer "*scratch*"
          (portal-fake-native-send (format "bridge %s\n" target)))
        (should (equal (reverse received)
                       '(("client" :type "first" :n 1) ("client" :type "second"))))
        (should (equal (portal--web-receive target) "[]"))
        (portal-web-send '(:type "reply" :n 2))
        (should (equal (portal-fake-native-calls 'portal--web-send)
                       `((,target "{\"type\":\"reply\",\"n\":2}"))))))))

(defun portal-web-test--wait (predicate)
  "Allow asynchronous process work until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun portal-web-test--stop-host ()
  "Stop the app host, and wait until its process has exited."
  (let ((process portal--server-process))
    (portal-stop-server)
    (when process
      (portal-web-test--wait (lambda () (not (process-live-p process)))))))

(ert-deftest portal-web-markdown-preview-with-the-real-app-host ()
  (skip-unless (file-executable-p (portal-server-program-file)))
  (portal-web-test--environment
    (let ((file (make-temp-file "portal-web-" nil ".md" "# Real notes\n"))
          (url-proxy-services nil))
      (unwind-protect
          (progn
            (should-not (portal-server-url))
            ;; The preview opens before the app host is ready.
            (portal-render-markdown file)
            (let ((target (portal-view-target))
                  (path (concat "/markdown?path=" (url-hexify-string file))))
              (should (equal (plist-get (portal-web-test--state) :url) "about:blank"))
              (portal-web-test--wait #'portal-server-url)
              (let ((url (concat (portal-server-url) path)))
                (should (equal (plist-get (portal-web-test--state target) :url) url))
                (let ((response (url-retrieve-synchronously url t t 3)))
                  (unwind-protect
                      (should (string-match-p "Real notes</h1>"
                                              (with-current-buffer response (buffer-string))))
                    (kill-buffer response)))
                ;; Stopping and restarting the host leave the loaded preview alone.
                (portal-web-test--stop-host)
                (should (equal (plist-get (portal-web-test--state target) :url) url))
                (portal-restart-server)
                (portal-web-test--wait #'portal-server-url)
                (should-not (string-prefix-p (portal-server-url) url))
                (should (equal (plist-get (portal-web-test--state target) :url) url))
                ;; g reloads it from the running host.
                (call-interactively (key-binding "g"))
                (should (equal (plist-get (portal-web-test--state target) :url)
                               (concat (portal-server-url) path))))))
        (portal-web-test--stop-host)
        (delete-file file)))))

(ert-deftest portal-web-toolbar-commands-use-the-selected-pane-view ()
  (portal-web-test--environment
    (portal-open-url "https://example.com")
    (let ((target (portal-view-target))
          (other (split-window-right))
          calls)
      (cl-letf (((symbol-function 'portal--toolbar-action)
                 (lambda (target action)
                   (push (list target action) calls)
                   "{\"value\":110,\"toc\":true}")))
        (should (= (portal-zoom-in) 110))
        (should (portal-toggle-toc))
        (portal-find)
        (call-interactively (key-binding "l"))
        (call-interactively (key-binding "r"))
        (should (equal (reverse calls)
                       `((,target "increase") (,target "toc") (,target "find")
                         (,target "back") (,target "forward"))))
        (should-error (portal-terminal-text-size-increase) :type 'user-error)
        ;; A pane showing another buffer has no view to act on.
        (set-window-buffer other (get-buffer "*scratch*"))
        (select-window other)
        (portal-view-sync)
        (should-error (portal-zoom-in) :type 'user-error)
        (should (= (length calls) 5))))))

;; Markdown previews: navigation, handoff to Emacs, and return.

(defconst portal-web-test--host "http://127.0.0.1:1/0123abcd"
  "The simulated app host's base URL.")

(defvar portal-web-test--directory nil "The Markdown tests' temporary folder.")

(defmacro portal-web-test--markdown (&rest body)
  "Run BODY with a simulated app host and `portal-web-test--directory'.
The folder holds README.md, \"docs é/arch notes.md\", a source file with
60 lines, an image and a folder."
  (declare (indent 0))
  `(portal-web-test--environment
     (let* ((portal-web-test--directory (make-temp-file "portal-markdown-" t))
            (directory portal-web-test--directory)
            (display-buffer-alist nil))
       (unwind-protect
           (cl-letf (((symbol-function 'portal-start-server) #'ignore)
                     ((symbol-function 'portal-server-url) (lambda () portal-web-test--host)))
             (make-directory (expand-file-name "docs é" directory))
             (make-directory (expand-file-name "src" directory))
             (with-temp-file (expand-file-name "README.md" directory) (insert "# Read me\n"))
             (with-temp-file (expand-file-name "docs é/arch notes.md" directory) (insert "# Arch\n"))
             (with-temp-file (expand-file-name "src/main file.ts" directory)
               (dotimes (line 60) (insert (format "// line %d\n" (1+ line)))))
             (with-temp-file (expand-file-name "pic.png" directory) (insert "\211PNG\r\n\032\n"))
             ,@body)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer) (file-in-directory-p (buffer-file-name buffer) directory))
             (kill-buffer buffer)))
         (delete-directory directory t)))))

(defun portal-web-test--file (name)
  "Return file NAME in `portal-web-test--directory'."
  (expand-file-name name portal-web-test--directory))

(defun portal-web-test--record (type target &optional file fragment)
  "Send what TARGET's view does for TYPE, with a URL for FILE when non-nil.
\"page\", \"follow\" and \"edit\" are bridge messages, and others records.  A
Markdown FILE gets its preview URL, and any other a file: URL."
  (let ((url (cond ((null file) nil)
                   ((string-suffix-p ".md" file)
                    (concat portal-web-test--host "/markdown?path=" (url-hexify-string file)))
                   (t (concat "file://" (url-hexify-string file (cons ?/ url-unreserved-chars)))))))
    (with-current-buffer "*scratch*"
      (if (member type '("page" "follow" "edit"))
          (progn
            (portal-fake-native-post
             target (json-serialize
                     (if url (list :type type :url (concat url (and fragment (concat "#" fragment))))
                       (list :type type))))
            (portal-fake-native-send (format "bridge %s\n" target)))
        (portal-fake-native-send (concat type " " target "\n"))))))

(defun portal-web-test--run-events ()
  "Run the commands that native records queued, as the command loop would."
  (while unread-command-events
    (let ((event (pop unread-command-events)))
      (funcall (lookup-key global-map (vector (car event))) event))))

(defun portal-web-test--preview (file)
  "Preview Markdown FILE; return its buffer, which the selected pane shows."
  (portal-render-markdown file)
  (portal-view-sync)
  (current-buffer))

(ert-deftest portal-web-markdown-preview-takes-the-identity-of-the-page-it-shows ()
  (portal-web-test--markdown
    (let* ((readme (portal-web-test--file "README.md"))
           (arch (portal-web-test--file "docs é/arch notes.md"))
           (preview (portal-web-test--preview readme))
           (target (portal-view-target)))
      (should (equal (buffer-name) "*portal: README.md*"))
      ;; A link to another Markdown file, with a heading, commits in the view.
      (portal-web-test--record "page" target arch "decisions")
      (should (equal (buffer-name preview) "*portal: arch notes.md*"))
      ;; g rereads the file on screen.
      (setq portal-fake-native-log nil)
      (call-interactively (key-binding "g"))
      (should (equal portal-fake-native-log
                     `((portal--web-load ,target ,(concat portal-web-test--host "/markdown?path="
                                                          (url-hexify-string arch))))))
      ;; Previewing the file on screen finds this buffer; the first file does not.
      (switch-to-buffer "*scratch*")
      (should (eq (portal-web-test--preview arch) preview))
      (let ((other (portal-web-test--preview readme)))
        (should-not (eq other preview))
        (should (equal (buffer-name other) "*portal: README.md*"))
        ;; Each preview keeps its own identity, even for the same file.
        (portal-web-test--record "page" (portal-view-target) arch)
        (should (equal (buffer-name other) "*portal: arch notes.md*<2>"))
        (should (equal (buffer-name preview) "*portal: arch notes.md*"))
        ;; Back in the first preview.
        (portal-web-test--record "page" target readme)
        (should (equal (buffer-name preview) "*portal: README.md*"))
        (switch-to-buffer "*scratch*")
        (should (eq (portal-web-test--preview readme) preview)))
      ;; Other pages, and pages of other hosted apps, change nothing.
      (with-current-buffer "*scratch*"
        (portal-fake-native-post target "{\"type\":\"page\",\"url\":\"about:blank\"}"
                                 (format "{\"type\":\"page\",\"url\":\"%s/hello\"}" portal-web-test--host))
        (portal-fake-native-send (format "bridge %s\n" target)))
      (should (equal (buffer-name preview) "*portal: README.md*"))
      (portal-hello)
      (portal-web-test--record "page" (portal-view-target) arch)
      (should (equal (buffer-name) "*portal: hello*")))))

(ert-deftest portal-web-markdown-preview-hands-local-files-to-another-pane ()
  (portal-web-test--markdown
    (let* ((preview (portal-web-test--preview (portal-web-test--file "README.md")))
           (target (portal-view-target))
           (origin (selected-window))
           (source (portal-web-test--file "src/main file.ts")))
      (portal-input-focus)
      (should (plist-get (portal-web-test--state target) :focused))
      ;; With one pane, the file gets a new one and the preview stays.
      (portal-web-test--record "follow" target source "L42-L50")
      (portal-web-test--run-events)
      (should (equal buffer-file-name source))
      (should (= (line-number-at-pos) 42))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) preview))
      (portal-view-sync)
      (should (plist-get (portal-web-test--state target) :visible))
      (should-not (plist-get (portal-web-test--state target) :focused))
      (should (eq (frame-parameter nil 'portal-render-return) preview))
      ;; The clicked preview's pane need not be selected; its other pane is reused.
      (let ((other (selected-window)))
        (should (= (count-windows) 2))
        (portal-web-test--record "follow" target (portal-web-test--file "pic.png"))
        (portal-web-test--run-events)
        (should (eq (selected-window) other))
        (should (equal buffer-file-name (portal-web-test--file "pic.png")))
        (select-window origin)
        (portal-web-test--record "follow" target (portal-web-test--file "src/"))
        (portal-web-test--run-events)
        (should (eq (selected-window) other))
        (should (eq major-mode 'dired-mode))
        ;; Existing buffers keep their point and edits; other fragments are ignored.
        (portal-web-test--record "follow" target source)
        (portal-web-test--run-events)
        (should (= (line-number-at-pos) 42))
        (insert "unsaved ")
        (forward-line -32)
        (portal-web-test--record "follow" target source "heading")
        (portal-web-test--run-events)
        (should (buffer-modified-p))
        (should (= (line-number-at-pos) 10))
        (set-buffer-modified-p nil)
        ;; A path far longer than a notification record still arrives.
        (let ((deep (portal-web-test--file
                     (concat (mapconcat #'identity (make-list 20 "très long dossier") "/")
                             "/fichier é.ts"))))
          (make-directory (file-name-directory deep) t)
          (with-temp-file deep (insert "one\ntwo\nthree\n"))
          (should (> (length (url-hexify-string deep)) 600))
          (portal-web-test--record "follow" target deep "L3")
          (portal-web-test--run-events)
          (should (equal buffer-file-name deep))
          (should (= (line-number-at-pos) 3))))
      (should (= (count-windows) 2))
      (should (eq (window-buffer origin) preview))
      (should (= (length (portal-fake-native-calls 'portal--web-load)) 2)))))

(ert-deftest portal-web-markdown-handoff-respects-placement-rules-and-failures ()
  (portal-web-test--markdown
    (let* ((preview (portal-web-test--preview (portal-web-test--file "README.md")))
           (target (portal-view-target))
           (source (portal-web-test--file "src/main file.ts")))
      ;; A failed visit reports the error and leaves the preview as it was.
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest _) (signal 'file-error '("Opening input file" "Permission denied")))))
        (portal-web-test--record "follow" target source)
        (should-error (portal-web-test--run-events) :type 'file-error))
      (should (eq (window-buffer) preview))
      (should (= (count-windows) 1))
      ;; Placement rules win, even when they replace the preview.
      (let ((display-buffer-alist '(("\\.ts\\'" display-buffer-same-window))))
        (portal-web-test--record "follow" target source)
        (portal-web-test--run-events))
      (should (equal buffer-file-name source))
      (should (= (count-windows) 1))
      (portal-view-sync)
      (should-not (plist-get (portal-web-test--state target) :visible))
      ;; Return shows it again, with the page it had.
      (setq portal-fake-native-log nil)
      (portal-render-return)
      (should (eq (window-buffer) preview))
      (should (plist-get (portal-web-test--state target) :visible))
      (should (plist-get (portal-web-test--state target) :focused))
      (should-not (portal-fake-native-calls 'portal--web-load)))))

(ert-deftest portal-web-markdown-open-in-emacs-and-return ()
  (portal-web-test--markdown
    (let* ((readme (portal-web-test--file "README.md"))
           (arch (portal-web-test--file "docs é/arch notes.md"))
           (preview (portal-web-test--preview readme))
           (target (portal-view-target))
           (origin (selected-window)))
      (should-error (with-current-buffer "*scratch*" (portal-render-open-in-emacs)) :type 'user-error)
      (should-error (portal-render-return) :type 'user-error)
      ;; The toolbar opens the file on screen, after back or forward too.
      (portal-web-test--record "page" target arch)
      (portal-web-test--record "edit" target)
      (portal-web-test--run-events)
      (should (equal buffer-file-name arch))
      (should-not (eq (selected-window) origin))
      (should-not (plist-get (portal-web-test--state target) :focused))
      (portal-web-test--record "page" target readme)
      (select-window origin)
      (portal-render-open-in-emacs)
      (should (equal buffer-file-name readme))
      ;; Return survives switching among source buffers, and does not reload.
      (find-file (portal-web-test--file "src/main file.ts"))
      (find-file arch)
      (setq portal-fake-native-log nil)
      (portal-render-return)
      (should (eq (selected-window) origin))
      (should (plist-get (portal-web-test--state target) :focused))
      (should-not (portal-fake-native-calls 'portal--web-load))
      ;; The most recent handoff wins, and a killed preview is reported.
      (switch-to-buffer "*scratch*")
      (let ((second (portal-web-test--preview arch)))
        (should-not (eq second preview))
        (portal-render-open-in-emacs)
        (portal-render-return)
        (should (eq (window-buffer) second))
        (kill-buffer second))
      (should (buffer-live-p preview))
      (should-error (portal-render-return) :type 'user-error))))

(ert-deftest portal-web-markdown-return-follows-a-handoff-into-another-frame ()
  (portal-web-test--markdown
    (portal-fake-native-with-frame frame
      (let* ((preview (portal-web-test--preview (portal-web-test--file "README.md")))
             (source (portal-web-test--file "src/main file.ts")))
        (with-selected-frame frame (find-file source))
        (let ((display-buffer-alist
               '(("\\.ts\\'" (display-buffer-reuse-window) (reusable-frames . t)))))
          (portal-web-test--record "follow" (portal-view-target) source)
          (portal-web-test--run-events))
        (should (eq (selected-frame) frame))
        (should (eq (frame-parameter frame 'portal-render-return) preview))
        (should (eq (frame-parameter portal-fake-native--selected 'portal-render-return) preview))
        ;; Return selects the preview's pane in the first frame, not a copy here.
        (let ((origin (get-buffer-window preview portal-fake-native--selected)))
          (portal-render-return)
          (should (eq (selected-window) origin))
          (should-not (get-buffer-window preview frame))
          (should (plist-get (portal-web-test--state (portal-view-target)) :focused)))))))

(ert-deftest portal-web-click-selects-the-views-pane ()
  (portal-web-test--environment
    (portal-open-url "about:blank")
    (let ((target (portal-view-target))
          (origin (selected-window)))
      (select-window (split-window-right))
      (switch-to-buffer "*scratch*")
      (portal-view-sync)
      (with-current-buffer "*scratch*"
        (portal-fake-native-send (format "select %s\n" target)))
      (portal-web-test--run-events)
      (should (eq (selected-window) origin))
      (should (plist-get (portal-web-test--state target) :focused)))))

;; Requests: what a page asks its buffer for.

(defun portal-web-test--answers (target)
  "Return the answers given to TARGET's requests, oldest first, as (ID ANSWER)."
  (mapcar #'cdr (cl-remove-if-not (lambda (call) (equal (car call) target))
                                  (portal-fake-native-calls 'portal--web-answer))))

(ert-deftest portal-web-dialogs-ask-in-the-minibuffer-and-always-answer ()
  (portal-web-test--environment
    (portal-open-url "https://example.com/")
    (portal-view-sync)
    (let ((target (portal-view-target))
          (page (current-buffer)))
      (portal-input-focus)
      (should (plist-get (portal-web-test--state target) :focused))
      ;; Requests wait for the command loop, and arrive in order.
      (portal-fake-native-request
       target
       "{\"id\":1,\"type\":\"alert\",\"message\":\"Saved\",\"origin\":\"https://example.com\"}"
       "{\"id\":2,\"type\":\"confirm\",\"message\":\"Leave?\",\"origin\":\"https://example.com\"}"
       "{\"id\":3,\"type\":\"prompt\",\"message\":\"Name:\",\"default\":\"Ada\",\"origin\":\"\"}")
      (should (= (length unread-command-events) 3))
      (let (prompts)
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt) (push prompt prompts) t))
                  ((symbol-function 'read-string)
                   (lambda (prompt _initial _history default)
                     (push (list prompt default) prompts) "Grace \"Hopper\"")))
          (with-current-buffer "*scratch*" (portal-web-test--run-events)))
        (should (equal (reverse prompts)
                       '("https://example.com says: Leave? " ("Name: " "Ada")))))
      (should (equal (portal-web-test--answers target)
                     '(("1" "true") ("2" "true") ("3" "\"Grace \\\"Hopper\\\"\""))))
      ;; The view, which had the keyboard, has it back.
      (should (plist-get (portal-web-test--state target) :focused))
      (should (eq (window-buffer (selected-window)) page))
      ;; Declining and quitting answer too.
      (setq portal-fake-native-log nil)
      (portal-fake-native-request target "{\"id\":4,\"type\":\"confirm\",\"message\":\"Sure?\"}"
                                  "{\"id\":5,\"type\":\"prompt\",\"message\":\"Why\"}")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil))
                ((symbol-function 'read-string) (lambda (&rest _) (signal 'quit nil))))
        (portal-web-test--run-events-in "*scratch*" 1)
        (should (eq (condition-case nil
                        (portal-web-test--run-events-in "*scratch*" 1)
                      (quit 'quit))
                    'quit)))
      (should (equal (portal-web-test--answers target) '(("4" "false") ("5" "null")))))))

(defun portal-web-test--run-events-in (buffer count)
  "Run COUNT queued native commands with BUFFER current."
  (with-current-buffer buffer
    (dotimes (_ count)
      (let ((event (pop unread-command-events)))
        (funcall (lookup-key global-map (vector (car event))) event)))))

(ert-deftest portal-web-a-window-a-page-opens-gets-its-own-buffer ()
  (portal-web-test--environment
    (portal-open-url "https://example.com/")
    (portal-view-sync)
    (let ((opener (portal-view-target))
          (origin (selected-window))
          (display-buffer-alist nil))
      (portal-fake-native-request
       opener "{\"id\":7,\"type\":\"popup\",\"window\":\"window-3\",\"url\":\"https://login.example.org/sso\"}")
      (portal-web-test--run-events)
      ;; It shows in another pane, adopting the window the page opened.
      (should (equal (buffer-name) "*portal: login.example.org*"))
      (should-not (eq (selected-window) origin))
      (let* ((window (portal-view-target))
             (options (plist-get (portal-web-test--state window) :options)))
        (should (equal (plist-get options :window) "window-3"))
        (should (equal (plist-get options :toolbar) "navigation"))
        ;; Adopting loads nothing, as the window's page is loading already:
        ;; only the opener loaded.
        (should (equal (portal-fake-native-calls 'portal--web-load)
                       `((,opener "https://example.com/"))))
        ;; When its page closes the window, its buffer and pane go.
        (let ((buffer (current-buffer)))
          (portal-fake-native-request window "{\"id\":1,\"type\":\"close\"}")
          (portal-web-test--run-events)
          (should-not (buffer-live-p buffer))
          (should (eq (selected-window) origin))))
      ;; An ordinary page that closes its window keeps its buffer.
      (let ((buffer (current-buffer)))
        (portal-fake-native-request opener "{\"id\":8,\"type\":\"close\"}")
        (portal-web-test--run-events)
        (should (buffer-live-p buffer)))
      ;; Other choices discard the window.
      (let ((portal-web-popups nil))
        (setq portal-fake-native-log nil)
        (portal-fake-native-request opener "{\"id\":9,\"type\":\"popup\",\"window\":\"window-4\"}")
        (portal-web-test--run-events)
        (should (equal (portal-web-test--answers opener) '(("9" "false")))))
      (let ((portal-web-popups 'browser) browsed)
        (setq portal-fake-native-log nil)
        (cl-letf (((symbol-function 'browse-url-default-browser)
                   (lambda (url &rest _) (push url browsed))))
          (portal-fake-native-request
           opener "{\"id\":10,\"type\":\"popup\",\"window\":\"window-5\",\"url\":\"https://e.com/x\"}")
          (portal-web-test--run-events))
        (should (equal browsed '("https://e.com/x")))
        (should (equal (portal-web-test--answers opener) '(("10" "false")))))
      ;; A window that has gone by the time Emacs adopts it is discarded.
      (setq portal-fake-native-log nil)
      (let ((portal-fake-native-failures '(portal--open))
            (buffers (buffer-list)))
        (portal-fake-native-request opener "{\"id\":11,\"type\":\"popup\",\"window\":\"window-6\"}")
        (should-error (portal-web-test--run-events))
        (should (equal (portal-web-test--answers opener) '(("11" "false"))))
        (should (equal (buffer-list) buffers))))))

(ert-deftest portal-web-goto-reads-addresses-hosts-files-and-searches ()
  (let ((file (make-temp-file "portal-page-" nil ".html")))
    (unwind-protect
        (progn
          (should (equal (portal-web--address "https://a.example/x") "https://a.example/x"))
          (should (equal (portal-web--address "  example.com/docs?q=1 ") "https://example.com/docs?q=1"))
          (should (equal (portal-web--address "localhost:8080/app") "http://localhost:8080/app"))
          (should (equal (portal-web--address "127.0.0.1") "http://127.0.0.1"))
          (should (equal (portal-web--address "emacs portal") "https://duckduckgo.com/?q=emacs%20portal"))
          ;; As in a browser, a name with a dot and a top-level domain is a host.
          (should (equal (portal-web--address "notes.md") "https://notes.md"))
          (should (equal (portal-web--address "what is 2.5") "https://duckduckgo.com/?q=what%20is%202.5"))
          (should (equal (portal-web--address file) (browse-url-file-url file)))
          (should-error (portal-web--address "  ") :type 'user-error))
      (delete-file file))))

(ert-deftest portal-web-goto-loads-in-place-or-in-a-new-buffer ()
  (portal-web-test--environment
    (portal-open-url "https://example.com/")
    (portal-view-sync)
    (let ((page (current-buffer)) (target (portal-view-target)))
      ;; The address on screen is where reading starts.
      (let (initial)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt start &rest _) (setq initial start) "example.org/next")))
          (call-interactively #'portal-web-goto))
        (should (equal initial "https://example.com/")))
      (should (eq (current-buffer) page))
      (should (equal (plist-get (portal-web-test--state target) :url) "https://example.org/next"))
      (should (equal (portal-web-current-url) "https://example.org/next"))
      ;; w copies it.
      (portal-web-copy-url)
      (should (equal (current-kill 0) "https://example.org/next"))
      ;; The toolbar's Go to address asks for one in the view's buffer.
      (with-current-buffer "*scratch*"
        (portal-fake-native-request
         target "{\"id\":0,\"type\":\"address\",\"url\":\"https://example.org/next\"}")
        (let (initial)
          (cl-letf (((symbol-function 'read-string)
                     (lambda (_prompt start &rest _) (setq initial start) "https://gnu.org/")))
            (portal-web-test--run-events))
          (should (equal initial "https://example.org/next"))))
      (should (equal (plist-get (portal-web-test--state target) :url) "https://gnu.org/"))
      ;; The page has the keyboard again, to use the new address.
      (should (plist-get (portal-web-test--state target) :focused))
      ;; A prefix argument opens a new buffer instead.
      (portal-web-goto "https://example.net/" t)
      (should-not (eq (current-buffer) page))
      (should (equal (buffer-name) "*portal: example.net*")))))

(ert-deftest portal-web-bookmarks-remember-pages-and-previews ()
  (portal-web-test--markdown
    (require 'bookmark)
    (let ((bookmark-alist nil)
          (bookmark-save-flag nil)
          (readme (portal-web-test--file "README.md")))
      ;; A page: its address and title.
      (portal-open-url "https://example.com/")
      (portal-view-sync)
      (puthash (portal-view-target)
               (plist-put (plist-put (portal-web-test--state) :url "https://example.com/a")
                          :title "Example A")
               portal-fake-native--views)
      (bookmark-set "page")
      (should (equal (bookmark-prop-get "page" 'location) "https://example.com/a"))
      (should (eq (bookmark-prop-get "page" 'portal) 'page))
      ;; Its default name is the page's title.
      (should (equal (car (portal-web-bookmark-make-record)) "Example A"))
      ;; A Markdown preview: its file, whatever the app host's address.
      (portal-web-test--preview readme)
      (bookmark-set "readme")
      (should (equal (bookmark-prop-get "readme" 'filename) readme))
      ;; Jumping opens each again.
      (switch-to-buffer "*scratch*")
      (setq portal-fake-native-log nil)
      (bookmark-jump "page")
      (should (equal (portal-fake-native-calls 'portal--web-load)
                     `((,(portal-view-target) "https://example.com/a"))))
      (switch-to-buffer "*scratch*")
      (bookmark-jump "readme")
      (should (equal portal-web--markdown readme))
      ;; Other hosted apps cannot be bookmarked.
      (portal-hello)
      (should-error (portal-web-bookmark-make-record) :type 'user-error))))

(provide 'portal-web-tests)
;;; portal-web-tests.el ends here
