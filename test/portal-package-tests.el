;;; portal-package-tests.el --- Installing Portal as a package -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch.  Each test installs a copy of this checkout, including
;; uncommitted files, through docs/install.md's own examples, in a child Emacs
;; whose HOME, `user-emacs-directory' and package directory are new and empty.
;; Nothing is downloaded and nothing native is built.  PORTAL_TEST_ELPA lists
;; package directories that include Consult and Embark, separated by colons,
;; for the test of the optional integrations.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(defconst portal-package-test--checkout
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory (or (macroexp-file-name) buffer-file-name)))))

(defun portal-package-test--example (name)
  "Return docs/install.md's example NAME as text."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "docs/install.md" portal-package-test--checkout))
    (unless (re-search-forward
             (format "^<!-- example: %s -->\n```elisp\n" (regexp-quote name)) nil t)
      (error "docs/install.md has no example %s" name))
    (let ((start (point)))
      (re-search-forward "^```$")
      (buffer-substring-no-properties start (match-beginning 0)))))

(defun portal-package-test--git (directory &rest arguments)
  "Run git with ARGUMENTS in DIRECTORY and return its output, or fail."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "git" nil t nil "-C" directory arguments))
      (error "git %s failed: %s" (string-join arguments " ") (buffer-string)))
    (buffer-string)))

(defun portal-package-test--source (root)
  "Copy this checkout's files into a new Git repository in ROOT; return it.
Ignored files, such as build outputs, stay behind."
  (let ((source (expand-file-name "portal source/" root)))
    (dolist (file (split-string (portal-package-test--git
                                 portal-package-test--checkout
                                 "ls-files" "-z" "--cached" "--others" "--exclude-standard")
                                "\0" t))
      (let ((from (expand-file-name file portal-package-test--checkout))
            (to (expand-file-name file source)))
        (when (file-regular-p from)
          (make-directory (file-name-directory to) t)
          (copy-file from to nil t))))
    (portal-package-test--git source "init" "-q")
    (portal-package-test--git source "add" "-A")
    (portal-package-test--git source "-c" "user.name=Portal tests"
                              "-c" "user.email=tests@example.invalid"
                              "commit" "-q" "--no-gpg-sign" "-m" "Source")
    source))

(defun portal-package-test--emacs (home init &rest forms)
  "Run batch Emacs with HOME, loading INIT text first, then evaluating FORMS.
Return (STATUS . OUTPUT).  FORMS print their results."
  (let ((file (expand-file-name ".emacs.d/init.el" home)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";;; init.el -*- lexical-binding: t; -*-\n"
              ;; Never contact a package archive.
              "(setq package-archives nil)\n"
              init "\n"))
    (with-temp-buffer
      (let* ((process-environment (append (list (concat "HOME=" home)
                                                "XDG_CONFIG_HOME" "EMACSLOADPATH")
                                          process-environment))
             ;; Not abbreviated with the old HOME.
             (default-directory home)
             (status (apply #'call-process
                            (expand-file-name invocation-name invocation-directory)
                            nil t nil "--batch" "-l" file
                            (mapcan (lambda (form) (list "--eval" (prin1-to-string form)))
                                    forms))))
        (cons status (buffer-string))))))

(defun portal-package-test--compile-problems (output)
  "Return the lines of OUTPUT that report a problem compiling Portal."
  (seq-filter (lambda (line)
                (string-match-p "\\(Error\\|Warning\\)\\( (bytecomp)\\)?:" line))
              (split-string output "\n")))

