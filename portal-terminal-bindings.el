;;; portal-terminal-bindings.el --- Runtime native input bindings -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'json)
(require 'portal-terminal)
(declare-function portal--terminal-bindings "portal-terminal" (json))

(defvar portal-terminal-native-map (make-sparse-keymap)
  "Opt-in native shortcuts shared by all Portal terminals.
Initially empty.  Use `portal-terminal-bind-key' and
`portal-terminal-unbind-key' for live changes.  For direct edits, use
`portal-terminal-refresh-bindings'.
First chords must be modified ASCII keys; Emacs reads remaining prefix keys.")
(defvar portal-terminal-quick-native-map (make-sparse-keymap)
  "Additional native shortcuts for quick terminals, overriding the shared map.
Initially empty; this map never installs global Emacs shortcuts.")
(defvar portal-terminal--native-maps (cons (make-sparse-keymap) (make-sparse-keymap))
  "Last successfully registered dispatch maps: (REGULAR . QUICK).")

(defun portal-terminal--nonempty-binding-p (binding &optional ancestors)
  "Whether BINDING contains a command; reject cyclic prefix ANCESTORS."
  (if (not (keymapp binding))
      (commandp binding)
    (when (memq binding ancestors) (user-error "Cyclic native prefix map"))
    (let (found)
      (map-keymap (lambda (_key value)
                   (when (portal-terminal--nonempty-binding-p value (cons binding ancestors))
                     (setq found t)))
                 binding)
      found)))

(defun portal-terminal--compile-native-map (map prefix)
  "Validate MAP against PREFIX, returning (SNAPSHOT . NATIVE-ENTRIES)."
  (let ((snapshot (make-sparse-keymap)) seen entries chords)
    (map-keymap
     (lambda (key _value)
       (unless (memq key seen)
         (push key seen)
         (let ((binding (lookup-key map (vector key))))
           (when binding
             (unless (or (keymapp binding) (commandp binding))
               (user-error "Native binding %s must be a command or prefix map" key))
             (when (portal-terminal--nonempty-binding-p binding)
               (unless (integerp key)
                 (user-error "Native first chords must be modified ASCII keys: %s" key))
               (let ((chord (portal-terminal--prefix-description (key-description (vector key)))))
                 (when (equal chord prefix)
                   (user-error "Native binding conflicts with portal-terminal-prefix: %s"
                               (key-description (vector key))))
                 (when (member chord chords)
                   (user-error "Duplicate native chord: %s" (key-description (vector key))))
                 (push chord chords)
                 (define-key snapshot (vector key)
                             (if (keymapp binding) (copy-keymap binding) binding))
                 (push `((character . ,(car chord)) (flags . ,(cadr chord)) (event . ,key))
                       entries)))))))
     map)
    (cons snapshot (vconcat (nreverse entries)))))

(defun portal-terminal--validate-native-prefix (description)
  "Reject a new legacy prefix DESCRIPTION colliding with registered bindings."
  (portal-terminal--compile-native-map (car portal-terminal--native-maps) description)
  (portal-terminal--compile-native-map (cdr portal-terminal--native-maps) description))

;;;###autoload
(defun portal-terminal-refresh-bindings ()
  "Apply native keymap edits to existing and future terminal sessions.
Only first chords cross the native boundary; commands and prefix maps stay in
Elisp.  Invalid edits leave the last registered bindings active.  This does not
load the native module or create a terminal."
  (interactive)
  (let* ((prefix (portal-terminal--prefix-description portal-terminal-prefix))
         (regular (portal-terminal--compile-native-map portal-terminal-native-map prefix))
         (quick (portal-terminal--compile-native-map
                 (make-composed-keymap (list portal-terminal-quick-native-map
                                             portal-terminal-native-map)) prefix))
         (payload (json-encode `((regular . ,(cdr regular)) (quick . ,(cdr quick))))))
    (cond ((fboundp 'portal--terminal-bindings) (portal--terminal-bindings payload))
          ((featurep 'portal-native-module)
           (user-error "Rebuild Portal and restart Emacs to enable native bindings")))
    (setq portal-terminal--native-maps (cons (car regular) (car quick)))))

(defun portal-terminal--edit-native-binding (map key command remove)
  "Update MAP at KEY with COMMAND, or REMOVE it; register or roll back."
  (unless (memq map (list portal-terminal-native-map portal-terminal-quick-native-map))
    (user-error "Use portal-terminal-native-map or portal-terminal-quick-native-map"))
  (let ((saved (copy-keymap map)))
    (condition-case err
        (progn
          (if remove (keymap-unset map key t) (keymap-set map key command))
          (portal-terminal-refresh-bindings))
      (error (setcdr map (cdr saved)) (signal (car err) (cdr err))))))

(defun portal-terminal-bind-key (map key command)
  "Bind KEY to COMMAND in native MAP and apply it immediately.
MAP is `portal-terminal-native-map' or `portal-terminal-quick-native-map'.
KEY uses `keymap-set' syntax and can be a sequence.  COMMAND can also be a
prefix keymap.  No global Emacs binding is installed."
  (portal-terminal--edit-native-binding map key command nil))

(defun portal-terminal-unbind-key (map key)
  "Remove KEY from native MAP and apply immediately.
Removing a quick override reveals any shared binding.  Empty prefix maps
do not intercept keys: removing their last command releases the chord."
  (portal-terminal--edit-native-binding map key nil t))

(provide 'portal-terminal-bindings)
;;; portal-terminal-bindings.el ends here
