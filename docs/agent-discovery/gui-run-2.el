;;; gui-run-2.el --- Spike run 2: progress trigger, Pi, Codex exit, cost -*- lexical-binding: t; -*-
;; Not loaded by Portal.  Run with SPIKE_USE_PROGRESS=1; see run-gui.sh.

(defvar spike-run-dir (file-name-directory (or load-file-name buffer-file-name)))
(load (expand-file-name "gui-helpers.el" spike-run-dir))
(load (expand-file-name "prototype.el" spike-run-dir))

;; Count terminal change records and time their Lisp handling, per target.
(defvar spike-changed (make-hash-table :test #'equal) "TARGET -> (COUNT . SECONDS).")
(advice-add 'portal-terminal--changed :around
            (lambda (orig target)
              (let ((start (float-time)))
                (prog1 (funcall orig target)
                  (let ((cell (or (gethash target spike-changed) (cons 0 0.0))))
                    (puthash target (cons (1+ (car cell)) (+ (cdr cell) (- (float-time) start))) spike-changed))))))
;; Claude queries on title-glyph or progress changes while the list is shown.
(advice-add 'portal-terminal--changed :after
            (lambda (target)
              (when (and (portal-agents--shown-p)
                         (equal (plist-get (alist-get target spike-agents nil nil #'equal) :harness) "claude"))
                (spike-claude-maybe-query
                 (seq-filter (lambda (a) (equal (plist-get (cdr a) :harness) "claude")) spike-agents)))))

(defun spike-changed-snapshot ()
  (let (out) (maphash (lambda (k v) (push (list k (car v) (* 1000 (cdr v))) out)) spike-changed) out))

(defun spike-scenario2 ()
  (set-frame-size (selected-frame) 220 56)
  (delete-other-windows)
  (setq spike-right (split-window-right))
  (spike-wait 0.5)
  (spike-show-dashboard)

  ;; Claude: waiting -> idle on denial, with the progress trigger.
  (let ((t1 (spike-new "*T1 claude*")))
    (spike-type t1 "claude --model haiku")
    (spike-probe t1 #'identity 20 "T1 process visible")
    (spike-until (lambda () (spike-claude-is t1 "idle")) 20 "T1 idle at first prompt")
    (spike-mark "deny T1")
    (spike-type t1 (format "Use the Bash tool to run exactly this command: touch %sportal-gui2-denied.txt" spike-scratch))
    (when (spike-until (lambda () (spike-claude-is t1 "waiting")) 60 "T1 waiting")
      (spike-wait 2)
      (spike-key t1 "text:\\x1b")
      (spike-until (lambda () (spike-claude-is t1 "idle")) 40 "T1 idle after denial"))

    ;; Pi at its trust dialog, then quit.
    (let ((t5 (spike-new "*T5 pi*")))
      (spike-type t5 "pi")
      (spike-probe t5 #'identity 20 "T5 process visible")
      (spike-wait 3)
      (spike-log "check" :label "pi row at trust dialog" :row (format "%s" (spike-row t5))
                 :agent (format "%s" (spike-agent t5)))
      (spike-key t5 "text:\\x1b")
      (spike-wait 3)
      (spike-log "check" :label "pi row after trust dialog" :row (format "%s" (spike-row t5)))
      (spike-key t5 "text:\\x04")
      (unless (spike-probe t5 #'null 10 "T5 gone after ctrl-d")
        (spike-key t5 "text:\\x03") (spike-wait 0.5) (spike-key t5 "text:\\x03")
        (spike-probe t5 #'null 10 "T5 gone after ctrl-c")))

    ;; Codex: identified at its first prompt, then quit.
    (let ((t4 (spike-new "*T4 codex*")))
      (spike-type t4 "codex")
      (spike-probe t4 #'identity 20 "T4 process visible")
      (spike-wait 5)
      (spike-log "check" :label "codex row at first prompt" :row (format "%s" (spike-row t4)))
      (spike-type t4 "/quit")
      (spike-wait 1)
      (unless (spike-probe t4 #'null 2 "T4 gone after /quit")
        (spike-key t4 "text:\\r")
        (unless (spike-probe t4 #'null 10 "T4 gone after second Enter")
          (spike-key t4 "text:\\x03") (spike-wait 0.3) (spike-key t4 "text:\\x03")
          (spike-probe t4 #'null 10 "T4 gone after ctrl-c"))))

    ;; Collection cost: a 10 Hz title spinner, like Codex's, with the list hidden then shown.
    (let ((t2 (spike-new "*T2 spinner*")))
      (spike-wait 1)
      (spike-hide-dashboard)
      (clrhash spike-changed)
      (let ((scans (length spike-scan-log)) (queries spike-claude-queried))
        (spike-mark "spinner hidden")
        (spike-type t2 "for i in $(seq 100); do printf '\\e]0;%s spin\\a' $i; sleep 0.1; done")
        (spike-wait 11)
        (spike-log "cost" :label "hidden 10 Hz spinner" :changed (vconcat (mapcar #'vconcat (spike-changed-snapshot)))
                   :scans (- (length spike-scan-log) scans) :claude_queried_since (if (equal queries spike-claude-queried) :json-false t)))
      (spike-show-dashboard)
      (clrhash spike-changed)
      (let ((scans (length spike-scan-log)) (start (float-time)))
        (spike-mark "spinner shown")
        (spike-type t2 "for i in $(seq 100); do printf '\\e]0;%s spin\\a' $i; sleep 0.1; done")
        (spike-wait 11)
        (spike-log "cost" :label "shown 10 Hz spinner" :changed (vconcat (mapcar #'vconcat (spike-changed-snapshot)))
                   :scans (- (length spike-scan-log) scans)
                   :scan_us (vconcat (mapcar (lambda (s) (or (nth 2 s) 0)) (seq-take spike-scan-log (- (length spike-scan-log) scans))))
                   :helper_ms (vconcat (mapcar #'cadr (seq-take spike-scan-log (- (length spike-scan-log) scans))))
                   :seconds (- (float-time) start))))

    ;; Close T1 while a Claude query is in flight.
    (spike-mark "close T1 during query")
    (let ((pid (plist-get (spike-agent t1) :pid)))
      (spike-claude-query)
      (kill-buffer t1)
      (spike-wait 3)
      (spike-log "check" :label "after closing T1" :process_alive (if (process-attributes pid) t :json-false)
                 :status_after (or (gethash pid spike-claude-status) :json-false)
                 :rows (with-current-buffer portal-agents--buffer (length tabulated-list-entries)))))
  (spike-wait 1)
  (spike-mark "done"))

(condition-case err
    (spike-scenario2)
  (error (spike-log "error" :message (format "%S" err))))
(with-current-buffer "*Messages*" (write-region nil nil (expand-file-name "gui-run-2-messages.txt" spike-scratch)))
(portal-terminal-close-all)
(spike-wait 1)
(kill-emacs 0)
