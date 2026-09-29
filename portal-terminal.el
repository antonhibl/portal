;;; portal-terminal.el --- Native Ghostty terminals -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'windmove)

(defgroup portal-terminal nil
  "Native Ghostty terminals in Emacs panes."
  :group 'terminals)

(require 'portal-input
         (expand-file-name "portal-input"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-project
         (expand-file-name "portal-project"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(declare-function portal--terminal-theme "portal-terminal" (theme))
(declare-function portal--terminal-themes "portal-terminal" ())
(declare-function portal--inspect "portal-view" (target))

(defvar-local portal-terminal--last-buffer nil)
(defvar-local portal-terminal--quick-root nil)

;; What Portal knows about each terminal, cached in its buffer.  The buffer
;; is the session: its name is the label, and killing it ends the shell.
(defvar-local portal-terminal--project nil
  "The canonical root of the project the terminal belongs to, or nil.
It is set when the terminal starts and by `portal-terminal-set-project',
never by the shell changing directory.")
(defvar-local portal-terminal--directory nil
  "The terminal's working directory: the last its shell reported, or its start.")
(defvar-local portal-terminal--title nil "The title its program set last, or nil.")
(defvar-local portal-terminal--exited nil "Whether its program has exited.")
(defvar portal-terminal-quick-prefix-map)
(defvar portal-terminal--native-maps)
(declare-function portal-terminal-refresh-bindings "portal-terminal-bindings" ())
(declare-function portal-terminal--validate-native-prefix "portal-terminal-bindings" (description))
(declare-function portal-terminal-quick--display "portal-terminal-quick" (buffer))
(declare-function portal-terminal-quick--window "portal-terminal-quick" ())
(declare-function portal-terminal-quick-dismiss "portal-terminal-quick" ())

(defun portal-terminal--theme-changed (_symbol value operation _where)
  "Validate and apply theme VALUE to running terminals on OPERATION."
  (when (eq operation 'set)
    (unless (or (null value) (stringp value))
      (error "Terminal theme must be a theme name or nil"))
    (when (fboundp 'portal--terminal-theme)
      (portal--terminal-theme value))))

(defcustom portal-terminal-theme nil
  "Color theme for all Portal terminals.
Use an exact, case-sensitive name from `portal-terminal-themes', such as
\"Dracula\".  Nil follows native system appearance, using Alabaster in light
mode and Afterglow in dark mode.  Named themes stay fixed in both modes.
Changes with `setq' or Customize apply to running and future terminals
without restarting their shells.  May be set before loading Portal;
the name is validated when the native module is available."
  :type '(choice (const :tag "System appearance" nil) string)
  :group 'portal-terminal)
(add-variable-watcher 'portal-terminal-theme #'portal-terminal--theme-changed)

(defun portal-terminal-themes ()
  "Return the available terminal theme names from the bundled catalog."
  (portal-view--load)
  (portal--terminal-themes))

(defcustom portal-terminal-prefix-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("c" . portal-terminal-new)
                       ("\"" . portal-terminal-split-below)
                       ("%" . portal-terminal-split-right)
                       ("o" . portal-terminal-next-pane)
                       ("<up>" . windmove-up) ("<down>" . windmove-down)
                       ("<left>" . windmove-left) ("<right>" . windmove-right)
                       ("n" . portal-terminal-next)
                       ("p" . portal-terminal-previous)
                       ("l" . portal-terminal-last)
                       ("w" . portal-terminal-choose)
                       ("," . portal-terminal-rename)
                       ("x" . portal-terminal-kill-pane)
                       ("z" . portal-terminal-zoom)
                       ("d" . portal-terminal-unfocus)
                       (":" . portal-terminal-command-prompt)
                       ("?" . portal-terminal-help)))
      (keymap-set map (car binding) (cdr binding)))
    (dotimes (index 10)
      (define-key map (number-to-string index) #'portal-terminal-select-index))
    map)
  "Commands read by Emacs after `portal-terminal-prefix'.
Defaults follow tmux where there is an Emacs counterpart: terminal buffers
are windows, Emacs windows are panes.  This is not a tmux session manager.
Use `keymap-set' to add commands, including ordinary Emacs commands and
nested prefix maps.  Commands resume a selected terminal after returning;
call `portal-terminal-unfocus' to stay in Emacs instead.
C-g cancels.  The current leader repeated sends a literal leader key."
  :type 'keymap
  :group 'portal-terminal)

(define-derived-mode portal-terminal-mode special-mode "Ghostty"
  "A real native Ghostty surface occupies this buffer's displayed pane.
RET focuses Ghostty.  The configurable leader dispatches Emacs commands.
Command-Escape always returns focus to Emacs.  Scrollback belongs to Ghostty."
  (setq-local cursor-type nil)
  (setq-local portal-input--map-function
              (lambda () (if portal-terminal--quick-root portal-terminal-quick-prefix-map
                           portal-terminal-prefix-map)))
  (add-hook 'kill-buffer-hook #'portal-terminal--dismiss-quick nil t)
  (portal-input-mode 1))
(keymap-set portal-terminal-mode-map "RET" #'portal-terminal-focus)
(keymap-set portal-terminal-mode-map "C-c C-k" #'portal-terminal-close)

(defun portal-terminal-buffers (&optional project quick)
  "Return the live terminal buffers, in creation order.
With PROJECT, a project root, return only the terminals assigned to it,
wherever their shells are now.  Quick terminals, which belong to their
project too, are included only when QUICK is non-nil."
  (unless (and project (file-remote-p project)) ; Terminals belong to local roots.
    (let ((root (and project (file-name-as-directory (file-truename project)))))
      (cl-remove-if-not
       (lambda (buffer)
         (with-current-buffer buffer
           (and (or quick (not portal-terminal--quick-root))
                (or (null project) (equal portal-terminal--project root)))))
       (portal-view-buffers 'terminal)))))

(defun portal-terminal-metadata (&optional buffer)
  "Return what Portal knows about terminal BUFFER, or nil if it has no shell.
BUFFER defaults to the current buffer.  The plist holds its label, the
buffer's `:name'; its `:project' root, or nil; its working `:directory';
its `:title', as its program last set it, or nil; whether its program
`:exited'; and whether it is a `:quick' terminal.  Only facts are reported:
a live shell may be idle or busy, and a title may name anything."
  (let ((buffer (or buffer (current-buffer))))
    (when (memq buffer (portal-view-buffers 'terminal))
      (with-current-buffer buffer
        (list :name (buffer-name) :project portal-terminal--project
              :directory portal-terminal--directory :title portal-terminal--title
              :exited portal-terminal--exited :quick (and portal-terminal--quick-root t))))))

(defun portal-terminal--local-directory (path)
  "Return PATH as a directory name if a report of it can be trusted, else nil.
The terminal engine passes on only reports from this host.  PATH must be
absolute, not remote syntax, and an existing directory, checked with file
name handlers disabled so that a report never starts TRAMP."
  (and (stringp path) (string-prefix-p "/" path)
       (not (file-remote-p path))
       (let ((file-name-handler-alist nil))
         (file-directory-p path))
       (file-name-as-directory path)))

(defun portal-terminal--changed (target)
  "Cache what TARGET's terminal reports now: its title, directory and exit.
The native module sends the next record once this has inspected TARGET.
A trusted directory also becomes the buffer's `default-directory', for
ordinary file commands, and `list-buffers-directory', for buffer lists."
  (when-let* ((state (portal--inspect target)))
    (let ((title (plist-get state :title))
          (directory (portal-terminal--local-directory (plist-get state :pwd))))
      (setq portal-terminal--title (and (stringp title) (not (string-empty-p title)) title))
      (when directory
        (setq portal-terminal--directory directory
              default-directory directory
              list-buffers-directory directory))
      (unless (eq portal-terminal--exited (plist-get state :exited))
        (setq portal-terminal--exited (plist-get state :exited)
              mode-line-process (and portal-terminal--exited ":exited"))
        (force-mode-line-update)))))

(setf (alist-get "terminal" portal-view-record-handlers nil nil #'equal)
      #'portal-terminal--changed)

(defun portal-terminal--project-names (roots)
  "Return an alist from each of ROOTS to a short name that tells it apart.
A root's name is its last directory component, extended with parent
components while another of ROOTS ends the same way."
  (let ((parts (mapcar (lambda (root)
                         (cons root (reverse (split-string (abbreviate-file-name
                                                            (directory-file-name root))
                                                           "/" t))))
                       (delete-dups (copy-sequence roots)))))
    (mapcar
     (lambda (entry)
       (let ((depth 1))
         (while (and (< depth (length (cdr entry)))
                     (cl-some (lambda (other)
                                (and (not (eq other entry))
                                     (equal (take depth (cdr other)) (take depth (cdr entry)))))
                              parts))
           (cl-incf depth))
         (cons (car entry)
               (if (cdr entry) (string-join (reverse (take depth (cdr entry))) "/") (car entry)))))
     parts)))

(defun portal-terminal--default-name (label project directory)
  "Return a new terminal's buffer name, for LABEL in PROJECT or DIRECTORY.
PROJECT is named apart from the other terminals' projects; without one,
the abbreviated DIRECTORY stands in for it."
  (format "*%s: %s*" label
          (if project
              (alist-get project
                         (portal-terminal--project-names
                          (cons project (delq nil (mapcar (lambda (buffer)
                                                            (buffer-local-value
                                                             'portal-terminal--project buffer))
                                                          (portal-view-buffers 'terminal)))))
                         nil nil #'equal)
            (abbreviate-file-name (directory-file-name directory)))))

(defun portal-terminal--connect ()
  "Connect shared input and refresh terminal-specific native bindings."
  (portal-input--connect)
  (portal-terminal-refresh-bindings))

;;;###autoload
(defun portal-terminal (&optional new)
  "Open or return to a native Ghostty terminal in the selected pane.
With prefix argument NEW, always start a new shell.  Hidden shells persist."
  (interactive "P")
  (let ((buffer (car (portal-terminal-buffers))))
    (if (and buffer (not new))
        (progn (portal-terminal--switch buffer) (portal-terminal-focus))
      (portal-terminal-new))))

;;;###autoload
(defun portal-terminal-new ()
  "Create an independent native terminal in the selected Emacs pane."
  (interactive)
  (when (window-parameter nil 'portal-terminal-quick)
    (user-error "Dismiss the quick terminal before opening an ordinary terminal"))
  (portal-terminal--new))

(defun portal-terminal--new (&optional quick-root command name elsewhere argv label)
  "Create a terminal, optionally for QUICK-ROOT or with startup COMMAND.
NAME names its buffer; without it, the name holds LABEL, by default
\"terminal\", and the terminal's project.  ELSEWHERE displays it in
another pane.  ARGV is a JSON array of a program and literal arguments to
run through the user's shell, instead of COMMAND.  The terminal belongs to
QUICK-ROOT, or to the project of `default-directory', where it starts."
  (when (file-remote-p default-directory)
    (user-error "Start in a local directory; run ssh inside the terminal for remote shells"))
  (portal-terminal--connect)
  (let* ((directory (expand-file-name default-directory))
         (project (or quick-root (portal-project-root directory)))
         (previous (current-buffer))
         (buffer (generate-new-buffer
                  (cond (quick-root (format "*portal-quick:%s*" (abbreviate-file-name quick-root)))
                        (name)
                        (t (portal-terminal--default-name (or label "terminal") project directory)))))
         ready)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (portal-terminal-mode)
            (setq default-directory directory
                  list-buffers-directory directory
                  portal-terminal--directory directory
                  portal-terminal--project project
                  portal-terminal--quick-root quick-root
                  portal-terminal--last-buffer previous)
            (let ((inhibit-read-only t))
              (insert "Native Ghostty terminal\n\n"
                      "RET or a click focuses Ghostty. Command-Escape returns to Emacs.\n"
                      "Use the configured prefix then ? for terminal commands.\n"
                      "This buffer has one live view, which follows its selected pane.\n")))
          (if quick-root
              (portal-terminal-quick--display buffer)
            (if elsewhere
                (pop-to-buffer buffer '(nil (inhibit-same-window . t)
                                            (reusable-frames . visible)))
              (switch-to-buffer buffer)))
          (redisplay t)
          (with-current-buffer buffer
            ;; A change made while the view opened sent no record, having no
            ;; target yet, so read the facts once; later changes send records.
            (portal-terminal--changed
             (portal-view-open 'terminal (list :directory directory
                                               :command command
                                               :argv argv
                                               :theme portal-terminal-theme
                                               :quick (and quick-root t))))
            (portal-terminal-focus))
          (setq ready t))
      (unless ready (kill-buffer buffer)))
    buffer))

(defun portal-terminal-start (directory program arguments &optional name)
  "Start PROGRAM with ARGUMENTS in DIRECTORY in a new terminal in another pane.
Return its buffer.  NAME optionally names the buffer; by default, the name
holds PROGRAM's file name and DIRECTORY's project.  Arguments are literal
strings.  The native terminal starts the user's interactive login shell,
which loads its startup files and resolves PROGRAM on its PATH.
Lisp-side `process-environment' changes are not exported to the terminal.
A missing program is reported by the shell inside the terminal."
  (unless (and (stringp directory) (file-name-absolute-p directory)
               (not (file-remote-p directory)) (file-directory-p directory))
    (user-error "Choose an existing local terminal directory"))
  (unless (and (stringp program) (> (length program) 0) (sequencep arguments)
               (seq-every-p (lambda (s) (and (stringp s) (not (string-search "\0" s)))) arguments)
               (not (string-search "\0" program)))
    (user-error "Terminal program and arguments must be strings without NUL"))
  (let* ((default-directory (file-name-as-directory directory))
         (configuration (current-window-configuration)))
    (condition-case err
        (portal-terminal--new
         nil nil name t (json-serialize (vconcat (list program) arguments))
         (file-name-nondirectory program))
      (error (set-window-configuration configuration)
             (portal-view-sync)
             (signal (car err) (cdr err))))))

(defun portal-terminal-open-action (arguments)
  "Handle a hosted app's terminal.open operation with JSON ARGUMENTS.
The originating view gives up the keyboard, which the new terminal takes."
  (portal-input--action "unfocus" portal-view--target)
  (setq portal-input--resume nil)
  (let ((buffer (portal-terminal-start
                 (plist-get arguments :directory) (plist-get arguments :program)
                 (plist-get arguments :args) (plist-get arguments :name))))
    (list :target (buffer-local-value 'portal-view--target buffer))))

;;;###autoload
(defun portal-terminal-focus ()
  "Give this buffer's native terminal keyboard focus."
  (interactive)
  (unless (memq (current-buffer) (portal-view-buffers 'terminal))
    (user-error "No terminal in this buffer"))
  (portal-view-focus))

(defalias 'portal-terminal-unfocus #'portal-input-unfocus)

;;;###autoload
(defun portal-terminal-close ()
  "End this buffer's native shell.  Other terminal sessions keep running."
  (interactive)
  (portal-terminal--dismiss-quick)
  (portal-view-close))

(defun portal-terminal--dismiss-quick ()
  "Dismiss the quick panel when it shows this buffer."
  (when-let* ((window (get-buffer-window (current-buffer))))
    (when (and portal-terminal--quick-root (eq window (portal-terminal-quick--window)))
      (save-current-buffer (portal-terminal-quick-dismiss)))))

(defun portal-terminal-close-all ()
  "End all native shells, for Emacs shutdown or explicit cleanup."
  (interactive)
  (dolist (buffer (portal-view-buffers 'terminal))
    (with-current-buffer buffer (portal-terminal-close))))

(defalias 'portal-terminal--dispatch #'portal-input--dispatch)
(defalias 'portal-terminal-send-prefix #'portal-input-send-prefix)

(defun portal-terminal--switch (buffer)
  "Select terminal BUFFER and remember the previously selected terminal."
  (when (window-parameter nil 'portal-terminal-quick)
    (user-error "Dismiss the quick terminal before switching ordinary terminals"))
  (let ((previous (current-buffer)))
    (switch-to-buffer buffer)
    (unless (eq previous buffer) (setq portal-terminal--last-buffer previous))))

(defun portal-terminal-next (&optional previous)
  "Select the next terminal in creation order, or PREVIOUS when non-nil."
  (interactive)
  (let* ((buffers (portal-terminal-buffers))
         (index (or (cl-position (current-buffer) buffers) 0)))
    (unless buffers (user-error "No terminal buffers"))
    (portal-terminal--switch (nth (mod (+ index (if previous -1 1)) (length buffers)) buffers))))
(defun portal-terminal-previous ()
  "Select the previous terminal buffer."
  (interactive) (portal-terminal-next t))
(defun portal-terminal-last ()
  "Select the last terminal used in this pane."
  (interactive)
  (unless (memq portal-terminal--last-buffer (portal-terminal-buffers))
    (user-error "No previous terminal"))
  (portal-terminal--switch portal-terminal--last-buffer))
(defun portal-terminal-select-index ()
  "Select terminal 0 through 9 in creation order."
  (interactive)
  (let ((buffer (nth (- last-command-event ?0) (portal-terminal-buffers))))
    (unless buffer (user-error "No terminal at that index"))
    (portal-terminal--switch buffer)))
(defun portal-terminal--candidates (buffers)
  "Return completion candidates for BUFFERS, as (STRING BUFFER EXITED).
Each string holds the terminal's name, project, directory and title, so
that completion matches any of them, and is unique because its name is.
EXITED says whether its program has exited."
  (let* ((data (mapcar #'portal-terminal-metadata buffers))
         (projects (portal-terminal--project-names
                    (delq nil (mapcar (lambda (entry) (plist-get entry :project)) data))))
         (width (apply #'max 0 (mapcar #'string-width (mapcar #'buffer-name buffers)))))
    (cl-mapcar
     (lambda (buffer entry)
       (let ((project (alist-get (plist-get entry :project) projects nil nil #'equal))
             (title (plist-get entry :title)))
         (list (concat (truncate-string-to-width (buffer-name buffer) width nil ?\s)
                       (propertize
                        (string-join
                         (delq nil (list "" (or project "-")
                                         (abbreviate-file-name (plist-get entry :directory))
                                         (and title (replace-regexp-in-string
                                                     "[[:cntrl:]]" " " title))))
                         "  ")
                        'face 'completions-annotations))
               buffer (plist-get entry :exited))))
     buffers data)))

;; Match any part of a candidate, as Emacs does for buffer names, so context
;; after the name is searchable without extra packages.  Users' overrides win.
(add-to-list 'completion-category-defaults '(portal-terminal (styles basic substring)))

(defun portal-terminal--read (prompt buffers)
  "Read one of the terminal BUFFERS with completion, prompting with PROMPT.
Candidates show each terminal's context, which completion matches, and
resolve to the buffer, whatever its name.  An exited program is noted."
  (unless buffers (user-error "No terminal buffers"))
  (let* ((candidates (portal-terminal--candidates buffers))
         (choice (completing-read
                  prompt
                  (lambda (string predicate action)
                    (if (eq action 'metadata)
                        `(metadata
                          (category . portal-terminal)
                          (annotation-function
                           . ,(lambda (candidate)
                                (when (nth 2 (assoc candidate candidates))
                                  (propertize "  exited" 'face 'completions-annotations)))))
                      (complete-with-action action candidates string predicate)))
                  nil t))
         (buffer (nth 1 (assoc choice candidates))))
    (unless (memq buffer (portal-view-buffers 'terminal))
      (user-error "That terminal has closed"))
    buffer))

(defun portal-terminal-choose ()
  "Choose a terminal with Emacs completion.
Type any part of a terminal's name, project, directory or title."
  (interactive)
  (portal-terminal--switch (portal-terminal--read "Terminal: " (portal-terminal-buffers))))
(defun portal-terminal-rename (name)
  "Rename the current terminal buffer to NAME.
Portal never renames it again: titles and directory changes leave it."
  (interactive (list (read-string "Terminal name: " (buffer-name))))
  (when portal-terminal--quick-root
    (user-error "Quick terminals are named by their project"))
  (rename-buffer name t))
(defun portal-terminal-set-project (directory)
  "Assign this terminal to the project containing DIRECTORY.
The assignment lasts until the next one: the shell changing directory
does not change it.  With a nil DIRECTORY, or interactively with a prefix
argument, the terminal belongs to no project.  Its name stays as it is."
  (interactive
   (list (unless current-prefix-arg
           (read-directory-name "Project containing: " portal-terminal--directory nil t))))
  (unless (memq (current-buffer) (portal-view-buffers 'terminal))
    (user-error "No terminal in this buffer"))
  (when portal-terminal--quick-root
    (user-error "Quick terminals belong to the project they were opened for"))
  (setq portal-terminal--project
        (and directory (or (portal-project-root directory)
                           (user-error "No project contains %s" directory))))
  (message "Terminal project: %s"
           (if portal-terminal--project (abbreviate-file-name portal-terminal--project) "none")))
(defun portal-terminal-next-pane ()
  "Select the next Emacs pane, as tmux prefix o does."
  (interactive) (other-window 1))
(defun portal-terminal--split (side)
  "Split toward SIDE and start a new independent shell there."
  (let ((configuration (current-window-configuration)))
    (condition-case err
        (progn (select-window (split-window nil nil side)) (portal-terminal-new))
      (error (set-window-configuration configuration) (signal (car err) (cdr err))))))
(defun portal-terminal-split-below ()
  "Split the pane top/bottom and start a shell in the bottom pane."
  (interactive) (portal-terminal--split 'below))
(defun portal-terminal-split-right ()
  "Split the pane left/right and start a shell in the right pane."
  (interactive) (portal-terminal--split 'right))
(defun portal-terminal-kill-pane ()
  "Confirm, end this shell and remove its Emacs pane when possible."
  (interactive)
  (when (y-or-n-p (format "Kill terminal %s and its running shell? " (buffer-name)))
    (let ((window (selected-window)))
      (kill-buffer (current-buffer))
      (unless (one-window-p t) (delete-window window)))))
(defun portal-terminal-zoom ()
  "Toggle the selected pane between its layout and a full-frame view."
  (interactive)
  (let ((configuration (frame-parameter nil 'portal-terminal-zoom)))
    (if configuration
        (progn (set-frame-parameter nil 'portal-terminal-zoom nil)
               (set-window-configuration configuration))
      (set-frame-parameter nil 'portal-terminal-zoom (current-window-configuration))
      (delete-other-windows))))
(defalias 'portal-terminal-command-prompt #'execute-extended-command)
(defalias 'portal-terminal-help #'portal-input-help)

(provide 'portal-terminal)
(require 'portal-terminal-bindings
         (expand-file-name "portal-terminal-bindings"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal-quick
         (expand-file-name "portal-terminal-quick"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
;;; portal-terminal.el ends here
