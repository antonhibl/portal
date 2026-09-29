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
      (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list (current-buffer))))
                ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                ((symbol-function 'portal--input) (lambda (&rest _) t)))
        (portal-input--run "web:1" 1 (kbd "C-b") (portal-input--map)))
      (should portal-input-test--called)
      (should resumed))))

(ert-deftest portal-input-escape-and-error-do-not-resume ()
  (dolist (kind '(unfocus escape error hidden))
    (with-temp-buffer
      (portal-web-mode)
      (let (resumed
            (unread-command-events (pcase kind
                                     ('unfocus (list ?d))
                                     ('escape (list '(portal-input-escape ("web:1" 1 0)))))))
        (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list (current-buffer))))
                  ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                  ;; Once the user or a hidden view ended the handoff, it
                  ;; cannot be finished.
                  ((symbol-function 'portal--input)
                   (lambda (_target action &rest _)
                     (not (and (memq kind '(escape hidden)) (equal action "finish"))))))
          (portal-input--run "web:1" 1 (kbd "C-b")
                             (pcase kind
                               ((or 'unfocus 'escape) (portal-input--map))
                               ('error (lambda () (interactive) (error "Expected failure")))
                               ('hidden #'ignore))))
        ;; A command that hid the view, such as by showing another terminal
        ;; in its pane, still resumes the selected view.
        (should (eq resumed (eq kind 'hidden)))))))

(ert-deftest portal-input-escape-while-a-busy-command-runs-does-not-resume ()
  ;; A command that reads no input leaves the user's escape record in the
  ;; pipe; a hidden origin sends none.  A subprocess writes it, as the native
  ;; module does, while Emacs stops reading the pipe.
  (with-temp-buffer
    (portal-web-mode)
    (setq-local portal-view--target "web:1")
    (let* ((buffer (current-buffer))
           (portal-view--pending "")
           (portal-view--channel (make-pipe-process :name "portal-input-test" :noquery t
                                                    :filter #'portal-view--receive))
           (portal-input--escaped nil)
           (unread-command-events nil)
           (busy (lambda (escape)
                   (lambda ()
                     (interactive)
                     (when escape
                       (stop-process portal-view--channel)
                       (let ((writer (make-process
                                      :name "portal-input-test-escape" :noquery t
                                      :command '("sh" "-c" "printf 'escape web:1 2 0\\n' >&2")
                                      :stderr portal-view--channel)))
                         (while (process-live-p writer) (sleep-for 0.01)))
                       (continue-process portal-view--channel)))))
           resumed)
      (unwind-protect
          (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list buffer)))
                    ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                    ;; Either way, the handoff has ended by the time it finishes.
                    ((symbol-function 'portal--input)
                     (lambda (_target action &rest _) (not (equal action "finish")))))
            (portal-input--run "web:1" 1 (kbd "C-b") (funcall busy nil))
            (should resumed)
            (setq resumed nil)
            (portal-input--run "web:1" 2 (kbd "C-b") (funcall busy t))
            (should (equal portal-input--escaped '("web:1" 2)))
            (should-not resumed)
            (should (equal (mapcar #'car unread-command-events) '(portal-input-escape))))
        (delete-process portal-view--channel)))))

(ert-deftest portal-input-escape-ends-a-prefix-without-taking-the-next-event ()
  ;; A native handoff, such as Open in Emacs, escapes a pending prefix before
  ;; its own event arrives; the event must survive for the command loop.
  (with-temp-buffer
    (portal-web-mode)
    (let* ((edit '(portal-web-edit ("web:1")))
           (unread-command-events (list '(portal-input-escape ("web:1" 1 0)) edit))
           resumed)
      (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list (current-buffer))))
                ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                ((symbol-function 'portal--input) (lambda (&rest _) t)))
        (portal-input--run "web:1" 1 (kbd "C-b") (portal-input--map)))
      (should-not resumed)
      (should (equal unread-command-events (list edit))))))

(ert-deftest portal-input-old-prefix-setting-updates-shared-wrapper-map ()
  (let ((original portal-input-prefix))
    (unwind-protect
        (progn
          (setq portal-terminal-prefix "C-a")
          (should (equal portal-input-prefix "C-a"))
          (should (eq (lookup-key portal-input-mode-map (kbd "C-a")) #'portal-input-command))
          (should-not (lookup-key portal-input-mode-map (kbd "C-b"))))
      (setq portal-input-prefix original))))

(ert-deftest portal-input-prefix-descriptions-use-portal-modifiers ()
  ;; The native module's values, not a platform's key flags.
  (dolist (case '(("C-b" "b" 2) ("C-S-b" "b" 3) ("M-a" "a" 4) ("s-e" "e" 8)
                  ("s-!" "!" 8) ("s-J" "j" 9) ("C-M-s-SPC" " " 14)))
    (should (equal (portal-input--prefix-description (car case)) (cdr case))))
  (dolist (bad '("b" "C-b x" "<f5>" "s-S-1" "C-é"))
    (should-error (portal-input--prefix-description bad))))

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
        (cl-letf (((symbol-function 'portal-view-buffers) (lambda (&rest _) (list (current-buffer))))
                  ((symbol-function 'portal-input-focus) (lambda () (setq resumed t)))
                  ((symbol-function 'portal--input)
                   (lambda (_target action &rest _) (push action actions) t)))
          (portal-input--run "web:1" 1 (kbd "C-b") (portal-input--map)))
        (should resumed)
        (should-not (member "literal" actions))))))

(provide 'portal-input-tests)
