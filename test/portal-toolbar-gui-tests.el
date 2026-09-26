;;; portal-toolbar-gui-tests.el --- Toolbar through the real module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-tests)
(require 'portal-terminal-tests)

(ert-deftest portal-toolbar-web-state-survives-buffer-switch-and-reload ()
  (portal-test--with-web
    (portal-open-url "data:text/html,<title>Toolbar</title><h1>Heading</h1>")
    (portal-test--wait-for-page "Toolbar")
    (should (= (portal-zoom-in) 110))
    (let ((buffer (current-buffer)))
      (switch-to-buffer (get-buffer-create "*scratch*"))
      (redisplay t)
      (switch-to-buffer buffer)
      (redisplay t)
      (should (= (alist-get 'value (portal-toolbar--action "state")) 110)))
    (portal-toolbar--action "reload")
    (portal-test--wait-for-page "Toolbar")
    (should (= (alist-get 'value (portal-toolbar--action "state")) 110))
    ;; The navigation toolbar has find, but no table of contents.
    (portal-find)
    (should (alist-get 'find (portal-toolbar--action "state")))
    (portal-toolbar--action "close-find")
    (should-error (portal-toggle-toc))
    (should (= (portal-zoom-reset) 100))))

(ert-deftest portal-toolbar-terminal-grid-and-text-size ()
  (portal-terminal-test--session
    (portal-terminal-test--wait (lambda () (> (plist-get (portal-terminal-test--state) :rows) 0)))
    (let* ((initial (portal-terminal-test--state))
           (rows (plist-get initial :rows))
           (columns (plist-get initial :columns))
           (default (alist-get 'value (portal-toolbar--action "state" t))))
      (should (= (portal-terminal-text-size-increase) (1+ default)))
      (portal-terminal-test--wait (lambda () (< (plist-get (portal-terminal-test--state) :columns) columns)))
      (should (= (portal-terminal-text-size-reset) default))
      (portal-terminal-test--wait (lambda () (= (plist-get (portal-terminal-test--state) :rows) rows)))
      (let ((portal-toolbar nil))
        (portal-terminal-test--wait (lambda () (> (plist-get (portal-terminal-test--state) :rows) rows))))
      (portal-terminal-test--wait (lambda () (= (plist-get (portal-terminal-test--state) :rows) rows))))))

(ert-deftest portal-toolbar-preview-toc-survives-reload ()
  (portal-test--with-web
    (portal-preview-html "data:text/html,<title>Contents</title><h1>Main</h1><h2>Detail</h2>")
    (portal-test--wait-for-page "Contents")
    (portal-terminal-test--wait
     (lambda () (alist-get 'headings (portal-toolbar--action "state"))))
    (should (portal-toggle-toc))
    (call-interactively (key-binding "g"))
    (portal-test--wait-for-page "Contents")
    (should (alist-get 'toc (portal-toolbar--action "state")))))
