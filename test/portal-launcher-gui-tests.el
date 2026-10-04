;;; portal-launcher-gui-tests.el --- Real NS panel lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run only in a disposable graphical Emacs with the newly built module.
(require 'ert)
(require 'portal-launcher)
(declare-function portal-test-hotkey "test-terminal-input" (hotkey pressed))
(declare-function portal--launcher-inspect "portal-launcher" ())
(declare-function portal--shortcuts "portal-global-shortcut" ())
(declare-function portal-test-native-post-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-frontmost "test-terminal-input" (&optional app))
(declare-function portal-test-native-focus-target "test-terminal-input" ())
(declare-function portal-test-capture-target "test-terminal-input" (file))
(declare-function vertico-mode "vertico" (&optional arg))
(declare-function marginalia-mode "marginalia" (&optional arg))
(defvar launcher--apps)
(defvar launcher--current-entries)
(defvar launcher-bangs)
(defvar vertico-sort-function)
(defvar vertico-count)
(defvar vertico--candidates-ov)
(defvar vertico--index)

(defmacro portal-launcher-gui--with-panel (&rest body)
  (declare (indent 0))
  `(progn
     (skip-unless (eq window-system 'ns))
     (let ((before (frame-list))
           (ordinary (selected-window))
           (ordinary-buffer (window-buffer))
           (content (generate-new-buffer " *launcher GUI*"))
           (portal-launcher-size '(720 420))
           (portal-launcher-offset '(0 0))
           (portal-launcher-screen nil))
       (unwind-protect
           (progn ,@body)
         (portal-launcher-mode -1)
         (when (buffer-live-p content) (kill-buffer content))
         (when (window-live-p ordinary) (select-window ordinary))
         (dolist (frame (frame-list))
           (unless (memq frame before) (delete-frame frame t)))
         ;; Changing/deleting ordinary NS windows can asynchronously activate
         ;; the previous app. Drain that cleanup before another test starts a
         ;; session whose focus-loss observer would correctly cancel it.
         (portal-launcher-gui--settle-focus))
       (should-not portal-launcher--frame)
       (should (equal before (frame-list)))
       (should (eq (window-buffer ordinary) ordinary-buffer)))))

(defun portal-launcher-gui--settle ()
  (redisplay t)
  (accept-process-output nil 0.05)
  (redisplay t))

(defun portal-launcher-gui--settle-focus ()
  "Wait, up to 3 s, until the frontmost app has not changed for 0.5 s.
AppKit can report an activation after the next session has started to
watch focus. `sit-for' would return at once while input is pending."
  (let ((deadline (+ (float-time) 3))
        (front (portal-test-frontmost))
        (since (float-time)))
    (while (and (< (float-time) deadline) (< (- (float-time) since) 0.5))
      (accept-process-output nil 0.05)
      (let ((now (portal-test-frontmost)))
        (unless (eql now front) (setq front now since (float-time)))))))

(ert-deftest portal-launcher-gui-real-buffer-and-reuse ()
  (portal-launcher-gui--with-panel
    (with-current-buffer content (insert "Real buffer in a native panel\n"))
    (portal-launcher-mode 1)
    (should (equal before (frame-list)))
    (should-not (plist-get (portal--launcher-inspect) :attached))
    (let ((frame (portal-launcher-show content)))
      (portal-launcher-gui--settle)
      (should (eq (selected-frame) frame))
      (should (eq (window-buffer (frame-selected-window frame)) content))
      (should (equal (buffer-string) "Real buffer in a native panel\n"))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (should (plist-get (portal--launcher-inspect) :visible))
      (should (string-match-p "LauncherPanel" (plist-get (portal--launcher-inspect) :class)))
      (goto-char (point-max))
      (execute-kbd-macro "edited")
      (portal-launcher-hide)
      (should (eq (selected-window) ordinary))
      (should-not (frame-visible-p frame))
      (should-not (plist-get (portal--launcher-inspect) :visible))
      (should (eq (portal-launcher-show) frame))
      (should (string-suffix-p "edited" (buffer-string)))
      (dotimes (_ 100) (portal-launcher-hide) (should (eq (portal-launcher-show) frame)))
      (portal-launcher-hide))))

(ert-deftest portal-launcher-gui-native-keyboard ()
  (skip-unless (fboundp 'portal-test-native-post-key))
  (portal-launcher-gui--with-panel
    (portal-launcher-show content)
    (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
    (unwind-protect
        (progn
          (portal-test-native-post-key 0 0 "a")
          (should (equal (with-timeout (3 (ert-fail "Panel did not deliver input to Emacs"))
                           (read-key-sequence-vector nil)) [97])))
      (portal-test-native-target-frame nil))))

(ert-deftest portal-launcher-gui-geometry-and-appearance ()
  (portal-launcher-gui--with-panel
    (portal-launcher-show content)
    (let ((screens (plist-get (portal--launcher-inspect) :screens)) measurements)
      (dotimes (index (length screens))
        (dolist (size '((640 320) (720 420) (860 520) (713 407)))
          (dolist (offset '((0 0) (-137 81)))
            (let ((portal-launcher-screen index) (portal-launcher-size size)
                  (portal-launcher-offset offset))
              (portal-launcher-show)
              (portal-launcher-gui--settle)
              (let ((state (portal--launcher-inspect)))
                (should (equal (plist-get state :requested) (plist-get state :actual)))
                (should (equal (cddr (plist-get state :actual)) size))
                (should (equal (list (frame-pixel-width portal-launcher--frame)
                                    (frame-pixel-height portal-launcher--frame)) size))
                (push (list :screen index :size size :offset offset
                            :requested (plist-get state :requested) :actual (plist-get state :actual))
                      measurements))))))
      (message "Launcher geometry: %S; screens: %S" (nreverse measurements) screens))
    (let ((portal-launcher-size '(713 407)))
      (dolist (appearance '(dark light nil))
        (set-frame-parameter portal-launcher--frame 'ns-appearance appearance)
        (dolist (font '("Menlo 13" "Menlo 18" "Menlo 15"))
          (let ((portal-launcher-font font))
            (portal-launcher-show)
            (portal-launcher-gui--settle)
            (should (equal (cddr (plist-get (portal--launcher-inspect) :actual)) '(713 407)))))))
    (let ((portal-launcher-size '(100000 100000)) (portal-launcher-offset '(-100000 100000)))
      (portal-launcher-show)
      (portal-launcher-gui--settle)
      (let* ((state (portal--launcher-inspect)) (actual (plist-get state :actual)))
        (should (equal actual (plist-get state :requested)))
        (should (cl-some (lambda (screen) (equal actual (plist-get screen :visible)))
                         (plist-get state :screens)))))
    ;; A disconnected index falls back to the pointer screen.
    (let ((portal-launcher-screen 999)) (portal-launcher-show))))

(ert-deftest portal-launcher-gui-delete-disable-and-child ()
  (portal-launcher-gui--with-panel
    (dotimes (_ 20)
      (let ((frame (portal-launcher-show content)))
        (delete-frame frame t)
        (should-not (frame-live-p frame))
        (should-not (plist-get (portal--launcher-inspect) :attached))))
    (let* ((frame (portal-launcher-show content))
           (child (make-frame `((parent-frame . ,frame) (minibuffer . nil)
                               (undecorated . t) (width . 20) (height . 4)
                               (no-accept-focus . t) (visibility . nil)))))
      (make-frame-visible child)
      (portal-launcher-gui--settle)
      (delete-frame frame t)
      (should-not (frame-live-p child)))
    (dotimes (_ 3)
      (portal-launcher-show content)
      (portal-launcher-mode -1)
      (portal-launcher-mode -1)
      (should-not (plist-get (portal--launcher-inspect) :attached)))
    (should (eq (selected-window) ordinary))))

(ert-deftest portal-launcher-gui-rejects-mutation-and-rolls-back ()
  (portal-launcher-gui--with-panel
    (let ((initial-frames (frame-list)))
      (cl-letf (((symbol-function 'portal--launcher-attach)
                 (lambda (_title) (error "Simulated attachment failure"))))
        (should-error (portal-launcher-show content)))
      (should (equal initial-frames (frame-list)))
      (should-not (plist-get (portal--launcher-inspect) :attached)))
    (let ((frame (portal-launcher-show content)))
      (dolist (change '((undecorated . nil) (fullscreen . fullboth) (parent-frame . other)
                        (tool-bar-lines . 1) (no-focus-on-map . nil)))
        (should-error (set-frame-parameter frame (car change) (cdr change)) :type 'user-error))
      (modify-frame-parameters frame '((parent-frame . nil) (undecorated . t)))
      (should (plist-get (portal--launcher-inspect) :viewAttached))
      (portal-launcher-hide)
      ;; Ordinary Emacs frames still change their role normally.
      (set-frame-parameter (window-frame ordinary) 'undecorated t)
      (set-frame-parameter (window-frame ordinary) 'undecorated nil)
      (should (eq (portal-launcher-show) frame)))))

(defun portal-launcher-gui--command-loop ()
  "Let the real command loop execute queued shortcut events, then return."
  (let ((timer (run-at-time 0.2 nil #'exit-recursive-edit)))
    (unwind-protect (recursive-edit) (cancel-timer timer))))

(defun portal-launcher-gui--hotkey ()
  "The native hot key of the launcher's global shortcut, for the injector."
  (let ((id (cadr (assq 'portal-launcher portal-global-shortcut--registrations))))
    (plist-get (cl-find id (portal--shortcuts) :key (lambda (shortcut) (plist-get shortcut :id)))
               :hotkey)))

(ert-deftest portal-launcher-gui-shortcut-through-command-loop ()
  (skip-unless (fboundp 'portal-test-hotkey))
  (portal-launcher-gui--with-panel
    (let ((portal-launcher-command nil))
      (discard-input)
      (portal-launcher-mode 1)
      (should-not (portal-view-buffers))
      (should-not portal-launcher--frame)
      (let ((hotkey (portal-launcher-gui--hotkey)))
	(should (portal-test-hotkey hotkey t))
	(portal-view--read-records)
	;; The filter only queued it, without changing a frame.
	(should-not portal-launcher--frame)
	(should (cl-find 'portal-global-shortcut unread-command-events :key #'car-safe))
	(let ((overriding-local-map (make-sparse-keymap)))
          (portal-launcher-gui--command-loop))
	(should (frame-live-p portal-launcher--frame))
	(should (plist-get (portal--launcher-inspect) :visible))
	(should (eq (selected-frame) portal-launcher--frame))
	(should (portal-test-hotkey hotkey nil))
	(should (portal-test-hotkey hotkey t))
	(portal-view--read-records)
	(portal-launcher-gui--command-loop)
	(should-not (plist-get (portal--launcher-inspect) :visible))
	(should (eq (selected-window) ordinary))
	(should (portal-test-hotkey hotkey nil))
	(let ((portal-launcher-shortcut "Control-Option-Command-L"))
          (portal-launcher-mode 1)
          (should-not (eql hotkey (portal-launcher-gui--hotkey)))
          (should-not (portal-test-hotkey hotkey t))
          ;; Enabling again, as reloading a configuration does, ignores a
          ;; press from before.
          (portal-test-hotkey (portal-launcher-gui--hotkey) t)
          (portal-view--read-records)
          (portal-launcher-mode 1)
          (portal-launcher-gui--command-loop)
          (should-not (plist-get (portal--launcher-inspect) :visible))
          (portal-test-hotkey (portal-launcher-gui--hotkey) nil))
	(portal-launcher-mode -1)
	(should-not (assq 'portal-launcher portal-global-shortcut--registrations))))))

(defvar portal-launcher-gui--action nil)
(defun portal-launcher-gui--act ()
  (interactive)
  (funcall portal-launcher-gui--action))

(defun portal-launcher-gui--present (command strokes &optional action options)
  "Run COMMAND with native STROKES typed into its prompts; C-] calls ACTION.
OPTIONS are `portal-launcher-present' keywords and values.  With
:keep-open, STROKES also go to the panel's buffer after COMMAND returns."
  (let* ((portal-launcher-gui--action action)
         ;; A runner may call ERT from a timer, where quit is inhibited. Real
         ;; command-loop invocation permits native C-g to unwind a minibuffer.
         (inhibit-quit nil)
         (quit-flag nil)
         (map (make-sparse-keymap))
         (global (current-global-map))
         (depth (recursion-depth))
         (timer (run-with-timer
                 0.1 0.1
                 (lambda ()
                   ;; Deeper means a prompt, or a persistent panel's buffer.
                   (when (and strokes (> (recursion-depth) depth))
                     (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
                     (let ((stroke (pop strokes)))
                       ;; Synthetic AppKit C-g gets held by this Emacs build
                       ;; even in an ordinary read-string. Queue the Emacs
                       ;; event for this one key; other strokes are native.
                       (if (eq stroke 'quit)
                           (setq unread-command-events (append unread-command-events '(7)))
                         (apply #'portal-test-native-post-key stroke))))))))
    (set-keymap-parent map global)
    (keymap-set map "C-]" #'portal-launcher-gui--act)
    (use-global-map map)
    (unwind-protect
        (prog1 (with-timeout (10 (error "Launcher prompt timed out; pending input: %S" strokes))
                 (apply #'portal-launcher-present command options))
          (should-not strokes)
          (should (= depth (recursion-depth)))
          (should-not (active-minibuffer-window))
          (should-not portal-launcher--session)
          (should-not (plist-get (portal--launcher-inspect) :visible))
          (when (frame-live-p portal-launcher--frame)
            (should-not (frame-visible-p portal-launcher--frame))))
      (cancel-timer timer)
      (portal-test-native-target-frame nil)
      (use-global-map global))))

(defun portal-launcher-gui--text (text)
  (let ((codes '((?a . 0) (?b . 11) (?c . 8) (?d . 2) (?e . 14) (?f . 3)
                 (?g . 5) (?h . 4) (?i . 34) (?j . 38) (?k . 40) (?l . 37)
                 (?m . 46) (?n . 45) (?o . 31) (?p . 35) (?q . 12) (?r . 15)
                 (?s . 1) (?t . 17) (?u . 32) (?v . 9) (?w . 13) (?x . 7)
                 (?y . 16) (?z . 6) (?! . 18) (?- . 27) (?\s . 49))))
    (mapcar (lambda (char)
              (list (alist-get (downcase char) codes) (if (or (<= ?A char ?Z) (= char ?!)) 131072 0)
                    (string char))) text)))

(ert-deftest portal-launcher-gui-application-picker ()
  (require 'launcher)
  (require 'vertico)
  (require 'orderless)
  (require 'marginalia)
  (portal-launcher-gui--with-panel
    (let* ((launcher--apps '(("Calculator" . "/System/Applications/Calculator.app")))
           (launcher--current-entries nil)
           (reader completing-read-function)
           actions)
      (dolist (enhanced '(nil t))
        (let ((completion-styles (if enhanced '(orderless basic) '(basic)))
              (completion-category-defaults nil))
          (vertico-mode (if enhanced 1 -1))
          (marginalia-mode (if enhanced 1 -1))
          (unwind-protect
              (cl-letf (((symbol-function 'call-process)
                         (lambda (&rest arguments) (push arguments actions) 0))
                        ((symbol-function 'browse-url) (lambda (url &rest _) (push url actions))))
                ;; nil exercises the configured default through the session.
                (portal-launcher-gui--present
                 nil (append (portal-launcher-gui--text "Calculator") '((36 0 "\r"))))
                (should (equal (pop actions) '("open" nil nil nil "-a" "/System/Applications/Calculator.app")))
                (portal-launcher-gui--present
                 nil (append (portal-launcher-gui--text "!gh portal launcher") '((36 0 "\r"))))
                (should (equal (pop actions) "https://github.com/search?q=portal%20launcher"))
                (let ((launcher-bangs nil)) (portal-launcher-gui--present nil '((36 0 "\r"))))
                (when enhanced
                  (should (equal (pop actions)
                                 '("open" nil nil nil "-a" "/System/Applications/Calculator.app"))))
                (portal-launcher-gui--present nil '((53 0 "\e")))
                (should-not actions))
            (vertico-mode -1)
            (marginalia-mode -1)))
        (should (eq reader completing-read-function))
        (should (eq ordinary (selected-window)))
        (should-not launcher--current-entries)))))

(ert-deftest portal-launcher-gui-accepts-selection-without-typing ()
  (require 'launcher)
  (require 'vertico)
  (require 'orderless)
  (portal-launcher-gui--with-panel
    (let ((launcher--apps '(("Calculator" . "/System/Applications/Calculator.app")
                            ("Calendar" . "/System/Applications/Calendar.app")))
          (launcher--current-entries nil)
          (launcher-bangs nil)
          (minibuffer-history nil)
          (vertico-sort-function #'identity)
          (completion-styles '(orderless basic))
          actions)
      (vertico-mode 1)
      (unwind-protect
          (cl-letf (((symbol-function 'call-process)
                     (lambda (&rest arguments) (push arguments actions) 0)))
            (dolist (selection '(("Calculator" (36 0 "\r"))
                                 ("Calendar" (125 0 "\uf701") (36 0 "\r"))
                                 ("Calculator" (125 0 "\uf701") (126 0 "\uf700") (36 0 "\r"))))
              (portal-launcher-gui--present nil (cdr selection))
              (should (equal (pop actions)
                             (list "open" nil nil nil "-a"
                                   (cdr (assoc (car selection) launcher--apps)))))))
        (vertico-mode -1)))))

(ert-deftest portal-launcher-gui-session-stock-and-completion-stack ()
  (portal-launcher-gui--with-panel
    (require 'vertico)
    (require 'orderless)
    (require 'marginalia)
    (dolist (enhanced '(nil t))
      (let* ((completion-styles (if enhanced '(orderless basic) '(basic)))
             (completion-category-defaults nil)
             (rules display-buffer-alist)
             (maps emulation-mode-map-alists)
             frames visible
             (minibuffer-setup-hook
              (cons (lambda ()
                      (push (window-frame (active-minibuffer-window)) frames)
                      (push (and (frame-visible-p portal-launcher--frame)
                                 (plist-get (portal--launcher-inspect) :visible)) visible))
                    minibuffer-setup-hook)))
        (vertico-mode (if enhanced 1 -1))
        (marginalia-mode (if enhanced 1 -1))
        (unwind-protect
            (should
             (equal "forward-line"
                    (portal-launcher-gui--present
                     (lambda ()
                       (interactive)
                       (completing-read
                        "Command: "
                        (lambda (string predicate action)
                          (if (eq action 'metadata) '(metadata (category . command))
                            (complete-with-action action '("forward-line" "forward-char") string predicate)))
                        nil t))
                     (append (portal-launcher-gui--text (if enhanced "line for" "forward-line"))
                             '((36 0 "\r"))))))
          (vertico-mode -1)
          (marginalia-mode -1))
        (should (equal frames (list portal-launcher--frame)))
        (should (equal visible '(t)))
        (should (eq rules display-buffer-alist))
        (should (eq maps emulation-mode-map-alists))
        (should (eq (selected-window) ordinary))))))

;; Set PORTAL_LAUNCHER_SCREENSHOTS to a directory to keep pictures of the panel.
(defun portal-launcher-gui--capture (name)
  "Save the panel's Emacs drawing as NAME.png in $PORTAL_LAUNCHER_SCREENSHOTS."
  (when-let* ((directory (getenv "PORTAL_LAUNCHER_SCREENSHOTS")))
    (redisplay t)
    (portal-view--with-frame-title portal-launcher--frame #'portal-test-native-target-frame)
    (unwind-protect
        (should (portal-test-capture-target (expand-file-name (concat name ".png") directory)))
      (portal-test-native-target-frame nil))))

(defun portal-launcher-gui--minibuffer-layout ()
  "Describe the minibuffer launcher's layout, from inside its prompt."
  (redisplay t)
  (let* ((frame portal-launcher--frame)
         (mini (active-minibuffer-window))
         (state (portal--launcher-inspect)))
    (list :input (minibuffer-contents)
          :kind (portal-launcher--kind frame)
          :windows (equal (window-list frame t) (list mini))
          :root (eq (frame-root-window frame) mini)
          :top (- (cadr (window-pixel-edges mini)) (frame-internal-border-width frame))
          :spare (- (frame-pixel-height frame) (* 2 (frame-internal-border-width frame))
                    (window-pixel-height mini))
          :clipped (- (cdr (window-text-pixel-size mini nil nil nil nil t))
                      (window-pixel-height mini))
          :mode-line (window-mode-line-height mini)
          ;; Vertico starts its candidates with a newline and ends each with one.
          :candidates (and (bound-and-true-p vertico--candidates-ov)
                           (1- (cl-count ?\n (overlay-get vertico--candidates-ov 'before-string))))
          :index (bound-and-true-p vertico--index)
          :size (list (frame-pixel-width frame) (frame-pixel-height frame))
          :native (equal (plist-get state :requested) (plist-get state :actual))
          :actual (plist-get state :actual))))

(ert-deftest portal-launcher-gui-minibuffer-panel-vertico ()
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (dolist (size '((720 420) (640 320)))
      (let ((portal-launcher-size size)
            (vertico-sort-function nil) (vertico-count 10)
            (completion-styles '(basic)) (completion-category-defaults nil)
            layouts)
        (vertico-mode 1)
        (unwind-protect
            (should
             (equal "al02"
                    (portal-launcher-gui--present
                     (lambda ()
                       (minibuffer-with-setup-hook
                           (lambda ()
                             (add-hook 'post-command-hook
                                       (lambda () (push (portal-launcher-gui--minibuffer-layout) layouts))
                                       90 t))
                         (completing-read
                          "Pick: " (cons "beta" (mapcar (lambda (n) (format "al%02d" n))
                                                        (number-sequence 1 15)))
                          nil t)))
                     (append (portal-launcher-gui--text "al")
                             '((125 0 "\uf701"))
                             ;; A no-op key, so the layout after Down is
                             ;; pictured once Vertico has redrawn.
                             '((30 262144 "\C-]")) '((36 0 "\r")))
                     (lambda () (portal-launcher-gui--capture (format "minibuffer-vertico-%dx%d" (car size) (cadr size))))
                     '(:kind minibuffer))))
          (vertico-mode -1))
        (let ((layout (cadr layouts)))
          (message "Launcher minibuffer layout %S: %S" size layout)
          (should (equal (plist-get layout :input) "al"))
          (should (eq (plist-get layout :kind) 'minibuffer))
          ;; The minibuffer is the panel's only window: no buffer or mode line
          ;; above it, and the prompt starts at the top of the text area.
          (should (plist-get layout :windows))
          (should (plist-get layout :root))
          (should (= 0 (plist-get layout :top)))
          (should (= 0 (plist-get layout :spare)))
          (should (= 0 (plist-get layout :mode-line)))
          ;; Ten candidates of fifteen, the second selected, none clipped.
          (should (= 10 (plist-get layout :candidates)))
          (should (= 1 (plist-get layout :index)))
          (should (<= (plist-get layout :clipped) 0))
          (should (equal (plist-get layout :size) size))
          (should (plist-get layout :native))
          (should (equal (cddr (plist-get layout :actual)) size)))))))

(ert-deftest portal-launcher-gui-minibuffer-panel-stock-completion ()
  (portal-launcher-gui--with-panel
    (let ((windows (window-list (window-frame ordinary) t))
          shown)
      ;; Tab completes and Return accepts, but *Completions* shows nowhere.
      (should
       (equal "alpha"
              (portal-launcher-gui--present
               (lambda ()
                 (minibuffer-with-setup-hook
                     (lambda ()
                       (add-hook 'post-command-hook
                                 (lambda ()
                                   (push (list (minibuffer-contents)
                                               (get-buffer-window "*Completions*" t))
                                         shown))
                                 90 t))
                   (completing-read "Pick: " '("alpha" "alps" "beta") nil t)))
               (append (portal-launcher-gui--text "a") '((48 0 "\t") (48 0 "\t"))
                       (portal-launcher-gui--text "ha") '((36 0 "\r")))
               nil '(:kind minibuffer))))
      (should (member '("alp" nil) shown))
      (should-not (cl-some #'cadr shown))
      (should (equal windows (window-list (window-frame ordinary) t))))))

(ert-deftest portal-launcher-gui-buffer-panel-mode-lines ()
  (portal-launcher-gui--with-panel
    (let ((format (buffer-local-value 'mode-line-format ordinary-buffer))
          (ordinary-height (window-mode-line-height ordinary)))
      (should (> ordinary-height 0))
      (dolist (mode-line '(t nil))
        (let ((heights
               (portal-launcher-present
                (lambda ()
                  (cl-flet ((height (window) (redisplay t) (window-mode-line-height window)))
                    (let* ((first (selected-window))
                           (initial (height first))
                           (second (split-window first))
                           (split (height second)))
                      ;; Both launcher windows switch buffers; one shows the
                      ;; ordinary window's buffer.
                      (switch-to-buffer ordinary-buffer)
                      (set-window-buffer second content)
                      (with-current-buffer content (insert (format "Mode lines: %s\n" mode-line)))
                      (prog1 (list initial split (height first) (height second)
                                   (window-mode-line-height ordinary))
                        (portal-launcher-gui--capture (format "buffer-mode-line-%s" mode-line))))))
                :mode-line mode-line)))
          (message "Launcher mode lines %S: %S" mode-line heights)
          (should (equal (car (last heights)) ordinary-height))
          (should (cl-every (if mode-line (lambda (height) (> height 0)) #'zerop) (butlast heights)))
          ;; The call's split is gone, and the parameter and hook with it.
          (should (equal (window-list portal-launcher--frame 'never)
                         (list (frame-first-window portal-launcher--frame))))
          (should-not (window-parameter (frame-first-window portal-launcher--frame) 'mode-line-format))
          (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
          (should (eq format (buffer-local-value 'mode-line-format ordinary-buffer)))
          (should (= ordinary-height (window-mode-line-height ordinary)))))
      ;; A window's own mode-line parameter outlasts both settings, and an
      ;; explicit show leaves it alone.
      (let ((window (frame-first-window portal-launcher--frame))
            (custom '("Custom mode line")))
        (set-window-parameter window 'mode-line-format custom)
        (dolist (mode-line '(nil t))
          (should (equal (if mode-line custom 'none)
                         (portal-launcher-present
                          (lambda () (window-parameter (selected-window) 'mode-line-format))
                          :mode-line mode-line)))
          (should (equal custom (window-parameter window 'mode-line-format))))
        (portal-launcher-show content)
        (should (equal custom (window-parameter window 'mode-line-format)))
        (portal-launcher-hide)))))

(ert-deftest portal-launcher-gui-alternating-kinds ()
  (require 'vertico)
  (portal-launcher-gui--with-panel
    (let ((settings (list display-buffer-alist display-buffer-overriding-action resize-mini-frames
                          window-buffer-change-functions emulation-mode-map-alists
                          enable-recursive-minibuffers default-minibuffer-frame pop-up-frames
                          completing-read-function))
          (frames (length (frame-list)))
          timings)
      ;; Presenting while an explicitly shown launcher is selected returns to
      ;; the window it was shown from, even when the frame is replaced.
      (dolist (kind '(buffer minibuffer))
        (portal-launcher-show content)
        (should (eq (selected-frame) portal-launcher--frame))
        (should (eq kind (portal-launcher-present (lambda () kind) :kind kind)))
        (should (eq (selected-window) ordinary)))
      (dolist (options '((:kind minibuffer) (:kind buffer :mode-line nil) (:kind minibuffer)
                         (:mode-line t) (:kind buffer :mode-line nil) (:kind minibuffer :mode-line nil)
                         (:kind minibuffer) ()))
        (let* ((kind (or (plist-get options :kind) 'buffer))
               (start (float-time))
               (state (portal-launcher-gui--present
                       (lambda ()
                         (push (list options (- (float-time) start)) timings)
                         (list (portal-launcher--kind portal-launcher--frame) (length (frame-list))
                               (read-string "Name: ")))
                       (append (portal-launcher-gui--text "ok") '((36 0 "\r"))) nil options)))
          (should (equal state (list kind (1+ frames) "ok")))
          (should (= (length (frame-list)) (1+ frames)))
          (should (plist-get (portal--launcher-inspect) :attached))
          (should (portal-launcher--live-p kind))
          (when (eq kind 'buffer)
            (should (= 1 (length (window-list portal-launcher--frame 'never))))
            (should-not (window-parameter (frame-first-window portal-launcher--frame) 'mode-line-format)))
          (should (equal settings
                         (list display-buffer-alist display-buffer-overriding-action resize-mini-frames
                               window-buffer-change-functions emulation-mode-map-alists
                               enable-recursive-minibuffers default-minibuffer-frame pop-up-frames
                               completing-read-function)))))
      (message "Launcher show times (s): %S" (nreverse timings))
      ;; A split made in an explicitly shown panel outlives a presentation;
      ;; the window the call creates does not.
      (portal-launcher-show content)
      (let ((kept (split-window (frame-first-window portal-launcher--frame))))
        (portal-launcher-hide)
        (portal-launcher-present (lambda () (split-window)) :mode-line nil)
        (should (window-live-p kept))
        (should (= 2 (length (window-list portal-launcher--frame 'never))))
        (should (eq (selected-window) ordinary)))
      ;; Ordinary prompts behave as before, in the ordinary frame, with stock
      ;; completion's list there and with Vertico.
      (dolist (enhanced '(nil t))
        (vertico-mode (if enhanced 1 -1))
        (unwind-protect
            (let (minibuffer-frame completions-frame)
              (should
               (equal "alpha"
                      (minibuffer-with-setup-hook
                          (lambda ()
                            (setq minibuffer-frame (window-frame (active-minibuffer-window)))
                            (add-hook 'post-command-hook
                                      (lambda ()
                                        (when-let* ((window (get-buffer-window "*Completions*" t)))
                                          (setq completions-frame (window-frame window))))
                                      nil t))
                        (let ((unread-command-events
                               (listify-key-sequence (kbd (if enhanced "a l p h a RET"
                                                            "a l TAB TAB h a RET")))))
                          (completing-read "Pick: " '("alpha" "alps") nil t)))))
              (should (eq minibuffer-frame (window-frame ordinary)))
              (unless enhanced (should (eq completions-frame (window-frame ordinary)))))
          (vertico-mode -1))))))

(ert-deftest portal-launcher-gui-session-nested-dismissal-and-reentry ()
  (portal-launcher-gui--with-panel
    (dolist (kind '(buffer minibuffer))
      (dolist (reason '(escape quit second shortcut hide delete disable))
        (message "Launcher nested dismissal: %S %S" kind reason)
        (let (frames continued)
          (portal-launcher-gui--present
           (lambda ()
             (interactive)
             (minibuffer-with-setup-hook
                 (lambda ()
                   (push (window-frame (active-minibuffer-window)) frames)
                   (minibuffer-with-setup-hook
                       (lambda () (push (window-frame (active-minibuffer-window)) frames))
                     (completing-read "Inner: " '("alpha") nil t)))
               (completing-read "Outer: " '("alpha") nil t))
             (setq continued t))
           (list (pcase reason ('escape '(53 0 "\e")) ('quit 'quit)
                        (_ '(30 262144 "\C-]"))))
           (lambda ()
             (pcase reason
               ('second (portal-launcher-present))
               ('shortcut
                (portal-test-hotkey (portal-launcher-gui--hotkey) t)
                (portal-test-hotkey (portal-launcher-gui--hotkey) nil)
                (portal-view--read-records))
               ('hide (portal-launcher-hide))
               ('delete (delete-frame portal-launcher--frame t))
               ('disable (portal-launcher-mode -1))))
           (list :kind kind))
          (should-not continued)
          (should (= (length frames) 2))
          (should (eq (car frames) (cadr frames)))
          (should-not (eq (car frames) (window-frame ordinary)))
          (when (frame-live-p (car frames))
            (should (eq kind (portal-launcher--kind (car frames)))))
          (should (eq ordinary (selected-window)))
          (when (eq reason 'disable) (should-not portal-launcher-mode))
          (when (memq reason '(delete disable)) (should-not (frame-live-p (car frames))))
          ;; Re-entry works, in a buffer launcher even after a minibuffer one.
          (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again))))
          (should (portal-launcher--live-p 'buffer)))))))

(ert-deftest portal-launcher-gui-session-command-error ()
  (portal-launcher-gui--with-panel
    (dolist (kind '(buffer minibuffer))
      (let (read-finished)
        (should (equal '(error "Command failed")
                       (should-error
                        (portal-launcher-gui--present
                         (lambda () (read-string "Before error: ")
                           (setq read-finished t) (error "Command failed"))
                         '((36 0 "\r")) nil (list :kind kind :mode-line nil)))))
        (should read-finished))
      (should-not (active-minibuffer-window))
      (should-not portal-launcher--session)
      (should-not (plist-get (portal--launcher-inspect) :visible))
      (should (eq ordinary (selected-window)))
      (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
      (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again) :kind kind))))))

(ert-deftest portal-launcher-gui-session-focus-loss ()
  (portal-launcher-gui--with-panel
    (dolist (kind '(buffer minibuffer))
      (let (continued)
        (portal-launcher-gui--present
         (lambda () (interactive) (read-string "Focus away: ") (setq continued t))
         '((30 262144 "\C-]"))
         (lambda ()
           (portal-view--with-frame-title (window-frame ordinary) #'portal-test-native-target-frame)
           (portal-test-native-focus-target))
         (list :kind kind))
        (should-not continued)
        (should (eq ordinary (selected-window)))))))

(defvar portal-launcher-gui--prompts nil
  "For each prompt a hello command opened, whether it was in the panel.")

(defun portal-launcher-gui--hello (&rest bindings)
  "Set up the hello-world UI, with local BINDINGS of (KEY . COMMAND).
The local command n reads a name in the minibuffer and greets it."
  (switch-to-buffer (get-buffer-create "*Hello*"))
  (let ((inhibit-read-only t)) (erase-buffer) (insert "Hello world!"))
  (special-mode)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (keymap-set map "n" #'portal-launcher-gui--greet)
    (pcase-dolist (`(,key . ,command) bindings) (keymap-set map key command))
    (use-local-map map)))

(defun portal-launcher-gui--greet ()
  "Greet a name read from the minibuffer."
  (interactive)
  (let ((name (minibuffer-with-setup-hook
                  (lambda ()
                    (push (eq (window-frame (active-minibuffer-window)) portal-launcher--frame)
                          portal-launcher-gui--prompts))
                (read-string "Name: ")))
        (inhibit-read-only t))
    (goto-char (point-max))
    (insert "\nHello " name "!")))

(defun portal-launcher-gui--check-unwound ()
  "Check that a persistent presentation left no hooks or session."
  (should-not portal-launcher--session)
  (should-not (memq #'portal-launcher--dismiss-if-blurred (default-value 'post-command-hook)))
  (should-not (memq #'portal-launcher--hide-mode-lines window-buffer-change-functions))
  (should-not (cl-find 'portal-launcher-blur unread-command-events :key #'car-safe)))

(ert-deftest portal-launcher-gui-persistent-buffer ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (let ((depth (recursion-depth)) (portal-launcher-gui--prompts nil) state)
          ;; The setup function returns at once; a local command, then its
          ;; prompt, read native keys in the panel.
          (should-not
           (portal-launcher-gui--present
            #'portal-launcher-gui--hello
            (append (portal-launcher-gui--text "nok") '((36 0 "\r") (30 262144 "\C-]") (53 0 "\e")))
            (lambda ()
              (redisplay t)
              (setq state (list :session (and portal-launcher--session t)
                                :depth (- (recursion-depth) depth)
                                :visible (and (frame-visible-p portal-launcher--frame)
                                              (plist-get (portal--launcher-inspect) :visible))
                                :key (plist-get (portal--launcher-inspect) :key)
                                :window (eq (window-frame) portal-launcher--frame)
                                :buffer (buffer-name) :text (buffer-string)
                                :mode-line (window-mode-line-height)))
              (portal-launcher-gui--capture "persistent-hello"))
            '(:kind buffer :mode-line nil :keep-open t)))
          (message "Launcher persistent buffer: %S" state)
          (should (equal state '(:session t :depth 1 :visible t :key t :window t :buffer "*Hello*"
                                 :text "Hello world!\nHello ok!" :mode-line 0)))
          (should (equal portal-launcher-gui--prompts '(t)))
          (portal-launcher-gui--check-unwound)
          (should (eq ordinary (selected-window)))
          ;; Hiding kept the buffer and its contents.
          (should (equal "Hello world!\nHello ok!" (with-current-buffer "*Hello*" (buffer-string))))
          ;; Without :keep-open the panel hides as the function returns.
          (should (eq 'closed (portal-launcher-present (lambda () (portal-launcher-gui--hello) 'closed)
                                                       :mode-line nil)))
          (should-not (plist-get (portal--launcher-inspect) :visible)))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-persistent-dismissal-and-reentry ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (dolist (prompt '(nil t))
          (dolist (reason '(escape quit second shortcut hide delete disable focus))
            (message "Launcher persistent dismissal: %S %S" (if prompt 'prompt 'buffer) reason)
            (let ((portal-launcher-gui--prompts nil) frame)
              (should-not
               (portal-launcher-gui--present
                (lambda () (setq frame portal-launcher--frame) (portal-launcher-gui--hello))
                (append (when prompt (portal-launcher-gui--text "na"))
                        (list (pcase reason ('escape '(53 0 "\e")) ('quit 'quit)
                                     (_ '(30 262144 "\C-]")))))
                (lambda ()
                  (pcase reason
                    ('second (portal-launcher-present))
                    ('shortcut
                     (portal-test-hotkey (portal-launcher-gui--hotkey) t)
                     (portal-test-hotkey (portal-launcher-gui--hotkey) nil)
                     (portal-view--read-records))
                    ('hide (portal-launcher-hide))
                    ('delete (delete-frame portal-launcher--frame t))
                    ('disable (portal-launcher-mode -1))
                    ('focus
                     (portal-view--with-frame-title (window-frame ordinary)
                                                    #'portal-test-native-target-frame)
                     (portal-test-native-focus-target))))
                '(:mode-line nil :keep-open t)))
              (should (equal portal-launcher-gui--prompts (and prompt '(t))))
              (portal-launcher-gui--check-unwound)
              (should (eq ordinary (selected-window)))
              (should (equal "Hello world!" (with-current-buffer "*Hello*" (buffer-string))))
              (should (eq (and (frame-live-p frame) t) (not (memq reason '(delete disable)))))
              (when (eq reason 'disable) (should-not portal-launcher-mode))
              (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again)))))))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-persistent-command-errors ()
  (portal-launcher-gui--with-panel
    (unwind-protect
        (let ((messages (with-current-buffer "*Messages*" (point-max-marker))) state)
          ;; A later command's error is reported; then a command and its
          ;; prompt still work, until Escape.
          (should-not
           (portal-launcher-gui--present
            (lambda ()
              (portal-launcher-gui--hello
               (cons "e" (lambda () (interactive) (error "Later command failed")))))
            (append (portal-launcher-gui--text "enok") '((36 0 "\r") (30 262144 "\C-]") (53 0 "\e")))
            (lambda ()
              (setq state (list (and portal-launcher--session t)
                                (plist-get (portal--launcher-inspect) :visible)
                                (buffer-string))))
            '(:keep-open t)))
          (should (equal state '(t t "Hello world!\nHello ok!")))
          (should (with-current-buffer "*Messages*"
                    (save-excursion
                      (goto-char messages)
                      (search-forward "Later command failed" nil t))))
          (portal-launcher-gui--check-unwound)
          ;; Focus lost while a command runs, then discarded with the queued
          ;; input by Emacs's error report, still hides the panel, from the
          ;; buffer and from a prompt.
          (dolist (prompt '(nil t))
            (let (queued)
              (should-not
               (portal-launcher-gui--present
                #'portal-launcher-gui--hello
                (append (when prompt (portal-launcher-gui--text "n")) '((30 262144 "\C-]")))
                (lambda ()
                  (portal-view--with-frame-title (window-frame ordinary)
                                                 #'portal-test-native-target-frame)
                  (portal-test-native-focus-target)
                  (with-timeout (3 (error "The panel did not lose focus"))
                    (while (not (portal-launcher--session-blurred portal-launcher--session))
                      (accept-process-output nil 0.05)))
                  (setq queued (and (cl-find 'portal-launcher-blur unread-command-events :key #'car-safe) t))
                  (error "Failed after focus loss"))
                '(:keep-open t)))
              (should queued)
              (portal-launcher-gui--check-unwound)
              (should (eq ordinary (selected-window)))))
          (should (eq 'again (portal-launcher-present (lambda () (interactive) 'again)))))
      (kill-buffer "*Hello*"))))

(ert-deftest portal-launcher-gui-z-session-external-focus ()
  (portal-launcher-gui--with-panel
    ;; These are already-running, independent applications. Test both external
    ;; activation during a prompt and a command that opens an app and returns.
    (let ((previous (portal-test-frontmost)))
      (dolist (options '((:kind buffer) (:kind minibuffer) (:kind buffer) (:keep-open t)))
        (portal-launcher-gui--present
         (if (plist-get options :keep-open) #'portal-launcher-gui--hello
           (lambda () (interactive) (read-string "Cancel: ")))
         '((53 0 "\e")) nil options)
        (sit-for 0.1)
        (message "Launcher %S cancellation frontmost: %S (previous %S)"
                 options (portal-test-frontmost) previous)
        (should (eql previous (portal-test-frontmost)))))
    ;; A persistent panel's command that activates another app leaves that
    ;; app in front, as the panel hides on losing focus.
    (dolist (app (list (portal-test-frontmost -1) "com.apple.finder"))
      (let (activated)
        (should app)
        (portal-launcher-gui--present
         (lambda ()
           (portal-launcher-gui--hello
            (cons "o" (lambda () (interactive) (setq activated (portal-test-frontmost app))))))
         (portal-launcher-gui--text "o") nil '(:keep-open t))
        (with-timeout (3 (error "The panel's command did not activate %S" app))
          (while (not (eql activated (portal-test-frontmost))) (sit-for 0.05)))
        (message "Launcher persistent activation frontmost: %S (expected %S)"
                 (portal-test-frontmost) activated)
        (should (eql activated (portal-test-frontmost)))
        (should (eq ordinary (selected-window)))
        ;; AppKit can report the activation once the next session watches.
        (portal-launcher-gui--settle-focus)))
    (kill-buffer "*Hello*")
    (let ((destination (portal-test-frontmost -1)) continued)
      (should destination)
      (portal-launcher-gui--present
       (lambda () (interactive) (read-string "Activate another app: ") (setq continued t))
       '((30 262144 "\C-]")) (lambda () (portal-test-frontmost destination)))
      (should-not continued)
      (should (eql destination (portal-test-frontmost))))
    (let (finder)
      (portal-launcher-present
       (lambda () (interactive) (setq finder (portal-test-frontmost "com.apple.finder"))))
      (with-timeout (3 (error "Successful app launch did not activate Finder"))
        (while (not (eql finder (portal-test-frontmost))) (sit-for 0.05)))
      (message "Launcher success frontmost: %S (expected Finder %S)" (portal-test-frontmost) finder)
      (should (eql finder (portal-test-frontmost)))
      (should (eq ordinary (selected-window))))))

(provide 'portal-launcher-gui-tests)
