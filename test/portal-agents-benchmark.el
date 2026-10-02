;;; portal-agents-benchmark.el --- What the agent dashboard costs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Measures the dashboard over the fake native module, with 10, 50 and 100
;; tracked terminals spread over 10 projects.  In batch Emacs, time and
;; allocation per refresh, with nothing changed and after every terminal
;; reported a new title:
;;
;;   emacs --batch -Q -L . -l test/portal-agents-benchmark.el \
;;     -f portal-agents-benchmark-refresh
;;
;; In graphical Emacs, the time each live update takes in the event loop,
;; the redisplay that shows a change, and garbage collection, with live
;; updates on and off.  A key typed meanwhile waits that long:
;;
;;   emacs -Q -L . -l test/portal-agents-benchmark.el \
;;     -f portal-agents-benchmark-latency
;;
;; Each prints a table and exits.

(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-agents)

(setq portal-terminal-confirm-kill nil)

(defvar portal-agents-benchmark--directory nil "The projects' temporary directory.")
(defvar portal-agents-benchmark--generation 0 "Makes each burst's titles new.")

(defun portal-agents-benchmark--start (count &optional untracked)
  "Start COUNT tracked terminals and UNTRACKED others; show the dashboard."
  (setq portal-agents-benchmark--directory
        (file-truename (make-temp-file "portal-agents-benchmark-" t)))
  (dotimes (project 10)
    (make-directory (expand-file-name (format "project-%d/.git" project)
                                      portal-agents-benchmark--directory)
                    t))
  (dotimes (index (+ count (or untracked 0)))
    (let ((default-directory (expand-file-name (format "project-%d/" (% index 10))
                                               portal-agents-benchmark--directory)))
      (portal-terminal-new)
      (when (< index count) (portal-agents-track (current-buffer)))))
  (delete-other-windows)
  (portal-agents)
  (portal-agents--window-changed))

(defun portal-agents-benchmark--stop ()
  "End the dashboard, every terminal and the projects."
  (kill-buffer portal-agents--buffer)
  (portal-terminal-close-all)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'portal-terminal-mode) (kill-buffer buffer))))
  (setq portal-agents--tracked nil)
  (delete-directory portal-agents-benchmark--directory t))

