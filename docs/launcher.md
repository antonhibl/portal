# Configure launchers and global shortcuts

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

- [Global shortcuts](#global-shortcuts): register functions without showing a panel
- [Native launcher panel](#native-launcher-panel-opt-in): examples and setup
- [Set up safely](#set-up-safely): compatibility and fresh-session requirements
- [Migrate from the built-in launcher](#migrate-from-the-built-in-launcher)
- [Presentation options and lifecycle](#presentation-options-and-lifecycle)

## Global shortcuts

A global shortcut calls a Lisp function when its chord is pressed in any
application. It does not activate Emacs, select a frame or show a panel, so the
function decides what appears. Loading Portal registers nothing. Name each
shortcut with a symbol:

```elisp
(defun my/play-pause ()
  (interactive)
  (call-process "osascript" nil 0 nil "-e" "tell application \"Music\" to playpause"))

(portal-global-shortcut-set 'play-pause "Control-Option-Command-M" #'my/play-pause)
(portal-global-shortcut-set 'time "Control-Option-Command-T"
                            (let ((pattern "%H:%M"))
                              (lambda () (message "%s" (format-time-string pattern)))))
(portal-global-shortcut-remove 'time)    ; t, or nil when TIME was not set
```

Setting a name again replaces its chord and function and releases the old
chord, so evaluating a configuration again leaves one registration per name.
An interactive command runs with `call-interactively`; any other function of no
arguments runs with `funcall`, so a lambda can capture what it needs. Capturing,
as `pattern` above, needs lexical binding: start the configuration file with
`;;; -*- lexical-binding: t -*-`. Emacs 31 still loads a file without that line
with dynamic binding, where such a lambda signals `void-variable` when pressed.
`portal-global-shortcut-set` returns the name. It signals an error and changes
nothing for a name that is not a non-nil symbol, a function that needs
arguments, invalid notation, a chord another name has (the message names it), or
a chord that macOS refuses because the system or another application has it.
`portal-global-shortcut-remove` returns t when the name was set and nil
otherwise; it signals only if macOS cannot release the chord, and then keeps it.

The notation is case-insensitive, hyphen-separated modifier names (`Control`,
`Option`, `Command`, `Shift`) followed by `A`–`Z`, `0`–`9`, `Space`, or `F1`–`F20`.
At least one of Control, Option or Command is required, with no duplicate
modifiers. Letters and digits refer to **US physical key positions**, independent
of the input layout and Emacs's `ns-*-modifier` settings. Shift must be explicit;
capital letters in the notation do not imply it. Fn, Caps Lock, punctuation,
left/right modifier distinctions and multi-key sequences are unsupported.
Function keys require the keyboard to send the function key rather than its
media action. Two spellings of one chord, such as `command-control-option-p`,
are the same chord. System-reserved shortcuts and other hotkey utilities can
still intercept keys; choose another chord if one registers but is not
delivered.

The native module registers each chord with Carbon. A press sends a record
through Portal's notification pipe, even with no Portal view open; it needs
neither a subprocess nor an Accessibility event tap. The pipe's filter only
queues an input event, and the command loop calls the function, as for a key
bound to it, during a minibuffer prompt too. Emacs must be running, and busy
Lisp delays the call; there is no responsiveness guarantee. Holding a chord
calls the function once. A press while an earlier press of the same shortcut
still waits is dropped, and so is a press from before its name was last set or
removed. A press that arrives in the middle of a key sequence, or while a
prompt reads a single key, is read there instead and calls nothing.

An error in the function is shown as a message naming the shortcut. Every
shortcut stays set, and unlike other commands' errors it discards no waiting
input, such as another shortcut's press; with `debug-on-error`, the debugger
shows it. Unloading `portal-global-shortcut` or exiting Emacs releases every
chord; if one cannot be released, unloading fails and the feature stays loaded. Removing one shortcut, or disabling or deleting the launcher panel,
leaves the others.

## Native launcher panel (opt-in)

`portal-launcher.el` presents Emacs functions in one reusable, borderless,
nonactivating macOS panel. It uses Portal's existing module. Portal chooses no
command and claims no chord: loading the feature, presenting a panel and
enabling `portal-launcher-mode` register no global shortcut. Your configuration
composes launchers. A command calls `portal-launcher-present` with its
presentation options; run it with M-x, bind it to an Emacs key, or set it as a
[global shortcut](#global-shortcuts) to invoke it from any application. The
examples below need no other package, and they work whether or not your
configuration file enables `lexical-binding`.

The panel passed the user's daily-use checklist on 2026-10-04, with the
application picker that Portal then included. See the
[setup and validation guide](launcher-daily-use.md) for the tested versions,
fresh-session procedure and manual input/accessibility results.

Before trying these examples, follow [Set up safely](#set-up-safely): the panel
uses internal Emacs NS interfaces, accepts only the pinned Emacs build, and
requires native subroutine trampolines. Use a fresh disposable graphical Emacs.

### A minimal picker

After building and loading Portal:

<!-- example: launcher-picker -->
```elisp
(require 'portal-launcher)

(defun my/pick-fruit ()
  "Pick a fruit in Portal's panel and show the choice."
  (interactive)
  (message "Picked %s"
           (portal-launcher-present
            (lambda () (completing-read "Fruit: " '("Apple" "Banana" "Cherry") nil t))
            :kind 'minibuffer)))

(keymap-global-set "C-c f" #'my/pick-fruit)
```

`M-x my/pick-fruit` and `C-c f` run the same command, which shows only the
prompt and an inline completion UI, such as Vertico, in the panel.
`portal-launcher-present` returns the function's value, here the fruit, or nil
when the panel is dismissed.

### A persistent buffer

A buffer UI, such as a dashboard, can stay open after the function that sets
it up returns:

<!-- example: launcher-hello -->
```elisp
(define-derived-mode my/hello-mode special-mode "Hello")
(keymap-set my/hello-mode-map "n" #'my/hello-greet)

(defun my/hello-greet (name)
  (interactive "sName: ")
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert "\nHello " name "!")))

(defun my/hello ()
  (interactive)
  (portal-launcher-present
   (lambda ()
     (switch-to-buffer (get-buffer-create "*Hello*"))
     (let ((inhibit-read-only t))
       (erase-buffer)
       (insert "Hello world!"))
     (my/hello-mode))
   :kind 'buffer :mode-line nil :keep-open t))
```

With `:keep-open t`, commands then run in the panel, here `n`, and their
prompts use its minibuffer, until it is dismissed as described below; the call
returns nil then. The session's display rules, Escape and C-g, and focus
handling last until then. An error in a later command is reported and the
panel stays open. Dismissal kills no buffer, so `*Hello*` keeps its contents.
`:keep-open` defaults to nil, which hides the panel when the function
returns, and needs `:kind 'buffer`. While the panel is open, Emacs is in a
recursive edit, so the default mode line shows brackets around the mode
name.

### Global shortcuts for launchers

Set a global shortcut for each launcher that should open from any
application. A shortcut need not present a panel:

<!-- example: launcher-shortcuts -->
```elisp
(portal-global-shortcut-set 'pick-fruit "Control-Option-Command-F" #'my/pick-fruit)
(portal-global-shortcut-set 'hello "Control-Option-Command-H" #'my/hello)
(portal-global-shortcut-set 'clock "Control-Option-Command-K"
                            (lambda () (message "%s" (format-time-string "%H:%M"))))
```

Remove one with `(portal-global-shortcut-remove 'hello)`; the others stay set.
Shortcuts and the panel have separate lifetimes: dismissing, hiding or deleting
the panel, or disabling `portal-launcher-mode`, leaves every shortcut set, and
evaluating the configuration again keeps one registration per name. Pressing a
launcher's chord while a panel is open dismisses it: a second invocation
cancels the active session and presents nothing, so press again to open
another launcher. [Global shortcuts](#global-shortcuts) describes the notation,
conflicts and delivery.

### Application launcher with launcher.el (optional)

Portal includes no application picker. The separate
[launcher.el](https://github.com/xiaoxinghu/launcher.el) package discovers
applications with Spotlight, launches or activates them with `open -a` and
searches the web for other text; `!g`, `!yt` and `!gh` followed by a space and
a query choose a search engine. It owns its index, duplicate-name labels, path
annotations and `launcher-app-directories`, `launcher-fallback-search-url` and
`launcher-bangs` options. This recipe was tested with this revision:

```elisp
(use-package launcher
  :vc (:url "https://github.com/xiaoxinghu/launcher.el"
       :rev "731146d95d7d1ff16f48e7a200da873c8d8b375c")
  :commands (launcher launcher-refresh))
```

At that revision, `launcher` searches the web when completion returns an empty
string or a bang without a query, and stock completion's Space completes a word,
consuming the space in `!gh query`. Until launcher.el handles these, wrap its
completion reader in your configuration, as Portal's former built-in adapter
did:

<!-- example: launcher-app -->
```elisp
(defvar my/launcher-reader nil
  "The completion reader that `my/launcher-read' calls.")

(defun my/launcher-read (&rest arguments)
  "Read a choice for launcher.el, calling `my/launcher-reader' with ARGUMENTS.
In stock completion, Space inserts a space, so that \"!gh query\" can be
typed.  An empty result or a bang with no query cancels instead of searching."
  (let* ((choice (minibuffer-with-setup-hook
                     (lambda ()
                       (when (eq (key-binding " ") #'minibuffer-complete-word)
                         (use-local-map (define-keymap :parent (current-local-map)
                                          "SPC" #'self-insert-command))))
                   (let ((completing-read-function my/launcher-reader))
                     (apply my/launcher-reader arguments))))
         (words (split-string choice)))
    (when (or (null words)
              (and (null (cdr words)) (assoc (car words) launcher-bangs)))
      (signal 'quit nil))
    choice))

(defun my/app-launcher ()
  "Launch an app or search the web with launcher.el in Portal's panel.
With a prefix argument, launcher.el rebuilds its app index first."
  (interactive)
  (let ((my/launcher-reader completing-read-function)
        (completing-read-function #'my/launcher-read))
    (portal-launcher-present #'launcher :kind 'minibuffer)))

(portal-global-shortcut-set 'app-launcher "Control-Option-Command-P" #'my/app-launcher)
```

The panel shows only the prompt and candidates. With Vertico, or another
completion UI that highlights a candidate, Return accepts the highlighted
app, including the first one or one chosen with Up and Down, without typed
text. Stock completion shows no candidates in a minibuffer panel; type a name,
complete it with Tab, or use `:kind 'buffer` to see `*Completions*`. In stock
completion, Space inserts a space and Tab completes; a customized Space binding
is kept. The wrapper keeps your completion reader and changes no global
setting, so ordinary `M-x launcher` is unchanged. It holds your reader in a
variable rather than a closure, so it works with or without
`lexical-binding` in the file that defines it.

`C-u M-x my/app-launcher` rebuilds launcher.el's index before prompting, and
`M-x launcher-refresh` rebuilds it separately; refresh after installing,
removing or moving an app. Launching an app gives it focus as the panel hides.
Escape, C-g, the chord again, an empty result or a bang without a query close
the panel without an action and return focus to the previous app; clicking
another app hides it, leaving that app in front. Discovery and launch errors
close the panel and can be retried. Once launcher.el handles the three input
rules itself, present `#'launcher` directly and drop `my/launcher-read` and
its variable. See
the [application notes](launcher-applications.md) for the upstream
follow-ups, the optional integration smoke test and the historical evidence.

### Set up safely

Start in a disposable graphical Emacs. This feature depends on internal Emacs
NS behavior, and a native defect can crash the hosting Emacs. Initially it accepts
only GNU Emacs NS **31.1**, revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`. Rebuild Portal and restart Emacs before
using the new bindings. Native-compiled Emacs also needs a working
`modify-frame-parameters` and `delete-frame` trampolines so native callers cannot
bypass the frame guard or delete a frame with live session prompts.
Leave `native-comp-enable-subr-trampolines` enabled; if the trampoline is missing
and Emacs cannot compile it, presenting fails before creating a frame.

Try a new setup in a fresh disposable Emacs with your completion/theme setup
first. After that passes, explicitly evaluate it in a fresh normal session.
The launcher runs inside Emacs; it needs neither the app host, a separate
launcher application nor a per-invocation `emacsclient`. Emacs must already be
running, and long Lisp work delays invocation.

`(portal-launcher-mode -1)` deletes the dedicated panel and removes its frame
guards. Existing ordinary frames, Portal views and global shortcuts remain
usable, and the next presentation creates the panel again. The shared native
module stays loaded for other Portal features; restart Emacs to change its
binary. Rebuilding or unloading Lisp does not replace a loaded native module.

To migrate from M-x.app, start with a different Portal chord. Record the old
M-x launcher row's trigger and expression, then remove only that shortcut row
in M-x Settings before assigning its chord to your Portal shortcut. Keep M-x
running for its other shortcuts, `emacs://` and `org-protocol://` bindings.
Modifier double-taps remain M-x features. See the guide for the migration and
rollback checks. Restore the saved M-x launcher row if you roll back.

### Migrate from the built-in launcher

Until 2026-10-05, Portal included an application picker, ran it by default and
registered its chord when `portal-launcher-mode` was enabled. Each removed name
is gone without an alias, so an old setting cannot claim a chord or run a
picker by itself:

| Before | Now |
| --- | --- |
| `portal-launcher-applications`, the default command | Removed; use the launcher.el recipe above |
| `portal-launcher-command` | Removed; pass the function to `portal-launcher-present`, which now requires it |
| `portal-launcher-shortcut`, which the mode set as the global shortcut `portal-launcher` | Removed; call `portal-global-shortcut-set` with your command |
| `portal-launcher-toggle` | Removed; a second invocation of your command dismisses its panel, and `portal-launcher-show` and `portal-launcher-hide` show and hide a plain buffer |
| `M-x portal-launcher-present`, with `C-u` to refresh | No longer a command; use `M-x my/app-launcher`, with `C-u` to refresh |
| `portal-launcher-mode` | Retained; it registers no chord, presenting enables it, and disabling it still deletes the panel and removes its guards |
| `portal-launcher-present`, `portal-launcher-show`, `portal-launcher-hide`, `portal-launcher-cancel`, `portal-launcher-resize` and the appearance options | Retained; `portal-launcher-present`'s function is required |

An init file like this:

```elisp
(require 'portal-launcher)
(setopt portal-launcher-shortcut "Control-Option-Command-P"
        portal-launcher-command #'portal-launcher-applications
        portal-launcher-size '(720 420)
        portal-launcher-offset '(0 0))
(portal-launcher-mode 1)
```

becomes the `use-package` form and the recipe above, after the `require`,
with any appearance settings kept:

```elisp
(setopt portal-launcher-size '(720 420)
        portal-launcher-offset '(0 0))
```

In a running Emacs, run `(portal-launcher-mode -1)` before loading the new
version, or `(portal-global-shortcut-remove 'portal-launcher)` after, to free
the old chord for your own shortcut; restarting Emacs also frees it. Settings
of removed options do nothing and vanish on restart. To roll back to the
built-in launcher, check out `bc99e90`, the last commit with it, rebuild,
restart Emacs and restore the old init file. To remove a launcher you configured, delete its setup from the init
file and run `(portal-global-shortcut-remove 'app-launcher)` and
`(portal-launcher-mode -1)`; other Portal features and shortcuts keep working.

### Presentation options and lifecycle

The explicit buffer API remains available:

```elisp
(portal-launcher-show (get-buffer-create "*Launcher*"))
(portal-launcher-resize 713 407)
(portal-launcher-hide)
(portal-launcher-show)          ; same frame and content
(portal-launcher-mode -1)       ; delete the frame
```

Each call to `portal-launcher-present` chooses how the panel looks, without
registering a shortcut or changing the completion setup:

```elisp
;; Only the prompt and an inline completion UI, such as Vertico:
(portal-launcher-present (lambda () (completing-read "Fruit: " '("Apple" "Banana")))
                         :kind 'minibuffer)
;; Any function of no arguments; its value is returned:
(portal-launcher-present (lambda () (read-string "Name: ")) :kind 'minibuffer)
;; A buffer window without mode lines:
(portal-launcher-present #'my/buffer-command :kind 'buffer :mode-line nil)
```

`:kind 'buffer`, the default, shows a buffer window above the panel's own
minibuffer. Buffers the function displays appear in the panel, and windows it
creates there are deleted when the panel hides. `:kind 'minibuffer` makes the
whole panel a minibuffer: the prompt is its first line, an inline completion UI
follows directly below, and unused lines stay empty at the bottom. Buffers the
function displays appear nowhere, so stock completion's `*Completions*` list is
not shown, though Tab still completes and Return accepts; Vertico, Icomplete's
vertical mode or Fido show candidates in the panel. Commands that display or
preview buffers, split windows or otherwise need a buffer window require
`buffer`.

Both kinds have `portal-launcher-size`, and Emacs does not fit the panel to its
content. A completion UI that asks for more lines than the panel holds is
clipped at the bottom; the default 420 points hold Vertico's default 10
candidates. Lower the count or raise the height. Changing kind replaces the
dedicated frame; presenting the same kind again reuses it.

`:mode-line nil` hides the mode lines of the panel's windows, including windows
created and buffers switched during the call; the default, t, shows each
buffer's own. It sets the `mode-line-format` window parameter, so the same
buffers keep their mode lines in other frames, and restores each window's
earlier parameter when the panel hides. A minibuffer panel has none.

The function is an interactive command, called with `call-interactively` so it
sees a prefix argument, or any function of no arguments, called with `funcall`.
It runs with the buffer `*Portal Launcher*` current, in the panel's own
minibuffer and with the user's completion setup, including Vertico, Orderless
and Marginalia. Nested prompts stay in the panel. An invalid function or option
signals an error before anything is shown.

Success, when the function returns, hides the panel unless it is kept open;
Escape, C-g, another invocation, `portal-launcher-hide`, or losing keyboard
focus cancels the entire session. Errors propagate after
cleanup. Frame deletion and disabling unwind prompts before releasing the frame.
Cancellation returns focus to the previous app while the panel still owns the
keyboard; a successful external action or click-away preserves the destination
app's focus. Emacs's original window selection is restored without activating
its application. Display rules, presentation options and cancellation keys last
only for the session.

Functions must be synchronous. Invoke after any existing minibuffer has
finished. Functions that deliberately use other frames or catch arbitrary
throws need explicit wrappers.

Customize `portal-launcher-size` (default `(720 420)`), `portal-launcher-offset`
(`(0 0)`, positive right/down), `portal-launcher-screen` (nil uses the pointer's
monitor), `portal-launcher-font`, `portal-launcher-shadow`, and
`portal-launcher-corner-radius`. Show again to apply them. Size and offsets use
AppKit logical points, independent of Retina scale. The panel centers within the
monitor's usable area, clamps onscreen, and repositions when displays change.
`portal-launcher-frame-parameters` supplies initial colors, fringes and borders.

Fonts, buffers and appearance remain ordinary Emacs customization. The frame's
native role is fixed: changing decorations, fullscreen, parentage, toolbars or
focus policy is rejected. Deleting the launcher frame is supported; the next
show creates a new one. Hide preserves the launcher's content and returns Emacs
selection to the previous ordinary window without changing that window's buffer.

For plain buffer presentation outside a command session, finish or cancel an
active launcher minibuffer before hiding it. Outbound native drag-and-drop is
cancelled. The [daily-use guide](launcher-daily-use.md) records the user's
IME and VoiceOver validation.
See [implementation and measured geometry](launcher-native-panel.md).
