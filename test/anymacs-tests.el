;;; anymacs-tests.el --- Native presentation behaviour -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a disposable graphical Emacs, with anymacs.el already loaded.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'windmove)
(require 'browse-url)
(require 'anymacs)

(declare-function anymacs--load-url "anymacs" (url))
(declare-function anymacs--set-layout "anymacs" (layout))
(declare-function anymacs--native-views "anymacs" ())

(defmacro anymacs-test--with-view (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows) (anymacs-show) ,@body)
         (anymacs-hide)
         (when (get-buffer "*anymacs-green*")
           (kill-buffer "*anymacs-green*"))))))

(defun anymacs-test--views ()
  "Run real redisplay, then inspect the actual AppKit view hierarchy."
  (redisplay t)
  (anymacs--native-views))

(defun anymacs-test--expect-windows (&rest windows)
  "Expect one native view within each of WINDOWS, and no extra views."
  (let ((views (anymacs-test--views)))
    (should (= (length views) (length windows)))
    (dolist (view views) (should (plist-get view :visible)))
    (dolist (window windows)
      (should (= (seq-count (lambda (view)
                              (equal (plist-get view :edges)
                                     (window-inside-pixel-edges window)))
                            views)
                 1)))
    views))

(defun anymacs-test--expect-window (window)
  "Expect exactly one native view, visible within WINDOW's text area."
  (car (anymacs-test--expect-windows window)))

