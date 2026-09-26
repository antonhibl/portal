;;; portal-native.el --- Native helpers for web views and editors -*- lexical-binding: t; -*-
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

(defun portal-native--consume-lines (pending text receiver)
  "Deliver complete lines from PENDING and TEXT to RECEIVER; return the tail.
Native event pipes carry short records, independently of OS read boundaries.
RECEIVER must queue interactive work for the command loop, not run it here."
  (let ((input (concat pending text)) (start 0))
    (while (string-match "\n" input start)
      (let ((end (match-beginning 0)))
        (funcall receiver (substring input start end))
        (setq start (1+ end))))
    (substring input start)))

(provide 'portal-native)
;;; portal-native.el ends here
