;;; portal-launcher-daily-use-tests.el --- Launcher coexistence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Disposable graphical Emacs only; see launcher-daily-use.sh.

(require 'portal-tests)
(require 'portal-terminal-tests)
(require 'portal-launcher-gui-tests)
(defvar launcher--apps)
(defvar launcher--current-entries)
(defvar launcher-bangs)
(declare-function portal--web-load "portal-web" (target url))
(declare-function portal--launcher-inspect "portal-launcher" ())

(ert-deftest portal-launcher-daily-use-configured-completion ()
  ;; Unlike the stock/enhanced matrix, keep the caller's completion and theme
  ;; settings throughout. External actions are fixtures, native input is real.
  (require 'launcher)
  (portal-launcher-gui--with-panel
    (let ((launcher--apps '(("Calculator" . "/System/Applications/Calculator.app")))
          (launcher--current-entries nil)
          (settings (list completing-read-function completion-styles
                          completion-category-defaults completion-category-overrides
                          custom-enabled-themes (bound-and-true-p vertico-mode)
                          (bound-and-true-p marginalia-mode)))
          actions)
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest args) (push args actions) 0))
                ((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url actions))))
        (portal-launcher-gui--present
         nil (append (portal-launcher-gui--text "Calculator") '((36 0 "\r"))))
        (should (equal (pop actions)
                       '("open" nil nil nil "-a" "/System/Applications/Calculator.app")))
        (portal-launcher-gui--present
         nil (append (portal-launcher-gui--text "!gh portal launcher") '((36 0 "\r"))))
        (should (equal (pop actions) "https://github.com/search?q=portal%20launcher"))
        (portal-launcher-gui--present nil '((53 0 "\e")))
        (portal-launcher-gui--present
         nil (append (portal-launcher-gui--text "!gh ") '((36 0 "\r"))))
        (should-not actions)
        ;; The configured reader may accept a highlighted app with no text.
        ;; Stock completion has no selection and returns an empty result.
        (let ((launcher-bangs nil) (minibuffer-history nil))
          (portal-launcher-gui--present nil '((36 0 "\r"))))
        (when (bound-and-true-p vertico-mode)
          (should (equal (pop actions)
                         '("open" nil nil nil "-a" "/System/Applications/Calculator.app"))))
        (should-not actions))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest _) (error "Daily-use fixture: open failed"))))
        (should-error
         (portal-launcher-gui--present
          nil (append (portal-launcher-gui--text "Calculator") '((36 0 "\r"))))))
      ;; Recovery must read a new prompt, not merely return a Lisp value.
      (should (equal "recovered"
                     (portal-launcher-gui--present
                      (lambda () (interactive) (read-string "Recovery: "))
                      (append (portal-launcher-gui--text "recovered") '((36 0 "\r"))))))
      (should (equal settings
                     (list completing-read-function completion-styles
                           completion-category-defaults completion-category-overrides
                           custom-enabled-themes (bound-and-true-p vertico-mode)
                           (bound-and-true-p marginalia-mode)))))))

(ert-deftest portal-launcher-daily-use-reload-and-rollback-with-live-views ()
  (portal-launcher-gui--with-panel
    (let ((frame (make-frame))
          (receipt (make-temp-file "portal-launcher-shell-"))
          terminal-buffer terminal-id web-buffer web-id pid)
      (unwind-protect
          (progn
            (select-frame-set-input-focus frame)
            (sit-for 0.1)
            (portal-terminal)
            (setq terminal-buffer (current-buffer) terminal-id (portal-view-target))
            (let ((window (selected-window)))
              (select-window (split-window-right))
              (portal-open-url "data:text/html,<title>Launcher coexistence</title><input>")
              (setq web-buffer (current-buffer) web-id (portal-view-target))
              (portal-test--wait-for-page "Launcher coexistence" web-id)
              (select-window window))
            (dotimes (cycle 3)
              (portal-terminal-unfocus)
              (portal-launcher-mode 1)
              (let ((registration portal-launcher--registration))
                ;; Re-evaluate the launcher setup as a configuration reload does.
                (portal-launcher-mode 1)
                (should (= registration portal-launcher--registration)))
              (portal-launcher-gui--present
               (lambda () (interactive) (read-string "Coexistence: "))
               '((53 0 "\e")))
              (let ((panel portal-launcher--frame))
                (portal-launcher-mode -1)
                (portal-launcher-mode -1)
                (should-not (frame-live-p panel)))
              (should-not (plist-get (portal--launcher-inspect) :attached))
              (should (= 0 (plist-get (portal--launcher-inspect) :registration)))
              (should-not (advice-member-p #'portal-launcher--guard-parameters
                                          'modify-frame-parameters))
              (should-not (advice-member-p #'portal-launcher--delete-frame 'delete-frame))
              (should (eq (selected-frame) frame))
              (should (eq (current-buffer) terminal-buffer))
              ;; Both views keep their identity and accept input after rollback.
              (should (equal terminal-id (portal-view-target (get-buffer-window terminal-buffer frame))))
              (should (equal web-id (portal-view-target (get-buffer-window web-buffer frame))))
              (delete-file receipt)
              (portal-terminal-focus)
              (portal-terminal-test--paste
               (format "printf '%%s' \"$$\" > %s.tmp; /bin/mv %s.tmp %s"
                       (shell-quote-argument receipt) (shell-quote-argument receipt)
                       (shell-quote-argument receipt)) t terminal-id)
              (portal-terminal-test--wait (lambda () (file-exists-p receipt)))
              (let ((current-pid (with-temp-buffer
                                   (insert-file-contents receipt)
                                   (string-to-number (buffer-string)))))
                (should (process-attributes current-pid))
                (if pid (should (= pid current-pid)) (setq pid current-pid)))
              (portal-terminal-unfocus)
              (with-selected-window (get-buffer-window web-buffer frame)
                (portal--web-load web-id
                                  (format "data:text/html,<title>After rollback %d</title>" cycle))
                (portal-test--wait-for-page (format "After rollback %d" cycle) web-id)
                (should (portal-test--shown web-id (selected-window))))
              (should (frame-live-p (window-frame ordinary)))))
        (portal-launcher-mode -1)
        (when (buffer-live-p terminal-buffer) (kill-buffer terminal-buffer))
        (when (buffer-live-p web-buffer) (kill-buffer web-buffer))
        (when (frame-live-p frame) (delete-frame frame t))
        (when (file-exists-p receipt) (delete-file receipt))))))

(provide 'portal-launcher-daily-use-tests)
;;; portal-launcher-daily-use-tests.el ends here
