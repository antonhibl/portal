;;; portal-native.el --- Shared native module loading -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(defconst portal--module-file
  (expand-file-name "build/portal.bundle/Contents/MacOS/portal.dylib"
                    (file-name-directory
                     (or load-file-name
                         (bound-and-true-p byte-compile-current-file)
                         buffer-file-name)))
  "The single native module used by all Portal features.")

(defun portal-native--load ()
  "Load the shared native module once, before opening any native view."
  (unless (and (eq window-system 'ns) (fboundp 'module-load))
    (user-error "Portal needs graphical macOS Emacs with module support"))
  (unless (featurep 'portal-native-module)
    (when (or (fboundp 'portal--bind) (fboundp 'portal--terminal-open))
      (user-error "Restart Emacs to replace the old Portal native modules"))
    (module-load portal--module-file)))

(defun portal-native--call-with-frame (frame function &rest arguments)
  "Call FUNCTION with FRAME's temporary native title and ARGUMENTS."
  (let ((title (frame-parameter frame 'title))
        (token (make-temp-name "portal-host-")))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'title token)
          (apply function token arguments))
      (set-frame-parameter frame 'title title))))

(provide 'portal-native)
;;; portal-native.el ends here
