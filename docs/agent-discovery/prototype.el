;;; prototype.el --- Spike prototype: automatic agent rows in portal-agents -*- lexical-binding: t; -*-
;; Not for merge.  Discovery: `agentscan' finds agent processes carrying this
;; Emacs's PORTAL_TERMINAL marker.  Activity: Claude from `claude agents --json'
;; by pid, queried when its title glyph class changes; Codex from its title;
;; Pi unknown.  Everything is logged to `spike-lisp-trace'.

(require 'portal-agents)
(require 'json)

(defvar spike-dir (file-name-directory (or load-file-name buffer-file-name)))
(defvar spike-scan-program (or (getenv "SPIKE_SCANNER") (expand-file-name "../../build/agentscan" spike-dir)))
(defvar spike-lisp-trace (getenv "PORTAL_SPIKE_LISP_TRACE"))

(defun spike-log (event &rest fields)
  "Append EVENT with plist FIELDS to the Lisp trace."
  (when spike-lisp-trace
    (let ((json-encoding-pretty-print nil))
      (write-region (concat (json-encode (append (list :wall (float-time) :event event) fields)) "\n")
                    nil spike-lisp-trace t 'silent))))

;;;; Discovery

(defvar spike-agents nil "Alist (TARGET . PLIST) of foreground, outermost agents from the last scan.")
(defvar spike-skipped nil "Agents a scan saw but did not list: background or nested.")
(defvar spike-scan-log nil "List of (WALL ELAPSED-MS SCAN-US) for each scan.")

(defun spike-scan ()
  "Scan for agents now and return `spike-agents'."
  (let* ((start (float-time))
         (output (with-temp-buffer
                   (call-process spike-scan-program nil t nil (number-to-string (emacs-pid)))
                   (buffer-string)))
         (elapsed (* 1000 (- (float-time) start)))
         agents scan-us)
    (dolist (line (split-string output "\n" t))
      (let ((object (json-parse-string line :object-type 'plist :false-object nil)))
        (if (plist-get object :scan_us)
            (setq scan-us (plist-get object :scan_us))
          (when (and (plist-get object :fg) (not (plist-get object :nested)))
            (push (cons (plist-get object :target) object) agents))
          (unless (and (plist-get object :fg) (not (plist-get object :nested)))
            (push (cons 'skipped object) spike-skipped)))))
    (setq agents (nreverse agents))
    (push (list (float-time) elapsed scan-us) spike-scan-log)
    (let ((old (mapcar (lambda (a) (format "%s %s %s" (car a) (plist-get (cdr a) :harness) (plist-get (cdr a) :pid))) spike-agents))
          (new (mapcar (lambda (a) (format "%s %s %s" (car a) (plist-get (cdr a) :harness) (plist-get (cdr a) :pid))) agents)))
      (unless (equal old new)
        (spike-log "discovered" :agents (vconcat new) :scan_ms elapsed :scan_us scan-us)))
    (setq spike-agents agents)))

(defun spike-buffer (target)
  "Return the terminal buffer whose view is TARGET, or nil."
  (seq-find (lambda (buffer) (equal (buffer-local-value 'portal-view--target buffer) target))
            (portal-view-buffers 'terminal)))

;;;; Activity

(defvar spike-claude-status (make-hash-table) "PID -> status from the last `claude agents --json'.")
(defvar spike-claude-process nil)
(defvar spike-claude-classes nil "Alist (TARGET . TITLE-CLASS) when Claude was last queried.")
(defvar spike-claude-queried 0 "When Claude was last queried.")
(defvar spike-claude-pending nil
  "Non-nil if a trigger fired while a query ran: query again when it finishes.
The running query may have sampled a state that has since passed, even if
the title and progress are back to what they were when it started.")
(defvar spike-use-progress (getenv "SPIKE_USE_PROGRESS")
  "Whether the Claude query trigger includes the OSC 9;4 progress state.")
(defvar spike-claude-poll 30 "Seconds between safety queries while Claude rows are shown.")

(defun spike-claude-class (title)
  "Claude's title glyph: idle-or-waiting, working, or other."
  (cond ((null title) 'none)
        ((string-prefix-p "✳" title) 'star)
        ;; Braille through 2.1.227, half circles from 2.1.228.
        ((string-match-p "\\`[⠀-⣿◐◑◒◓]" title) 'spinner)
        (t 'other)))

(defun spike-claude-query ()
  "Start one asynchronous `claude agents --json' unless one runs."
  (unless (process-live-p spike-claude-process)
    (let ((buffer (generate-new-buffer " *spike-claude*"))
          (start (float-time)))
      (setq spike-claude-queried start)
      (spike-log "claude_query_start")
      (setq spike-claude-process
            (make-process
             :name "spike-claude" :buffer buffer :noquery t :connection-type 'pipe
             :command '("claude" "agents" "--json")
             :stderr (get-buffer-create " *spike-claude-err*")
             :sentinel
             (lambda (process _event)
               (unless (process-live-p process)
                 (let ((sessions (ignore-errors
                                   (with-current-buffer buffer
                                     (json-parse-string (buffer-string) :object-type 'plist
                                                        :array-type 'list :null-object nil)))))
                   (kill-buffer buffer)
                   (clrhash spike-claude-status)
                   (dolist (session sessions)
                     (puthash (plist-get session :pid) (or (plist-get session :status) "starting")
                              spike-claude-status))
                   (spike-log "claude_query_done" :ms (* 1000 (- (float-time) start))
                              :statuses (vconcat (mapcar (lambda (s) (format "%s %s" (plist-get s :pid) (plist-get s :status)))
                                                         sessions)))
                   (when spike-claude-pending
                     (setq spike-claude-pending nil)
                     (spike-claude-query))
                   (portal-agents--changed)))))))))

(defun spike-claude-maybe-query (claude)
  "Query Claude if its terminals' title classes changed, a pid is new, or the poll is due.
CLAUDE is a list of (TARGET . PLIST) agents."
  (let ((classes (mapcar (lambda (agent)
                           (cons (car agent)
                                 (cons (spike-claude-class
                                        (when-let* ((buffer (spike-buffer (car agent))))
                                          (plist-get (portal-terminal-metadata buffer) :title)))
                                       (and spike-use-progress
                                            (plist-get (portal--inspect (car agent)) :progress)))))
                         claude)))
    (when (and claude
               (or (not (equal classes spike-claude-classes))
                   (and (seq-some (lambda (agent) (not (gethash (plist-get (cdr agent) :pid) spike-claude-status)))
                                  claude)
                        (> (- (float-time) spike-claude-queried) 4))
                   (> (- (float-time) spike-claude-queried) spike-claude-poll)))
      (setq spike-claude-classes classes)
      (if (process-live-p spike-claude-process)
          (setq spike-claude-pending t)
        (spike-claude-query)))))

(defun spike-strip-title (title)
  "TITLE without one leading activity marker, so spinner frames and Codex's
blinking [ . ] / [ ! ] change no row.  Activity has its own column."
  (if (and title (string-match "\\`\\(?:[⠀-⣿◐◑◒◓✳]\\|\\[ [.!] \\]\\)[ \t]*" title))
      (substring title (match-end 0))
    title))

(defun spike-activity (agent buffer)
  "Return AGENT's activity in BUFFER as a string, with its source."
  (let ((title (plist-get (portal-terminal-metadata buffer) :title)))
    (pcase (plist-get (cdr agent) :harness)
      ("claude" (pcase (gethash (plist-get (cdr agent) :pid) spike-claude-status)
                  ("busy" "working") ("waiting" "waiting") ("idle" "idle")
                  (_ "unknown")))
      ("codex" (cond ((null title) "unknown")
                     ((string-match-p "Action Required" title) "waiting")
                     ((string-match-p "\\`[⠀-⣿]" title) "working")
                     (t "idle")))
      (_ "unknown"))))

;;;; Dashboard

(defun spike-facts (orig)
  "Tracked sessions from ORIG, then every discovered agent's terminal."
  (spike-scan)
  (spike-claude-maybe-query (seq-filter (lambda (a) (equal (plist-get (cdr a) :harness) "claude")) spike-agents))
  (let* ((tracked (funcall orig))
         (buffers (mapcar #'caar tracked)))
    (append tracked
            (delq nil
                  (mapcar (lambda (agent)
                            (let ((buffer (spike-buffer (car agent))))
                              (when (and buffer (not (memq buffer buffers)))
                                (let ((metadata (copy-sequence (portal-terminal-metadata buffer))))
                                  (setq metadata (plist-put metadata :title (spike-strip-title
                                                                             (plist-get metadata :title))))
                                  (list (cons buffer (car agent))
                                        (plist-get (cdr agent) :harness)
                                        (append metadata
                                                (list :activity (spike-activity agent buffer)
                                                      :pid (plist-get (cdr agent) :pid))))))))
                          spike-agents)))))

(defun spike-rows (orig facts)
  "Rows from ORIG for FACTS, with discovered activity in the Activity column."
  (let ((rows (funcall orig facts)))
    (cl-loop for row in rows for fact in facts
             for activity = (plist-get (nth 2 fact) :activity)
             when activity do (aset (cadr row) 4 activity))
    rows))

(defun spike-print (orig rows)
  "Log what the dashboard prints, then print ROWS with ORIG."
  (spike-log "rows" :rows (vconcat (mapcar (lambda (row)
                                             (let ((v (cadr row)))
                                               (format "%s | %s | %s | %s | %s" (aref v 0) (aref v 1) (aref v 3) (aref v 4) (aref v 6))))
                                           rows)))
  (funcall orig rows))

(advice-add 'portal-agents--facts :around #'spike-facts)
(advice-add 'portal-agents--rows :around #'spike-rows)
(advice-add 'portal-agents--print :around #'spike-print)
(spike-log "discovery_enabled")

;;; prototype.el ends here
