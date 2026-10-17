;;; portal-org-tests.el --- Org links and previews against the fake module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real Org exports and real buffers drive `portal-org.el'; the native module
;; and the app host are simulated, as in portal-web-tests.el.
(require 'ert)
(require 'cl-lib)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal)
(require 'org)
(require 'org-id)
(require 'ox-html)
(require 'ox-md)
(require 'portal-org)

(defconst portal-org-test--host "http://127.0.0.1:1/0123abcd"
  "The simulated app host's URL.")

(defvar portal-org-test--directory nil "The notes the current test previews.")

(defmacro portal-org-test--notes (&rest body)
  "Run BODY with notes in `portal-org-test--directory' and a simulated app host.
The notes are index.org, linking to the others, other note.org, with an ID,
a code file and an image."
  (declare (indent 0))
  `(let* ((initial-buffers (buffer-list))
          (portal-org-test--directory (file-name-as-directory (make-temp-file "portal-org-" t)))
          (portal-org-preview-directory (expand-file-name "previews/" portal-org-test--directory))
          (display-buffer-alist nil)
          (org-id-locations-file (expand-file-name "ids" portal-org-test--directory))
          (org-id-locations nil)
          (org-id-files nil)
          (org-agenda-files nil))
     (portal-fake-native-reset)
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (switch-to-buffer (get-buffer-create "*scratch*"))
           (cl-letf (((symbol-function 'portal-start-server) #'ignore)
                     ((symbol-function 'portal-server-url) (lambda () portal-org-test--host)))
             (make-directory (expand-file-name "notes é" portal-org-test--directory))
             (with-temp-file (portal-org-test--file "index.org")
               (insert "#+title: Index & More\n\n* First\n"
                       "See [[file:notes é/other note.org][other]], [[file:main.go][code]],\n"
                       "[[id:5E2C-roam][the roam note]] and [[https://example.com/][the web]].\n\n"
                       "[[file:pic.png]]\n\n"
                       "#+begin_src emacs-lisp :exports results\n(error \"Never run\")\n#+end_src\n"))
             (with-temp-file (portal-org-test--file "notes é/other note.org")
               (insert "#+title: Other\n\n* Second\n:PROPERTIES:\n:ID: 5E2C-roam\n:END:\n"
                       "Back to [[file:../index.org][the index]].\n"))
             (with-temp-file (portal-org-test--file "main.go")
               (dotimes (line 30) (insert (format "// line %d\n" (1+ line)))))
             (with-temp-file (portal-org-test--file "pic.png") (insert "\211PNG\r\n\032\n"))
             ,@body))
       (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-directory portal-org-test--directory t))
     (should-not (portal-view-buffers))
     (should-not (portal-fake-native-targets))))

(defun portal-org-test--file (name)
  "Return file NAME in `portal-org-test--directory'."
  (expand-file-name name portal-org-test--directory))

(defun portal-org-test--html (file)
  "Return the HTML exported for Org FILE's preview."
  (with-temp-buffer
    (insert-file-contents (portal-org--html-file file))
    (buffer-string)))

(defun portal-org-test--url (file &optional fragment)
  "Return the URL that the simulated app host serves Org FILE's preview at."
  (concat portal-org-test--host (portal-org--path file fragment)))

(defun portal-org-test--run-events ()
  "Run the commands that native records queued, as the command loop would."
  (while unread-command-events
    (let ((event (pop unread-command-events)))
      (funcall (lookup-key global-map (vector (car event))) event))))

