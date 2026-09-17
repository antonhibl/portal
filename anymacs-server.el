;;; anymacs-server.el --- Shared Bun UI host -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'json)
(require 'subr-x)

(defgroup anymacs nil "Native views and hosted UIs in Emacs." :group 'applications)

(defcustom anymacs-server-program
  (expand-file-name "build/anymacs-host"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Standalone UI host executable, including its Bun runtime."
  :type 'file)

(defcustom anymacs-server-start-timeout 5
  "Seconds to wait asynchronously for the UI host to become ready."
  :type 'number)

(defvar anymacs-server-ready-hook nil
  "Hook run when the shared UI host is ready, including after a restart.")
(defvar anymacs-server-stopped-hook nil
  "Hook run when the shared UI host stops or fails to start.")
(defvar anymacs--server-process nil "The shared UI host process, if started.")

(defun anymacs-server-url ()
  "Return the ready UI host's base URL, or nil."
  (when (and anymacs--server-process
             (process-live-p anymacs--server-process))
    (process-get anymacs--server-process 'url)))

(defun anymacs--server-cancel-timer (process property)
  "Cancel PROCESS's timer stored in PROPERTY."
  (when-let* ((timer (process-get process property)))
    (cancel-timer timer)
    (process-put process property nil)))

(defun anymacs--server-report (text)
  "Record TEXT in the host log and report it in the echo area."
  (with-current-buffer (get-buffer-create "*anymacs-server*")
    (goto-char (point-max))
    (insert "\n" text "\n"))
  (message "%s (see *anymacs-server*)" text))

(defun anymacs--server-fail (process reason)
  "Terminate PROCESS after a startup failure with REASON."
  (process-put process 'failure reason)
  (when (process-live-p process) (delete-process process)))

(defun anymacs--server-filter (process output)
  "Read the readiness record from PROCESS's OUTPUT, allowing partial lines."
  (when (and (eq process anymacs--server-process)
             (not (process-get process 'url)))
    (let ((pending (concat (process-get process 'pending) output)))
      (process-put process 'pending pending)
      (condition-case err
          (cond
           ((> (length pending) 4096) (error "Oversized readiness message"))
           ((string-match "\n" pending)
            (let* ((record (json-parse-string (substring pending 0 (match-beginning 0))
                                              :object-type 'plist))
                   (port (plist-get record :port)))
              (unless (and (equal (plist-get record :type) "ready")
                           (equal (plist-get record :protocol) 1)
                           (integerp port) (< 0 port 65536))
                (error "Invalid UI host readiness message"))
              (process-put process 'pending nil)
              (process-put process 'url (format "http://127.0.0.1:%d" port))
              (anymacs--server-cancel-timer process 'startup-timer))))
        (error (anymacs--server-fail process (error-message-string err))))
      (when (and (eq process anymacs--server-process)
                 (process-get process 'url))
        (message "Anymacs UI server ready")
        (run-hooks 'anymacs-server-ready-hook)))))

(defun anymacs--server-sentinel (process event)
  "Handle PROCESS exiting with EVENT, without restarting it automatically."
  (when (memq (process-status process) '(exit signal failed))
    (anymacs--server-cancel-timer process 'startup-timer)
    (anymacs--server-cancel-timer process 'stop-timer)
    (when (eq process anymacs--server-process)
      (setq anymacs--server-process nil)
      (anymacs--server-report
       (format "Anymacs UI server stopped: %s"
               (or (process-get process 'failure) (string-trim event))))
      (run-hooks 'anymacs-server-stopped-hook))))

;;;###autoload
(defun anymacs-start-server ()
  "Start the shared UI host asynchronously, or reuse the running process.
The ready hook runs after the server has bound its HTTP listener."
  (interactive)
  (unless (and anymacs--server-process (process-live-p anymacs--server-process))
    (let* ((program (expand-file-name anymacs-server-program))
           (default-directory (file-name-directory program)))
      (unless (file-executable-p program)
        (user-error "Build the Anymacs UI host with ./build.sh: %s" program))
      (setq anymacs--server-process
            (make-process :name "anymacs-server" :command (list program)
                          :connection-type 'pipe :coding 'utf-8-unix :noquery t
                          :stderr (get-buffer-create "*anymacs-server*")
                          :filter #'anymacs--server-filter
                          :sentinel #'anymacs--server-sentinel))
      (let ((process anymacs--server-process))
        (process-put process 'startup-timer
                     (run-at-time anymacs-server-start-timeout nil
                                  (lambda ()
                                    (when (and (eq process anymacs--server-process)
                                               (not (process-get process 'url)))
                                      (anymacs--server-fail process "Startup timed out"))))))
      (message "Starting Anymacs UI server…")))
  anymacs--server-process)

;;;###autoload
(defun anymacs-stop-server ()
  "Stop the UI host, giving it a bounded interval to shut down gracefully."
  (interactive)
  (when-let* ((process anymacs--server-process))
    ;; Detach first: a late sentinel from this process must not reset a new host.
    (setq anymacs--server-process nil)
    (anymacs--server-cancel-timer process 'startup-timer)
    (when (process-live-p process)
      (process-put process 'stop-timer
                   (run-at-time 1.5 nil
                                (lambda ()
                                  (when (process-live-p process)
                                    (delete-process process)))))
      (process-send-eof process))
    (run-hooks 'anymacs-server-stopped-hook)))

;;;###autoload
(defun anymacs-restart-server ()
  "Restart the shared UI host and notify hosted views when it is ready."
  (interactive)
  (anymacs-stop-server)
  (anymacs-start-server))

(defun anymacs--server-exit ()
  "Stop the host on Emacs exit without waiting for its event loop."
  (when (and anymacs--server-process (process-live-p anymacs--server-process))
    (process-send-eof anymacs--server-process)))

(add-hook 'kill-emacs-hook #'anymacs--server-exit)

(provide 'anymacs-server)
;;; anymacs-server.el ends here
