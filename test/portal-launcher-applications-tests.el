;;; portal-launcher-applications-tests.el --- Real launcher.el adapter -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-launcher)
(require 'launcher)
(require 'vertico)
(require 'orderless)
(require 'marginalia)

(defmacro portal-launcher-app-test--environment (&rest body)
  "Run BODY with real bundle directories and mocked Spotlight/open/browser."
  (declare (indent 0))
  `(let* ((root (make-temp-file "portal apps " t))
          (native-comp-enable-subr-trampolines nil)
          (paths (mapcar (lambda (name) (expand-file-name name root))
                         '("one/同 名.app" "two/同 名.app" "Space App.app")))
          (launcher-app-directories (list root))
          (launcher--apps nil)
          (launcher--current-entries nil)
          (launcher-bangs '(("!g" "Google" "https://www.google.com/search?q=%s")
                            ("!yt" "YouTube" "https://www.youtube.com/results?search_query=%s")
                            ("!gh" "GitHub" "https://github.com/search?q=%s")))
          (launcher-fallback-search-url "https://example.org/?q=%s")
          (scans 0) (status 0) actions)
     (unwind-protect
         (progn
           (dolist (path paths) (make-directory path t))
           (cl-letf (((symbol-function 'process-lines)
                      (lambda (program &rest arguments)
                        (should (equal program "mdfind"))
                        (should (equal arguments (list "-onlyin" root launcher-mdfind-query)))
                        (cl-incf scans)
                        paths))
                     ((symbol-function 'call-process)
                      (lambda (&rest arguments) (push arguments actions) status))
                     ((symbol-function 'browse-url)
                      (lambda (url &rest _) (push url actions))))
             ,@body))
       (delete-directory root t))))

(defun portal-launcher-app-test--choose (choice &optional refresh)
  "Return CHOICE from the user's reader, preserving real upstream dispatch."
  (let ((completing-read-function (lambda (&rest _) choice)))
    (portal-launcher-applications refresh)))

(ert-deftest portal-launcher-app-exact-identity-and-annotations ()
  (portal-launcher-app-test--environment
    (launcher-refresh)
    (dolist (entry launcher--apps)
      (let ((completing-read-function
             (lambda (prompt collection &rest _)
               (should (equal prompt "Launch: "))
               (should (member (car entry) (all-completions "" collection)))
               (should (equal (funcall (plist-get completion-extra-properties :annotation-function)
                                      (car entry))
                              (concat "  " (abbreviate-file-name (cdr entry)))))
               ;; Text properties are presentation, never a different identity.
               (propertize (car entry) 'face 'bold 'display "Another app"))))
        (portal-launcher-applications)
        (should (equal (pop actions) (list "open" nil nil nil "-a" (cdr entry))))))
    (should (= scans 1))
    (should-not launcher--current-entries)))

(ert-deftest portal-launcher-app-cache-refresh-and-removal ()
  (portal-launcher-app-test--environment
    (portal-launcher-app-test--choose "Space App")
    (portal-launcher-app-test--choose "Space App")
    (should (= scans 1))
    (delete-directory (car (last paths)))
    (setq paths (butlast paths))
    (let ((added (expand-file-name "New App.app" root)))
      (make-directory added)
      (push added paths)
      (let ((completing-read-function (lambda (&rest _) "New App"))
            (current-prefix-arg '(4)))
        (call-interactively #'portal-launcher-applications))
      (should (= scans 2))
      (should-not (assoc "Space App" launcher--apps))
      (should (equal (pop actions) (list "open" nil nil nil "-a" added))))))

(ert-deftest portal-launcher-app-encoded-fallback-and-bangs ()
  (portal-launcher-app-test--environment
    (let ((query "café & 中文/space?"))
      (portal-launcher-app-test--choose query)
      (should (equal (pop actions) (concat "https://example.org/?q=" (url-hexify-string query))))
      (dolist (bang launcher-bangs)
        (portal-launcher-app-test--choose (concat (car bang) " " query))
        (should (equal (pop actions) (format (caddr bang) (url-hexify-string query))))))
    (should (= scans 1))))

(ert-deftest portal-launcher-app-empty-input-and-quit-have-no-action ()
  (portal-launcher-app-test--environment
    (dolist (input '("" "  \t" "!g" "!yt " "!gh   " " !g "))
      (should (eq 'quit (condition-case nil (portal-launcher-app-test--choose input)
                         (quit 'quit))))
      (should-not actions)
      (should-not launcher--current-entries))
    (let ((completing-read-function (lambda (&rest _) (signal 'quit nil))))
      (should (eq 'quit (condition-case nil (portal-launcher-applications) (quit 'quit)))))
    (should-not actions)))

(ert-deftest portal-launcher-app-failures-and-empty-index-recover ()
  (portal-launcher-app-test--environment
    (let ((saved paths))
      (setq paths nil)
      (should-error (portal-launcher-app-test--choose "Space App") :type 'user-error)
      (setq paths saved))
    (should-not actions)
    (portal-launcher-app-test--choose "Space App")
    (should (= scans 2))
    (setq actions nil)
    (let ((cache launcher--apps))
      (cl-letf (((symbol-function 'process-lines) (lambda (&rest _) (error "Spotlight failed"))))
        (should-error (portal-launcher-app-test--choose "Space App" t)))
      (should (eq cache launcher--apps)))
    (delete-directory (car (last paths)))
    (should-error (portal-launcher-app-test--choose "Space App") :type 'user-error)
    (should-not actions)
    (make-directory (car (last paths)))
    (setq status 1)
    (should-error (portal-launcher-app-test--choose "Space App") :type 'user-error)
    (setq status 0)
    (should-not launcher--current-entries)
    (portal-launcher-app-test--choose "Space App")
    (should (= (length actions) 2))
    (cl-letf (((symbol-function 'browse-url) (lambda (&rest _) (error "Browser failed"))))
      (should-error (portal-launcher-app-test--choose "!g query")))
    (should-not launcher--current-entries)))

(defvar portal-launcher-app-test--command nil)
(defvar portal-launcher-app-test--probe nil)
(defun portal-launcher-app-test--run ()
  (interactive)
  (condition-case nil (funcall portal-launcher-app-test--command) (quit nil)))
(defun portal-launcher-app-test--inspect ()
  (interactive)
  (funcall portal-launcher-app-test--probe))

(defun portal-launcher-app-test--type (text &optional probe)
  "Type TEXT through a real minibuffer, probing before Return."
  (let ((global (current-global-map)) (map (make-sparse-keymap))
        (portal-launcher-app-test--command #'portal-launcher-applications)
        (portal-launcher-app-test--probe (or probe #'ignore)))
    (set-keymap-parent map global)
    (define-key map [f10] #'portal-launcher-app-test--run)
    (define-key map [f11] #'portal-launcher-app-test--inspect)
    (unwind-protect
        (progn
          (use-global-map map)
          (with-timeout (5 (error "Completion timed out: %S" text))
            (execute-kbd-macro (vconcat [f10] text [f11 return]))))
      (use-global-map global))))

(ert-deftest portal-launcher-app-real-completion-and-bang-input ()
  (portal-launcher-app-test--environment
    (dolist (enhanced '(nil t))
      (let ((completion-styles (if enhanced '(orderless basic) '(basic)))
            (completion-category-defaults nil)
            (reader completing-read-function))
        (vertico-mode (if enhanced 1 -1))
        (marginalia-mode (if enhanced 1 -1))
        (unwind-protect
            (progn
              (portal-launcher-app-test--type
               (if enhanced "App Space" "Space App")
               (lambda ()
                 (should (string-match-p
                          "Space App.app"
                          (funcall (plist-get completion-extra-properties :annotation-function) "Space App")))))
              (should (equal (pop actions) (list "open" nil nil nil "-a" (car (last paths)))))
              (dolist (entry (cdr launcher--apps))
                (portal-launcher-app-test--type (car entry))
                (should (equal (pop actions) (list "open" nil nil nil "-a" (cdr entry)))))
              (portal-launcher-app-test--type
               "!gh café & 中文"
               (lambda ()
                 ;; Orderless asks for all candidates with an empty STRING.
                 ;; Upstream reads the actual minibuffer to detect bang mode.
                 (should-not (all-completions "" minibuffer-completion-table))))
              (should (equal (pop actions)
                             (concat "https://github.com/search?q=" (url-hexify-string "café & 中文"))))
              ;; With no bang candidates, Vertico highlights an actual app at
              ;; an empty prompt. Return must still do nothing.
              (let ((launcher-bangs nil)) (portal-launcher-app-test--type ""))
              (should-not actions)
              (should (eq reader completing-read-function)))
          (vertico-mode -1)
          (marginalia-mode -1))))
    (should (= scans 1))))

(ert-deftest portal-launcher-app-ordinary-command-is-unchanged ()
  (portal-launcher-app-test--environment
    (let ((completing-read-function (lambda (&rest _) "")))
      (launcher)
      (should (equal actions '("https://example.org/?q=")))))
  (should-not (advice-member-p #'portal-launcher-applications 'launcher)))

(provide 'portal-launcher-applications-tests)
