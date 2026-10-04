;;; portal-startup-tests.el --- Direct package loading -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in a fresh emacs --batch -Q, without -L or a fake native backend.
(require 'ert)
(defvar portal-global-shortcut--registrations)
(defvar portal-view-feature-record-handlers)
(declare-function portal-global-shortcut--remove-all "portal-global-shortcut" ())

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
                      portal-excalidraw portal-tasks portal-global-shortcut))
      (should (featurep feature)))
    (dolist (command '(portal-hello portal-terminal portal-agents portal-tasks))
      (should (commandp command)))
    (should (fboundp 'portal-global-shortcut-set))
    ;; Loading registers no shortcut and loads no native code.
    (should-not portal-global-shortcut--registrations)
    (should-not (featurep 'portal-native-module))
    (should-not (assoc "shortcut" portal-view-feature-record-handlers))
    (should-not (memq #'portal-global-shortcut--remove-all kill-emacs-hook))))

(provide 'portal-startup-tests)
;;; portal-startup-tests.el ends here
