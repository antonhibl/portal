;;; portal-web.el --- Web views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A web buffer presents one web view, which follows the buffer as
;; `portal-view.el' describes.  Pages and previews each get their own buffer.
;; Hosted apps open at once, at about:blank, and load once the app host is
;; ready.  After that they keep their page while the app host stops or restarts.
;; A hosted app and its buffer exchange JSON messages over the bridge.
;; A Markdown preview follows links to other Markdown files itself, and hands
;; links to other local files to Emacs, which visits them in another pane.
;; Its view reports the pages it shows, and those links, over the bridge.
;; Any page may ask its buffer for something: an alert, a confirmation or a
;; line of text, which Emacs reads in the minibuffer; a window it opens,
;; which gets a buffer of its own; or another address, from the toolbar.
;; Those requests wait outside the record pipe, as bridge messages do.

(require 'browse-url)
(require 'json)
(require 'seq)
(require 'url-parse)
(require 'url-util)
(require 'portal-view)
(require 'portal-input)
(require 'portal-server)

(declare-function portal--web-load "portal-web" (target url))
(declare-function portal--web-send "portal-web" (target json))
(declare-function portal--web-receive "portal-web" (target))
(declare-function portal--web-appearance "portal-web" (appearance))
(declare-function portal--web-requests "portal-web" (target))
(declare-function portal--web-answer "portal-web" (target id answer))
(declare-function portal--inspect "portal-view" (target))
(declare-function bookmark-prop-get "bookmark" (bookmark prop))

(defun portal-web--appearance-changed (_symbol value operation _where)
  "Check appearance VALUE and show every web view in it, on OPERATION `set'."
  (when (eq operation 'set)
    (unless (memq value '(nil light dark))
      (error "Web view appearance must be nil, `light' or `dark'"))
    (when (fboundp 'portal--web-appearance)
      (portal--web-appearance (and value (symbol-name value))))))

(defcustom portal-web-appearance nil
  "Whether web views, such as Markdown previews, look light or dark.
Nil follows the system's light or dark appearance as it changes, even when
Emacs frames force their own with the `ns-appearance' frame parameter.
`light' or `dark' keeps every web view so.  A page sees it as CSS's
prefers-color-scheme.  Changes with `setq', `setopt' or Customize, or with
`portal-web-set-appearance', apply to open web views without reloading."
  :type '(choice (const :tag "System appearance" nil)
                 (const :tag "Light" light)
                 (const :tag "Dark" dark))
  :group 'portal)
(add-variable-watcher 'portal-web-appearance #'portal-web--appearance-changed)

;;;###autoload
(defun portal-web-set-appearance (appearance)
  "Show every web view in APPEARANCE: `light', `dark', or nil for the system's.
This sets `portal-web-appearance'."
  (interactive
   (list (cdr (assoc (completing-read "Web view appearance: " '("system" "light" "dark") nil t)
                     '(("light" . light) ("dark" . dark))))))
  (setq portal-web-appearance appearance))

(defvar-local portal-web--target nil "This buffer's web view target, or nil.")
(defvar-local portal-web--url nil
  "The URL this buffer's web view loaded last.
It is nil while a hosted app waits for the app host.")
(defvar-local portal-web--preview nil "The URL this buffer previews, in a `portal-render-html' buffer.")
(defvar-local portal-web--hosted-path nil "The app host path of this buffer's hosted app, or nil.")
(defvar-local portal-web--markdown nil "The Markdown file this preview shows, or nil.")
(defvar-local portal-web--org nil "The Org file this preview shows, or nil.")
(defvar-local portal-web--popup nil
  "Non-nil in a buffer that shows a window a page opened.
Such a buffer closes when its page closes its window.")
(defvar-local portal-web--refresh-function nil
  "Function that `portal-web-reload' calls first, with no arguments, or nil.
An Org preview exports its file again before the view loads it.")
(defvar-local portal-web--follow-function nil
  "Function that takes a local file this hosted page links to, or nil.
It is called with the file and the link's fragment, or nil, in the
command loop, and returns non-nil if it showed the file itself, as an Org
preview does for other Org files.  Otherwise the file opens in Emacs.")
(defvar-local portal-web-bridge-function nil
  "Function called with each message this buffer's hosted app sends, in order.
Each message is a JSON object parsed into a plist.  The function runs with
the buffer current, inside a process filter, so it must never prompt; it
queues commands through `unread-command-events'.")

(define-derived-mode portal-web-mode special-mode "Portal Web"
  "Major mode for a buffer presenting a web view.
RET or a click enters the page; `portal-input-escape-key' returns to Emacs.
A chord the page does not use reaches Emacs, which runs it in this buffer.
g or Command-R loads the page again, l and r go back and forward, and
Command-F finds text in the page, whether Emacs or the page owns the
keyboard, unless the page uses those chords itself.  G or Command-L goes
to another address, and w copies the page's.  q hides the view while the
page keeps running, and killing the buffer closes it.  \\[bookmark-set]
bookmarks the page."
  (setq-local cursor-type nil)
  (setq-local bookmark-make-record-function #'portal-web-bookmark-make-record)
  (portal-input-mode 1))
(keymap-set portal-web-mode-map "g" #'portal-web-reload)
(keymap-set portal-web-mode-map "l" #'portal-web-back)
(keymap-set portal-web-mode-map "r" #'portal-web-forward)
(keymap-set portal-web-mode-map "s-f" #'portal-find)
(keymap-set portal-web-mode-map "s-r" #'portal-web-reload)
(keymap-set portal-web-mode-map "G" #'portal-web-goto)
(keymap-set portal-web-mode-map "s-l" #'portal-web-goto)
(keymap-set portal-web-mode-map "w" #'portal-web-copy-url)

(defun portal-web--check-url (url)
  "Signal a user error unless URL is a URL a web view can load."
  (unless (and (stringp url)
               (string-match-p "\\`\\(?:https?://[^/[:space:]]+\\|file:///\\|data:\\|about:\\)" url))
    (user-error "Enter an absolute http, https, file, data or about URL")))

(defun portal-web-open (url toolbar)
  "Open a web view for the current buffer, load URL in it and return its target.
URL is an absolute http, https, file, data or about URL.  TOOLBAR is
\"navigation\" for back, forward, find, zoom and reload, \"contents\" for
those and a table of contents, \"markdown\" for those, a table of contents
and, in a hosted app, Open in Emacs, or \"none\".
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
  "Open a web view with OPTIONS for the current buffer, and load URL in it.
The view starts in `portal-web-appearance'."
  (portal-input--connect)
  (let ((target (portal-view-open
                 'web (if portal-web-appearance
                          (append (list :appearance (symbol-name portal-web-appearance)) options)
                        options)))
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
  (when portal-web--refresh-function (funcall portal-web--refresh-function))
  (if portal-web--hosted-path
      (portal-web--load-hosted)
    (portal--web-load portal-web--target portal-web--url)))

(defun portal-web-back ()
  "Go back to the previous page in this web view's history."
  (interactive)
  (portal-toolbar--action "back"))

(defun portal-web-forward ()
  "Go forward to the next page in this web view's history."
  (interactive)
  (portal-toolbar--action "forward"))

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
                      "RET or a click enters the page. The configured escape returns to Emacs.\n"
                      "See M-x customize-option RET portal-input-escape-key for that key.\n"
                      "g loads the page again. q hides it; killing the buffer closes it.\n"
                      "This buffer has one live view, which follows its selected pane.\n"))
            (redisplay t)
            (funcall open)
            (message "Web view opened. RET enters; %s returns to Emacs; q hides the view."
                     portal-input-escape-key))
        (unless (and (buffer-live-p buffer) (buffer-local-value 'portal-web--target buffer))
          (kill-buffer buffer))))))

;;;###autoload
(defun portal-open-url (url)
  "Open URL in a web view, in a new buffer named after its page.
Click the page or press RET to interact; `portal-input-escape-key'
returns control to Emacs.  HTTP(S), file, data and about
URLs are supported."
  (interactive (list (read-string "Open URL: " "https://")))
  (portal-web--check-url url)
  (portal-web--visit nil (portal-web--page-name url)
                     (lambda () (portal-web-open url "navigation"))))

;;;###autoload
(defun portal-render-html (file-or-url)
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
(defun portal-about ()
  "Show Portal's versions and contact details, starting the app host if needed."
  (interactive)
  (portal-web--visit-hosted
   (format "/about?portal=%s&emacs=%s"
           (url-hexify-string (or (portal-build-version) "unknown"))
           (url-hexify-string emacs-version))
   "about" "none"))

;;;###autoload
(defun portal-render-markdown (file)
  "Preview the saved contents of local Markdown FILE using the app host.
Use the current buffer's file when it has a Markdown mode or extension;
otherwise prompt for FILE.  With a prefix argument, always prompt.
Previewing the same file again reuses its buffer.  Press g in the preview
buffer to reread the file from disk.  Unsaved edits are not included.
A link to another Markdown file opens it in the same preview, and l and r
go back and forward.  A link to any other local file opens it in another
pane, as does `portal-render-open-in-emacs' for the file on screen;
`portal-render-return' comes back."
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
    (portal-web--visit-hosted (portal-web--markdown-path path)
                              (file-name-nondirectory path) "markdown")
    (setq portal-web--markdown path)))

(defun portal-web--markdown-path (file)
  "Return the app host path that previews Markdown FILE."
  (concat "/markdown?path=" (url-hexify-string file)))

(defun portal-web--unhex (text)
  "Decode percent-encoded UTF-8 TEXT."
  (decode-coding-string (url-unhex-string text) 'utf-8))

(defun portal-web--queue (event &rest arguments)
  "Queue EVENT with ARGUMENTS as input, for its command to run in the command loop.
Visiting a file can prompt, which a process filter must never do."
  (setq unread-command-events (nconc unread-command-events (list (list event arguments)))))

(defun portal-web--page (url)
  "Note that this buffer's hosted app shows percent-encoded URL now.
A page of the same app becomes the app host path to load, so g reloads
the page on screen, even after the app host restarts with a new token.
A Markdown preview that shows another Markdown file takes that file's
identity, so previewing the file finds this buffer."
  (let* ((parsed (url-generic-parse-url url))
         (route (and (equal (url-type parsed) "http") (equal (url-host parsed) "127.0.0.1")
                     (string-match "\\`/[[:xdigit:]]+\\(/[^?#]*\\)\\([^#]*\\)" (url-filename parsed))
                     (list (match-string 1 (url-filename parsed))
                           (match-string 2 (url-filename parsed))))))
    (when (and route portal-web--hosted-path
               (equal (car route) (car (split-string portal-web--hosted-path "?"))))
      (setq portal-web--hosted-path (apply #'concat route)))
    (when (and portal-web--markdown
               (equal (url-type parsed) "http") (equal (url-host parsed) "127.0.0.1")
               (string-match "\\`/[[:xdigit:]]+/markdown\\?\\(?:[^#]*&\\)?path=\\([^&#]*\\)"
                             (url-filename parsed)))
      (let* ((file (portal-web--unhex (match-string 1 (url-filename parsed))))
             (name (format "*portal: %s*" (file-name-nondirectory file))))
        (setq portal-web--markdown file
              portal-web--hosted-path (portal-web--markdown-path file))
        (unless (string-prefix-p name (buffer-name))
          (rename-buffer name t))))
    (when (and portal-web--org
               (equal (url-type parsed) "http") (equal (url-host parsed) "127.0.0.1")
               (string-match "\\`/[[:xdigit:]]+/org\\?\\(?:[^#]*&\\)?source=\\([^&#]*\\)"
                             (url-filename parsed)))
      (let* ((file (portal-web--unhex (match-string 1 (url-filename parsed))))
             (name (format "*portal: %s*" (file-name-nondirectory file))))
        (setq portal-web--org file)
        (unless (string-prefix-p name (buffer-name))
          (rename-buffer name t))))))

(defun portal-web--display-elsewhere (buffer alist)
  "Display BUFFER in a window other than the selected one, reusing one if possible.
This is a `display-buffer' action function.  Rules in `display-buffer-alist'
come first, and ALIST keeps them free to use the selected window."
  (let ((alist (cons '(inhibit-same-window . t) alist)))
    (or (display-buffer-reuse-window buffer alist)
        (display-buffer-use-some-window buffer alist)
        (display-buffer-pop-up-window buffer alist))))

(defun portal-web--hand-off (file &optional line)
  "Visit FILE in a pane other than this hosted page's, at LINE if non-nil.
The page is a Markdown preview.  Select that pane with
Emacs owning the keyboard, and remember this page's buffer for
`portal-render-return' in both frames involved."
  (let ((preview (current-buffer))
        (origin (selected-window))
        (buffer (find-file-noselect file)))
    (portal-input--action "unfocus" portal-web--target)
    (setq portal-input--resume nil)
    (pop-to-buffer buffer '(portal-web--display-elsewhere))
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))
    (dolist (frame (list (window-frame origin) (selected-frame)))
      (set-frame-parameter frame 'portal-render-return preview))))

(defun portal-web--from-view (target function)
  "Call FUNCTION with web view TARGET's buffer current, in the pane showing it.
With no such pane, FUNCTION runs in the selected pane."
  (when-let* ((buffer (portal-view--target-buffer target)))
    (when-let* ((window (portal-input--window target)))
      (select-window window))
    (set-buffer buffer)
    (funcall function)))

(defun portal-web--follow (event)
  "Visit the local file whose link EVENT's hosted page followed.
A fragment such as #L42 or #L42-L50 moves to line 42."
  (interactive "e")
  (pcase-let ((`(,target ,url) (cadr event)))
    (portal-web--from-view
     target
     (lambda ()
       (let* ((parsed (url-generic-parse-url url))
              (fragment (or (url-target parsed) ""))
              (file (portal-web--unhex (url-filename parsed))))
         (unless (and portal-web--follow-function
                      (funcall portal-web--follow-function file
                               (and (not (string-empty-p fragment)) fragment)))
           (portal-web--hand-off
            file
            (and (string-match "\\`L\\([0-9]+\\)\\(?:-L[0-9]+\\)?\\'" fragment)
                 (string-to-number (match-string 1 fragment))))))))))

(defun portal-web--edit (event)
  "Open the Markdown file on screen in EVENT's preview, from its toolbar."
  (interactive "e")
  (portal-web--from-view (car (cadr event)) #'portal-render-open-in-emacs))

(define-key global-map [portal-web-follow] #'portal-web--follow)
(define-key global-map [portal-web-edit] #'portal-web--edit)

;;;###autoload
(defun portal-render-open-in-emacs ()
  "Visit the Markdown or Org file this preview shows, in another pane.
Emacs gets the keyboard, and `portal-render-return' comes back here."
  (interactive)
  (unless (or portal-web--markdown portal-web--org)
    (user-error "This buffer is not a Markdown or Org preview"))
  (portal-web--hand-off (or portal-web--markdown portal-web--org)))

;;;###autoload
(defun portal-render-return ()
  "Return to the Markdown preview this frame last opened a file from.
Select a pane showing it, in this frame or any other, or show it again
if it is hidden, and give its view the keyboard.  The page stays as it was."
  (interactive)
  (let ((preview (frame-parameter nil 'portal-render-return)))
    (unless (memq preview (portal-view-buffers 'web))
      (user-error "No live Markdown preview to return to"))
    ;; A handoff can select another frame, leaving the preview shown in the first.
    (if-let* ((window (or (get-buffer-window preview) (get-buffer-window preview t))))
        (progn (select-frame-set-input-focus (window-frame window))
               (select-window window))
      (pop-to-buffer preview))
    (portal-view-focus)))

;; Hosted apps.
(defun portal-web-send (plist)
  "Send PLIST to the current buffer's hosted app, as a JSON object over the bridge.
The app receives it through `window.portalBridge.receive'."
  (portal--web-send portal-web--target (json-serialize plist)))

(defun portal-web--bridge (target)
  "Pass each message waiting on TARGET's bridge to `portal-web-bridge-function'.
The view's own messages are handled here instead: \"page\" reports each
page it commits, \"follow\" each click on a link to a local file, and
\"edit\" Open in Emacs in a Markdown preview's toolbar.
Receiving the messages lets the next ones send a new record."
  (mapc (lambda (message)
          (pcase (plist-get message :type)
            ("page" (portal-web--page (plist-get message :url)))
            ("follow" (portal-web--queue 'portal-web-follow target (plist-get message :url)))
            ("edit" (portal-web--queue 'portal-web-edit target))
            (_ (when portal-web-bridge-function (funcall portal-web-bridge-function message)))))
        (json-parse-string (portal--web-receive target) :object-type 'plist)))

(setf (alist-get "bridge" portal-view-record-handlers nil nil #'equal) #'portal-web--bridge)

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

;; Addresses.
(defcustom portal-web-search-url "https://duckduckgo.com/?q=%s"
  "Where `portal-web-goto' looks up words that are not an address.
%s stands for the words, percent-encoded."
  :type 'string :group 'portal)

(defvar portal-web--address-history nil "Addresses `portal-web-goto' has read.")

(defun portal-web-current-url ()
  "Return the URL this buffer's web view shows now, or nil without one.
It follows the links and history the page navigates; before the view
reports any, it is the URL the buffer loaded."
  (when portal-web--target
    (or (plist-get (portal--inspect portal-web--target) :url) portal-web--url)))

(defun portal-web--address (input)
  "Return the URL that INPUT names: a URL, a host, a file or words to search.
A host may have a path, as example.com/docs does; localhost and IP
addresses load over http, other hosts over https."
  (let ((input (string-trim input)))
    (cond
     ((string-empty-p input) (user-error "Enter an address or words to search for"))
     ((string-match-p "\\`\\(?:https?\\|file\\|data\\|about\\):" input) input)
     ((string-match-p "\\`\\(?:localhost\\|[0-9]+\\(?:\\.[0-9]+\\)\\{3\\}\\)\\(?::[0-9]+\\)?\\(?:[/?#].*\\)?\\'"
                      input)
      (concat "http://" input))
     ((string-match-p "\\`[^[:space:]/?#]+\\.[[:alpha:]]\\{2,\\}\\(?::[0-9]+\\)?\\(?:[/?#][^[:space:]]*\\)?\\'"
                      input)
      (concat "https://" input))
     ((and (file-name-absolute-p (expand-file-name input))
           (string-match-p "\\`[~/.]" input)
           (file-regular-p (expand-file-name input)))
      (browse-url-file-url (expand-file-name input)))
     (t (format portal-web-search-url (url-hexify-string input))))))

(defun portal-web--read-address (initial)
  "Read an address for a web view, starting with INITIAL, and return its URL."
  (portal-web--address
   (read-string "Go to address or search: " initial 'portal-web--address-history)))

;;;###autoload
(defun portal-web-goto (url &optional new)
  "Go to URL in this buffer's web page, or in a new buffer.
Interactively, read an address, a host, a local file or words to search
for with `portal-web-search-url', starting with the address on screen.
A preview, a hosted app or a buffer without a web view opens URL in a new
buffer instead, as does a prefix argument, NEW."
  (interactive
   (list (portal-web--read-address (and (derived-mode-p 'portal-web-mode)
                                        (not portal-web--hosted-path)
                                        (portal-web-current-url)))
         current-prefix-arg))
  (portal-web--check-url url)
  (if (or new (not portal-web--target) portal-web--hosted-path portal-web--preview)
      (portal-open-url url)
    (portal--web-load portal-web--target url)
    (setq portal-web--url url)))

(defun portal-web-copy-url ()
  "Copy the address this buffer's web page shows to the kill ring."
  (interactive)
  (let ((url (or (portal-web-current-url) (user-error "No web page in this buffer"))))
    (kill-new url)
    (message "Copied %s" url)))

;; Requests: what a page asks its buffer for.
(defcustom portal-web-popups 'buffer
  "What happens to a window that a web page opens.
Pages open windows for sign-in pop-ups, links to new tabs, and the like.
`buffer' shows the window in a web buffer of its own, in another pane,
where the page that opened it can still talk to it, as sign-in pop-ups
need; the window's buffer closes when its page closes the window.
`browser' opens the window's address in the default browser instead, and
nil ignores the window."
  :type '(choice (const :tag "A new web buffer" buffer)
                 (const :tag "The default browser" browser)
                 (const :tag "Ignore it" nil))
  :group 'portal)

(defcustom portal-web-popup-display-action nil
  "How a buffer showing a window a page opened is displayed.
This is the ACTION of `pop-to-buffer', where nil uses
`display-buffer-alist' and Emacs's defaults."
  :type '(choice (const :tag "Default" nil) sexp)
  :group 'portal)

(defun portal-web--requests (target)
  "Queue each request that TARGET's page made, for the command loop.
This runs in the record pipe's process filter, which must never prompt."
  (dolist (request (json-parse-string (portal--web-requests target)
                                      :object-type 'plist :array-type 'list
                                      :null-object nil :false-object nil))
    (portal-web--queue 'portal-web-request target request)))

(setf (alist-get "request" portal-view-record-handlers nil nil #'equal) #'portal-web--requests)

(defun portal-web--answer (target id answer)
  "Answer request ID of TARGET's page with ANSWER.
ANSWER is t, nil for false, `cancel' for none, or a string."
  (portal--web-answer target (number-to-string id)
                      (pcase answer
                        ('t "true")
                        ('nil "false")
                        ('cancel "null")
                        (_ (json-encode-string answer)))))

(defun portal-web--request (event)
  "Act on the request in EVENT, which a web page made of its buffer."
  (interactive "e")
  (pcase-let ((`(,target ,request) (cadr event)))
    (portal-web--from-view
     target
     (lambda ()
       (pcase (plist-get request :type)
         ((or "alert" "confirm" "prompt") (portal-web--dialog target request))
         ("popup" (portal-web--open-window target request))
         ("close" (portal-web--close-window))
         ("address"
          ;; From the toolbar: the page gets the keyboard back with its address.
          (portal-web-goto (portal-web--read-address (plist-get request :url)))
          (when (equal (portal-view-target) target)
            (portal-view-focus))))))))

(define-key global-map [portal-web-request] #'portal-web--request)

(defun portal-web--dialog (target request)
  "Ask, in the minibuffer, what REQUEST, a dialog of TARGET's page, asks.
The page waits for the answer, which it gets however the dialog ends:
quitting cancels it.  The view gets the keyboard back if it had it."
  (let* ((id (plist-get request :id))
         (message (string-trim-right (or (plist-get request :message) "")))
         (origin (plist-get request :origin))
         (text (if (and origin (not (string-empty-p origin)))
                   (format "%s says: %s" origin message)
                 message))
         (focused (plist-get (portal--inspect target) :focused))
         (answer 'cancel))
    (portal-input--action "unfocus" target)
    (unwind-protect
        (setq answer
              (pcase (plist-get request :type)
                ("alert" (message "%s" text) t)
                ("confirm" (and (y-or-n-p (concat text " ")) t))
                ("prompt" (read-string (concat (string-remove-suffix ":" text) ": ")
                                       nil nil (plist-get request :default)))))
      (with-demoted-errors "Portal web request: %S"
        (portal-web--answer target id answer))
      (when (and focused (equal (portal-view-target) target))
        (portal-view-focus)))))

(defun portal-web--open-window (target request)
  "Show the window that REQUEST says TARGET's page opened.
`portal-web-popups' says how."
  (let ((id (plist-get request :id))
        (url (plist-get request :url)))
    (pcase portal-web-popups
      ('buffer
       (let ((buffer (generate-new-buffer
                      (format "*portal: %s*" (if url (portal-web--page-name url) "window"))))
             opened)
         (unwind-protect
             (progn
               (pop-to-buffer buffer portal-web-popup-display-action)
               (portal-web-mode)
               (let ((inhibit-read-only t))
                 (insert "Web view: a window a page opened\n\n"
                         "RET or a click enters the page. The configured escape returns to Emacs.\n"
                         "It closes when its page closes the window; killing the buffer closes it too.\n"))
               (portal-input--connect)
               (setq portal-web--target
                     (portal-view-open 'web (append (and portal-web-appearance
                                                         (list :appearance
                                                               (symbol-name portal-web-appearance)))
                                                    (list :toolbar "navigation"
                                                          :window (plist-get request :window))))
                     portal-web--url (or url "about:blank")
                     portal-web--popup t
                     opened t)
               (portal-input-mode 1))
           (unless opened
             (with-demoted-errors "Portal web window: %S"
               (portal-web--answer target id nil))
             (when (buffer-live-p buffer)
               (if-let* ((window (get-buffer-window buffer)))
                   (quit-window t window)
                 (kill-buffer buffer)))))))
      ('browser
       (when url (browse-url-default-browser url))
       (portal-web--answer target id nil))
      (_ (portal-web--answer target id nil)))))

(defun portal-web--close-window ()
  "Close this buffer, if it shows a window its page opened and now closes."
  (when portal-web--popup
    (if-let* ((window (get-buffer-window (current-buffer))))
        (quit-window t window)
      (kill-buffer (current-buffer)))))

;; Bookmarks.
(defun portal-web-bookmark-make-record ()
  "Return a bookmark record for this web buffer, as `bookmark-set' makes.
A preview remembers its file, and a page its address.  Other hosted apps,
whose address changes with each app host, cannot be bookmarked."
  (let* ((url (portal-web-current-url))
         (title (and portal-web--target (plist-get (portal--inspect portal-web--target) :title))))
    (when (and portal-web--hosted-path (not (or portal-web--markdown portal-web--org)))
      (user-error "Portal cannot bookmark this hosted app"))
    `(,(cond ((and title (not (string-empty-p title))) title)
             ((or portal-web--markdown portal-web--org)
              (file-name-nondirectory (or portal-web--markdown portal-web--org)))
             (t (or url (buffer-name))))
      ,@(cond (portal-web--markdown `((filename . ,portal-web--markdown) (portal . markdown)))
              (portal-web--org `((filename . ,portal-web--org) (portal . org)))
              (portal-web--preview `((location . ,portal-web--preview) (portal . html)))
              (t `((location . ,url) (portal . page))))
      (handler . portal-web-bookmark-jump))))

;;;###autoload
(defun portal-web-bookmark-jump (bookmark)
  "Show BOOKMARK, a Portal page or preview, in a web buffer."
  (require 'bookmark)
  (let ((file (bookmark-prop-get bookmark 'filename))
        (url (bookmark-prop-get bookmark 'location)))
    (pcase (bookmark-prop-get bookmark 'portal)
      ('markdown (portal-render-markdown file))
      ('org (if (fboundp 'portal-render-org)
                (funcall 'portal-render-org file)
              (user-error "Load Org to preview %s" file)))
      ('html (portal-render-html url))
      (_ (portal-open-url url)))))
(put 'portal-web-bookmark-jump 'bookmark-handler-type "Portal")

(provide 'portal-web)
;;; portal-web.el ends here
