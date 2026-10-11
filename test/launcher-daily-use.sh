#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run after ./build.sh, in a desktop session. Uses disposable Emacs windows,
# through test/gui-ert.sh.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
set --
# Optional file with only the completion/theme setup to validate. Do not load
# the normal init into this automated test: it can start services or other UIs.
if [ -n "${PORTAL_LAUNCHER_CONFIG:-}" ]; then
    set -- -l "$PORTAL_LAUNCHER_CONFIG"
fi
exec sh "$root/test/gui-ert.sh" "$@" \
    -l "$root/test/portal-launcher-daily-use-tests.el" \
    --eval '(portal-gui-ert-start "^portal-launcher-daily-use-" nil 2)'
