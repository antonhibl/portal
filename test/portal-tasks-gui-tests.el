;;; portal-tasks-gui-tests.el --- The task browser in real WebKit -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Task pages run on the real app host from ./build.sh.  Load the other
;; graphical suites and the test-only event injector first.
(require 'portal-markdown-gui-tests)

(defconst portal-tasks-gui--png
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="
  "A one-pixel PNG, in base64.")

(defmacro portal-tasks-gui--root (&rest body)
  "Run BODY with the task list of a task root that has both layouts.
The root is `portal-markdown-gui--directory'."
  (declare (indent 0))
  `(portal-test--with-web
     (skip-unless (file-executable-p portal-server-program))
     (let ((portal-markdown-gui--directory (file-truename (make-temp-file "portal-tasks-gui-" t)))
           (display-buffer-alist nil))
       (unwind-protect
           (let ((paragraphs (lambda (word)
                               (mapconcat (lambda (n) (format "%s %d.\n\n" word n))
                                          (number-sequence 1 120)))))
             (dotimes (n 60)
               (portal-markdown-gui--write (format "task-%02d.md" n)
                                           (format "---\nstatus: todo\n---\n# Task %d\n" n)))
             (portal-markdown-gui--write
              "fix-search.md"
              (concat "---\nstatus: todo\n---\n# Fix search\n\n"
                      "[Navigation](<markdown-navigation/content.md#next-steps>) "
                      "[Log](<assets/search log.txt#L2>)\n\n![Search](assets/search.png)\n\n"
                      (funcall paragraphs "Detail")))
             (portal-markdown-gui--write
              "markdown-navigation/content.md"
              (concat "---\nstatus: todo\n---\n# Navigation\n\n![Mockup](mockup.png)\n\n"
                      (funcall paragraphs "Step") "## Next steps\n\n"
                      "[Prototype](prototype/index.html) [Back to search](../fix-search.md)\n"))
             (portal-markdown-gui--write "markdown-navigation/prototype/index.html"
                                         "<title>Prototype</title><script>document.title = 'Ran';</script>\n")
             (portal-markdown-gui--write "shipped.md" "---\nstatus: done\n---\n# Shipped\n")
             (portal-markdown-gui--write "assets/search log.txt" "one\ntwo\nthree\n")
             (dolist (image '("assets/search.png" "markdown-navigation/mockup.png"))
               (let ((coding-system-for-write 'binary))
                 (write-region (base64-decode-string portal-tasks-gui--png)
                               nil (portal-markdown-gui--file image))))
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             (should (portal-view--with-frame-title (selected-frame)
                                                    #'portal-test-native-target-frame))
             (portal-tasks portal-markdown-gui--directory)
             (portal-test--wait-for-page "Tasks")
             ,@body)
         (portal-test-native-target-frame nil)
         (setq unread-command-events nil)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (file-in-directory-p (buffer-file-name buffer) portal-markdown-gui--directory))
             (kill-buffer buffer)))
         (delete-directory portal-markdown-gui--directory t)))))

(defun portal-tasks-gui--link (text)
  "Follow the page's link whose text contains TEXT, as a page script would."
  (portal-excalidraw-gui--js
   (format "[...document.links].find(a => a.textContent.includes(%S)).click(); return true;" text)))

(defun portal-tasks-gui--route (text)
  "Wait until the buffer's app host path contains TEXT."
  (portal-terminal-test--wait (lambda () (string-search text portal-web--hosted-path))))

(defun portal-tasks-gui--image-loaded ()
  "Return non-nil once the page's first image has loaded."
  (portal-excalidraw-gui--js
   "const image = document.querySelector('img'); return !!image && image.complete && image.naturalWidth === 1;"))

(defun portal-tasks-gui--text ()
  "Return the page's visible text."
  (portal-excalidraw-gui--js "return document.body.innerText;"))

(defun portal-tasks-gui--readiness (title)
  "Return the readiness of the list row titled TITLE, or :null without one."
  (portal-excalidraw-gui--js
   (format "const row = [...document.querySelectorAll('li')].find(li => li.querySelector('.title')?.textContent === %S); return row ? row.querySelector('.readiness')?.textContent ?? '' : null;"
           title)))

(ert-deftest portal-tasks-gui-list-and-detail-keep-history-filter-and-position ()
  (portal-tasks-gui--root
    (should-not (alist-get 'back (portal-markdown-gui--state)))
    (should-not (string-match-p "Shipped" (portal-excalidraw-gui--js "return document.body.innerText;")))
    (portal-excalidraw-gui--js "window.scrollTo(0, 800); return true;")
    (should (= (portal-markdown-gui--scroll) 800))
    (portal-tasks-gui--link "Fix search")
    (portal-test--wait-for-page "Fix search")
    (portal-tasks-gui--route "&task=fix-search")
    (portal-terminal-test--wait #'portal-tasks-gui--image-loaded)
    (portal-excalidraw-gui--js "window.scrollTo(0, 600); return true;")
    ;; Back and forward restore the list and the detail at their positions.
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait (lambda () (= (portal-markdown-gui--scroll) 800)))
    (portal-tasks-gui--route "?root=")
    (should-not (string-search "&task=" portal-web--hosted-path))
    (call-interactively (key-binding "r"))
    (portal-test--wait-for-page "Fix search")
    (portal-terminal-test--wait (lambda () (= (portal-markdown-gui--scroll) 600)))
    ;; g reloads the page on screen from the saved file.
    (portal-markdown-gui--write "fix-search.md" "---\nstatus: todo\ntitle: Fix search now\n---\nSaved.\n")
    (call-interactively (key-binding "g"))
    (portal-test--wait-for-page "Fix search now")
    ;; The filter survives list, detail and the Tasks link.
    (portal-web-back)
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Show completed")
    (portal-tasks-gui--route "&show=all")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Shipped")
    (portal-test--wait-for-page "Shipped")
    (portal-tasks-gui--route "&task=shipped&show=all")
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (should (string-match-p "Hide completed" (portal-excalidraw-gui--js "return document.body.innerText;")))
    ;; A new link after going back discards the old forward branch.
    (portal-web-back)
    (portal-test--wait-for-page "Shipped")
    (should (alist-get 'forward (portal-markdown-gui--state)))
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (should-not (alist-get 'forward (portal-markdown-gui--state)))
    (should (file-exists-p (portal-markdown-gui--file "shipped.md")))))

(ert-deftest portal-tasks-gui-task-links-images-and-attachment-handoff ()
  (portal-tasks-gui--root
    (let ((tasks (current-buffer))
          (target (portal-view-target))
          (origin (selected-window)))
      (portal-tasks-gui--link "Fix search")
      (portal-test--wait-for-page "Fix search")
      ;; A task link opens its detail in the same view, at the heading.
      (portal-tasks-gui--link "Navigation")
      (portal-test--wait-for-page "Navigation")
      (portal-tasks-gui--route "&task=markdown-navigation")
      (portal-terminal-test--wait (lambda () (> (portal-markdown-gui--scroll) 1000)))
      (portal-terminal-test--wait #'portal-tasks-gui--image-loaded)
      (portal-excalidraw-gui--js "window.marker = 'kept'; return true;")
      ;; Mock-up HTML opens as source in Emacs, in one click, and never runs.
      (portal-input-focus)
      (should (portal-input--action "focused" target))
      (portal-markdown-gui--click-link "Prototype")
      (portal-markdown-gui--event 'portal-web-follow)
      (should (equal buffer-file-name (portal-markdown-gui--file "markdown-navigation/prototype/index.html")))
      (should-not (eq major-mode 'portal-web-mode))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) tasks))
      (should-not (portal-input--action "focused" target))
      (portal-integration-test--emacs-input)
      (should (equal (plist-get (portal--inspect target) :title) "Navigation"))
      (should (equal (portal-excalidraw-gui--js "return window.marker;") "kept"))
      ;; A standalone task's attachment opens at its line; history is intact.
      (select-window origin)
      (portal-web-back)
      (portal-test--wait-for-page "Fix search")
      (portal-terminal-test--wait #'portal-tasks-gui--image-loaded)
      (portal-markdown-gui--click-link "Log")
      (portal-markdown-gui--event 'portal-input-select)
      (portal-markdown-gui--event 'portal-web-follow)
      (should (equal buffer-file-name (portal-markdown-gui--file "assets/search log.txt")))
      (should (= (line-number-at-pos) 2))
      (select-window origin)
      (should (alist-get 'back (portal-markdown-gui--state)))
      (should (alist-get 'forward (portal-markdown-gui--state))))))

(ert-deftest portal-tasks-gui-dependencies-readiness-and-links ()
  (portal-tasks-gui--root
    ;; A saved task waits for one unfinished and one completed task.
    (portal-markdown-gui--write
     "release.md"
     "---\nid: release-notes\nstatus: todo\ndepends_on: [shipped, fix-search]\n---\n# Release notes\n")
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait
     (lambda () (equal (portal-tasks-gui--readiness "Release notes") "Blocked by Fix search")))
    (should (equal (portal-tasks-gui--readiness "Fix search") "Ready"))
    ;; Its page links its prerequisites, including completed ones.
    (portal-tasks-gui--link "Release notes")
    (portal-test--wait-for-page "Release notes")
    (portal-tasks-gui--route "&task=release-notes")
    (let ((text (portal-tasks-gui--text)))
      (should (string-match-p "release-notes" text))
      (should (string-match-p "blocked" text))
      (should (string-match-p "Shipped shipped done" text))
      (should (string-match-p "Fix search fix-search todo" text)))
    (portal-tasks-gui--link "Shipped")
    (portal-test--wait-for-page "Shipped")
    (portal-tasks-gui--route "&task=shipped")
    (should-not (string-search "show=all" portal-web--hosted-path))
    ;; A completed task shows what it blocks, and no readiness.
    (should (portal-excalidraw-gui--js
             "return !document.querySelector('.readiness') && document.body.innerText.includes('Blocks');"))
    (portal-tasks-gui--link "Release notes")
    (portal-test--wait-for-page "Release notes")
    (call-interactively (key-binding "l"))
    (portal-test--wait-for-page "Shipped")
    (call-interactively (key-binding "r"))
    (portal-test--wait-for-page "Release notes")
    ;; The completed filter survives the list and dependency links.
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (portal-tasks-gui--link "Show completed")
    (portal-tasks-gui--route "&show=all")
    (portal-test--wait-for-page "Tasks")
    (should (portal-excalidraw-gui--js
             "return document.querySelector('.completed h2').textContent === 'Completed' && document.querySelector('.completed').innerText.includes('Shipped');"))
    (portal-tasks-gui--link "Release notes")
    (portal-test--wait-for-page "Release notes")
    (portal-tasks-gui--route "&task=release-notes&show=all")
    (portal-tasks-gui--link "Fix search")
    (portal-test--wait-for-page "Fix search")
    (portal-tasks-gui--route "&task=fix-search&show=all")
    ;; Completing a prerequisite and reloading makes its dependent ready.
    (portal-web-back)
    (portal-test--wait-for-page "Release notes")
    (portal-markdown-gui--write "fix-search.md" "---\nstatus: done\n---\n# Fix search\n")
    (call-interactively (key-binding "g"))
    (portal-terminal-test--wait
     (lambda () (portal-excalidraw-gui--js "return document.querySelector('.readiness')?.textContent === 'ready';")))
    (portal-tasks-gui--route "&task=release-notes&show=all")
    (portal-tasks-gui--link "Tasks")
    (portal-test--wait-for-page "Tasks")
    (portal-terminal-test--wait (lambda () (equal (portal-tasks-gui--readiness "Release notes") "Ready")))
    (should (portal-excalidraw-gui--js
             "return document.querySelector('.completed').innerText.includes('Fix search');"))))

(ert-deftest portal-tasks-gui-reload-after-an-app-host-restart ()
  (portal-tasks-gui--root
    (portal-tasks-gui--link "Fix search")
    (portal-test--wait-for-page "Fix search")
    (portal-tasks-gui--route "&task=fix-search")
    (let ((old (portal-server-url)))
      (portal-restart-server)
      (portal-terminal-test--wait (lambda () (and (portal-server-url)
                                                  (not (equal (portal-server-url) old)))))
      ;; The page stays; g loads the same route from the new host.
      (should (equal (plist-get (portal--inspect (portal-view-target)) :title) "Fix search"))
      (call-interactively (key-binding "g"))
      (portal-test--wait-for-page "Fix search")
      (should (string-prefix-p (portal-server-url)
                               (plist-get (portal--inspect (portal-view-target)) :url)))
      (should (string-search "&task=fix-search" portal-web--hosted-path)))))

(provide 'portal-tasks-gui-tests)
;;; portal-tasks-gui-tests.el ends here
