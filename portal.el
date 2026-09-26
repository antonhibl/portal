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

(provide 'portal)
;;; portal.el ends here
