;;; portal-agents.el --- A live list of tracked terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; `portal-agents' lists the terminals you track, typically ones running coding
;; agents, in one ordinary Tabulated List buffer.  Rows come from what
;; `portal-terminal-metadata' has cached, so a refresh asks nothing of native
;; code or the shells.  While the list is shown, one timer refreshes it, and a
;; refresh rewrites the buffer only when those facts changed.  A running shell
;; says nothing of what its agent is doing, so activity stays unknown.

(require 'cl-lib)
(require 'tabulated-list)
(require 'portal-terminal)
(require 'portal-terminal-choose)

(defgroup portal-agents nil
  "A live list of tracked Portal terminals."
  :group 'portal-terminal)

(defcustom portal-agents-live-update t
  "Whether the agent dashboard refreshes itself while it is shown.
When non-nil, one timer refreshes it every `portal-agents-live-update-interval'
seconds while a window on a visible frame shows it.  Either way, it refreshes
when opened or shown again and with \\`g'.  Toggle it in the dashboard with
`portal-agents-toggle-live-update'."
  :type 'boolean
  :group 'portal-agents)

(defcustom portal-agents-live-update-interval 2
  "Seconds between the agent dashboard's live refreshes.
A change applies the next time live updates start."
  :type 'number
  :group 'portal-agents)

(defvar portal-agents--tracked nil
  "The tracked sessions in tracking order, as ((BUFFER . TARGET) . LABEL).
TARGET is the native view BUFFER had when tracked, so that a terminal
closed or replaced in the same buffer is never taken for the one tracked.
LABEL is the agent's label, as supplied, or nil.")

(defvar portal-agents--buffer nil "The dashboard buffer, or nil.")
(defvar portal-agents--shown nil "Whether the dashboard was shown when last checked.")
(defvar portal-agents--timer nil "The timer refreshing the shown dashboard, or nil.")
(defvar-local portal-agents--facts nil "The facts last printed; see `portal-agents--facts'.")

(defconst portal-agents--columns
  '(("Terminal" 32) ("Agent" 16) ("Project" 20) ("Process" 7) ("Activity" 8)
    ("Directory" 40) ("Title" 0))
  "Each column's name and widest width; the last column is never cut.")

(defun portal-agents--live-p (key)
  "Return non-nil if KEY, a (BUFFER . TARGET) pair, is still BUFFER's session."
  (and (buffer-live-p (car key))
       (equal (buffer-local-value 'portal-view--target (car key)) (cdr key))))

(defun portal-agents--sessions ()
  "Return the tracked sessions that are still live, and forget the others.
A session whose program exited stays while its buffer keeps its view."
  (setq portal-agents--tracked
        (cl-remove-if-not #'portal-agents--live-p portal-agents--tracked :key #'car)))

(defun portal-agents--tracked-p (buffer)
  "Return BUFFER's tracked session, as an element of `portal-agents--tracked'."
  (cl-find buffer (portal-agents--sessions) :key #'caar))

(defun portal-agents--facts ()
  "Return what the dashboard shows of each live tracked session, in order.
Each is (KEY LABEL METADATA), METADATA being what `portal-terminal-metadata'
has cached."
  (mapcar (lambda (session)
            (list (car session) (cdr session) (portal-terminal-metadata (caar session))))
          (portal-agents--sessions)))

(defun portal-agents--rows (facts)
  "Return a row for each of FACTS, from `portal-agents--facts'.
Each is (KEY [TERMINAL AGENT PROJECT PROCESS ACTIVITY DIRECTORY TITLE])."
  (let ((projects (portal-terminal--project-names
                   (delq nil (mapcar (lambda (fact) (plist-get (nth 2 fact) :project)) facts)))))
    (mapcar
     (pcase-lambda (`(,key ,label ,entry))
       (let ((title (plist-get entry :title)))
         (list key
               (vector (plist-get entry :name)
                       (or label "")
                       (or (alist-get (plist-get entry :project) projects nil nil #'equal) "-")
                       (if (plist-get entry :exited) "exited" "running")
                       ;; No source reports what an agent is doing yet.
                       (propertize "unknown" 'face 'shadow)
                       (abbreviate-file-name (plist-get entry :directory))
                       (if title (replace-regexp-in-string "[[:cntrl:]]" " " title) "")))))
     facts)))

(defun portal-agents--format (rows)
  "Return the column format, each column as wide as ROWS need, within limits."
  (vconcat
   (cl-loop for (name limit) in portal-agents--columns
            for column from 0
            collect (list name
                          (min limit (apply #'max (string-width name)
                                            (mapcar (lambda (row)
                                                      (string-width (aref (cadr row) column)))
                                                    rows)))
                          t))))

(defun portal-agents--place (position)
  "Return where POSITION is, as (KEY COLUMN LINE), to find it after printing."
  (save-excursion
    (goto-char position)
    (list (tabulated-list-get-id) (current-column) (line-number-at-pos))))

(defun portal-agents--find (place)
  "Return the position of PLACE: its session's row, or else its line."
  (pcase-let ((`(,key ,column ,line) place))
    (save-excursion
      (goto-char (point-min))
      (while (and key (not (eobp)) (not (equal (tabulated-list-get-id) key)))
        (forward-line 1))
      (when (or (not key) (eobp))
        (goto-char (point-min))
        (forward-line (1- line))
        (setq column 0))
      (move-to-column column)
      (point))))

(defun portal-agents--print (rows)
  "Print ROWS in the current buffer, sorted as chosen.
Point and every window showing the buffer stay on their session's row,
which stays on the same screen line, or else on the same line."
  (let ((place (portal-agents--place (point)))
        (windows (mapcar (lambda (window)
                           (let ((place (portal-agents--place (window-point window))))
                             (list window place
                                   (- (nth 2 place) (line-number-at-pos (window-start window))))))
                         (get-buffer-window-list nil nil t))))
    (setq tabulated-list-entries (copy-sequence rows)
          tabulated-list-format (portal-agents--format rows))
    ;; `tabulated-list-sort' with -1 restores the first order, tracking order.
    (when tabulated-list--original-order
      (clrhash tabulated-list--original-order)
      (cl-loop for row in rows for index from 0
               do (puthash row index tabulated-list--original-order)))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (goto-char (portal-agents--find place))
    (pcase-dolist (`(,window ,place ,lines) windows)
      (let ((position (portal-agents--find place)))
        (set-window-point window position)
        (set-window-start window (save-excursion (goto-char position)
                                                 (forward-line (- lines))
                                                 (point))
                          t)))))

(defun portal-agents--refresh (&optional force)
  "Show the tracked sessions' facts in the current buffer, if they changed.
With FORCE, print them even if they did not.  This reads only cached
facts: it never selects a window, focuses a view or prompts."
  (let ((facts (portal-agents--facts)))
    (when (or force (not (equal facts portal-agents--facts)))
      (setq portal-agents--facts facts)
      (portal-agents--print (portal-agents--rows facts)))))

(defun portal-agents--revert (&rest _)
  "Refresh the dashboard now, as \\`g' does."
  (portal-agents--refresh t))

(defun portal-agents--shown-p ()
  "Return non-nil if a window on a visible frame shows the dashboard."
  (and (buffer-live-p portal-agents--buffer)
       (get-buffer-window portal-agents--buffer 'visible)
       t))

(defun portal-agents--schedule ()
  "Start the live update timer if the dashboard needs it, or else stop it.
It needs it while it is shown and `portal-agents-live-update' is on."
  (if (and portal-agents-live-update (portal-agents--shown-p))
      (unless portal-agents--timer
        (setq portal-agents--timer (run-at-time portal-agents-live-update-interval
                                                portal-agents-live-update-interval
                                                #'portal-agents--tick)))
    (when portal-agents--timer
      (cancel-timer portal-agents--timer)
      (setq portal-agents--timer nil))))

(defun portal-agents--tick ()
  "Refresh the shown dashboard, or stop the timer if it is no longer needed.
Live updates also stop for a frame made invisible, which no window hook reports."
  (portal-agents--schedule)
  (when portal-agents--timer
    (with-current-buffer portal-agents--buffer (portal-agents--refresh))))

(defun portal-agents--window-changed (&optional _frame)
  "Refresh the dashboard when it is shown again, and start or stop its timer.
Window state change hooks call this with the frame that changed."
  (let ((shown (portal-agents--shown-p)))
    (when (and shown (not portal-agents--shown))
      (with-current-buffer portal-agents--buffer (portal-agents--refresh)))
    (setq portal-agents--shown shown)
    (portal-agents--schedule)))

(defun portal-agents--changed ()
  "Refresh the dashboard after tracking changed, if it is shown.
A hidden one refreshes when it is shown again."
  (when (portal-agents--shown-p)
    (with-current-buffer portal-agents--buffer (portal-agents--refresh))))

(defun portal-agents--teardown ()
  "Stop updating the dashboard, which is being killed or changing mode."
  (when (eq (current-buffer) portal-agents--buffer)
    (setq portal-agents--buffer nil
          portal-agents--shown nil)
    (remove-hook 'window-state-change-functions #'portal-agents--window-changed)
    (portal-agents--schedule)))

(defun portal-agents--at-point ()
  "Return the terminal buffer on this line of the dashboard, or nil."
  (and (derived-mode-p 'portal-agents-mode) (car (tabulated-list-get-id))))

(defun portal-agents--read (prompt predicate)
  "Read the name of a terminal buffer for which PREDICATE holds, with PROMPT.
The default is the terminal on this line of the dashboard, or this one."
  (let ((default (or (portal-agents--at-point) (current-buffer))))
    (read-buffer prompt (and (funcall predicate default) default) t
                 (lambda (entry)
                   (let ((buffer (if (consp entry) (cdr entry) (get-buffer entry))))
                     (and buffer (funcall predicate buffer)))))))

;;;###autoload
(defun portal-agents-track (buffer &optional label)
  "Show terminal BUFFER's session in the agent dashboard, `portal-agents'.
BUFFER is a buffer or its name.  LABEL names the agent it runs; an empty
string removes the label, and nil keeps any the session has.  Interactively,
read a terminal's name, and with a prefix argument a label.  Quick and
hidden terminals can be tracked.  Tracking follows the session, whatever
its name, directory or title, until it is untracked or its terminal
closes or is replaced.  A program exiting does not end it."
  (interactive
   (list (portal-agents--read "Track terminal: " #'portal-terminal-metadata)
         (and current-prefix-arg (read-string "Agent label: "))))
  (let ((buffer (get-buffer buffer)))
    (unless (and buffer (portal-terminal-metadata buffer))
      (user-error "Not a terminal: %s" buffer))
    (let ((session (portal-agents--tracked-p buffer)))
      (unless session
        (setq session (list (cons buffer (buffer-local-value 'portal-view--target buffer)))
              portal-agents--tracked (append portal-agents--tracked (list session))))
      (when label
        (setcdr session (and (not (string-blank-p label)) (string-trim label)))))
    (portal-agents--changed)))

;;;###autoload
(defun portal-agents-untrack (buffer)
  "Remove terminal BUFFER from the agent dashboard; its program keeps running.
BUFFER is a buffer or its name.  Interactively, untrack the terminal on this
line of the dashboard, or else read a tracked terminal's name."
  (interactive (list (or (portal-agents--at-point)
                         (portal-agents--read "Untrack terminal: " #'portal-agents--tracked-p))))
  (let ((session (portal-agents--tracked-p (get-buffer buffer))))
    (unless session (user-error "Not a tracked terminal: %s" buffer))
    (setq portal-agents--tracked (delq session portal-agents--tracked))
    (portal-agents--changed)))

(defun portal-agents-visit ()
  "Visit the terminal on this line and give it the keyboard.
A quick terminal opens in its quick panel and any other in this window,
as `portal-terminal-select' shows them, in whichever frame showed it."
  (interactive)
  (let ((key (tabulated-list-get-id)))
    (unless key (user-error "No terminal on this line"))
    (unless (portal-agents--live-p key)
      (portal-agents--refresh)
      (user-error "That terminal has closed"))
    (portal-terminal--visit (car key))
    (with-current-buffer (car key) (portal-terminal-focus))))

(defun portal-agents-toggle-live-update (&optional arg)
  "Turn the dashboard's live updates on or off: `portal-agents-live-update'.
With prefix ARG, turn them on if ARG is positive, and off otherwise."
  (interactive "P")
  (setq portal-agents-live-update (if arg
                                      (> (prefix-numeric-value arg) 0)
                                    (not portal-agents-live-update)))
  (portal-agents--schedule)
  (force-mode-line-update t)
  (message "Agent dashboard live updates %s" (if portal-agents-live-update "on" "off")))

(defvar-keymap portal-agents-mode-map
  :doc "Keys in the agent dashboard."
  "RET" #'portal-agents-visit
  "t" #'portal-agents-track
  "u" #'portal-agents-untrack)

(define-derived-mode portal-agents-mode tabulated-list-mode "Agents"
  "The agent dashboard: the terminals tracked with `portal-agents-track'.
Each row shows a terminal's buffer, the agent label it was tracked with,
its assigned project, whether its program runs, its activity, its
directory and the title its program set.  A running program may be
working, idle or waiting: activity is unknown, as nothing reports it.
Titles are whatever a program set.

\\[portal-agents-visit] visits a terminal with the keyboard.
\\[portal-agents-track] tracks another terminal.
\\[portal-agents-untrack] untracks this one, which keeps running.
\\[revert-buffer] refreshes, and \\[tabulated-list-sort] sorts by the column at point.
While shown, the list refreshes itself; see `portal-agents-live-update'.

\\{portal-agents-mode-map}"
  (setq tabulated-list-format (portal-agents--format nil))
  (setq-local revert-buffer-function #'portal-agents--revert
              mode-line-process '(portal-agents-live-update ":live"))
  (tabulated-list-init-header)
  ;; This buffer is now the dashboard.
  (setq portal-agents--buffer (current-buffer)
        portal-agents--shown nil)
  (add-hook 'kill-buffer-hook #'portal-agents--teardown nil t)
  (add-hook 'change-major-mode-hook #'portal-agents--teardown nil t)
  (add-hook 'window-state-change-functions #'portal-agents--window-changed))

;;;###autoload
(defun portal-agents ()
  "Show the agent dashboard: the terminals tracked with `portal-agents-track'.
There is one dashboard.  It is an ordinary text buffer, with no native view.
See `portal-agents-mode'."
  (interactive)
  (unless (buffer-live-p portal-agents--buffer)
    (with-current-buffer (get-buffer-create "*Portal Agents*")
      (portal-agents-mode)))
  (with-current-buffer portal-agents--buffer (portal-agents--refresh))
  (pop-to-buffer-same-window portal-agents--buffer))

(provide 'portal-agents)
;;; portal-agents.el ends here
