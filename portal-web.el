;;; portal-web.el --- Web views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A web buffer presents one web view, which follows the buffer as
;; `portal-view.el' describes.  Pages and previews each get their own buffer.
;; Hosted apps open at once, at about:blank, and load once the app host is
;; ready.  After that they keep their page while the app host stops or restarts.

(require 'browse-url)
(require 'seq)
(require 'url-parse)
(require 'url-util)
(require 'portal-view)
(require 'portal-input)
(require 'portal-server)

(declare-function portal--web-load "portal-web" (target url))

(defvar-local portal-web--target nil "This buffer's web view target, or nil.")
(defvar-local portal-web--url nil
  "The URL this buffer's web view loaded last.
It is nil while a hosted app waits for the app host.")
(defvar-local portal-web--preview nil "The URL this buffer previews, in a `portal-preview-html' buffer.")
(defvar-local portal-web--hosted-path nil "The app host path of this buffer's hosted app, or nil.")

(define-derived-mode portal-web-mode special-mode "Portal Web"
  "Major mode for a buffer presenting a web view.
RET or a click enters the page, and Command-Escape returns to Emacs.
g loads the page again.  q hides the view while the page keeps running,
and killing the buffer closes it."
  (setq-local cursor-type nil)
  (setq-local portal-input--map-function (lambda () portal-web-mode-map))
  (portal-input-mode 1))
