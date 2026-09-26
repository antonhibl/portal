;;; portal-input-tests.el --- Shared input contract -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal)

(ert-deftest portal-input-shared-map-keeps-legacy-terminal-commands ()
  (with-temp-buffer
    (portal-terminal-mode)
    (let ((map (portal-input--map)))
      (should (eq (lookup-key map "d") #'portal-input-unfocus))
      (should (eq (lookup-key map "o") #'other-window))
      (should (eq (lookup-key map "c") #'portal-terminal-new))
      (should (eq (lookup-key map "mc") #'portal-terminal-new))
      (should (equal (lookup-key map (kbd "C-x")) (key-binding (kbd "C-x")))))
    (setq portal-terminal--quick-root "/tmp/")
    (let ((map (portal-input--map)))
      (should (eq (lookup-key map "o") #'other-window))
      (should-not (lookup-key map "c")))))

(defvar portal-input-test--called nil)
(defun portal-input-test--save () (interactive) (setq portal-input-test--called t))

(ert-deftest portal-input-gateway-respects-command-remapping-and-resumes ()
  (with-temp-buffer
    (portal-web-mode)
    (use-local-map (make-sparse-keymap))
    (define-key (current-local-map) [remap save-buffer] #'portal-input-test--save)
    (let ((portal-input-test--called nil) resumed
          (unread-command-events (list ?\C-x ?\C-s)))
      (setq-local portal-input--focus-function (lambda () (setq resumed t)))
      (cl-letf (((symbol-function 'portal--input) (lambda (&rest _) t)))
        (portal-input--run "web:1" 1 (kbd "C-b") (portal-input--map)))
      (should portal-input-test--called)
      (should resumed))))

(ert-deftest portal-input-escape-error-and-stale-handoff-do-not-resume ()
  (dolist (kind '(escape error stale))
    (with-temp-buffer
      (portal-web-mode)
      (let (resumed
            (unread-command-events (when (eq kind 'escape) (list ?d))))
        (setq-local portal-input--focus-function (lambda () (setq resumed t)))
        (cl-letf (((symbol-function 'portal--input)
                   (lambda (_target action &rest _) (not (and (eq kind 'stale) (equal action "finish"))))))
          (portal-input--run "web:1" 1 (kbd "C-b")
                             (pcase kind ('escape (portal-input--map))
                               ('error (lambda () (interactive) (error "Expected failure")))
                               (_ #'ignore))))
        (should-not resumed)))))

(ert-deftest portal-input-old-prefix-setting-updates-shared-wrapper-map ()
  (let ((original portal-input-prefix))
    (unwind-protect
        (progn
          (setq portal-terminal-prefix "C-a")
          (should (equal portal-input-prefix "C-a"))
          (should (eq (lookup-key portal-input-mode-map (kbd "C-a")) #'portal-input-command))
          (should-not (lookup-key portal-input-mode-map (kbd "C-b"))))
      (setq portal-input-prefix original))))

(ert-deftest portal-input-wrapper-controls-work-with-evil ()
  (skip-unless (locate-library "evil"))
  (require 'evil)
  (dolist (mode '(portal-web-mode portal-terminal-mode portal-excalidraw-mode))
    (with-temp-buffer
      (cl-letf (((symbol-function 'portal-excalidraw--start) #'ignore))
        (funcall mode))
      (evil-local-mode 1)
      (let ((original portal-input-prefix))
        (unwind-protect
            (dolist (prefix '("C-b" "C-a"))
              (setq portal-input-prefix prefix)
              (dolist (state '(normal motion insert))
                (evil-change-state state)
                (should (eq (key-binding (kbd prefix)) #'portal-input-command))
                (should (eq (key-binding (kbd "RET")) #'portal-input-focus))
                (should (eq (key-binding (kbd "s-<escape>")) #'portal-input-unfocus))))
          (setq portal-input-prefix original))))))

(ert-deftest portal-input-cancel-and-unknown-prefix-never-reach-guest ()
  (dolist (key '(?\C-g ?~))
    (with-temp-buffer
      (portal-web-mode)
      (let ((unread-command-events (list key)) actions resumed)
        (setq-local portal-input--focus-function (lambda () (setq resumed t)))
        (cl-letf (((symbol-function 'portal--input)
                   (lambda (_target action &rest _) (push action actions) t)))
          (portal-input--run "web:1" 1 (kbd "C-b") (portal-input--map)))
        (should resumed)
        (should-not (member "literal" actions))))))

(provide 'portal-input-tests)
