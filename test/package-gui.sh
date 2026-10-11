#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: bash test/vm.sh sh test/package-gui.sh
# Installs this copy of Portal through docs/install.md's use-package-vc example
# into an empty HOME, then checks first use in graphical Emacs: the first
# native command offers one build, and a fresh Emacs then opens a terminal and
# a web view.  The installation and its build are deleted afterwards.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
emacs=${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}
work=$(mktemp -d "${TMPDIR:-/tmp}/portal-package-gui.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The runner copies files without Git metadata; installing needs a repository.
[ -d "$root/.git" ] || git -C "$root" init -q
"$emacs" --batch -Q -l "$root/test/portal-package-tests.el" \
    --eval "(portal-package-test--install \"$work\" \"$work/home/\" \"\")"

for phase in setup use; do
    echo "Graphical Emacs: $phase"
    (cd "$work/home" &&
        HOME="$work/home" PORTAL_PACKAGE_GUI_PHASE=$phase \
        "$emacs" -Q -l "$root/test/portal-package-gui.el")
done
