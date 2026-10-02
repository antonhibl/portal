;;; portal.el --- Native web views and terminals for macOS -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The package root.  Loading it loads every Portal feature; the commands are
;; autoloaded from the feature files.

(require 'portal-web
         (expand-file-name "portal-web"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal
         (expand-file-name "portal-terminal"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-agents
         (expand-file-name "portal-agents"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-excalidraw
         (expand-file-name "portal-excalidraw"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(require 'portal-tasks
         (expand-file-name "portal-tasks"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(defcustom portal-terminal-consult-auto-enable t
  "Whether loading Portal and Consult enables their terminal integration.
Set this to nil before loading either package to opt out.  The integration
can still be enabled or disabled with `portal-terminal-consult-mode'."
  :type 'boolean
  :group 'portal-terminal)

;; Capture our directory now: Consult may load later from another directory.
(let ((adapter (expand-file-name
                "portal-terminal-consult"
                (file-name-directory
                 (or load-file-name
                     (bound-and-true-p byte-compile-current-file)
                     buffer-file-name)))))
  (with-eval-after-load 'consult
    (when portal-terminal-consult-auto-enable
      (require 'portal-terminal-consult adapter)
      (portal-terminal-consult-mode 1))))

(provide 'portal)
;;; portal.el ends here
