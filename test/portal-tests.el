;;; portal-tests.el --- Native presentation behaviour -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a disposable graphical Emacs, with portal.el already loaded.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'windmove)
(require 'browse-url)
(require 'portal)

(declare-function portal--load-url "portal" (url))
(declare-function portal--set-layout "portal" (layout))
(declare-function portal--native-views "portal" ())

(defmacro portal-test--with-view (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows) (portal-show) ,@body)
         (portal-hide)
         (when (get-buffer "*portal-green*")
           (kill-buffer "*portal-green*"))))))

(defun portal-test--views ()
  "Run real redisplay, then inspect the actual AppKit view hierarchy."
  (redisplay t)
  (portal--native-views))

(defun portal-test--expect-windows (&rest windows)
  "Expect one native view within each of WINDOWS, and no extra views."
  (let ((views (portal-test--views)))
    (should (= (length views) (length windows)))
    (dolist (view views) (should (plist-get view :visible)))
    (dolist (window windows)
      (should (= (seq-count (lambda (view)
                              (equal (plist-get view :edges)
                                     (window-inside-pixel-edges window)))
                            views)
                 1)))
    views))

(defun portal-test--expect-window (window)
  "Expect exactly one native view, visible within WINDOW's text area."
  (car (portal-test--expect-windows window)))

