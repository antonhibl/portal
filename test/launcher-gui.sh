#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: bash test/vm.sh sh test/launcher-gui.sh [SELECTOR]
# The launcher's graphical suite, daily-use checks included, in one fresh
# Emacs. SELECTOR, an ERT regexp, defaults to every launcher test. Tests
# that need a second display skip. Set PORTAL_LAUNCHER_SCREENSHOTS to a
# directory to save the panel's drawing there.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PORTAL_LAUNCHER_TEST_ROOT="$root" PORTAL_LAUNCHER_SELECTOR="${1:-^portal-launcher-}"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
    -I "$(cat "$root/build/emacs-include.txt")" "$root/test/terminal-input.m" \
    -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
    -o "$root/build/test-terminal-input.dylib"
set -- -Q --module-assertions -L "$root" -L "$root/test"
for package in "$root"/build/elpa/*; do
    if [ -d "$package" ]; then set -- "$@" -L "$package"; fi
done
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" "$@" \
    -l "$root/portal.el" \
    --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"
                                         (getenv "PORTAL_LAUNCHER_TEST_ROOT")))' \
    -l "$root/test/portal-launcher-daily-use-tests.el" \
    --eval '(run-at-time 1 nil
      (lambda ()
        (condition-case err
            (let* ((message-log-max t)
                   (stats (ert-run-tests-batch (getenv "PORTAL_LAUNCHER_SELECTOR"))))
              (with-current-buffer "*Messages*"
                (princ (buffer-string) (quote external-debugging-output)))
              (kill-emacs (if (and (= (ert-stats-completed-unexpected stats) 0)
                                  (> (ert-stats-completed-expected stats) 0)) 0 1)))
          (error
           (princ (format "Launcher checks failed: %S\n" err)
                  (quote external-debugging-output))
           (kill-emacs 1)))))'
