;;; portal-actions.el --- Hosted app actions in the Emacs command loop -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'portal-view)
(require 'portal-input)
(require 'portal-server)

(defvar-local portal-actions--properties nil)
(defvar-local portal-actions--handlers nil)

(defun portal-actions-enable (properties handlers)
  "Give this buffer hosted action PROPERTIES and explicit operation HANDLERS.
PROPERTIES is JSON metadata for the app host.  HANDLERS maps operation names
to functions taking a JSON arguments plist and returning a JSON result plist.
Handlers run in the command loop, with the originating view selected."
  (setq portal-actions--properties properties portal-actions--handlers handlers)
  (add-hook 'portal-view-close-hook #'portal-actions--close nil t))

(defun portal-actions-register ()
  "Register this live view with the ready app host; return its context handle.
Called before loading a hosted page, including after an app host restart."
  (when (and portal-actions--properties portal-view--target)
    (portal-server-send
     (list :type "context" :id portal-view--target :properties portal-actions--properties))
    portal-view--target))

(defun portal-actions--close ()
  "Forget this view's context, without starting a stopped app host."
  (when (and portal-actions--properties (portal-server-url))
    (portal-server-send (list :type "forget" :id portal-view--target))))

(defun portal-actions--receive (process request)
  "Queue REQUEST from PROCESS; never run UI commands in its process filter."
  (setq unread-command-events
        (nconc unread-command-events (list (list 'portal-action (list process request))))))

(defun portal-actions--dispatch (event)
  "Execute EVENT's operation once, only while its process and source are live."
  (interactive "e")
  (pcase-let* ((`(,process ,request) (cadr event))
               (id (plist-get request :id))
               (target (plist-get request :context)))
    (when (and (eq process portal--server-process) (process-live-p process))
      (let (result failure)
        (condition-case err
            (let ((buffer (portal-view--target-buffer target)))
              (unless (and (numberp (plist-get request :deadline))
                           (< (* 1000 (float-time)) (plist-get request :deadline)))
                (user-error "The action expired; try again"))
              (unless buffer (user-error "The originating Portal view has closed"))
              (with-current-buffer buffer
                (let ((handler (cdr (assoc (plist-get request :operation) portal-actions--handlers))))
                  (unless handler (user-error "This view does not support that action"))
                  (when-let* ((window (portal-input--window target)))
                    (select-window window))
                  (portal-input--action "unfocus" target)
                  (setq portal-input--resume nil)
                  (setq result (funcall handler (plist-get request :arguments))))))
          (error (setq failure (error-message-string err))))
        (portal-server-send
         (if failure (list :type "result" :id id :error failure)
           (list :type "result" :id id :value result)) process)))))

(define-key global-map [portal-action] #'portal-actions--dispatch)
(setq portal-server-request-function #'portal-actions--receive)

(provide 'portal-actions)
;;; portal-actions.el ends here
