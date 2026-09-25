;;; portal-toolbar-gui-tests.el --- Toolbar through the real module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-tests)
(require 'portal-terminal-tests)

(ert-deftest portal-toolbar-web-state-survives-buffer-switch-and-reload ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>Toolbar</title><h1>Heading</h1>")
    (portal-test--wait-for-page "Toolbar" 1)
    (should (= (portal-zoom-in) 110))
    (let ((buffer (current-buffer)))
      (switch-to-buffer (get-buffer-create "*scratch*"))
      (redisplay t)
      (portal--sync (selected-frame))
      (switch-to-buffer buffer)
      (redisplay t)
      (portal--sync (selected-frame))
      (should (= (alist-get 'value (portal-toolbar--action "state")) 110)))
    (portal-toolbar--action "reload")
    (portal-test--wait-for-page "Toolbar" 1)
    (should (= (alist-get 'value (portal-toolbar--action "state")) 110))
    (should (= (portal-zoom-reset) 100))))

(ert-deftest portal-toolbar-terminal-grid-and-text-size ()
  (portal-terminal-test--session
    (portal-terminal-test--wait (lambda () (> (plist-get (portal--terminal-state) :rows) 0)))
    (let* ((initial (portal--terminal-state))
           (rows (plist-get initial :rows))
           (columns (plist-get initial :columns))
           (default (alist-get 'value (portal-toolbar--action "state" t))))
      (should (= (portal-terminal-text-size-increase) (1+ default)))
      (portal-terminal-test--wait (lambda () (< (plist-get (portal--terminal-state) :columns) columns)))
      (should (= (portal-terminal-text-size-reset) default))
      (portal-terminal-test--wait (lambda () (= (plist-get (portal--terminal-state) :rows) rows)))
      (let ((portal-toolbar nil))
        (portal-terminal-test--wait (lambda () (> (plist-get (portal--terminal-state) :rows) rows))))
      (portal-terminal-test--wait (lambda () (= (plist-get (portal--terminal-state) :rows) rows))))))

(ert-deftest portal-toolbar-deleted-pane-releases-retained-webview ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>Pane lifetime</title>")
    (let ((other (split-window-right)))
      (portal-test--wait-for-page "Pane lifetime" 2)
      (delete-window other)
      (redisplay t)
      (portal--sync (selected-frame))
      (should (= (length (portal--native-views)) 1)))))

(ert-deftest portal-toolbar-markdown-toc-survives-reload ()
  (portal-test--with-web
    (let ((file (make-temp-file "portal-toolbar-" nil ".md" "# Main\n\n## Detail\n")))
      (unwind-protect
          (progn
            (portal-preview-markdown file)
            (portal-test--wait-for-page (file-name-nondirectory file) 1)
            (portal-terminal-test--wait
             (lambda () (alist-get 'headings (portal-toolbar--action "state"))))
            (should (portal-toggle-toc))
            (portal-toolbar--action "reload")
            (portal-test--wait-for-page (file-name-nondirectory file) 1)
            (should (alist-get 'toc (portal-toolbar--action "state"))))
        (portal-hide)
        (portal-stop-server)
        (delete-file file)))))
