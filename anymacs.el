;;; anymacs.el --- Native web views and terminals for macOS -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'url-util)
(require 'browse-url)
(require 'anymacs-terminal
         (expand-file-name "anymacs-terminal"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'anymacs-server
         (expand-file-name "anymacs-server"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(declare-function anymacs--load-url "anymacs" (url))
(declare-function anymacs--bind "anymacs" (title))
(declare-function anymacs--set-layout "anymacs" (layout))
(declare-function anymacs--destroy "anymacs" ())
(declare-function anymacs--native-views "anymacs" ())

;; One buffer's content, with a native presentation in each of its host panes.
(defvar anymacs--buffer nil "Buffer owning the shared native content.")
(defvar anymacs--frame nil "Frame hosting the native presentations.")
(defvar anymacs--panes nil "Alist mapping displayed Emacs windows to native IDs.")
(defvar anymacs--next-id 0 "Last allocated native pane ID in this session.")
(defvar anymacs--hosted-path nil "Request path for the active hosted view, or nil.")
(defvar anymacs--geometry nil
  "Last sent geometry: frame height paired with the native layout vector.
Nil means no layout has been sent yet.")

(define-derived-mode anymacs-mode special-mode "Anymacs"
  "Major mode for Anymacs native views."
  (setq-local cursor-type nil))

(keymap-set anymacs-mode-map "q" #'anymacs-hide)
(keymap-set anymacs-mode-map "g" #'anymacs-refresh)

;; Host binding and presentation geometry.
(defun anymacs--bind-frame (frame)
  "Identify FRAME to AppKit without depending on asynchronous focus changes."
  (anymacs-native--call-with-frame frame #'anymacs--bind))

(defun anymacs--update-layout ()
  "Reconcile all panes showing the buffer with their native presentations."
  (let* ((panes
          (mapcar (lambda (window)
                    (or (assq window anymacs--panes)
                        (cons window (setq anymacs--next-id
                                           (1+ anymacs--next-id)))))
                  (get-buffer-window-list anymacs--buffer nil anymacs--frame)))
         ;; Window enumeration can change order with focus; native IDs do not.
         (panes (sort panes (lambda (a b) (< (cdr a) (cdr b)))))
         (layout (vconcat
                  (apply #'append
                         (mapcar (lambda (pane)
                                   (cons (cdr pane)
                                         (window-inside-pixel-edges (car pane))))
                                 panes))))
         ;; An unflipped AppKit host also needs the frame's height.
         (geometry (cons (frame-pixel-height anymacs--frame) layout)))
    (unless (equal geometry anymacs--geometry)
      ;; Send the complete layout, including an empty one when hidden.
      (anymacs--set-layout layout)
      (setq anymacs--geometry geometry))
    (setq anymacs--panes panes)))

(defun anymacs--sync (frame)
  "Update native presentations after FRAME's window layout changes."
  (when (and anymacs--frame (eq frame anymacs--frame))
    (condition-case err
        (if (and (frame-live-p frame) (buffer-live-p anymacs--buffer))
            (anymacs--update-layout)
          (anymacs-hide))
      (error
       ;; A failing redisplay callback must not leave a stale overlay behind.
       (anymacs-hide)
       (signal (car err) (cdr err))))))

(defun anymacs--frame-deleted (frame)
  "Stop tracking when the host FRAME is deleted."
  (when (eq frame anymacs--frame)
    (anymacs-hide)))

;; Public lifecycle.  All hook registration is owned by these two commands.
;;;###autoload
(defun anymacs-show ()
  "Display Swift-drawn green rectangles in *anymacs-green*.
Each window showing the buffer in the current frame gets its own native view.
All views share the buffer's native content."
  (interactive)
  (anymacs--show))

;;;###autoload
(defun anymacs-open-url (url)
  "Open URL in a native WKWebView in *anymacs-web*.
Each pane gets an independent webview starting at URL.  Click the page to
interact; Escape or C-g returns keyboard focus to Emacs.  HTTP(S), file,
data and about URLs are supported.  This replaces the active Anymacs content."
  (interactive (list (read-string "Open URL: " "https://")))
  (unless (and (stringp url)
               (string-match-p "\\`\\(?:https?://[^/[:space:]]+\\|file:///\\|data:\\|about:\\)" url))
    (user-error "Enter an absolute http, https, file, data or about URL"))
  (anymacs--show url))

;;;###autoload
(defun anymacs-preview-html (file-or-url)
  "Open local HTML FILE-OR-URL or a URL in the embedded webview.
Use the current buffer's file when its extension is .html or .htm;
otherwise prompt for a path or URL.  With a prefix argument, always prompt.
Local paths are relative to `default-directory'.  Only saved contents are
shown; unsaved edits are not included.  Relative assets can load from the
file's containing directory.  URLs supported by `anymacs-open-url' are accepted."
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
      (anymacs-open-url file-or-url)
    (let ((path (expand-file-name file-or-url)))
      (when (file-remote-p path)
        (user-error "Choose a local HTML file or an HTTP(S) URL"))
      (unless (and (file-regular-p path) (file-readable-p path))
        (user-error "Choose a readable regular file: %s" path))
      (anymacs-open-url (browse-url-file-url path)))))

;;;###autoload
(defun anymacs-hello ()
  "Open Hello World, starting the bundled UI host on first use."
  (interactive)
  (anymacs--open-hosted "/hello"))

;;;###autoload
(defun anymacs-preview-markdown (file)
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
    (anymacs--open-hosted
     (concat "/markdown?path=" (url-hexify-string path)))))

;;;###autoload
(defun anymacs-refresh ()
  "Reload the active hosted page, starting its server again if needed."
  (interactive)
  (unless anymacs--hosted-path
    (user-error "No hosted Anymacs page to refresh"))
  (anymacs--ensure-host))

(defun anymacs--open-hosted (path)
  "Display hosted PATH, starting the shared server if necessary."
  (anymacs--show "about:blank")
  (setq anymacs--hosted-path path)
  (anymacs--ensure-host))

(defun anymacs--ensure-host ()
  "Start the host if necessary and load the current hosted page when ready."
  (condition-case err
      (progn
        (anymacs-start-server)
        (when (anymacs-server-url) (anymacs--host-ready)))
    (error
     (anymacs--host-stopped)
     (signal (car err) (cdr err)))))

(defun anymacs--host-ready ()
  "Navigate the current hosted view when the server becomes ready."
  (when (and anymacs--hosted-path (buffer-live-p anymacs--buffer)
             (frame-live-p anymacs--frame) (anymacs-server-url))
    (anymacs--load-url (concat (anymacs-server-url) anymacs--hosted-path))))

(defun anymacs--host-stopped ()
  "Show a retry message if the currently displayed UI loses its host."
  (when (and anymacs--hosted-path (buffer-live-p anymacs--buffer)
             (frame-live-p anymacs--frame))
    (anymacs--load-url
     (concat "data:text/html;charset=utf-8,"
             "<title>Anymacs server stopped</title><h1>UI server stopped</h1>"
             "<p>Press g or run M-x anymacs-refresh to retry. See *anymacs-server* for details.</p>"))))

(add-hook 'anymacs-server-ready-hook #'anymacs--host-ready)
(add-hook 'anymacs-server-stopped-hook #'anymacs--host-stopped)

(defun anymacs--show (&optional url)
  "Display native content, loading URL when non-nil."
  (anymacs-native--load)
  (anymacs-hide)
  (let (ready)
    (unwind-protect
        (progn
          (switch-to-buffer (get-buffer-create (if url "*anymacs-web*" "*anymacs-green*")))
          (unless (derived-mode-p 'anymacs-mode)
            (anymacs-mode))
          (redisplay t)
          (setq anymacs--buffer (current-buffer)
                anymacs--frame (selected-frame))
          (anymacs--bind-frame anymacs--frame)
          (when url (anymacs--load-url url))
          ;; Attach before registering redisplay callbacks, so errors reach
          ;; the caller instead of being swallowed by redisplay's safe_call.
          (anymacs--sync anymacs--frame)
          (add-hook 'kill-buffer-hook #'anymacs-hide nil t)
          (add-hook 'change-major-mode-hook #'anymacs-hide nil t)
          (add-hook 'window-state-change-functions #'anymacs--sync)
          (add-hook 'delete-frame-functions #'anymacs--frame-deleted)
          (setq ready t)
          (message (if url
                       "Webview opened. Escape/C-g returns to Emacs; q hides the view."
                     "Swift native views attached. Press q or M-x anymacs-hide to remove them.")))
      (unless ready (anymacs-hide)))))

;;;###autoload
(defun anymacs-hide ()
  "Release web/demo views and content; terminal sessions are unaffected."
  (interactive)
  (remove-hook 'window-state-change-functions #'anymacs--sync)
  (remove-hook 'delete-frame-functions #'anymacs--frame-deleted)
  (when (buffer-live-p anymacs--buffer)
    (with-current-buffer anymacs--buffer
      (remove-hook 'kill-buffer-hook #'anymacs-hide t)
      (remove-hook 'change-major-mode-hook #'anymacs-hide t)))
  (setq anymacs--hosted-path nil
        anymacs--buffer nil
        anymacs--frame nil
        anymacs--panes nil
        anymacs--next-id 0
        anymacs--geometry nil)
  (when (fboundp 'anymacs--destroy)
    (anymacs--destroy)))

(provide 'anymacs)
;;; anymacs.el ends here