(defun portal-agents-benchmark--burst ()
  "Have every terminal report a new title, as the native module would."
  (cl-incf portal-agents-benchmark--generation)
  (dolist (buffer (portal-terminal-buffers))
    (portal-fake-native-report (buffer-local-value 'portal-view--target buffer)
                               :title (format "agent step %d" portal-agents-benchmark--generation))))

(defun portal-agents-benchmark--bytes (before after)
  "Return the approximate bytes allocated between memory counts BEFORE and AFTER.
Counts are `memory-use-counts': conses, floats, vector cells, symbols,
string bytes, intervals and strings, weighted by their 64-bit sizes."
  (cl-loop for size in '(16 16 8 48 1 56 32)
           for old in before for new in after
           sum (* size (- new old))))

(defun portal-agents-benchmark--measure (runs function &optional prepare)
  "Call FUNCTION RUNS times, after calling PREPARE each time, untimed.
Return FUNCTION's mean milliseconds and bytes per call, and the garbage
collections and their milliseconds over all calls."
  (garbage-collect)
  (let ((elapsed 0.0) (bytes 0) (gcs gcs-done) (gc-time gc-elapsed))
    (dotimes (_ runs)
      (when prepare (funcall prepare))
      (let ((counts (memory-use-counts))
            (start (float-time)))
        (funcall function)
        (cl-incf elapsed (- (float-time) start))
        (cl-incf bytes (portal-agents-benchmark--bytes counts (memory-use-counts)))))
    (list (* 1000 (/ elapsed runs)) (/ bytes runs) (- gcs-done gcs)
          (* 1000 (- gc-elapsed gc-time)))))

(defun portal-agents-benchmark--prints (function)
  "Call FUNCTION and return how many times it printed the dashboard."
  (let ((prints 0))
    (let ((count (lambda (&rest _) (cl-incf prints))))
      (advice-add 'tabulated-list-print :before count)
      (unwind-protect (funcall function)
        (advice-remove 'tabulated-list-print count)))
    prints))

(defun portal-agents-benchmark-refresh ()
  "Print what refreshing the dashboard costs, then exit."
  (let ((runs 200) lines)
    (dolist (sizes '((10 0) (50 0) (100 0) (100 100)))
      (pcase-let ((`(,count ,untracked) sizes))
        (portal-agents-benchmark--start count untracked)
        (with-current-buffer portal-agents--buffer
          (let* ((buffers (mapcar #'caar portal-agents--tracked))
                 (metadata (portal-agents-benchmark--measure
                            runs (lambda () (mapcar #'portal-terminal-metadata buffers))))
                 (unchanged (portal-agents-benchmark--measure runs #'portal-agents--tick))
                 (changed (portal-agents-benchmark--measure
                           runs #'portal-agents--tick #'portal-agents-benchmark--burst))
                 (burst (portal-agents-benchmark--measure 20 #'portal-agents-benchmark--burst))
                 ;; A minute of live updates at the default interval.
                 (quiet (progn
                          (portal-agents--tick)
                          (portal-agents-benchmark--prints
                           (lambda () (dotimes (_ 30) (portal-agents--tick))))))
                 (busy (portal-agents-benchmark--prints
                        (lambda () (dotimes (_ 30)
                                     (portal-agents-benchmark--burst)
                                     (portal-agents--tick))))))
            (push (format "| %3d | %3d | %6.3f | %6.1f | %6.3f | %6.1f | %3d | %6.3f | %6.3f | %2d/30 | %2d/30 |"
                          count (+ count untracked)
                          (nth 0 unchanged) (/ (nth 1 unchanged) 1024.0)
                          (nth 0 changed) (/ (nth 1 changed) 1024.0)
                          (+ (nth 2 unchanged) (nth 2 changed))
                          (nth 0 metadata) (nth 0 burst) quiet busy)
                  lines)))
        (portal-agents-benchmark--stop)))
    (princ (concat
            (format "Emacs %s, %d refreshes each, gc-cons-threshold %d\n\n"
                    emacs-version runs gc-cons-threshold)
            "| Tracked | Views | Unchanged ms | Unchanged KB | Changed ms | Changed KB "
            "| GCs | Metadata ms | Burst ms | Prints, quiet minute | Prints, busy minute |\n"
            "|---|---|---|---|---|---|---|---|---|---|---|\n"
            (mapconcat #'identity (nreverse lines) "\n") "\n"))
    (kill-emacs 0)))

(defun portal-agents-benchmark--wait (seconds)
  "Run the event loop for SECONDS, with timers and redisplay.
Unlike `sit-for', it waits while input is pending."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.05)
      (redisplay))))

(defun portal-agents-benchmark-latency ()
  "Print what live updates cost the graphical event loop, then exit.
For each size, mode and rate of change, run the event loop for 10 seconds
and time each dashboard tick, apart from garbage collection, and the
redisplay that shows a printed change.  A key typed meanwhile waits for
both, and for any collection."
  (let ((seconds 10) lines)
    (dolist (count '(10 50 100))
      (portal-agents-benchmark--start count)
      (dolist (live '(nil t))
        (dolist (busy '(nil t))
          (with-current-buffer portal-agents--buffer (portal-agents--refresh t))
          (redisplay t)
          (setq portal-agents-live-update live)
          (portal-agents--schedule)
          (let* ((ticks nil) (prints 0)
                 (count-print (lambda (&rest _) (cl-incf prints)))
                 (time-tick (lambda (tick)
                              (let ((before prints) (gc gc-elapsed) (start (float-time)))
                                (funcall tick)
                                (let ((middle (float-time)) (collecting (- gc-elapsed gc)))
                                  (when (> prints before) (redisplay t))
                                  (push (list (* 1000 (- middle start collecting))
                                              (* 1000 (- (float-time) middle))
                                              (* 1000 collecting))
                                        ticks)))))
                 ;; Every terminal changes its title twice a second.
                 (bursts (and busy (run-at-time 0.5 0.5 #'portal-agents-benchmark--burst)))
                 (gcs gcs-done) (gc-time gc-elapsed))
            (advice-add 'tabulated-list-print :before count-print)
            (advice-add 'portal-agents--tick :around time-tick)
            (unwind-protect (portal-agents-benchmark--wait seconds)
              (advice-remove 'portal-agents--tick time-tick)
              (advice-remove 'tabulated-list-print count-print)
              (when bursts (cancel-timer bursts)))
            (push (format "| %3d | %-6s | %-11s | %2d | %2d | %5.2f | %5.2f | %5.2f | %5.1f | %3d | %5.1f |"
                          count (if live "live" "manual") (if busy "every 0.5 s" "unchanged")
                          (length ticks) prints
                          (if ticks (/ (apply #'+ (mapcar #'car ticks)) (length ticks)) 0)
                          (apply #'max 0 (mapcar #'car ticks))
                          (apply #'max 0 (mapcar #'cadr ticks))
                          (apply #'+ 0 (mapcar #'caddr ticks))
                          (- gcs-done gcs) (* 1000 (- gc-elapsed gc-time)))
                  lines))))
      (setq portal-agents-live-update t)
      (portal-agents-benchmark--stop))
    (let ((report (concat
                   (format "Emacs %s, %s, %d s each, interval %s s, gc-cons-threshold %d\n\n"
                           emacs-version window-system seconds
                           portal-agents-live-update-interval gc-cons-threshold)
                   "| Tracked | Mode | Titles | Ticks | Prints | Tick mean ms | Tick max ms "
                   "| Redisplay max ms | GC in ticks ms | GCs | GC ms |\n"
                   "|---|---|---|---|---|---|---|---|---|---|---|\n"
                   (mapconcat #'identity (nreverse lines) "\n") "\n")))
      (with-temp-file (expand-file-name "portal-agents-latency.txt" temporary-file-directory)
        (insert report))
      (princ report #'external-debugging-output))
    (kill-emacs 0)))

(provide 'portal-agents-benchmark)
;;; portal-agents-benchmark.el ends here