(defmacro portal-package-test--with-home (&rest body)
  "Run BODY with ROOT a new temporary directory and HOME an empty one in it."
  (declare (indent 0))
  `(let* ((root (make-temp-file "portal package " t))
          (home (expand-file-name "home/" root)))
     (unwind-protect (progn (make-directory home) ,@body)
       (delete-directory root t))))

(defun portal-package-test--install (root home init)
  "Install Portal in HOME through the use-package-vc example after INIT.
The source is a copy of this checkout in ROOT.  Return the package directory."
  (let* ((source (portal-package-test--source root))
         (recipe (string-replace "\"https://github.com/xiaoxinghu/portal\""
                                 (prin1-to-string (directory-file-name source))
                                 (portal-package-test--example "use-package-vc")))
         (install (portal-package-test--emacs home (concat init "\n" recipe)))
         (package (expand-file-name ".emacs.d/elpa/portal/" home)))
    (unless (zerop (car install))
      (ert-fail (list "Installation failed" (cdr install))))
    ;; package-vc reports success even when files fail to compile.
    (should-not (portal-package-test--compile-problems (cdr install)))
    (should (file-exists-p (expand-file-name "portal.elc" package)))
    (should (file-exists-p (expand-file-name "portal-build.elc" package)))
    (should (file-exists-p (expand-file-name "portal-autoloads.el" package)))
    ;; Development tests are not compiled; native sources ship for the build.
    (should-not (directory-files-recursively (expand-file-name "test" package) "\\.elc\\'"))
    (should (file-exists-p (expand-file-name "native/Package.swift" package)))
    (should (file-exists-p (expand-file-name "tools/resolve-bun.sh" package)))
    ;; Installing started no build.
    (should-not (file-exists-p (expand-file-name "build" package)))
    package))

(defun portal-package-test--read-result (output)
  "Return the last form printed in OUTPUT."
  (car (last (car (read-from-string (concat "(" output ")"))))))

(ert-deftest portal-package-installs-with-use-package-vc ()
  (portal-package-test--with-home
    (let ((package (portal-package-test--install root home "")))
      ;; A fresh Emacs: autoloads only, then the whole package, without native code.
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home "(package-initialize)"
                    '(prin1 (list (autoloadp (symbol-function 'portal-build))
                                  (autoloadp (symbol-function 'portal-terminal))
                                  (progn (require 'portal) (featurep 'portal-native-module))
                                  portal-build-root
                                  (portal-build-problem)
                                  (condition-case err (portal-build-ensure)
                                    (user-error (cadr err))))))))
        (should (zerop status))
        (pcase-let ((`(,autoloads ,command ,native ,root ,problem ,error)
                     (portal-package-test--read-result output)))
          (should (equal (list autoloads command native root problem)
                         (list t t nil (file-truename package) 'missing)))
          (should (string-match-p "not built: run M-x portal-build" error)))))))

(ert-deftest portal-package-installs-optional-integrations ()
  (let ((elpa (getenv "PORTAL_TEST_ELPA")))
    (skip-unless elpa)
    (portal-package-test--with-home
      (let ((init (mapconcat (lambda (directory)
                               (format "(add-to-list 'load-path %S)" directory))
                             (split-string elpa ":" t) "\n")))
        (portal-package-test--install root home init)
        (pcase-let ((`(,status . ,output)
                     (portal-package-test--emacs
                      home (concat "(package-initialize)\n" init)
                      '(progn
                         (require 'portal)
                         (require 'consult)
                         (portal-terminal-embark-mode 1)
                         (prin1 (list portal-terminal-consult-mode
                                      (eq (keymap-parent portal-terminal-embark-map)
                                          embark-buffer-map)))))))
          (should (zerop status))
          (should (equal (portal-package-test--read-result output) '(t t))))))))

(ert-deftest portal-package-loads-from-a-clone ()
  (portal-package-test--with-home
    (let* ((source (portal-package-test--source root))
           (init (string-replace "\"~/src/portal\"" (prin1-to-string source)
                                 (portal-package-test--example "use-package-load-path"))))
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home init
                    '(prin1 (list (featurep 'portal) portal-build-root
                                  (featurep 'portal-native-module))))))
        (should (zerop status))
        (should (equal (portal-package-test--read-result output)
                       (list t (file-truename source) nil)))))))

(provide 'portal-package-tests)
;;; portal-package-tests.el ends here