(ert-deftest portal-split-renders-both-panes-through-focus-and-deletion ()
  (dolist (side '(left right))
    (portal-test--with-view
      (let* ((mount (selected-window))
             (buffer (window-buffer mount))
             (other (split-window nil nil side)))
        (portal-test--expect-windows mount other)
        ;; Evil's C-w h/l use these same directional navigation commands.
        (funcall (if (eq side 'left) #'windmove-left #'windmove-right))
        (should (eq (selected-window) other))
        (should (eq (window-buffer mount) buffer))
        (should (eq (window-buffer other) buffer))
        (portal-test--expect-windows mount other)
        (funcall (if (eq side 'left) #'windmove-right #'windmove-left))
        (should (eq (selected-window) mount))
        (portal-test--expect-windows mount other)
        (delete-window mount)
        (portal-test--expect-window other)))))

(ert-deftest portal-split-below-and-resize ()
  (portal-test--with-view
    (let* ((upper (selected-window))
           (lower (split-window-below)))
      (select-window lower)
      (portal-test--expect-windows upper lower)
      (window-resize upper -3)
      (portal-test--expect-windows upper lower))))

(ert-deftest portal-navigation-to-text-buffer-keeps-mount ()
  (portal-test--with-view
    (let* ((left (selected-window))
           (green (window-buffer left))
           (right (split-window-right))
           (text (generate-new-buffer " *portal-test-text*")))
      (unwind-protect
          (progn
            (set-window-buffer right text)
            (windmove-right)
            (should (eq (selected-window) right))
            (should (eq (current-buffer) text))
            (insert "Editable text")
            (portal-test--expect-window left)
            (windmove-left)
            (should (eq (selected-window) left))
            (should (eq (window-buffer left) green))
            (should (eq (window-buffer right) text))
            (should (equal (with-current-buffer text (buffer-string))
                           "Editable text"))
            (portal-test--expect-window left))
        (kill-buffer text)))))

(ert-deftest portal-hidden-buffer-returns-in-new-pane ()
  (portal-test--with-view
    (let* ((host (selected-window))
           (buffer (window-buffer host))
           (other (split-window-right)))
      (set-window-buffer other (get-buffer-create "*scratch*"))
      (select-window other)
      ;; Focusing another buffer must not move or hide the native view.
      (portal-test--expect-window host)
      (set-window-buffer host (get-buffer "*scratch*"))
      (should-not (portal-test--views))
      (set-window-buffer other buffer)
      (portal-test--expect-window other))))

(ert-deftest portal-buffer-switch-only-removes-that-panes-view ()
  (portal-test--with-view
    (let* ((mount (selected-window))
           (green (window-buffer mount))
           (other (split-window-right)))
      (select-window other)
      (portal-test--expect-windows mount other)
      (set-window-buffer mount (get-buffer-create "*scratch*"))
      (portal-test--expect-window other)
      (set-window-buffer mount green)
      (portal-test--expect-windows mount other))))

(ert-deftest portal-stop-stays-stopped-and-can-restart ()
  (portal-test--with-view
    (split-window-right)
    ;; Repeated show must not accumulate attached native views.
    (dotimes (_ 3)
      (portal-show)
      (apply #'portal-test--expect-windows (window-list)))
    (call-interactively (key-binding (kbd "q")))
    (should-not (portal-test--views))
    (select-window (split-window-right))
    (should-not (portal-test--views))
    (portal-show)
    (apply #'portal-test--expect-windows (window-list))))

(ert-deftest portal-buffer-lifecycle-releases-view ()
  (portal-test--with-view
    (split-window-right)
    (apply #'portal-test--expect-windows (window-list))
    (fundamental-mode)
    (should-not (portal-test--views))
    (portal-show)
    (apply #'portal-test--expect-windows (window-list))
    (kill-buffer (current-buffer))
    (should-not (portal-test--views))))

(ert-deftest portal-frame-resize ()
  (portal-test--with-view
    (split-window-right)
    (split-window-below)
    (let ((width (frame-width))
          (height (frame-height)))
      (unwind-protect
          (progn
            (set-frame-size nil (+ width 8) (+ height 4))
            (apply #'portal-test--expect-windows (window-list)))
        (set-frame-size nil width height)))))

(ert-deftest portal-host-frame-ownership-and-cleanup ()
  (portal-test--with-view
    (let* ((original (selected-frame))
           (host (plist-get (portal-test--expect-window (selected-window)) :window))
           (frame (make-frame '((name . "Portal lifecycle test")))))
      (unwind-protect
          (progn
            (select-frame-set-input-focus frame)
            ;; Merely focusing another frame must not steal the presentation.
            (should (= (plist-get (car (portal-test--views)) :window) host))
            (portal-show)
            (should-not (= (plist-get (portal-test--expect-window (selected-window)) :window)
                           host))
            (delete-frame frame)
            (select-frame-set-input-focus original)
            (should-not (portal-test--views)))
        (when (frame-live-p frame) (delete-frame frame))))))

(ert-deftest portal-invalid-native-input-preserves-view ()
  (portal-test--with-view
    (split-window-right)
    (let ((before (portal-test--views)))
      (should-error (portal--set-layout "bad") :type 'wrong-type-argument)
      (should-error (portal--set-layout [1 "bad" 0 100 100])
                    :type 'wrong-type-argument)
      ;; Even a valid first rectangle must not be applied if a later one is bad.
      (dolist (layout '([1 0 0 100] [0 0 0 100 100]
                       [1 0 0 100 100 2 0 0 0 100]
                       [1 0 0 100 100 1 0 0 200 200]))
        (should-error (portal--set-layout layout))
        (should (equal before (portal-test--views)))))))

(ert-deftest portal-failed-start-cleans-up-and-can-retry ()
  (portal-test--with-view
    ;; Fail after host binding and attachment to exercise partial-setup cleanup.
    (split-window-right)
    (dolist (operation '(portal--bind portal--set-layout))
      (let ((original (symbol-function operation))
            (title (frame-parameter nil 'title)))
        (cl-letf (((symbol-function operation)
                   (lambda (&rest args)
                     (apply original args)
                     (error "Simulated attachment failure"))))
          (should-error (portal-show)))
        (should (equal (frame-parameter nil 'title) title))
        (should-not (portal-test--views))))
    (split-window-right)
    (should-not (portal-test--views))
    (portal-show)
    (apply #'portal-test--expect-windows (window-list))))

(ert-deftest portal-failed-update-removes-stale-view ()
  (portal-test--with-view
    (let ((original (symbol-function 'portal--set-layout)))
      (cl-letf (((symbol-function 'portal--set-layout)
                 (lambda (layout)
                   (funcall original layout)
                   (error "Simulated layout failure"))))
        (split-window-right)
        ;; Failure after creating both views must still remove all of them.
        (should-not (portal-test--views))))
    (delete-other-windows)
    (should-not (portal-test--views))
    (portal-show)
    (portal-test--expect-window (selected-window))))

(defun portal-test--wait-for-page (title count)
  "Wait for COUNT real WebKit documents to finish loading with TITLE."
  (let ((deadline (+ (float-time) 15)) views)
    (while (progn
             (setq views (portal-test--views))
             (and (< (float-time) deadline)
                  (not (and (= (length views) count)
                            (seq-every-p
                             (lambda (view)
                               (and (equal (plist-get view :title) title)
                                    (not (plist-get view :loading))
                                    (not (plist-get view :error))))
                             views)))))
      (sleep-for 0.05))
    (should (= (length views) count))
    (dolist (view views)
      (should-not (plist-get view :loading))
      (should-not (plist-get view :error))
      (should (equal (plist-get view :title) title)))
    views))

(defmacro portal-test--with-web (&rest body)
  (declare (indent 0))
  `(portal-test--with-view
     (unwind-protect
         (progn ,@body)
       (portal-hide)
       (when (get-buffer "*portal-web*") (kill-buffer "*portal-web*")))))

(ert-deftest portal-web-renders-javascript-and-survives-pane-changes ()
  (portal-test--with-web
    (portal-open-url
     "data:text/html,<title>Initial</title><h1>WebKit works</h1><script>document.title='JS works'</script>")
    (portal-test--wait-for-page "JS works" 1)
    (let* ((buffer (current-buffer))
           (left (selected-window))
           (right (split-window-right)))
      (portal-test--wait-for-page "JS works" 2)
      (portal-test--expect-windows left right)
      (window-resize left -5 t)
      (portal-test--expect-windows left right)
      (set-window-buffer left (get-buffer-create "*scratch*"))
      (portal-test--expect-window right)
      (set-window-buffer right (get-buffer "*scratch*"))
      (should-not (portal-test--views))
      (set-window-buffer right buffer)
      (portal-test--wait-for-page "JS works" 1)
      (portal-test--expect-window right)
      (kill-buffer buffer)
      (should-not (portal-test--views)))))

(ert-deftest portal-web-loads-local-file-with-relative-javascript ()
  (portal-test--with-web
    (let* ((directory (make-temp-file "portal-web-" t))
           (file (expand-file-name "Résumé #%?.HTML" directory)))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "<title>Initial</title><script src='script.js'></script>"))
            (with-temp-file (expand-file-name "script.js" directory)
              (insert "document.title = 'Local assets work';"))
            (with-temp-buffer
              (setq buffer-file-name file)
              (call-interactively #'portal-preview-html))
            (portal-test--wait-for-page "Local assets work" 1))
        (portal-hide)
        (delete-directory directory t)))))

(ert-deftest portal-web-can-navigate-again-and-rejects-invalid-input ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>First</title>")
    (portal-test--wait-for-page "First" 1)
    (dolist (url '("" "relative/path" "javascript:alert(1)" "https://"))
      (should-error (portal-open-url url) :type 'user-error))
    (should-error (portal--load-url 42) :type 'wrong-type-argument)
    (should-error (portal--load-url "relative/path"))
    (portal-test--wait-for-page "First" 1)
    (portal-open-url "data:text/html,<title>Second</title>")
    (portal-test--wait-for-page "Second" 1)
    (portal-hide)
    (should-not (portal-test--views))))

(ert-deftest portal-hello-loads-shares-and-restarts-the-bundled-host ()
  (portal-test--with-web
    (unwind-protect
        (progn
          (portal-hello)
          ;; The title is set by the served page's JavaScript.
          (portal-test--wait-for-page "Hello, world!" 1)
          (let ((process (portal-start-server)))
            (split-window-right)
            (portal-test--wait-for-page "Hello, world!" 2)
            (portal-hide)
            (should-not (portal-test--views))
            (should (process-live-p process))
            (portal-hello)
            (portal-test--wait-for-page "Hello, world!" 2)
            (should (eq process (portal-start-server)))
            (portal-restart-server)
            (portal-test--wait-for-page "Hello, world!" 2)
            (should-not (eq process (portal-start-server))))
          (portal-stop-server)
          (portal-test--wait-for-page "Portal server stopped" 2))
      (portal-stop-server))))

(ert-deftest portal-hello-cancelled-start-does-not-replace-new-content ()
  (portal-test--with-web
    (unwind-protect
        (progn
          (portal-stop-server)
          (portal-hello)
          (portal-open-url "data:text/html,<title>Keep this page</title>")
          (portal-test--wait-for-page "Keep this page" 1)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (portal-server-url)) (< (float-time) deadline))
              (sleep-for 0.05)))
          (should (portal-server-url))
          (portal-test--wait-for-page "Keep this page" 1))
      (portal-stop-server))))

(ert-deftest portal-markdown-previews-refreshes-and-survives-host-restart ()
  (portal-test--with-web
    (let* ((directory (make-temp-file "portal-markdown-web-" t))
           (name "Résumé & notes #%?.md")
           (file (expand-file-name name directory)))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "# Markdown in WebKit\n\n**Rendered by Bun.**\n\n"
                      "<script>document.title = 'Injected';</script>\n"))
            (portal-stop-server)
            (portal-preview-markdown file)
            (portal-test--wait-for-page name 1)
            (split-window-right)
            (portal-test--wait-for-page name 2)
            (let ((process (portal-start-server)))
              ;; Refresh must read disk again and display a useful HTTP error.
              (delete-file file)
              (portal-refresh)
              (portal-test--wait-for-page "Markdown preview unavailable" 2)
              (with-temp-file file (insert "# Restored file\n"))
              (call-interactively (key-binding (kbd "g")))
              (portal-test--wait-for-page name 2)
              (should (eq process (portal-start-server)))
              (portal-stop-server)
              (portal-test--wait-for-page "Portal server stopped" 2)
              (portal-refresh)
              (portal-test--wait-for-page name 2)
              (should-not (eq process (portal-start-server))))
            (should-error (portal-preview-markdown directory) :type 'user-error)
            (should-error (portal-preview-markdown "/ssh:host:/file.md") :type 'user-error)
            (portal-test--wait-for-page name 2))
        (portal-hide)
        (portal-stop-server)
        (delete-directory directory t)))))

(ert-deftest portal-markdown-cancelled-start-does-not-replace-new-content ()
  (portal-test--with-web
    (let ((file (make-temp-file "portal-markdown-" nil ".md" "# Preview\n")))
      (unwind-protect
          (progn
            (portal-stop-server)
            (portal-preview-markdown file)
            (portal-open-url "data:text/html,<title>Keep this page</title>")
            (portal-test--wait-for-page "Keep this page" 1)
            (let ((deadline (+ (float-time) 5)))
              (while (and (not (portal-server-url)) (< (float-time) deadline))
                (sleep-for 0.05)))
            (should (portal-server-url))
            (portal-test--wait-for-page "Keep this page" 1))
        (portal-stop-server)
        (delete-file file)))))
