;;; gui-run-1.el --- Spike run 1: discovery, controls, activity, lifecycle -*- lexical-binding: t; -*-
;; Not loaded by Portal.  Load last into a graphical emacs -Q running a build
;; with instrumentation.patch; see run-gui.sh.  Marks go to the Lisp trace.

(defvar spike-run-dir (file-name-directory (or load-file-name buffer-file-name)))
(load (expand-file-name "gui-helpers.el" spike-run-dir))

(defun spike-scenario ()
  (set-frame-size (selected-frame) 220 56)
  (delete-other-windows)
  (setq spike-right (split-window-right))
  (spike-wait 0.5)

  ;; An agent already running when discovery is enabled.
  (let ((t3 (spike-new "*T3 preexisting*")))
    (spike-type t3 "claude")
    (spike-wait 8)
    (load (expand-file-name "prototype.el" spike-run-dir))
    (advice-add 'portal-terminal--changed :after
                (lambda (target)
                  (when (and (portal-agents--shown-p)
                             (equal (plist-get (alist-get target spike-agents nil nil #'equal) :harness) "claude"))
                    (spike-claude-maybe-query
                     (seq-filter (lambda (a) (equal (plist-get (cdr a) :harness) "claude")) spike-agents)))))
    (spike-mark "discovery enabled")

    ;; Launch with the dashboard never opened.
    (let ((t1 (spike-new "*T1 claude*")))
      (spike-mark "launch T1")
      (spike-type t1 "claude --model haiku")
      (spike-probe t1 #'identity 20 "T1 process visible")
      (spike-wait 3)
      (spike-show-dashboard)
      (spike-wait 1)
      (spike-log "check" :label "rows after open" :t1 (if (spike-row t1) t :json-false) :t3 (if (spike-row t3) t :json-false))
      (spike-until (lambda () (spike-claude-is t1 "idle")) 15 "T1 idle at first prompt")

      ;; Negative controls in another terminal; T1 is now hidden.
      (let ((t2 (spike-new "*T2 control*")))
        (spike-wait 2)
        (dolist (control `(("synthetic claude title, progress, notifications"
                            . "printf '\\e]0;✳ Claude Code\\a\\e]9;4;3\\a\\e]9;Claude is waiting for your input\\a'; sleep 1.2; printf '\\e]777;notify;Claude Code;Claude is waiting for your input\\a'")
                           ,@(when spike-raw-claude
                               (list (cons "replay claude output"
                                           (format "cat %s; printf '\\e[?1049l\\e[0m\\n'" spike-raw-claude))))
                           ("progress with percent, like a build"
                            . "for i in 1 2 3; do printf '\\e]9;4;1;%d\\a' $((i*30)); sleep 1; done; printf '\\e]9;4;0\\a'")
                           ("sleep in foreground" . "sleep 4")
                           ("argv0 spoofed as claude" . "bash -c 'exec -a claude sleep 4'")
                           ("node that is not pi" . "node -e 'setTimeout(()=>{},4000)'")
                           ("reset title" . "printf '\\e]0;\\a'; clear")))
          (spike-mark (concat "control: " (car control)))
          (spike-type t2 (cdr control))
          (spike-wait 4.5)
          (spike-log "check" :label (car control) :t2_row (if (spike-row t2) t :json-false)
                     :t2_agent (if (spike-agent t2) t :json-false))))

      ;; Claude activity, through the native paste and binding actions.
      (spike-mark "prompt T1")
      (spike-type t1 "Reply with exactly the word OK and nothing else.")
      (spike-until (lambda () (spike-claude-is t1 "busy")) 20 "T1 busy")
      (spike-until (lambda () (spike-claude-is t1 "idle")) 60 "T1 idle after turn")
      (spike-mark "permission T1")
      (spike-type t1 (format "Use the Bash tool to run exactly this command: touch %sportal-gui-approved.txt" spike-scratch))
      (when (spike-until (lambda () (spike-claude-is t1 "waiting")) 60 "T1 waiting")
        (spike-log "check" :label "row while waiting" :row (format "%s" (spike-row t1)))
        (spike-wait 2)
        (spike-key t1 "text:\\r")
        (spike-until (lambda () (spike-claude-is t1 "idle")) 60 "T1 idle after approval"))
      (spike-mark "deny T1")
      (spike-type t1 (format "Use the Bash tool to run exactly this command: touch %sportal-gui-denied.txt" spike-scratch))
      (when (spike-until (lambda () (spike-claude-is t1 "waiting")) 60 "T1 waiting again")
        (spike-wait 2)
        (spike-key t1 "text:\\x1b")
        (spike-until (lambda () (spike-claude-is t1 "idle")) 30 "T1 idle after denial"))
      (spike-mark "cancel T1")
      (spike-type t1 "Use the Bash tool to run exactly this command: sleep 15")
      (when (spike-until (lambda () (spike-claude-is t1 "busy")) 20 "T1 busy before cancel")
        (spike-wait 4)
        (spike-key t1 "text:\\x1b")
        (spike-until (lambda () (spike-claude-is t1 "idle")) 30 "T1 idle after cancel"))

      ;; Codex started while the dashboard is hidden.
      (spike-hide-dashboard)
      (let ((t4 (spike-new "*T4 codex*")))
        (spike-type t4 "codex -c model_reasoning_effort=low")
        (spike-probe t4 #'identity 20 "T4 process visible")
        (spike-wait 6)
        (spike-show-dashboard)
        (spike-wait 1)
        (spike-log "check" :label "codex row after reopen" :row (format "%s" (spike-row t4)))
        (spike-mark "prompt T4")
        (spike-type t4 "Reply with exactly the word OK.")
        (spike-until (lambda () (equal (spike-activity (cons "x" (spike-agent t4)) t4) "working")) 20 "T4 working")
        (spike-until (lambda () (equal (spike-activity (cons "x" (spike-agent t4)) t4) "idle")) 90 "T4 idle")
        (spike-wait 2.5)
        (spike-log "check" :label "codex row idle" :row (format "%s" (spike-row t4)))
        (spike-type t4 "/quit")
        (spike-probe t4 #'null 15 "T4 gone after quit"))

      ;; Pi at its trust dialog: identified, activity unknown.
      (let ((t5 (spike-new "*T5 pi*")))
        (spike-type t5 "pi")
        (spike-probe t5 #'identity 20 "T5 process visible")
        (spike-wait 3)
        (spike-log "check" :label "pi row at trust dialog" :row (format "%s" (spike-row t5)))
        (spike-key t5 "text:\\x1b")
        (spike-wait 3)
        (spike-key t5 "text:\\x04")
        (unless (spike-probe t5 #'null 10 "T5 gone after ctrl-d")
          (spike-key t5 "text:\\x03") (spike-wait 0.5) (spike-key t5 "text:\\x03")
          (spike-probe t5 #'null 10 "T5 gone after ctrl-c")))

      ;; A second Claude in the same directory, in the quick terminal.
      (spike-mark "quick terminal")
      (let ((default-directory spike-project)) (portal-terminal-toggle))
      (let ((quick (current-buffer)))
        (spike-type quick "claude")
        (spike-probe quick #'identity 20 "quick process visible")
        (spike-wait 3)
        (spike-log "check" :label "three claude rows"
                   :rows (vconcat (mapcar (lambda (b) (format "%s" (spike-row b))) (list t1 t3 quick))))
        (spike-type quick "/exit")
        (spike-probe quick #'null 15 "quick gone after exit")
        (portal-terminal-quick-dismiss))

      ;; RET visits the right terminal.
      (with-selected-window spike-right
        (with-current-buffer portal-agents--buffer
          (goto-char (point-min))
          (while (and (not (eobp)) (not (eq (car (tabulated-list-get-id)) t1))) (forward-line 1))
          (portal-agents-visit)
          (spike-log "check" :label "RET visit" :buffer (buffer-name (window-buffer (selected-window))))))
      (spike-show-dashboard)

      ;; Quit back to the shell, then relaunch in the same terminal.
      (let ((old (plist-get (spike-agent t1) :pid)))
        (spike-mark "exit T1")
        (spike-type t1 "/exit")
        (spike-probe t1 #'null 15 "T1 gone after exit")
        (spike-wait 2.5)
        (spike-log "check" :label "T1 row after exit" :row (if (spike-row t1) t :json-false))
        (spike-type t1 "claude --model haiku")
        (let ((new (spike-probe t1 (lambda (a) (and a (not (equal (plist-get a :pid) old)))) 20 "T1 relaunched")))
          (spike-log "check" :label "relaunch" :old old :new (plist-get new :pid)
                     :status_at_relaunch (or (gethash (plist-get new :pid) spike-claude-status) :json-false)))
        (spike-until (lambda () (spike-claude-is t1 "idle")) 15 "T1 relaunch idle"))

      ;; Close a view while its agent runs, and let a late Claude report arrive.
      (spike-mark "close T3")
      (let ((pid (plist-get (spike-agent t3) :pid)))
        (spike-claude-query)
        (kill-buffer t3)
        (spike-wait 3)
        (spike-log "check" :label "after closing T3" :process_alive (if (process-attributes pid) t :json-false)
                   :status_after (or (gethash pid spike-claude-status) :json-false)
                   :rows (with-current-buffer portal-agents--buffer (length tabulated-list-entries))))
      (spike-type t1 "/exit")
      (spike-probe t1 #'null 15 "T1 gone at end")))
  (spike-wait 2)
  (spike-mark "done")
  (spike-log "scan_stats" :scans (length spike-scan-log)
             :helper_ms (vconcat (mapcar #'cadr spike-scan-log))
             :scan_us (vconcat (mapcar (lambda (s) (or (nth 2 s) 0)) spike-scan-log))))

(condition-case err
    (spike-scenario)
  (error (spike-log "error" :message (format "%S" err))))
(with-current-buffer "*Messages*" (write-region nil nil (expand-file-name "gui-run-1-messages.txt" spike-scratch)))
(portal-terminal-close-all)
(spike-wait 1)
(kill-emacs 0)
