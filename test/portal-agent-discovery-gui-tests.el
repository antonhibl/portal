;;; portal-agent-discovery-gui-tests.el --- Real Claude smoke test -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Opt in with PORTAL_TEST_CLAUDE_DIRECTORY pointing at an already trusted project.
;; Starts plain Claude sessions, sends one harmless prompt, then exits them.
(require 'portal-agents-gui-tests)
(declare-function portal--process-snapshot "portal-view" (variable))
(declare-function portal--terminal-paste "portal-terminal" (target text &optional enter))

(defun portal-discovery-gui--type (buffer text)
  "Type TEXT and Return in BUFFER's shell or Claude session."
  (portal--terminal-paste (buffer-local-value 'portal-view--target buffer) text t))

(defun portal-discovery-gui--wait (predicate &optional seconds)
  "Wait up to SECONDS (default 15) for PREDICATE through the real event loop."
  (let ((deadline (+ (float-time) (or seconds 15))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (redisplay t))
    (should (funcall predicate))))

(ert-deftest portal-discovery-gui-plain-claude ()
  (skip-unless (getenv "PORTAL_TEST_CLAUDE_DIRECTORY"))
  (portal-agents-gui--environment
    (let* ((default-directory (file-name-as-directory (getenv "PORTAL_TEST_CLAUDE_DIRECTORY")))
           ;; Use the promised default refresh bound, not the GUI helper's 0.2 s.
           (portal-agents-live-update-interval 2)
           (one (portal-agents-gui--open "claude-smoke-one"))
           (two (portal-agents-gui--open "claude-smoke-two"))
           (control (portal-agents-gui--open "claude-smoke-control"))
           (window (selected-window))
           (right (split-window-right))
           scan-times)
      (portal-agents-gui--wait 1)
      ;; A pre-existing plain launch must appear as soon as the dashboard opens.
      (portal-discovery-gui--type one "claude")
      (portal-agents-gui--wait 3)
      (with-selected-window right (portal-agents))
      (should (portal-agents-gui--row one))
      (should-not portal-agents--tracked)
      (portal-discovery-gui--wait
       (lambda () (equal (nth 4 (portal-agents-gui--row one)) "idle")))
      (portal-discovery-gui--type control "printf '\\033]0;✳ Claude Code\\007\\033]9;4;3\\007'; bash -c 'exec -a claude sleep 3'")
      (let ((start (float-time)))
        (portal-discovery-gui--type two "claude")
        (portal-discovery-gui--wait (lambda () (portal-agents-gui--row two)) 3)
        (message "DISCOVERY launch-to-row %.3f s" (- (float-time) start)))
      (should (= (length portal-agent-discovery--agents) 2))
      (should-not (portal-agents-gui--row control))
      (portal-discovery-gui--wait
       (lambda () (equal (nth 4 (portal-agents-gui--row two)) "idle")))
      (with-current-buffer one (rename-buffer "renamed-real-Claude"))
      (with-selected-window right
        (portal-agents-gui--visit one)
        (should (equal (portal-agents-gui--view one) (list right t)))
        (portal-agents))
      ;; A real turn exercises native title/progress -> asynchronous query -> row.
      (portal-discovery-gui--type one "Reply with exactly PORTAL_OK. Do not use tools.")
      (portal-discovery-gui--wait
       (lambda () (equal (nth 4 (portal-agents-gui--row one)) "working")) 30)
      (portal-discovery-gui--wait
       (lambda () (equal (nth 4 (portal-agents-gui--row one)) "idle")) 60)
      (dotimes (_ 50)
        (let ((start (float-time)))
          (portal--process-snapshot "PORTAL_TERMINAL")
          (push (* 1000 (- (float-time) start)) scan-times)))
      (message "DISCOVERY native scan ms mean=%.3f max=%.3f"
               (/ (apply #'+ scan-times) (length scan-times)) (apply #'max scan-times))
      ;; Hide collection while the terminals and their metadata keep running.
      (set-window-buffer right (get-buffer-create "*scratch*"))
      (portal-agents-gui--settle)
      (should-not portal-agents--timer)
      (should-not portal-agent-discovery--process)
      (portal-discovery-gui--type one "/exit")
      (portal-agents-gui--wait 3)
      (with-selected-window right (portal-agents))
      (should-not (portal-agents-gui--row one))
      (should (portal-agents-gui--row two))
      (should-not (plist-get (portal-terminal-metadata one) :exited))
      (portal-discovery-gui--type one "claude")
      (portal-discovery-gui--wait (lambda () (portal-agents-gui--row one)) 3)
      (portal-discovery-gui--type two "/exit")
      (portal-discovery-gui--wait (lambda () (not (portal-agents-gui--row two))) 5)
      ;; The selected suspension policy is exercised against a real foreground job.
      (portal-discovery-gui--wait
       (lambda () (equal (nth 4 (portal-agents-gui--row one)) "idle")))
      (signal-process (portal-agent-pid (portal-agent-discovery--find one)) 'SIGTSTP)
      (portal-discovery-gui--wait (lambda () (not (portal-agents-gui--row one))) 5)
      (portal-discovery-gui--type one "fg")
      (portal-discovery-gui--wait (lambda () (portal-agents-gui--row one)) 5)
      ;; A quick terminal is discovered and remains discoverable while hidden.
      (select-window window)
      (portal-terminal-quick--show default-directory)
      (let ((quick (current-buffer)))
        (portal-agents-gui--wait 1)
        (portal-discovery-gui--type quick "claude")
        (portal-terminal-quick-dismiss)
        (portal-discovery-gui--wait (lambda () (portal-agents-gui--row quick)) 3)
        (with-selected-window right (portal-agents-gui--visit quick))
        (should (equal (portal-agents-gui--view quick)
                       (list (portal-terminal-quick--window) t)))
        (portal-terminal-quick-dismiss)
        (should (portal-agents-gui--row quick)))
      (should-not portal-agents--tracked)
      (select-window window))))

(provide 'portal-agent-discovery-gui-tests)
;;; portal-agent-discovery-gui-tests.el ends here
