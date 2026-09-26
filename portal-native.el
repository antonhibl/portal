;;; portal-native.el --- Frame identification for web views and editors -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

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
