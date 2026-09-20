;;; portal.el --- Native web views and terminals for macOS -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'url-util)
(require 'browse-url)
(require 'portal-terminal
         (expand-file-name "portal-terminal"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-server
         (expand-file-name "portal-server"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(declare-function portal--load-url "portal" (url))
(declare-function portal--bind "portal" (title))
(declare-function portal--set-layout "portal" (layout))
(declare-function portal--destroy "portal" ())
(declare-function portal--native-views "portal" ())

;; One buffer's content, with a native presentation in each of its host panes.
(defvar portal--buffer nil "Buffer owning the shared native content.")
(defvar portal--frame nil "Frame hosting the native presentations.")
(defvar portal--panes nil "Alist mapping displayed Emacs windows to native IDs.")
(defvar portal--next-id 0 "Last allocated native pane ID in this session.")
(defvar portal--hosted-path nil "Request path for the active hosted view, or nil.")
(defvar portal--geometry nil
  "Last sent geometry: frame height paired with the native layout vector.
Nil means no layout has been sent yet.")

(define-derived-mode portal-mode special-mode "Portal"
  "Major mode for Portal native views."
  (setq-local cursor-type nil))

(keymap-set portal-mode-map "q" #'portal-hide)
(keymap-set portal-mode-map "g" #'portal-refresh)

;; Host binding and presentation geometry.
(defun portal--bind-frame (frame)
  "Identify FRAME to AppKit without depending on asynchronous focus changes."
  (portal-native--call-with-frame frame #'portal--bind))

(defun portal--update-layout ()
  "Reconcile all panes showing the buffer with their native presentations."
  (let* ((panes
          (mapcar (lambda (window)
                    (or (assq window portal--panes)
                        (cons window (setq portal--next-id
                                           (1+ portal--next-id)))))
                  (get-buffer-window-list portal--buffer nil portal--frame)))
         ;; Window enumeration can change order with focus; native IDs do not.
         (panes (sort panes (lambda (a b) (< (cdr a) (cdr b)))))
         (layout (vconcat
                  (apply #'append
                         (mapcar (lambda (pane)
                                   (cons (cdr pane)
                                         (window-inside-pixel-edges (car pane))))
                                 panes))))
         ;; An unflipped AppKit host also needs the frame's height.
         (geometry (cons (frame-pixel-height portal--frame) layout)))
    (unless (equal geometry portal--geometry)
      ;; Send the complete layout, including an empty one when hidden.
      (portal--set-layout layout)
      (setq portal--geometry geometry))
    (setq portal--panes panes)))

(defun portal--sync (frame)
  "Update native presentations after FRAME's window layout changes."
  (when (and portal--frame (eq frame portal--frame))
    (condition-case err
        (if (and (frame-live-p frame) (buffer-live-p portal--buffer))
            (portal--update-layout)
          (portal-hide))
      (error
       ;; A failing redisplay callback must not leave a stale overlay behind.
       (portal-hide)
       (signal (car err) (cdr err))))))

(defun portal--frame-deleted (frame)
  "Stop tracking when the host FRAME is deleted."
  (when (eq frame portal--frame)
    (portal-hide)))

;; Public lifecycle.  All hook registration is owned by these two commands.
;;;###autoload
(defun portal-show ()
  "Display Swift-drawn green rectangles in *portal-green*.
Each window showing the buffer in the current frame gets its own native view.
All views share the buffer's native content."
  (interactive)
  (portal--show))

;;;###autoload
(defun portal-open-url (url)
  "Open URL in a native WKWebView in *portal-web*.
Each pane gets an independent webview starting at URL.  Click the page to
interact; Escape or C-g returns keyboard focus to Emacs.  HTTP(S), file,
data and about URLs are supported.  This replaces the active Portal content."
  (interactive (list (read-string "Open URL: " "https://")))
  (unless (and (stringp url)
               (string-match-p "\\`\\(?:https?://[^/[:space:]]+\\|file:///\\|data:\\|about:\\)" url))
    (user-error "Enter an absolute http, https, file, data or about URL"))
  (portal--show url))

;;;###autoload
(defun portal-preview-html (file-or-url)
  "Open local HTML FILE-OR-URL or a URL in the embedded webview.
Use the current buffer's file when its extension is .html or .htm;
otherwise prompt for a path or URL.  With a prefix argument, always prompt.
Local paths are relative to `default-directory'.  Only saved contents are
shown; unsaved edits are not included.  Relative assets can load from the
file's containing directory.  URLs supported by `portal-open-url' are accepted."
  (interactive
   (list
    (if (and (not current-prefix-arg) buffer-file-name
             (let ((case-fold-search t))
               (string-match-p "\\.html?\\'" buffer-file-name)))
        buffer-file-name
      (read-string "Open HTML file or URL: "))))
  (unless (and (stringp file-or-url) (not (string-empty-p file-or-url)))
    (user-error "Enter a local HTML path or URL"))
  (if (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" file-or-url)
      (portal-open-url file-or-url)
    (let ((path (expand-file-name file-or-url)))
      (when (file-remote-p path)
        (user-error "Choose a local HTML file or an HTTP(S) URL"))
      (unless (and (file-regular-p path) (file-readable-p path))
        (user-error "Choose a readable regular file: %s" path))
      (portal-open-url (browse-url-file-url path)))))

;;;###autoload
(defun portal-hello ()
  "Open Hello World, starting the bundled UI host on first use."
  (interactive)
  (portal--open-hosted "/hello"))

;;;###autoload
(defun portal-preview-markdown (file)
  "Preview the saved contents of local Markdown FILE using the Bun host.
Use the current buffer's file when it has a Markdown mode or extension;
otherwise prompt for FILE.  With a prefix argument, always prompt.
Press g in the preview buffer to reread it from disk.  Unsaved edits are
not included."
  (interactive
   (list
    (if (and (not current-prefix-arg) buffer-file-name
             (or (derived-mode-p 'markdown-mode 'gfm-mode 'markdown-ts-mode)
                 (let ((case-fold-search t))
                   (string-match-p "\\.\\(?:md\\|markdown\\|mdown\\|mkd\\|mkdn\\)\\'"
                                   buffer-file-name))))
        buffer-file-name
      (read-file-name "Preview Markdown file: " nil buffer-file-name t))))
  (let ((path (expand-file-name file)))
    (when (file-remote-p path)
      (user-error "Choose a local Markdown file"))
    (unless (and (file-regular-p path) (file-readable-p path))
      (user-error "Choose a readable regular file: %s" path))
    (portal--open-hosted
     (concat "/markdown?path=" (url-hexify-string path)))))

;;;###autoload
(defun portal-refresh ()
  "Reload the active hosted page, starting its server again if needed."
  (interactive)
  (unless portal--hosted-path
    (user-error "No hosted Portal page to refresh"))
  (portal--ensure-host))

(defun portal--open-hosted (path)
  "Display hosted PATH, starting the shared server if necessary."
  (portal--show "about:blank")
  (setq portal--hosted-path path)
  (portal--ensure-host))

(defun portal--ensure-host ()
  "Start the host if necessary and load the current hosted page when ready."
  (condition-case err
      (progn
        (portal-start-server)
        (when (portal-server-url) (portal--host-ready)))
    (error
     (portal--host-stopped)
     (signal (car err) (cdr err)))))

(defun portal--host-ready ()
  "Navigate the current hosted view when the server becomes ready."
  (when (and portal--hosted-path (buffer-live-p portal--buffer)
             (frame-live-p portal--frame) (portal-server-url))
    (portal--load-url (concat (portal-server-url) portal--hosted-path))))

(defun portal--host-stopped ()
  "Show a retry message if the currently displayed UI loses its host."
  (when (and portal--hosted-path (buffer-live-p portal--buffer)
             (frame-live-p portal--frame))
    (portal--load-url
     (concat "data:text/html;charset=utf-8,"
             "<title>Portal server stopped</title><h1>UI server stopped</h1>"
             "<p>Press g or run M-x portal-refresh to retry. See *portal-server* for details.</p>"))))

(add-hook 'portal-server-ready-hook #'portal--host-ready)
(add-hook 'portal-server-stopped-hook #'portal--host-stopped)

(defun portal--show (&optional url)
  "Display native content, loading URL when non-nil."
  (portal-native--load)
  (portal-hide)
  (let (ready)
    (unwind-protect
        (progn
          (switch-to-buffer (get-buffer-create (if url "*portal-web*" "*portal-green*")))
          (unless (derived-mode-p 'portal-mode)
            (portal-mode))
          (redisplay t)
          (setq portal--buffer (current-buffer)
                portal--frame (selected-frame))
          (portal--bind-frame portal--frame)
          (when url (portal--load-url url))
          ;; Attach before registering redisplay callbacks, so errors reach
          ;; the caller instead of being swallowed by redisplay's safe_call.
          (portal--sync portal--frame)
          (add-hook 'kill-buffer-hook #'portal-hide nil t)
          (add-hook 'change-major-mode-hook #'portal-hide nil t)
          (add-hook 'window-state-change-functions #'portal--sync)
          (add-hook 'delete-frame-functions #'portal--frame-deleted)
          (setq ready t)
          (message (if url
                       "Webview opened. Escape/C-g returns to Emacs; q hides the view."
                     "Swift native views attached. Press q or M-x portal-hide to remove them.")))
      (unless ready (portal-hide)))))

;;;###autoload
(defun portal-hide ()
  "Release web/demo views and content; terminal sessions are unaffected."
  (interactive)
  (remove-hook 'window-state-change-functions #'portal--sync)
  (remove-hook 'delete-frame-functions #'portal--frame-deleted)
  (when (buffer-live-p portal--buffer)
    (with-current-buffer portal--buffer
      (remove-hook 'kill-buffer-hook #'portal-hide t)
      (remove-hook 'change-major-mode-hook #'portal-hide t)))
  (setq portal--hosted-path nil
        portal--buffer nil
        portal--frame nil
        portal--panes nil
        portal--next-id 0
        portal--geometry nil)
  (when (fboundp 'portal--destroy)
    (portal--destroy)))

(provide 'portal)
;;; portal.el ends here