(ert-deftest anymacs-split-renders-both-panes-through-focus-and-deletion ()
  (dolist (side '(left right))
    (anymacs-test--with-view
      (let* ((mount (selected-window))
             (buffer (window-buffer mount))
             (other (split-window nil nil side)))
        (anymacs-test--expect-windows mount other)
        ;; Evil's C-w h/l use these same directional navigation commands.
        (funcall (if (eq side 'left) #'windmove-left #'windmove-right))
        (should (eq (selected-window) other))
        (should (eq (window-buffer mount) buffer))
        (should (eq (window-buffer other) buffer))
        (anymacs-test--expect-windows mount other)
        (funcall (if (eq side 'left) #'windmove-right #'windmove-left))
        (should (eq (selected-window) mount))
        (anymacs-test--expect-windows mount other)
        (delete-window mount)
        (anymacs-test--expect-window other)))))

(ert-deftest anymacs-split-below-and-resize ()
  (anymacs-test--with-view
    (let* ((upper (selected-window))
           (lower (split-window-below)))
      (select-window lower)
      (anymacs-test--expect-windows upper lower)
      (window-resize upper -3)
      (anymacs-test--expect-windows upper lower))))

(ert-deftest anymacs-navigation-to-text-buffer-keeps-mount ()
  (anymacs-test--with-view
    (let* ((left (selected-window))
           (green (window-buffer left))
           (right (split-window-right))
           (text (generate-new-buffer " *anymacs-test-text*")))
      (unwind-protect
          (progn
            (set-window-buffer right text)
            (windmove-right)
            (should (eq (selected-window) right))
            (should (eq (current-buffer) text))
            (insert "Editable text")
            (anymacs-test--expect-window left)
            (windmove-left)
            (should (eq (selected-window) left))
            (should (eq (window-buffer left) green))
            (should (eq (window-buffer right) text))
            (should (equal (with-current-buffer text (buffer-string))
                           "Editable text"))
            (anymacs-test--expect-window left))
        (kill-buffer text)))))

(ert-deftest anymacs-hidden-buffer-returns-in-new-pane ()
  (anymacs-test--with-view
    (let* ((host (selected-window))
           (buffer (window-buffer host))
           (other (split-window-right)))
      (set-window-buffer other (get-buffer-create "*scratch*"))
      (select-window other)
      ;; Focusing another buffer must not move or hide the native view.
      (anymacs-test--expect-window host)
      (set-window-buffer host (get-buffer "*scratch*"))
      (should-not (anymacs-test--views))
      (set-window-buffer other buffer)
      (anymacs-test--expect-window other))))

(ert-deftest anymacs-buffer-switch-only-removes-that-panes-view ()
  (anymacs-test--with-view
    (let* ((mount (selected-window))
           (green (window-buffer mount))
           (other (split-window-right)))
      (select-window other)
      (anymacs-test--expect-windows mount other)
      (set-window-buffer mount (get-buffer-create "*scratch*"))
      (anymacs-test--expect-window other)
      (set-window-buffer mount green)
      (anymacs-test--expect-windows mount other))))

(ert-deftest anymacs-stop-stays-stopped-and-can-restart ()
  (anymacs-test--with-view
    (split-window-right)
    ;; Repeated show must not accumulate attached native views.
    (dotimes (_ 3)
      (anymacs-show)
      (apply #'anymacs-test--expect-windows (window-list)))
    (call-interactively (key-binding (kbd "q")))
    (should-not (anymacs-test--views))
    (select-window (split-window-right))
    (should-not (anymacs-test--views))
    (anymacs-show)
    (apply #'anymacs-test--expect-windows (window-list))))

(ert-deftest anymacs-buffer-lifecycle-releases-view ()
  (anymacs-test--with-view
    (split-window-right)
    (apply #'anymacs-test--expect-windows (window-list))
    (fundamental-mode)
    (should-not (anymacs-test--views))
    (anymacs-show)
    (apply #'anymacs-test--expect-windows (window-list))
    (kill-buffer (current-buffer))
    (should-not (anymacs-test--views))))

(ert-deftest anymacs-frame-resize ()
  (anymacs-test--with-view
    (split-window-right)
    (split-window-below)
    (let ((width (frame-width))
          (height (frame-height)))
      (unwind-protect
          (progn
            (set-frame-size nil (+ width 8) (+ height 4))
            (apply #'anymacs-test--expect-windows (window-list)))
        (set-frame-size nil width height)))))

(ert-deftest anymacs-host-frame-ownership-and-cleanup ()
  (anymacs-test--with-view
    (let* ((original (selected-frame))
           (host (plist-get (anymacs-test--expect-window (selected-window)) :window))
           (frame (make-frame '((name . "Anymacs lifecycle test")))))
      (unwind-protect
          (progn
            (select-frame-set-input-focus frame)
            ;; Merely focusing another frame must not steal the presentation.
            (should (= (plist-get (car (anymacs-test--views)) :window) host))
            (anymacs-show)
            (should-not (= (plist-get (anymacs-test--expect-window (selected-window)) :window)
                           host))
            (delete-frame frame)
            (select-frame-set-input-focus original)
            (should-not (anymacs-test--views)))
        (when (frame-live-p frame) (delete-frame frame))))))

(ert-deftest anymacs-invalid-native-input-preserves-view ()
  (anymacs-test--with-view
    (split-window-right)
    (let ((before (anymacs-test--views)))
      (should-error (anymacs--set-layout "bad") :type 'wrong-type-argument)
      (should-error (anymacs--set-layout [1 "bad" 0 100 100])
                    :type 'wrong-type-argument)
      ;; Even a valid first rectangle must not be applied if a later one is bad.
      (dolist (layout '([1 0 0 100] [0 0 0 100 100]
                       [1 0 0 100 100 2 0 0 0 100]
                       [1 0 0 100 100 1 0 0 200 200]))
        (should-error (anymacs--set-layout layout))
        (should (equal before (anymacs-test--views)))))))

(ert-deftest anymacs-failed-start-cleans-up-and-can-retry ()
  (anymacs-test--with-view
    ;; Fail after host binding and attachment to exercise partial-setup cleanup.
    (split-window-right)
    (dolist (operation '(anymacs--bind anymacs--set-layout))
      (let ((original (symbol-function operation))
            (title (frame-parameter nil 'title)))
        (cl-letf (((symbol-function operation)
                   (lambda (&rest args)
                     (apply original args)
                     (error "Simulated attachment failure"))))
          (should-error (anymacs-show)))
        (should (equal (frame-parameter nil 'title) title))
        (should-not (anymacs-test--views))))
    (split-window-right)
    (should-not (anymacs-test--views))
    (anymacs-show)
    (apply #'anymacs-test--expect-windows (window-list))))

(ert-deftest anymacs-failed-update-removes-stale-view ()
  (anymacs-test--with-view
    (let ((original (symbol-function 'anymacs--set-layout)))
      (cl-letf (((symbol-function 'anymacs--set-layout)
                 (lambda (layout)
                   (funcall original layout)
                   (error "Simulated layout failure"))))
        (split-window-right)
        ;; Failure after creating both views must still remove all of them.
        (should-not (anymacs-test--views))))
    (delete-other-windows)
    (should-not (anymacs-test--views))
    (anymacs-show)
    (anymacs-test--expect-window (selected-window))))

(defun anymacs-test--wait-for-page (title count)
  "Wait for COUNT real WebKit documents to finish loading with TITLE."
  (let ((deadline (+ (float-time) 15)) views)
    (while (progn
             (setq views (anymacs-test--views))
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

(defmacro anymacs-test--with-web (&rest body)
  (declare (indent 0))
  `(anymacs-test--with-view
     (unwind-protect
         (progn ,@body)
       (anymacs-hide)
       (when (get-buffer "*anymacs-web*") (kill-buffer "*anymacs-web*")))))

(ert-deftest anymacs-web-renders-javascript-and-survives-pane-changes ()
  (anymacs-test--with-web
    (anymacs-open-url
     "data:text/html,<title>Initial</title><h1>WebKit works</h1><script>document.title='JS works'</script>")
    (anymacs-test--wait-for-page "JS works" 1)
    (let* ((buffer (current-buffer))
           (left (selected-window))
           (right (split-window-right)))
      (anymacs-test--wait-for-page "JS works" 2)
      (anymacs-test--expect-windows left right)
      (window-resize left -5 t)
      (anymacs-test--expect-windows left right)
      (set-window-buffer left (get-buffer-create "*scratch*"))
      (anymacs-test--expect-window right)
      (set-window-buffer right (get-buffer "*scratch*"))
      (should-not (anymacs-test--views))
      (set-window-buffer right buffer)
      (anymacs-test--wait-for-page "JS works" 1)
      (anymacs-test--expect-window right)
      (kill-buffer buffer)
      (should-not (anymacs-test--views)))))

(ert-deftest anymacs-web-loads-local-file-with-relative-javascript ()
  (anymacs-test--with-web
    (let ((directory (make-temp-file "anymacs-web-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "page.html" directory)
              (insert "<title>Initial</title><script src='script.js'></script>"))
            (with-temp-file (expand-file-name "script.js" directory)
              (insert "document.title = 'Local assets work';"))
            (anymacs-open-url
             (browse-url-file-url (expand-file-name "page.html" directory)))
            (anymacs-test--wait-for-page "Local assets work" 1))
        (anymacs-hide)
        (delete-directory directory t)))))

(ert-deftest anymacs-web-can-navigate-again-and-rejects-invalid-input ()
  (anymacs-test--with-web
    (anymacs-open-url "data:text/html,<title>First</title>")
    (anymacs-test--wait-for-page "First" 1)
    (dolist (url '("" "relative/path" "javascript:alert(1)" "https://"))
      (should-error (anymacs-open-url url) :type 'user-error))
    (should-error (anymacs--load-url 42) :type 'wrong-type-argument)
    (should-error (anymacs--load-url "relative/path"))
    (anymacs-test--wait-for-page "First" 1)
    (anymacs-open-url "data:text/html,<title>Second</title>")
    (anymacs-test--wait-for-page "Second" 1)
    (anymacs-hide)
    (should-not (anymacs-test--views))))
