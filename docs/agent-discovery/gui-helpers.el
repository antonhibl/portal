;;; gui-helpers.el --- Spike: helpers for the graphical runs -*- lexical-binding: t; -*-
;; Not for merge.  Loaded last into a graphical emacs -Q with the worktree's
;; build.  Writes marks to the Lisp trace; the native trace has callbacks.

(defvar spike-run-dir (file-name-directory (or load-file-name buffer-file-name)))
(defvar spike-project (or (getenv "SPIKE_PROJECT") (expand-file-name "../../" spike-run-dir))
  "A directory Claude and Codex already trust, so they open at their first prompt.")
(defvar spike-scratch (file-name-as-directory (or (getenv "SPIKE_SCRATCH") temporary-file-directory)))
(setq portal-terminal-confirm-kill nil
      message-log-max t)
(require 'portal)
(require 'portal-agents)
(require 'json)
(defvar spike-lisp-trace (getenv "PORTAL_SPIKE_LISP_TRACE"))
(defun spike-log (event &rest fields)
  (when spike-lisp-trace
    (write-region (concat (json-encode (append (list :wall (float-time) :event event) fields)) "\n")
                  nil spike-lisp-trace t 'silent)))

(defun spike-wait (seconds)
  "Run the event loop for SECONDS."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.05)
      (redisplay))))

(defun spike-mark (label &rest fields)
  (apply #'spike-log "mark" :label label fields)
  (message "SPIKE %s" label))

(defun spike-target (buffer) (buffer-local-value 'portal-view--target buffer))

(defun spike-type (buffer text)
  "Paste TEXT into BUFFER's terminal and press Enter."
  (spike-log "type" :target (spike-target buffer) :text text)
  (portal--terminal-paste (spike-target buffer) text t))

(defun spike-key (buffer action)
  "Run Ghostty binding ACTION, such as text:\\x1b, in BUFFER's terminal."
  (spike-log "key" :target (spike-target buffer) :action action)
  (portal--terminal-paste (spike-target buffer) (concat "" action)))

(defun spike-agent (buffer)
  (alist-get (spike-target buffer) spike-agents nil nil #'equal))

(defun spike-probe (buffer pred timeout label)
  "Scan every 0.1 s until PRED holds for BUFFER's agent; log the latency."
  (let ((start (float-time)) agent ok)
    (while (and (not (setq ok (funcall pred (setq agent (progn (spike-scan) (spike-agent buffer))))))
                (< (- (float-time) start) timeout))
      (spike-wait 0.1))
    (spike-log "probe" :label label :ms (* 1000 (- (float-time) start)) :ok (if ok t :json-false)
               :pid (and agent (plist-get agent :pid)) :harness (and agent (plist-get agent :harness)))
    agent))

(defun spike-until (pred timeout label)
  "Wait until PRED holds, at most TIMEOUT seconds; log it."
  (let ((start (float-time)) ok)
    (while (and (not (setq ok (funcall pred))) (< (- (float-time) start) timeout))
      (spike-wait 0.1))
    (spike-log "until" :label label :ms (* 1000 (- (float-time) start)) :ok (if ok t :json-false))
    ok))

(defun spike-claude-is (buffer status)
  (when-let* ((agent (spike-agent buffer)))
    (equal (gethash (plist-get agent :pid) spike-claude-status) status)))

(defun spike-row (buffer)
  "BUFFER's dashboard row vector, or nil."
  (when (buffer-live-p portal-agents--buffer)
    (with-current-buffer portal-agents--buffer
      (cadr (seq-find (lambda (entry) (eq (car (car entry)) buffer)) tabulated-list-entries)))))

(defun spike-new (name)
  "Start a terminal NAME in the selected window."
  (let ((default-directory spike-project))
    (portal-terminal-new)
    (portal-terminal-rename name)
    (spike-mark (concat "opened " name) :target (spike-target (current-buffer)))
    (current-buffer)))

(defun spike-show-dashboard ()
  (with-selected-window spike-right (portal-agents))
  (spike-mark "dashboard shown"))

(defun spike-hide-dashboard ()
  (with-selected-window spike-right (switch-to-buffer "*scratch*"))
  (spike-mark "dashboard hidden"))

(defvar spike-right nil)
(defvar spike-raw-claude (getenv "SPIKE_REPLAY") "A capture.py .raw file of a Claude session, replayed as a control.")

