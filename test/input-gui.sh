#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: bash test/vm.sh sh test/input-gui.sh
# Shell-startup testing needs its separate terminal-shell-startup.sh fixture.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
    -I "$(cat "$root/build/emacs-include.txt")" "$root/test/terminal-input.m" \
    -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
    -o "$root/build/test-terminal-input.dylib"
set -- -Q --module-assertions -L "$root" -L "$root/test"
for package in "$root"/build/elpa/*; do
    if [ -d "$package" ]; then set -- "$@" -L "$package"; fi
done
export PORTAL_INPUT_TEST_ROOT="$root"
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" "$@" \
    -l "$root/portal.el" \
    --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"
                                         (getenv "PORTAL_INPUT_TEST_ROOT")))' \
    -l "$root/test/portal-tests.el" \
    -l "$root/test/portal-terminal-tests.el" \
    -l "$root/test/portal-integration-tests.el" \
    -l "$root/test/portal-input-gui-tests.el" \
    -l "$root/test/portal-toolbar-gui-tests.el" \
    --eval '(run-at-time 1 nil
      (lambda ()
        (condition-case err
            (let ((stats (ert-run-tests-batch
                          (quote (and "^portal-\\(input-gui\\|terminal\\|integration\\|toolbar\\)-"
                                      (not portal-terminal-start-uses-shell-startup))))))
              (with-current-buffer "*Messages*"
                (princ (buffer-string) (quote external-debugging-output)))
              (kill-emacs (if (and (= (ert-stats-completed-unexpected stats) 0)
                                  (= (ert-stats-skipped stats) 0)
                                  (> (ert-stats-completed-expected stats) 0)) 0 1)))
          (error
           (princ (format "Input checks failed: %S\n" err)
                  (quote external-debugging-output))
           (kill-emacs 1)))))'