(keymap-set portal-web-mode-map "g" #'portal-web-reload)

(defun portal-web--check-url (url)
  "Signal a user error unless URL is a URL a web view can load."
  (unless (and (stringp url)
               (string-match-p "\\`\\(?:https?://[^/[:space:]]+\\|file:///\\|data:\\|about:\\)" url))
    (user-error "Enter an absolute http, https, file, data or about URL")))

(defun portal-web-open (url toolbar)
  "Open a web view for the current buffer, load URL in it and return its target.
URL is an absolute http, https, file, data or about URL.  TOOLBAR is
\"navigation\" for back, forward, find, zoom and reload, \"contents\" for a
table of contents in place of back and forward, or \"none\".
Once URL starts loading, this turns on `portal-input-mode', keeping the
buffer's major mode.  If the view cannot open or load URL, it is closed."
  (portal-web--check-url url)
  (portal-web--open url (list :toolbar toolbar)))

(defun portal-web-open-hosted (path toolbar)
  "Open a hosted web view for the current buffer and return its target.
The view opens at once, at about:blank, and loads PATH from the app host,
such as \"/hello\", as soon as the host is ready.  This starts the host if
needed; if it cannot start, the view stays at about:blank and
`portal-web-reload' tries again.  TOOLBAR is as for `portal-web-open'.
The view keeps no cookies or storage between Emacs sessions, and a page
outside the app host opens in the default browser instead."
  (prog1 (portal-web--open "about:blank" (list :toolbar toolbar :hosted t))
    (setq portal-web--hosted-path path)
    (portal-web--load-hosted)))

(defun portal-web--open (url options)
  "Open a web view with OPTIONS for the current buffer, and load URL in it."
  (portal-input--connect)
  (let ((target (portal-view-open 'web options))
        ready)
    (unwind-protect
        (progn
          (portal--web-load target url)
          (setq ready t))
      (unless ready (portal-view-close)))
    (setq portal-web--target target
          portal-web--url url)
    (portal-input-mode 1)
    target))

(defun portal-web-reload ()
  "Load this buffer's page again.
A hosted app loads from the app host, which starts first if needed."
  (interactive)
  (unless portal-web--target (user-error "No web view in this buffer"))
  (if portal-web--hosted-path
      (portal-web--load-hosted)
    (portal--web-load portal-web--target portal-web--url)))

(defun portal-web--find (variable value)
  "Return the web buffer whose buffer-local VARIABLE is VALUE, or nil."
  (seq-find (lambda (buffer) (equal (buffer-local-value variable buffer) value))
            (portal-view-buffers 'web)))

(defun portal-web--page-name (url)
  "Name URL's page: its host, its file name, or the URL itself."
  (let ((parsed (url-generic-parse-url url)))
    (pcase (url-type parsed)
      ((or "http" "https") (url-host parsed))
      ;; Decode as `browse-url-file-url' encodes.
      ("file" (file-name-nondirectory
               (decode-coding-string (url-unhex-string (url-filename parsed))
                                     (or file-name-coding-system
                                         default-file-name-coding-system))))
      ("data" "data")
      (_ url))))

(defun portal-web--visit (buffer name open)
  "Select web BUFFER and reload it, or, when BUFFER is nil, open a new one.
The new buffer is called *portal: NAME*, and OPEN opens its view.  If the
view cannot open, the new buffer is killed."
  (if buffer
      (progn (switch-to-buffer buffer) (portal-web-reload))
    (let ((buffer (generate-new-buffer (format "*portal: %s*" name))))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (portal-web-mode)
            (let ((inhibit-read-only t))
              (insert "Web view\n\n"
                      "RET or a click enters the page. Command-Escape returns to Emacs.\n"
                      "g loads the page again. q hides it; killing the buffer closes it.\n"
                      "This buffer has one live view, which follows its selected pane.\n"))
            (redisplay t)
            (funcall open)
            (message "Web view opened. RET enters; Command-Escape returns to Emacs; q hides the view."))
        (unless (and (buffer-live-p buffer) (buffer-local-value 'portal-web--target buffer))
          (kill-buffer buffer))))))

;;;###autoload
(defun portal-open-url (url)
  "Open URL in a web view, in a new buffer named after its page.
Click the page or press RET to interact; the Portal prefix or
Command-Escape returns control to Emacs.  HTTP(S), file, data and about
URLs are supported."
  (interactive (list (read-string "Open URL: " "https://")))
  (portal-web--check-url url)
  (portal-web--visit nil (portal-web--page-name url)
                     (lambda () (portal-web-open url "navigation"))))

;;;###autoload
(defun portal-preview-html (file-or-url)
  "Preview local HTML FILE-OR-URL, or a URL, in a web view.
Use the current buffer's file when its extension is .html or .htm;
otherwise prompt for a path or URL.  With a prefix argument, always prompt.
Local paths are relative to `default-directory'.  Only saved contents are
shown; unsaved edits are not included.  Relative assets can load from the
file's containing directory.  URLs supported by `portal-open-url' are accepted.
Previewing the same file or URL again reuses its buffer and reloads it."
  (interactive
   (list
    (if (and (not current-prefix-arg) buffer-file-name
             (let ((case-fold-search t))
               (string-match-p "\\.html?\\'" buffer-file-name)))
        buffer-file-name
      (read-string "Open HTML file or URL: "))))
  (unless (and (stringp file-or-url) (not (string-empty-p file-or-url)))
    (user-error "Enter a local HTML path or URL"))
  (let ((url (if (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" file-or-url)
                 file-or-url
               (let ((path (expand-file-name file-or-url)))
                 (when (file-remote-p path)
                   (user-error "Choose a local HTML file or an HTTP(S) URL"))
                 (unless (and (file-regular-p path) (file-readable-p path))
                   (user-error "Choose a readable regular file: %s" path))
                 (browse-url-file-url path)))))
    (portal-web--check-url url)
    (portal-web--visit (portal-web--find 'portal-web--preview url)
                       (portal-web--page-name url)
                       (lambda () (portal-web-open url "contents")))
    (setq portal-web--preview url)))

;;;###autoload
(defun portal-hello ()
  "Open Hello World, starting the bundled app host on first use."
  (interactive)
  (portal-web--visit-hosted "/hello" "hello" "navigation"))

;;;###autoload
(defun portal-preview-markdown (file)
  "Preview the saved contents of local Markdown FILE using the app host.
Use the current buffer's file when it has a Markdown mode or extension;
otherwise prompt for FILE.  With a prefix argument, always prompt.
Previewing the same file again reuses its buffer.  Press g in the preview
buffer to reread the file from disk.  Unsaved edits are not included."
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
    (portal-web--visit-hosted (concat "/markdown?path=" (url-hexify-string path))
                              (file-name-nondirectory path) "contents")))

;; Hosted apps.
(defun portal-web--visit-hosted (path name toolbar)
  "Show the buffer for hosted app PATH, opening one called *portal: NAME*.
A new buffer's view has TOOLBAR."
  (portal-web--visit (portal-web--find 'portal-web--hosted-path path) name
                     (lambda () (portal-web-open-hosted path toolbar))))

(defun portal-web--load-hosted ()
  "Load this buffer's hosted app from the app host, starting the host if needed.
The view keeps its page until the host is ready."
  (setq portal-web--url nil)
  (portal-start-server)
  (when (portal-server-url) (portal-web--host-ready)))

(defun portal-web--host-ready ()
  "Load each hosted app that waits for the app host, which is now ready.
Hosted apps that have already loaded keep their page."
  (dolist (buffer (portal-view-buffers 'web))
    (with-current-buffer buffer
      (when (and portal-web--hosted-path (not portal-web--url))
        (setq portal-web--url (concat (portal-server-url) portal-web--hosted-path))
        (portal--web-load portal-web--target portal-web--url)))))

(add-hook 'portal-server-ready-hook #'portal-web--host-ready)

(provide 'portal-web)
;;; portal-web.el ends here
