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

(ert-deftest portal-web-preview-html-reuses-its-buffer-and-g-reloads ()
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
              (call-interactively #'portal-preview-html))
            (set-buffer (window-buffer))
            (let ((buffer (current-buffer))
                  (target (portal-view-target)))
              (should (equal (buffer-name) "*portal: Résumé #%?.html*"))
              (should (equal (plist-get (portal-web-test--state) :url) url))
              (should (equal (portal-web-test--toolbar) "contents"))
              (switch-to-buffer "*scratch*")
              (let ((default-directory directory))
                (portal-preview-html "Résumé #%?.html"))
              (should (eq (current-buffer) buffer))
              (should (equal (portal-view-target) target))
              (should (equal (portal-fake-native-calls 'portal--web-load)
                             (list (list target url) (list target url))))
              (setq portal-fake-native-log nil)
              (call-interactively (key-binding "g"))
              (should (equal portal-fake-native-log `((portal--web-load ,target ,url))))
              ;; Another file gets its own buffer.
              (portal-preview-html other)
              (should-not (eq (current-buffer) buffer))
              (should (= (length (portal-fake-native-calls 'portal--open)) 1))))
        (delete-directory directory t)))
    (dolist (input '("" "relative/missing.html" "/ssh:host:/index.html" "javascript:alert(1)"))
      (should-error (portal-preview-html input) :type 'user-error))))

(ert-deftest portal-web-preview-html-only-reuses-preview-buffers ()
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
                (portal-preview-html file)
                (let ((preview (current-buffer)))
                  (should-not (memq preview (list page client)))
                  (should (equal (portal-web-test--toolbar) "contents"))
                  (switch-to-buffer page)
                  (portal-preview-html file)
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
              (portal-preview-markdown file)
              (let ((markdown (current-buffer))
                    (markdown-target (portal-view-target))
                    (markdown-url (concat "http://127.0.0.1:1/token/markdown?path="
                                          (url-hexify-string file))))
                (should (equal (buffer-name) (format "*portal: %s*" (file-name-nondirectory file))))
                (should (equal (portal-web-test--toolbar) "contents"))
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
                (portal-preview-markdown file)
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
  (skip-unless (file-executable-p portal-server-program))
  (portal-web-test--environment
    (let ((file (make-temp-file "portal-web-" nil ".md" "# Real notes\n"))
          (url-proxy-services nil))
      (unwind-protect
          (progn
            (should-not (portal-server-url))
            ;; The preview opens before the app host is ready.
            (portal-preview-markdown file)
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
        (should (equal (reverse calls)
                       `((,target "increase") (,target "toc") (,target "find"))))
        (should-error (portal-terminal-text-size-increase) :type 'user-error)
        ;; A pane showing another buffer has no view to act on.
        (set-window-buffer other (get-buffer "*scratch*"))
        (select-window other)
        (portal-view-sync)
        (should-error (portal-zoom-in) :type 'user-error)
        (should (= (length calls) 3))))))

(provide 'portal-web-tests)
;;; portal-web-tests.el ends here
