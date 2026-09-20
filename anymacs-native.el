;;; anymacs-native.el --- Shared native module loading -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(defconst anymacs--module-file
  (expand-file-name "build/anymacs.bundle/Contents/MacOS/anymacs.dylib"
                    (file-name-directory
                     (or load-file-name
                         (bound-and-true-p byte-compile-current-file)
                         buffer-file-name)))
  "The single native module used by all Anymacs features.")

(defun anymacs-native--load ()
  "Load the shared native module once, before opening any native view."
  (unless (and (eq window-system 'ns) (fboundp 'module-load))
    (user-error "Anymacs needs graphical macOS Emacs with module support"))
  (unless (featurep 'anymacs-native-module)
    (when (or (fboundp 'anymacs--bind) (fboundp 'anymacs--terminal-open))
      (user-error "Restart Emacs to replace the old Anymacs native modules"))
    (module-load anymacs--module-file)))

(defun anymacs-native--call-with-frame (frame function &rest arguments)
  "Call FUNCTION with FRAME's temporary native title and ARGUMENTS."
  (let ((title (frame-parameter frame 'title))
        (token (make-temp-name "anymacs-host-")))
    (unwind-protect
        (progn
          (set-frame-parameter frame 'title token)
          (apply function token arguments))
      (set-frame-parameter frame 'title title))))

(provide 'anymacs-native)
;;; anymacs-native.el ends here
