#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Whether a global shortcut on a bare Escape keeps Escape from the frontmost
# app, with key events that go through macOS's hot key matching. Run after
# ./build.sh in the VM, as `bash test/vm.sh sh test/escape-shortcut-leak.sh`.
# One Emacs, the target, is frontmost and logs every Escape it reads. Another,
# the holder, sets Escape as a shortcut and posts Escape: the shortcut must
# run and the target read nothing. Once the holder removes it, the next posted
# Escape must reach the target, which shows that posting reaches it at all.
# Posting needs Emacs.app to have Accessibility permission, which only a
# person can switch on. Both start with `open`, so that TCC sees Emacs.app
# rather than sshd, and `open` passes no environment.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir=$(mktemp -d -t portal-escape-leak)
log=$dir/log
: >"$log"
cleanup() {
    pkill -f "$dir/" 2>/dev/null || :
    pkill -f universalAccessAuthWarn 2>/dev/null || :
}
trap cleanup EXIT

cat >"$dir/target.el" <<EOF
;;; -*- lexical-binding: t; -*-
(setq inhibit-startup-screen t)
(defun target-log (text) (write-region text nil "$log" t 'silent))
;; A GUI Escape may arrive as the escape key or as ESC.
(dolist (key (list [escape] (kbd "ESC")))
  (global-set-key key (lambda () (interactive) (target-log "target read escape\n"))))
(run-at-time 1 nil (lambda () (target-log (format "target ready %d\n" (emacs-pid)))))
EOF

cat >"$dir/holder.el" <<EOF
;;; -*- lexical-binding: t; -*-
(load "$root/portal.el" nil t)
(defun holder-log (text) (write-region text nil "$log" t 'silent))
(defvar holder-front-info nil "What lsappinfo last said about the front app.")
(defun holder-frontmost ()
  "The pid of the frontmost app, or nil."
  (let ((info (shell-command-to-string
               "lsappinfo info -only pid \$(lsappinfo front)")))
    (setq holder-front-info info)
    ;; Either "pid"=123 or pid = 123.
    (and (string-match "\"?pid\"? *= *\\\\([0-9]+\\\\)" info)
         (string-to-number (match-string 1 info)))))
(defun holder-target ()
  "The target's pid, once it is ready."
  (with-temp-buffer
    (insert-file-contents "$log")
    (and (re-search-forward "^target ready \\\\([0-9]+\\\\)" nil t)
         (string-to-number (match-string 1)))))
(defun holder-finish (status)
  (holder-log (format "holder done %d\n" status))
  (kill-emacs status))
(defun holder-post (label)
  (condition-case err
      (progn (portal-post-key "Escape") (holder-log (format "posted %s\n" label)))
    (error (holder-log (format "post failed: %s\n" (error-message-string err)))
           (holder-finish 3))))
(defun holder-steps (steps)
  "Run STEPS, functions, one a second, from the command loop."
  (when steps
    (run-at-time 1 nil (lambda () (funcall (car steps)) (holder-steps (cdr steps))))))
(defun holder-start (tries)
  (let ((target (holder-target)))
    (cond ((and target (eql (holder-frontmost) target))
           (holder-log "target is frontmost\n")
           (portal-global-shortcut-set
            'escape-leak "Escape"
            (lambda () (holder-log "holder shortcut ran\n")))
           (holder-log "holder holds escape\n")
           (holder-steps
            (list (lambda () (holder-post "while held"))
                  (lambda () (holder-post "while held, again"))
                  (lambda ()
                    (portal-global-shortcut-remove 'escape-leak)
                    (holder-log "holder released escape\n"))
                  (lambda () (holder-post "after release"))
                  (lambda () (holder-finish 0)))))
          ((> tries 0) (run-at-time 0.5 nil #'holder-start (1- tries)))
          (t (holder-log (format "target never frontmost: target %s, frontmost %s from %S\n"
                                 target (holder-frontmost) holder-front-info))
             (holder-finish 4)))))
(run-at-time 60 nil #'holder-finish 2)
(holder-start 40)
EOF

emacs=/Applications/Emacs.app
# The holder first, in the background, then the target, which takes the front.
open -n -g -a "$emacs" --args -Q -l "$dir/holder.el" &
sleep 3
open -n -a "$emacs" --args -Q -l "$dir/target.el"
for _ in $(seq 90); do
    if grep -q '^holder done' "$log"; then break; fi
    sleep 1
done
cat "$log"

fail() { echo "FAIL: $*"; exit 1; }
grep -q '^holder done 0$' "$log" || fail "the holder did not finish"
# Lines between holding and releasing must not include the target reading.
held=$(sed -n '/^holder holds escape$/,/^holder released escape$/p' "$log")
echo "$held" | grep -q 'target read escape' && fail "Escape reached the target while held"
[ "$(echo "$held" | grep -c '^holder shortcut ran$')" = 2 ] ||
    fail "the shortcut did not run once for each held Escape"
after=$(sed -n '/^holder released escape$/,$p' "$log")
[ "$(echo "$after" | grep -c '^target read escape$')" = 1 ] ||
    fail "the target did not read the Escape posted after release"
echo "$after" | grep -q '^holder shortcut ran$' && fail "the shortcut ran after release"
echo "PASS: a held Escape never reached the frontmost app, and a released one did"
