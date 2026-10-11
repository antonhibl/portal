#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/input-gui.sh [SELECTOR]
# The shared input, terminal, integration and toolbar checks in one fresh
# Emacs, through test/gui-ert.sh. SELECTOR, an ERT regexp, narrows them.
# Shell-startup testing needs its separate terminal-shell-startup.sh fixture.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
export PORTAL_INPUT_SELECTOR="${1:-}"
exec sh "$root/test/gui-ert.sh" \
    -l "$root/test/portal-tests.el" \
    -l "$root/test/portal-terminal-tests.el" \
    -l "$root/test/portal-integration-tests.el" \
    -l "$root/test/portal-input-gui-tests.el" \
    -l "$root/test/portal-toolbar-gui-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and)
                   "^portal-\\(input-gui\\|terminal\\|integration\\|toolbar\\)-"
                   (quote (not portal-terminal-start-uses-shell-startup))
                   (let ((focus (getenv "PORTAL_INPUT_SELECTOR")))
                     (if (equal focus "") t focus))))'
