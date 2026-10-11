;;; portal-build-tests.el --- Native build checks and first-use setup -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch with the package directory on `load-path'.  Builds here run a
;; stand-in build.sh, never the real one.  With PORTAL_TEST_BUILD set to a
;; real build directory, one test also checks that build's record.

(require 'ert)
(require 'cl-lib)
(require 'portal-build)
(require 'portal-server)

(defvar compilation-finish-functions)

(defmacro portal-build-test--with-root (&rest body)
  "Run BODY with `portal-build-root' a new source tree, then delete it.
The tree's name contains a space.  It has native and host sources, a
stand-in build.sh, Lisp and a node_modules directory.  No build is running."
  (declare (indent 0))
  `(let* ((portal-build-root (file-name-as-directory (make-temp-file "portal build " t)))
          (portal-build-directory nil)
          (portal-build--ready nil)
          (portal-build--loaded nil)
          (portal-build--process nil)
          (portal-build-on-first-use 'ask))
     (unwind-protect
         (progn
           (dolist (file '("native/Package.swift" "native/Core/emacs.c" "host/server.ts"
                           "host/node_modules/dependency/index.js" "host/.generated/asset.js"
                           "tools/bun.manifest" "CMakeLists.txt" "portal.el"))
             (portal-build-test--write file file))
           (portal-build-test--write "build.sh" "echo built")
           ,@body)
       (when (process-live-p portal-build--process) (delete-process portal-build--process))
       (when (get-buffer "*portal-build*") (kill-buffer "*portal-build*"))
       (delete-directory portal-build-root t))))

(defun portal-build-test--write (file text)
  "Write TEXT to FILE in `portal-build-root', creating its directories."
  (let ((file (expand-file-name file portal-build-root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun portal-build-test--complete (&optional identity)
  "Make the tree's build complete, recording IDENTITY or the sources' identity."
  (dolist (file portal-build--artifacts)
    (portal-build-test--write (concat "build/" file) ""))
  (portal-build-test--write "build/portal-build.eld"
                            (prin1-to-string
                             (list :identity (or identity (portal-build-source-identity))))))

(defmacro portal-build-test--interactive (&rest body)
  "Run BODY as if from an interactive command in a graphical session."
  (declare (indent 0))
  `(let ((noninteractive nil) (this-command 'portal-terminal))
     ,@body))

(ert-deftest portal-build-problem-follows-the-record-and-sources ()
  (portal-build-test--with-root
    (should (eq (portal-build-problem) 'missing))
    (portal-build-test--complete)
    (should-not (portal-build-problem))
    ;; Each part of the build is required, not just the module.
    (delete-file (portal-build-file "portal-host"))
    (should (eq (portal-build-problem) 'missing))
    (portal-build-test--complete)
    (delete-file (portal-build-file "portal-build.eld"))
    (should (eq (portal-build-problem) 'missing))
    (portal-build-test--complete)
    (portal-build-test--write "native/Core/emacs.c" "changed")
    (should (eq (portal-build-problem) 'stale))
    (portal-build-test--complete)
    (let ((portal-build--loaded "an older build"))
      (should (eq (portal-build-problem) 'restart)))))

(ert-deftest portal-build-identity-covers-only-native-inputs ()
  (portal-build-test--with-root
    (should (equal (portal-build--input-files)
                   '("CMakeLists.txt" "build.sh" "host/server.ts" "native/Core/emacs.c"
                     "native/Package.swift" "tools/bun.manifest")))
    (let ((identity (portal-build-source-identity)))
      ;; Lisp, installed packages and generated files need no rebuild.
      (portal-build-test--write "portal.el" "changed")
      (portal-build-test--write "host/node_modules/dependency/index.js" "changed")
      (portal-build-test--write "host/.generated/asset.js" "changed")
      (should (equal (portal-build-source-identity) identity))
      (portal-build-test--write "tools/bun.manifest" "changed")
      (should-not (equal (portal-build-source-identity) identity)))
    ;; Supplied builds come without native sources: only the record counts.
    (delete-file (expand-file-name "native/Package.swift" portal-build-root))
    (should-not (portal-build-source-identity))))

(ert-deftest portal-build-ensure-never-builds-or-asks-in-batch ()
  (portal-build-test--with-root
    (dolist (portal-build-on-first-use '(ask always))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'portal-build) (lambda () (ert-fail "Built"))))
        (should (string-match-p "not built: run M-x portal-build"
                                (cadr (should-error (portal-build-ensure)
                                                    :type 'user-error))))))))

(ert-deftest portal-build-ensure-offers-a-build-from-a-command ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)) asked built)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) t))
                ((symbol-function 'portal-build) (lambda () (push t built))))
        (portal-build-test--interactive
          ;; The command stops: the build runs in the background.
          (should (string-match-p "retry when it finishes"
                                  (cadr (should-error (portal-build-ensure)
                                                      :type 'user-error))))
          (should (equal built '(t)))
          (should (string-match-p "downloads its dependencies" (car asked)))
          ;; Declining builds nothing.
          (cl-letf (((symbol-function 'y-or-n-p) #'ignore))
            (should-error (portal-build-ensure) :type 'user-error))
          (should (equal built '(t)))
          ;; Unattended setups build without asking.
          (setq asked nil)
          (let ((portal-build-on-first-use 'always))
            (should-error (portal-build-ensure) :type 'user-error))
          (should-not asked)
          (should (equal built '(t t))))))))

(ert-deftest portal-build-ensure-only-reports-when-it-must-not-build ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'portal-build) (lambda () (ert-fail "Built"))))
        (portal-build-test--interactive
          (let ((portal-build-on-first-use 'never))
            (should-error (portal-build-ensure) :type 'user-error))
          ;; Outside a command, as in an init file or a timer.
          (let ((this-command nil))
            (should-error (portal-build-ensure) :type 'user-error))
          ;; A supplied build is reported where it is.
          (let ((portal-build-directory (expand-file-name "supplied/" portal-build-root)))
            (should (string-match-p "supplied"
                                    (cadr (should-error (portal-build-ensure)
                                                        :type 'user-error)))))
          ;; A running build is not started again.
          (let ((portal-build--process (make-process :name "portal-build-test"
                                                     :command '("sleep" "10") :noquery t)))
            (unwind-protect
                (should (string-match-p "yet: retry"
                                        (cadr (should-error (portal-build-ensure)
                                                            :type 'user-error))))
              (delete-process portal-build--process)))
          ;; A build that cannot succeed is explained, not offered.
          (let ((exec-path nil))
            (should (string-match-p "cmake, ninja, xcrun"
                                    (cadr (should-error (portal-build-ensure)
                                                        :type 'user-error))))))))))

(ert-deftest portal-build-ensure-checks-once-until-reloaded ()
  (portal-build-test--with-root
    (portal-build-test--complete)
    (portal-build-ensure)
    (cl-letf (((symbol-function 'portal-build-problem) (lambda () (ert-fail "Checked again"))))
      (portal-build-ensure))
    ;; A loaded module from another build needs a restart, once the
    ;; reloaded Lisp checks again.
    (let ((portal-build--ready nil) (portal-build--loaded "an older build"))
      (should (string-match-p "restart Emacs"
                              (cadr (should-error (portal-build-ensure) :type 'user-error)))))))

(ert-deftest portal-build-load-module-records-the-loaded-build ()
  (portal-build-test--with-root
    (portal-build-test--complete "the build")
    (let ((portal-build--ready t) loaded)
      (cl-letf (((symbol-function 'module-load) (lambda (file) (push file loaded))))
        (portal-build-load-module))
      (should (equal loaded (list (portal-build-file "portal.bundle/Contents/MacOS/portal.dylib"))))
      (should (equal portal-build--loaded "the build")))))

(defun portal-build-test--tools ()
  "Return an `exec-path' with stand-ins for the build's tools."
  (let ((bin (expand-file-name "bin/" portal-build-root)))
    (dolist (tool '("cmake" "ninja" "xcrun"))
      (portal-build-test--write (concat "bin/" tool) "#!/bin/sh\n")
      (set-file-modes (expand-file-name tool bin) #o755))
    (list bin "/usr/bin" "/bin")))

(ert-deftest portal-build-diagnoses-unusable-destinations ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (let ((portal-build-directory "/supplied/"))
        (should-error (portal-build) :type 'user-error))
      (set-file-modes portal-build-root #o555)
      (unwind-protect
          (should (string-match-p "not writable"
                                  (cadr (should-error (portal-build) :type 'user-error))))
        (set-file-modes portal-build-root #o755))
      (delete-file (expand-file-name "build.sh" portal-build-root))
      (should (string-match-p "lack build.sh"
                              (cadr (should-error (portal-build) :type 'user-error)))))
    (should-not (get-buffer "*portal-build*"))))

(defun portal-build-test--run ()
  "Start `portal-build', wait for it to finish, and return Portal's messages."
  (let ((buffer (portal-build)) messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest arguments)
                 (when format (push (apply #'format-message format arguments) messages)))))
      (while (process-live-p (get-buffer-process buffer))
        (accept-process-output (get-buffer-process buffer) 0.05))
      ;; The finish functions run from the sentinel, after the process ends.
      (let ((deadline (+ (float-time) 5)))
        (while (and portal-build--process (< (float-time) deadline))
          (accept-process-output nil 0.05))))
    (string-join (seq-filter (lambda (text) (string-search "Portal" text)) messages) "\n")))

(ert-deftest portal-build-runs-build-sh-for-this-emacs ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools))
          (portal-build-bun "/opt/bun/bin/bun")
          (portal-build-download-bun nil)
          (portal-build-tools-directory "/tools cache/"))
      (portal-build-test--write
       "build.sh"
       "echo \"args: $*\"\necho \"PATH=$PATH\"\necho \"EMACS=$EMACS\"
echo \"BUN=$BUN\"\necho \"DOWNLOAD=$PORTAL_BUN_DOWNLOAD\"
echo \"TOOLS=$PORTAL_TOOLS_DIR\"\nmkdir -p build\n")
      (should (string-match-p "finished, but" (portal-build-test--run)))
      (with-current-buffer "*portal-build*"
        (let ((text (buffer-string)))
          (should (string-match-p "^args: -DBUILD_TESTING=OFF$" text))
          (should (string-search (concat "PATH=" (string-join exec-path ":")) text))
          (should (string-search (concat "EMACS=" (expand-file-name invocation-name
                                                                    invocation-directory))
                                 text))
          (should (string-search "BUN=/opt/bun/bin/bun" text))
          (should (string-search "DOWNLOAD=0" text))
          (should (string-search "TOOLS=/tools cache/" text))))
      ;; The log outlives the buffer.
      (should (string-search "-DBUILD_TESTING=OFF"
                             (with-temp-buffer
                               (insert-file-contents (portal-build-file "portal-build.log"))
                               (buffer-string)))))))

(ert-deftest portal-build-reports-success-failure-and-restarts ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (portal-build-test--write "build.sh" "echo failing\nexit 3\n")
      (should (string-match-p "build failed" (portal-build-test--run)))
      (should-not portal-build--ready)
      ;; Success is reported only for a complete build of these sources.
      (portal-build-test--write "build.sh" "exit 0\n")
      (portal-build-test--complete)
      (should (string-match-p "ready: retry" (portal-build-test--run)))
      (let ((portal-build--loaded "an older build"))
        (should (string-match-p "restart Emacs" (portal-build-test--run)))))))

(ert-deftest portal-build-starts-one-build-at-a-time ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (portal-build-test--write "build.sh" "sleep 10\n")
      (let ((buffer (portal-build)))
        (should (process-live-p portal-build--process))
        (let ((process portal-build--process))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (portal-build))
          (should (eq portal-build--process process))
          (should (= 1 (seq-count (lambda (p) (eq (process-buffer p) buffer))
                                  (process-list)))))))))

(ert-deftest portal-build-server-offers-a-build-for-its-own-host ()
  (portal-build-test--with-root
    (let ((portal-server-program nil) checked)
      (cl-letf (((symbol-function 'portal-build-ensure) (lambda () (setq checked t))))
        (should-error (portal-start-server) :type 'user-error))
      (should checked)
      ;; A host chosen by the user is never built.
      (setq checked nil)
      (let ((portal-server-program "/missing/host"))
        (cl-letf (((symbol-function 'portal-build-ensure) (lambda () (setq checked t))))
          (should-error (portal-start-server) :type 'user-error)))
      (should-not checked))))

(ert-deftest portal-build-root-resolves-linked-packages ()
  ;; As straight.el and Elpaca do, link the Lisp into a separate directory.
  (let ((linked (make-temp-file "portal-linked " t)))
    (unwind-protect
        (progn
          (make-symbolic-link (expand-file-name "portal-build.el" portal-build-root)
                              (expand-file-name "portal-build.el" linked))
          (byte-compile-file (expand-file-name "portal-build.el" linked))
          (dolist (file '("portal-build.el" "portal-build.elc"))
            (should (equal (with-temp-buffer
                             (call-process (expand-file-name invocation-name invocation-directory)
                                           nil t nil "--batch" "-Q" "-l"
                                           (expand-file-name file linked)
                                           "--eval" "(princ portal-build-root)")
                             (buffer-string))
                           (file-truename portal-build-root)))))
      (delete-directory linked t))))

(ert-deftest portal-build-real-build-is-ready ()
  ;; An unchanged installation must not ask for a rebuild.
  (let ((directory (getenv "PORTAL_TEST_BUILD")))
    (skip-unless directory)
    (let ((portal-build-directory directory) (portal-build--loaded nil))
      (should-not (portal-build-problem)))))

(provide 'portal-build-tests)
;;; portal-build-tests.el ends here
