;;; portal-agent-discovery.el --- Foreground Claude discovery -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Process identity and activity collection, independent of table rendering.
(require 'cl-lib)
(require 'json)
(require 'portal-terminal)
(require 'portal-agent-process)

(declare-function portal--process-snapshot "portal-view" (variable))
(declare-function portal-agents--shown-p "portal-agents" ())
(declare-function portal-agents--changed "portal-agents" ())
(defvar portal-agents-live-update)

(defcustom portal-agents-discover-claude t
  "Discover foreground Claude sessions when the dashboard is refreshed.
No Claude configuration is required.  Suspended sessions disappear until
foregrounded.  Terminals must have been started by a build with discovery."
  :type 'boolean :group 'portal-agents)

(defcustom portal-agents-claude-program "claude"
  "Claude executable used for asynchronous `agents --json' status queries.
Use an absolute path if Claude is not on Emacs's `exec-path'."
  :type 'string :group 'portal-agents)

(cl-defstruct (portal-agent (:constructor portal-agent--create))
  key pid start signal (revision 0) (activity "unknown")
  (reason "Not yet listed (possibly at a trust dialog)") process-error)

(defvar portal-agent-discovery--agents nil "Current foreground agents, in terminal order.")
(defvar portal-agent-discovery--hidden nil "Incarnations explicitly hidden by untracking.")
(defvar portal-agent-discovery--process nil "The sole in-flight status query.")
(defvar portal-agent-discovery--timeout nil "Its deadline timer.")
(defvar portal-agent-discovery--pending nil "A trigger arrived during the query.")
(defvar portal-agent-discovery--queried 0 "Time the last query started.")
(defvar portal-agent-discovery--collecting nil "Prevent recursive collection.")

(defun portal-agent-discovery--class (title)
  "Classify TITLE's leading glyph solely as a status-query trigger."
  (cond ((not title) 'none)
        ((string-prefix-p "✳" title) 'star)
        ((string-match-p "\\`[⠀-⣿◐◑◒◓]" title) 'spinner)
        (t 'other)))

(defun portal-agent-discovery--strip-title (title)
  "Remove one activity marker from TITLE to avoid spinner-only redraws."
  (if (and title (string-match "\\`\\(?:[⠀-⣿◐◑◒◓✳]\\|\\[ [.!] \\]\\)[ \t]*" title))
      (substring title (match-end 0))
    title))

(defun portal-agent-discovery--signal (buffer)
  "Return BUFFER's cached title class and progress state."
  (with-current-buffer buffer
    (cons (portal-agent-discovery--class portal-terminal--title) portal-terminal--progress)))

(defun portal-agent-discovery--identity (agent)
  "Return AGENT's terminal and process incarnation."
  (list (portal-agent-key agent) (portal-agent-pid agent) (portal-agent-start agent)))

(defun portal-agent-discovery--live-p (agent)
  "Whether AGENT's buffer still owns its original terminal view."
  (let ((key (portal-agent-key agent)))
    (and (buffer-live-p (car key))
         (equal (buffer-local-value 'portal-view--target (car key)) (cdr key)))))

(defun portal-agent-discovery--find (buffer)
  "Return the discovered agent in BUFFER, if any."
  (seq-find (lambda (a) (and (eq buffer (car (portal-agent-key a)))
                             (portal-agent-discovery--live-p a))) portal-agent-discovery--agents))

(defun portal-agent-discovery--unknown (agent reason)
  "Invalidate AGENT's activity with REASON."
  (setf (portal-agent-activity agent) "unknown" (portal-agent-reason agent) reason))

(defun portal-agent-discovery--hidden-p (agent)
  "Whether AGENT's incarnation was explicitly hidden."
  (member (portal-agent-discovery--identity agent) portal-agent-discovery--hidden))

(defun portal-agent-discovery--set-hidden (buffer hidden)
  "Set whether BUFFER's discovered run is HIDDEN, owning all invalidation.
Showing clears the terminal session's hidden identities even without a cached
agent.  Hiding ends observation and invalidates replies already in flight."
  (let ((key (cons buffer (buffer-local-value 'portal-view--target buffer)))
        (agent (portal-agent-discovery--find buffer)))
    (if (not hidden)
        (setq portal-agent-discovery--hidden
              (cl-delete key portal-agent-discovery--hidden :key #'car :test #'equal))
      (when agent
        (cl-pushnew (portal-agent-discovery--identity agent) portal-agent-discovery--hidden :test #'equal)
        (cl-incf (portal-agent-revision agent))
        (setf (portal-agent-signal agent) nil)
        (portal-agent-discovery--unknown agent "Status unobserved while untracked")))))

(defun portal-agent-discovery--scan ()
  "Reconcile a foreground snapshot with terminal buffers.  Return success.
Unchanged incarnations retain their objects; results can only update those
objects, so replacement, exit, PID reuse and late replies cannot create rows."
  (condition-case err
      (let* ((processes (and (fboundp 'portal--process-snapshot)
                             (append (portal--process-snapshot "PORTAL_TERMINAL") nil)))
             (prefix (format "%s/" (emacs-pid)))
             (sessions (portal-agent-process-sessions processes (emacs-pid)))
             (old portal-agent-discovery--agents) agents)
        (dolist (buffer (portal-terminal-buffers nil t))
          (let* ((key (cons buffer (buffer-local-value 'portal-view--target buffer)))
                 (marker (concat prefix (cdr key)))
                 (p (cdr (assoc marker sessions))))
            (when (and (equal (plist-get p :agent) "claude")
                       (not (buffer-local-value 'portal-terminal--exited buffer)))
              (let* ((identity (list key (plist-get p :pid) (plist-get p :start)))
                     (agent (or (cl-find identity old :key #'portal-agent-discovery--identity :test #'equal)
                                (portal-agent--create :key key :pid (plist-get p :pid)
                                                      :start (plist-get p :start)))))
                (setf (portal-agent-process-error agent) nil)
                (push agent agents)))))
        (setq portal-agent-discovery--agents (nreverse agents)
              portal-agent-discovery--hidden
              (cl-intersection portal-agent-discovery--hidden
                               (mapcar #'portal-agent-discovery--identity portal-agent-discovery--agents) :test #'equal))
        t)
    (error
     (dolist (agent portal-agent-discovery--agents)
       (setf (portal-agent-process-error agent) t)
       (portal-agent-discovery--unknown agent (concat "Discovery failed: " (error-message-string err))))
     nil)))

(defun portal-agent-discovery--visible-agents ()
  "Return the discovered agents not explicitly hidden."
  (seq-remove (lambda (a) (or (not (portal-agent-discovery--live-p a))
                             (portal-agent-discovery--hidden-p a)))
              portal-agent-discovery--agents))

(defun portal-agent-discovery--observe ()
  "Notice all title/progress transitions, even while a query is in flight."
  (let (changed)
    (dolist (agent (portal-agent-discovery--visible-agents))
      (let ((signal (portal-agent-discovery--signal (car (portal-agent-key agent)))))
        (unless (equal signal (portal-agent-signal agent))
          (setf (portal-agent-signal agent) signal)
          (cl-incf (portal-agent-revision agent))
          (portal-agent-discovery--unknown agent "Status changed; refreshing")
          (setq changed t))))
    changed))

(defun portal-agent-discovery--stop ()
  "Cancel collection and release query resources.  Keep identities for redisplay."
  (when portal-agent-discovery--timeout (cancel-timer portal-agent-discovery--timeout))
  (setq portal-agent-discovery--timeout nil portal-agent-discovery--pending nil)
  (when-let* ((process portal-agent-discovery--process))
    (setq portal-agent-discovery--process nil)
    (set-process-sentinel process #'ignore)
    (delete-process process)
    (dolist (buffer (list (process-buffer process) (process-get process 'stderr)))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (dolist (agent portal-agent-discovery--agents)
    (portal-agent-discovery--unknown agent "Refresh paused")))

(defun portal-agent-discovery--statuses (text)
  "Parse TEXT as Claude's JSON status array, rejecting malformed responses."
  (let ((value (json-parse-string text :object-type 'plist :array-type 'array
                                  :null-object nil :false-object nil))
        (seen (make-hash-table)))
    (unless (vectorp value) (error "Expected a status array"))
    (seq-doseq (entry value)
      (unless (and (listp entry) (keywordp (car entry)))
        (error "Invalid status entry"))
      ;; The API also lists blocked background sessions with no live process.
      ;; Their pid/status fields are absent, and cannot describe a terminal.
      (when (plist-member entry :pid)
        (unless (and (integerp (plist-get entry :pid)) (> (plist-get entry :pid) 0)
                     (stringp (plist-get entry :status))
                     (not (gethash (plist-get entry :pid) seen)))
          (error "Invalid or duplicate process status"))
        (puthash (plist-get entry :pid) (plist-get entry :status) seen)))
    seen))

(defun portal-agent-discovery--apply (requested statuses failure)
  "Apply STATUSES or FAILURE only to unchanged agents in REQUESTED."
  (dolist (request requested)
    (let ((agent (car request)))
      (when (and (memq agent portal-agent-discovery--agents)
                 (= (cdr request) (portal-agent-revision agent))
                 (not (portal-agent-process-error agent)))
        (let* ((status (and statuses (gethash (portal-agent-pid agent) statuses)))
               (activity (cdr (assoc status '(("busy" . "working") ("waiting" . "waiting") ("idle" . "idle"))))))
          (setf (portal-agent-activity agent) (or activity "unknown")
                (portal-agent-reason agent)
                (cond (failure failure)
                      (activity "Reported by claude agents --json; idle does not mean success")
                      (status (format "Unsupported Claude status: %s" status))
                      (t "Not yet listed (possibly at a trust dialog)"))))))))

(defun portal-agent-discovery--finished (process _event)
  "Accept PROCESS's bounded response if it is still the current query."
  (when (and (eq process portal-agent-discovery--process) (not (process-live-p process)))
    (when portal-agent-discovery--timeout (cancel-timer portal-agent-discovery--timeout))
    (setq portal-agent-discovery--timeout nil portal-agent-discovery--process nil)
    (let ((requested (process-get process 'requested))
          (failure (or (process-get process 'failure)
                       (unless (= (process-exit-status process) 0) "Claude status query failed")))
          statuses)
      (unwind-protect
          (unless failure
            (condition-case nil
                (setq statuses (portal-agent-discovery--statuses
                                (with-current-buffer (process-buffer process) (buffer-string))))
              (error (setq failure "Invalid Claude status response"))))
        (dolist (buffer (list (process-buffer process) (process-get process 'stderr)))
          (when (buffer-live-p buffer) (kill-buffer buffer))))
      (when (and portal-agents-discover-claude (portal-agents--shown-p))
        ;; Revalidate the process start time before accepting a PID-only answer.
        (when (portal-agent-discovery--scan)
          (when (portal-agent-discovery--observe) (setq portal-agent-discovery--pending t))
          (portal-agent-discovery--apply requested statuses failure))
        (portal-agents--changed)
        (when (and portal-agent-discovery--pending portal-agents-live-update)
          (setq portal-agent-discovery--pending nil)
          (portal-agent-discovery--query))))))

(defun portal-agent-discovery--query ()
  "Request status asynchronously, with one process and a five-second deadline."
  (if portal-agent-discovery--process
      (setq portal-agent-discovery--pending t)
    (when-let* ((agents (portal-agent-discovery--visible-agents)))
      (let ((buffer (generate-new-buffer " *portal-claude-status*"))
            (stderr (generate-new-buffer " *portal-claude-errors*"))
            ;; A dashboard may have been opened from a remote buffer.
            (default-directory temporary-file-directory))
        (setq portal-agent-discovery--queried (float-time)
              portal-agent-discovery--pending nil)
        (condition-case nil
            (let ((process
                   (make-process
                    :name "portal-claude-status" :buffer buffer :stderr stderr
                    :command (list portal-agents-claude-program "agents" "--json")
                    :connection-type 'pipe :coding 'utf-8-unix :noquery t
                    :filter (lambda (p text)
                              (when (buffer-live-p (process-buffer p))
                                (with-current-buffer (process-buffer p)
                                  (if (> (+ (buffer-size) (length text)) (* 1024 1024))
                                      (progn (process-put p 'failure "Claude status response too large")
                                             (delete-process p))
                                    (goto-char (point-max)) (insert text)))))
                    :sentinel #'portal-agent-discovery--finished)))
              (setq portal-agent-discovery--process process)
              (process-put process 'stderr stderr)
              (when-let* ((errors (get-buffer-process stderr)))
                (set-process-filter
                 errors (lambda (_ text)
                          (when (buffer-live-p stderr)
                            (with-current-buffer stderr
                              (if (> (+ (buffer-size) (length text)) (* 64 1024))
                                  (progn (process-put process 'failure "Claude status errors too large")
                                         (delete-process process))
                                (goto-char (point-max)) (insert text)))))))
              (process-put process 'requested (mapcar (lambda (a) (cons a (portal-agent-revision a))) agents))
              (setq portal-agent-discovery--timeout
                    (run-at-time 5 nil
                                 (lambda ()
                                   (when (eq process portal-agent-discovery--process)
                                     (process-put process 'failure "Claude status query timed out")
                                     (delete-process process))))))
          (error
           (kill-buffer buffer) (kill-buffer stderr)
           (dolist (agent agents)
             (portal-agent-discovery--unknown agent "Cannot start Claude status query"))))))))

(defun portal-agent-discovery--collect (&optional force)
  "Discover current agents and schedule status when needed; FORCE queries on show."
  (when (and (not portal-agent-discovery--collecting) (portal-agents--shown-p))
    (let ((portal-agent-discovery--collecting t))
      (if (not portal-agents-discover-claude)
          (progn (portal-agent-discovery--stop) (setq portal-agent-discovery--agents nil))
        (when (portal-agent-discovery--scan)
          (let* ((changed (portal-agent-discovery--observe))
                 (elapsed (- (float-time) portal-agent-discovery--queried))
                 (agents (portal-agent-discovery--visible-agents)))
            (when (and agents
                       (or force changed (> elapsed 30)
                           (and (> elapsed 4) (seq-some (lambda (a) (equal (portal-agent-activity a) "unknown")) agents))))
              (portal-agent-discovery--query))))))))

(defun portal-agent-discovery--metadata-changed ()
  "Use a cached terminal transition to trigger status while live and shown."
  (when (and portal-agents-discover-claude portal-agents-live-update
             (portal-agents--shown-p) (portal-agent-discovery--find (current-buffer))
             (portal-agent-discovery--observe))
    (portal-agent-discovery--query)))

(add-hook 'portal-terminal-metadata-change-hook #'portal-agent-discovery--metadata-changed)

(provide 'portal-agent-discovery)
;;; portal-agent-discovery.el ends here
