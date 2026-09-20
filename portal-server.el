;;; portal-server.el --- Shared Bun UI host -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'json)
(require 'subr-x)

(defgroup portal nil "Native views and hosted UIs in Emacs." :group 'applications)

(defcustom portal-server-program
  (expand-file-name "build/portal-host"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Standalone UI host executable, including its Bun runtime."
  :type 'file)

(defcustom portal-server-start-timeout 5
  "Seconds to wait asynchronously for the UI host to become ready."
  :type 'number)

(defvar portal-server-ready-hook nil
  "Hook run when the shared UI host is ready, including after a restart.")
(defvar portal-server-stopped-hook nil
  "Hook run when the shared UI host stops or fails to start.")
(defvar portal--server-process nil "The shared UI host process, if started.")

(defun portal-server-url ()
  "Return the ready UI host's base URL, including its access token, or nil."
  (when (and portal--server-process
             (process-live-p portal--server-process))
    (process-get portal--server-process 'url)))

(defun portal--server-cancel-timer (process property)
  "Cancel PROCESS's timer stored in PROPERTY."
  (when-let* ((timer (process-get process property)))
    (cancel-timer timer)
    (process-put process property nil)))

(defun portal--server-report (text)
  "Record TEXT in the host log and report it in the echo area."
  (with-current-buffer (get-buffer-create "*portal-server*")
    (goto-char (point-max))
    (insert "\n" text "\n"))
  (message "%s (see *portal-server*)" text))

(defun portal--server-fail (process reason)
  "Terminate PROCESS after a startup failure with REASON."
  (process-put process 'failure reason)
  (when (process-live-p process) (delete-process process)))

(defun portal--server-filter (process output)
  "Read the readiness record from PROCESS's OUTPUT, allowing partial lines."
  (when (and (eq process portal--server-process)
             (not (process-get process 'url)))
    (let ((pending (concat (process-get process 'pending) output)))
      (process-put process 'pending pending)
      (condition-case err
          (cond
           ((> (length pending) 4096) (error "Oversized readiness message"))
           ((string-match "\n" pending)
            (let* ((record (json-parse-string (substring pending 0 (match-beginning 0))
                                              :object-type 'plist))
                   (port (plist-get record :port))
                   (token (plist-get record :token)))
              (unless (and (equal (plist-get record :type) "ready")
                           (equal (plist-get record :protocol) 2)
                           (integerp port) (< 0 port 65536)
                           (stringp token)
                           (string-match-p "\\`[[:xdigit:]]\\{32\\}\\'" token))
                (error "Invalid UI host readiness message"))
              (process-put process 'pending nil)
              (process-put process 'url (format "http://127.0.0.1:%d/%s" port token))
              (portal--server-cancel-timer process 'startup-timer))))
        (error (portal--server-fail process (error-message-string err))))
      (when (and (eq process portal--server-process)
                 (process-get process 'url))
        (message "Portal UI server ready")
        (run-hooks 'portal-server-ready-hook)))))

(defun portal--server-sentinel (process event)
  "Handle PROCESS exiting with EVENT, without restarting it automatically."
  (when (memq (process-status process) '(exit signal failed))
    (portal--server-cancel-timer process 'startup-timer)
    (portal--server-cancel-timer process 'stop-timer)
    (when (eq process portal--server-process)
      (setq portal--server-process nil)
      (portal--server-report
       (format "Portal UI server stopped: %s"
               (or (process-get process 'failure) (string-trim event))))
      (run-hooks 'portal-server-stopped-hook))))

;;;###autoload
(defun portal-start-server ()
  "Start the shared UI host asynchronously, or reuse the running process.
The ready hook runs after the server has bound its HTTP listener."
  (interactive)
  (unless (and portal--server-process (process-live-p portal--server-process))
    (let* ((program (expand-file-name portal-server-program))
           (default-directory (file-name-directory program)))
      (unless (file-executable-p program)
        (user-error "Build the Portal UI host with ./build.sh: %s" program))
      (setq portal--server-process
            (make-process :name "portal-server" :command (list program)
                          :connection-type 'pipe :coding 'utf-8-unix :noquery t
                          :stderr (get-buffer-create "*portal-server*")
                          :filter #'portal--server-filter
                          :sentinel #'portal--server-sentinel))
      (let ((process portal--server-process))
        (process-put process 'startup-timer
                     (run-at-time portal-server-start-timeout nil
                                  (lambda ()
                                    (when (and (eq process portal--server-process)
                                               (not (process-get process 'url)))
                                      (portal--server-fail process "Startup timed out"))))))
      (message "Starting Portal UI server…")))
  portal--server-process)

;;;###autoload
(defun portal-stop-server ()
  "Stop the UI host, giving it a bounded interval to shut down gracefully."
  (interactive)
  (when-let* ((process portal--server-process))
    ;; Detach first: a late sentinel from this process must not reset a new host.
    (setq portal--server-process nil)
    (portal--server-cancel-timer process 'startup-timer)
    (when (process-live-p process)
      (process-put process 'stop-timer
                   (run-at-time 1.5 nil
                                (lambda ()
                                  (when (process-live-p process)
                                    (delete-process process)))))
      (process-send-eof process))
    (run-hooks 'portal-server-stopped-hook)))

;;;###autoload
(defun portal-restart-server ()
  "Restart the shared UI host and notify hosted views when it is ready."
  (interactive)
  (portal-stop-server)
  (portal-start-server))

(defun portal--server-exit ()
  "Stop the host on Emacs exit without waiting for its event loop."
  (when (and portal--server-process (process-live-p portal--server-process))
    (process-send-eof portal--server-process)))

(add-hook 'kill-emacs-hook #'portal--server-exit)

(provide 'portal-server)
;;; portal-server.el ends here
