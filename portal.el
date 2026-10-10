;;; portal.el --- Native web views and terminals for macOS -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The package root.  Loading it loads every Portal feature; the commands are
;; autoloaded from the feature files.

;; Support loading this entry point by absolute path without prior package
;; setup.  Transitive and deferred sibling requires need the same directory.
(add-to-list 'load-path
             (file-name-directory
              (or load-file-name
                  (bound-and-true-p byte-compile-current-file)
                  buffer-file-name)))

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
(require 'portal-excalidraw
         (expand-file-name "portal-excalidraw"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

;; Registers nothing until `portal-global-shortcut-set' is called.
(require 'portal-global-shortcut
         (expand-file-name "portal-global-shortcut"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

;; Posts nothing until `portal-post-key' is called.
(require 'portal-system
         (expand-file-name "portal-system"
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

(declare-function portal-terminal-consult-mode "portal-terminal-consult" (&optional arg))

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