(defun portal-org-test--bridge (target &rest messages)
  "Send MESSAGES, plists, as TARGET's hosted page posts them."
  (with-current-buffer "*scratch*"
    (apply #'portal-fake-native-post target (mapcar #'json-serialize messages))
    (portal-fake-native-send (format "bridge %s\n" target))))

(defun portal-org-test--file-url (file &optional fragment)
  "Return FILE's file: URL, as a page reports a link to it."
  (concat "file://" (url-hexify-string file (cons ?/ url-unreserved-chars))
          (and fragment (concat "#" fragment))))

(ert-deftest portal-org-render-exports-and-shows-a-preview ()
  (portal-org-test--notes
    (let ((index (portal-org-test--file "index.org")))
      (portal-render-org index)
      (portal-view-sync)
      (let ((target (portal-view-target))
            (html (portal-org-test--html index)))
        (should (equal (buffer-name) "*portal: index.org*"))
        (should (equal portal-web--org index))
        (should (equal (plist-get (plist-get (portal--inspect target) :options) :toolbar)
                       "markdown"))
        ;; A hosted view opens at about:blank, then loads the preview.
        (should (equal (portal-fake-native-calls 'portal--web-load)
                       `((,target "about:blank") (,target ,(portal-org-test--url index)))))
        ;; The title, escaped, then the body, whose links stay relative to the
        ;; Org file for the app host to resolve, and Org links stay Org.
        (should (string-prefix-p "<h1 class=\"title\">Index &amp; More</h1>\n" html))
        (should (string-match-p "href=\"notes é/other note.org\"" html))
        (should (string-match-p "href=\"main.go\"" html))
        (should (string-match-p "src=\"pic.png\"" html))
        (should (string-match-p "href=\"https://example.com/\"" html))
        ;; Code never runs for a preview, which would fail here: it shows as
        ;; code.  A broken ID link is only marked.
        (should (string-match-p "<pre class=\"src src-emacs-lisp\"><code>(error &quot;Never run&quot;)\\|(error \"Never run\")" html))
        (should (string-match-p "BROKEN LINK" html))
        ;; Previewing it again reuses the buffer, and exports it again.
        (with-current-buffer (find-file-noselect index)
          (goto-char (point-max))
          (insert "\n* Unsaved heading\n"))
        (switch-to-buffer "*scratch*")
        (setq portal-fake-native-log nil)
        (portal-render-org index)
        (should (equal (buffer-name) "*portal: index.org*"))
        (should (equal portal-fake-native-log
                       `((portal--web-load ,target ,(portal-org-test--url index)))))
        (should (string-match-p "Unsaved heading" (portal-org-test--html index)))
        ;; g exports the file on screen again.
        (with-current-buffer (find-buffer-visiting index)
          (goto-char (point-max))
          (insert "\n* Another heading\n"))
        (call-interactively (key-binding "g"))
        (should (string-match-p "Another heading" (portal-org-test--html index)))
        ;; The toolbar names the Org file.
        (should (equal (portal-toolbar-default-label) (abbreviate-file-name index)))))))

(ert-deftest portal-org-render-resolves-org-roam-ids-to-their-files ()
  (portal-org-test--notes
    (let ((index (portal-org-test--file "index.org"))
          (other (portal-org-test--file "notes é/other note.org")))
      (cl-letf (((symbol-function 'org-roam-node-from-id)
                 (lambda (id) (and (equal id "5E2C-roam") 'node)))
                ((symbol-function 'org-roam-node-file) (lambda (_node) other)))
        (portal-render-org index))
      (let ((html (portal-org-test--html index)))
        ;; Relative to the Org file, for the app host to resolve.
        (should (string-match-p "href=\"notes é/other note.org#ID-5E2C-roam\"" html))
        (should-not (string-match-p "BROKEN LINK" html))))))

(ert-deftest portal-org-preview-follows-org-links-and-hands-off-other-files ()
  (portal-org-test--notes
    (let* ((index (portal-org-test--file "index.org"))
           (other (portal-org-test--file "notes é/other note.org"))
           (preview (progn (portal-render-org index) (portal-view-sync) (current-buffer)))
           (target (portal-view-target))
           (origin (selected-window)))
      (portal-input-focus)
      ;; A link to another Org file exports it and shows it in this preview,
      ;; which keeps the keyboard.
      (setq portal-fake-native-log nil)
      (portal-org-test--bridge target (list :type "follow"
                                            :url (portal-org-test--file-url other "ID-5E2C-roam")))
      (portal-org-test--run-events)
      (should (eq (selected-window) origin))
      (should (eq (current-buffer) preview))
      (should (equal (portal-fake-native-calls 'portal--web-load)
                     `((,target ,(portal-org-test--url other "ID-5E2C-roam")))))
      (should (string-match-p "Back to" (portal-org-test--html other)))
      ;; The heading the link names has the anchor it goes to.
      (should (string-match-p "id=\"ID-5E2C-roam\"" (portal-org-test--html other)))
      (should (plist-get (portal--inspect target) :focused))
      ;; Once it commits, the preview takes its identity.
      (portal-org-test--bridge target (list :type "page" :url (portal-org-test--url other)))
      (should (equal (buffer-name preview) "*portal: other note.org*"))
      (should (equal (buffer-local-value 'portal-web--org preview) other))
      ;; g exports the file on screen; Open in Emacs visits it.
      (setq portal-fake-native-log nil)
      (with-current-buffer preview
        (call-interactively (key-binding "g")))
      (should (equal (portal-fake-native-calls 'portal--web-load)
                     `((,target ,(portal-org-test--url other)))))
      (with-current-buffer preview (portal-render-open-in-emacs))
      (should (equal (buffer-file-name (window-buffer (selected-window))) other))
      ;; Any other file opens in another pane, at its line.
      (select-window origin)
      (portal-org-test--bridge target (list :type "follow"
                                            :url (portal-org-test--file-url
                                                  (portal-org-test--file "main.go") "L12")))
      (portal-org-test--run-events)
      (should (equal buffer-file-name (portal-org-test--file "main.go")))
      (should (= (line-number-at-pos) 12))
      (should (eq (window-buffer origin) preview)))))

(ert-deftest portal-org-links-open-store-and-export-pages ()
  (portal-org-test--notes
    ;; Following opens a web view; a prefix argument, the default browser.
    (portal-org-link-open "https://example.com/docs")
    (portal-view-sync)
    (let ((target (portal-view-target)) browsed)
      (should (equal (portal-fake-native-calls 'portal--web-load)
                     `((,target "https://example.com/docs"))))
      (cl-letf (((symbol-function 'browse-url-default-browser)
                 (lambda (url &rest _) (push url browsed))))
        (portal-org-link-open "https://example.com/x" t))
      (should (equal browsed '("https://example.com/x")))
      ;; A page stores a portal: link named by its title.
      (puthash target (plist-put (plist-put (portal--inspect target) :url "https://example.com/a")
                                 :title "Docs A")
               portal-fake-native--views)
      (let ((org-stored-links nil))
        (org-store-link nil t)
        (should (equal (car org-stored-links) '("portal:https://example.com/a" "Docs A")))))
    ;; A preview stores a link to its file.
    (let ((index (portal-org-test--file "index.org")) (org-stored-links nil))
      (portal-render-org index)
      (org-store-link nil t)
      (should (equal (car org-stored-links)
                     (list (concat "file:" (abbreviate-file-name index)) "index.org"))))
    ;; Exporting writes the URL for each backend.
    (should (equal (portal-org-link-export "https://e.com/?a=1&b=2" "A & B" 'html nil)
                   "<a href=\"https://e.com/?a=1&amp;b=2\">A &amp; B</a>"))
    (should (equal (portal-org-link-export "https://e.com/" "Docs" 'md nil) "[Docs](https://e.com/)"))
    (should (equal (portal-org-link-export "https://e.com/" nil 'ascii nil) "https://e.com/"))
    (should (equal (portal-org-link-export "https://e.com/#a" "D" 'latex nil)
                   "\\href{https://e.com/\\#a}{D}"))
    (with-temp-buffer
      (org-mode)
      (insert "[[portal:https://e.com/a][Site]]\n")
      (should (string-match-p "<a href=\"https://e.com/a\">Site</a>"
                              (org-export-as 'html nil nil t))))))

(ert-deftest portal-org-bookmarks-reopen-previews ()
  (portal-org-test--notes
    (require 'bookmark)
    (let ((bookmark-alist nil) (bookmark-save-flag nil)
          (index (portal-org-test--file "index.org")))
      (portal-render-org index)
      (bookmark-set "index")
      (should (eq (bookmark-prop-get "index" 'portal) 'org))
      (kill-buffer (current-buffer))
      (switch-to-buffer "*scratch*")
      (bookmark-jump "index")
      (should (equal portal-web--org index)))))

(provide 'portal-org-tests)
;;; portal-org-tests.el ends here
