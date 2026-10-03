;;; portal-startup-tests.el --- Direct package loading -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a fresh emacs --batch -Q, without -L or a fake native backend.
(require 'ert)

(defconst portal-startup-test--entry
  (expand-file-name "../portal.el" (file-name-directory
                                   (or load-file-name
                                       (bound-and-true-p byte-compile-current-file)
                                       buffer-file-name))))

(ert-deftest portal-startup-loads-from-absolute-path ()
  ;; An unrelated working directory must not supply implicit sibling lookup.
  (let ((default-directory temporary-file-directory))
    (should-not (featurep 'portal))
    (load portal-startup-test--entry nil t)
    (dolist (feature '(portal portal-web portal-terminal portal-agents
                      portal-agent-discovery portal-agent-process
                      portal-excalidraw portal-tasks))
      (should (featurep feature)))
    (dolist (command '(portal-hello portal-terminal portal-agents portal-tasks))
      (should (commandp command)))))

(provide 'portal-startup-tests)
;;; portal-startup-tests.el ends here
