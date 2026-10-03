#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run after ./build.sh, in a desktop session. Uses disposable Emacs windows.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
    -I "$(cat "$root/build/emacs-include.txt")" "$root/test/terminal-input.m" \
    -framework AppKit -framework WebKit -framework Carbon \
    -o "$root/build/test-terminal-input.dylib"
set -- -Q --module-assertions -L "$root" -L "$root/test"
for package in "$root"/build/elpa/*; do
    if [ -d "$package" ]; then set -- "$@" -L "$package"; fi
done
set -- "$@" -l "$root/portal.el"
# Optional file with only the completion/theme setup to validate. Do not load
# the normal init into this automated test: it can start services or other UIs.
if [ -n "${PORTAL_LAUNCHER_CONFIG:-}" ]; then
    set -- "$@" -l "$PORTAL_LAUNCHER_CONFIG"
fi
export PORTAL_LAUNCHER_TEST_ROOT="$root"
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" "$@" \
    --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"
                                         (getenv "PORTAL_LAUNCHER_TEST_ROOT")))' \
    -l "$root/test/portal-launcher-daily-use-tests.el" \
    --eval '(run-at-time 1 nil
      (lambda ()
        (condition-case err
            (let ((stats (ert-run-tests-batch "^portal-launcher-daily-use-")))
              (with-current-buffer "*Messages*"
                (princ (buffer-string) (quote external-debugging-output)))
              (kill-emacs (if (and (= (ert-stats-completed-unexpected stats) 0)
                                  (= (ert-stats-skipped stats) 0)
                                  (= (ert-stats-completed-expected stats) 2)) 0 1)))
          (error
           (princ (format "Launcher checks failed: %S\n" err)
                  (quote external-debugging-output))
           (kill-emacs 1)))))'
