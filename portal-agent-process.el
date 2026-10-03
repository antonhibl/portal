;;; portal-agent-process.el --- Evidence for terminal agent identity -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; A deliberately closed grammar: an unfamiliar option is not evidence of a
;; script.  Extend a runtime's grammar only with its documented arity and tests.
;; Inline code, module/task execution, stdin and check/help/version modes are
;; absent.  They must never turn their operands into a claimed agent script.
(defconst portal-agent-process--runtimes
  '(("node" :flags ("--no-warnings" "--trace-warnings" "--enable-source-maps"
                    "--preserve-symlinks" "--preserve-symlinks-main")
     :values ("--require" "--import" "--loader" "--experimental-loader" "--conditions"
              "--env-file" "--env-file-if-exists" "--max-old-space-size")
     :optional ("--inspect" "--inspect-brk" "--inspect-wait") :short-values "rC")
    ("bun" :flags ("--no-install" "--silent" "--smol")
     :values ("--preload" "--require" "--import" "--cwd" "--env-file" "--config")
     :short-values "rc" :path t)
    ("deno" :flags ("--allow-all" "--no-config" "--no-lock" "--quiet")
     :values ("--config" "--import-map" "--cert" "--location")
     :optional ("--allow-read" "--allow-write" "--allow-net" "--allow-env"
                "--allow-run" "--allow-sys" "--allow-ffi" "--no-check")
     :short-flags "Aq" :short-values "c")
    ("python" :values ("--check-hash-based-pycs") :short-flags "bBdEiIOPqsSuvx"
     :short-values "WX")
    ("sh" :short-flags "aefiluvx" :short-values "o")
    ("bash" :flags ("--noprofile" "--norc" "--posix" "--login")
     :values ("--rcfile" "--init-file") :short-flags "abefhiklptuvxBEHPT" :short-values "oO")
    ("zsh" :short-flags "efiluvx" :short-values "o")
    ("fish" :flags ("--no-config" "--interactive" "--login" "--private")
     :short-flags "ilP"))
  "Known script-launch options, separated by arity, for each runtime.
Optional values use =; short values may be attached or separate.")

(defun portal-agent-process--runtime (name)
  "Return the script-launch grammar for executable NAME, if supported."
  (assoc (if (equal name "python3") "python" name) portal-agent-process--runtimes))

(defun portal-agent-process--script (runtime arguments)
  "Return the script in RUNTIME's ARGUMENTS only for a known launch form."
  (let ((grammar (cdr (portal-agent-process--runtime runtime))))
    (catch 'script
      (when (equal runtime "deno")
        (unless (equal (pop arguments) "run") (throw 'script nil)))
      (when (and (equal runtime "bun") (equal (car arguments) "run"))
        (pop arguments))
      (while arguments
        (let* ((arg (pop arguments))
               (equal-sign (string-search "=" arg))
               (option (if equal-sign (substring arg 0 equal-sign) arg)))
          (cond
           ((equal arg "--") (throw 'script (portal-agent-process--script-path grammar (car arguments))))
           ((not (string-prefix-p "-" arg))
            (throw 'script (portal-agent-process--script-path grammar arg)))
           ((and (not equal-sign) (member arg (plist-get grammar :flags))))
           ((member option (plist-get grammar :optional)))
           ((member option (plist-get grammar :values))
            (unless equal-sign
              (unless arguments (throw 'script nil))
              (pop arguments)))
           ((or (equal arg "-") (string-prefix-p "--" arg)) (throw 'script nil))
           (t
            ;; Short flags may be clustered. A value consumes the rest of the
            ;; cluster, or the next argument, never a candidate script.
            (let ((index 1))
              (while (< index (length arg))
                (let ((letter (aref arg index)))
                  (cl-incf index)
                  (cond
                   ((seq-contains-p (plist-get grammar :short-flags) letter))
                   ((seq-contains-p (plist-get grammar :short-values) letter)
                    (when (= index (length arg))
                      (unless arguments (throw 'script nil))
                      (pop arguments))
                    (setq index (length arg)))
                   (t (throw 'script nil)))))))))))))

(defun portal-agent-process--script-path (grammar path)
  "Accept PATH as a script under GRAMMAR, excluding ambiguous package tasks."
  (and path (not (equal path "-"))
       (or (not (plist-get grammar :path)) (file-name-directory path)) path))

(defun portal-agent-process--name (process)
  "Identify PROCESS from its executable and a proven script position."
  (let* ((argv (append (plist-get process :argv) nil))
         (name (file-name-nondirectory (or (car argv) "")))
         (path (or (plist-get process :executable) ""))
         (exe (file-name-nondirectory path))
         (runtime (portal-agent-process--runtime name))
         (script (and runtime (portal-agent-process--script name (cdr argv)))))
    (when runtime (setq name (file-name-nondirectory (or script ""))))
    (when (and (member name '("claude" "codex" "pi"))
               (or (equal exe name)
                   (and (equal name "claude") (string-match-p "/claude/versions/[^/]+\\'" path))
                   (and script (portal-agent-process--runtime exe))
                   ;; Verified Pi launch: process.title replaces Node's argv.
                   (and (equal name "pi") (equal exe "node"))))
      name)))

(defun portal-agent-process-sessions (processes owner)
  "Return (MARKER . PROCESS) for unambiguous outer agents owned by OWNER.
PROCESSES is the native foreground snapshot.  Each result adds :agent to its
process facts.  Both the marker and uninterrupted same-TTY ancestry to OWNER
must agree.  An inherited marker on a nested or unrelated PTY is insufficient.
Unknown launch forms and ambiguous sessions supply no identity evidence."
  (let ((prefix (format "%s/" owner)) groups sessions)
    (dolist (process processes)
      (let ((marker (plist-get process :environment)))
        (when (and (eql (plist-get process :tty-parent) owner)
                   (stringp marker) (string-prefix-p prefix marker))
          (when-let* ((name (portal-agent-process--name process)))
            (push (cons :agent (cons name process)) (alist-get marker groups nil nil #'equal))))))
    (pcase-dolist (`(,marker . ,candidates) groups)
      (let ((outer (seq-remove
                    (lambda (process)
                      (seq-some (lambda (other)
                                  (memql (plist-get other :pid)
                                         (append (plist-get process :ancestors) nil)))
                                candidates)) candidates)))
        (when (= (length outer) 1) (push (cons marker (car outer)) sessions))))
    sessions))

(provide 'portal-agent-process)
;;; portal-agent-process.el ends here
