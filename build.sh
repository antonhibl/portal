#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")"

# Preserve the existing environment overrides, including on later builds.
if [ -n "${EMACS:-}" ]; then set -- "$@" "-DEMACS=$EMACS"; fi
if [ -n "${EMACS_INCLUDE:-}" ]; then set -- "$@" "-DEMACS_INCLUDE=$EMACS_INCLUDE"; fi
cmake --preset dev "$@"
cmake --build --preset dev
echo "Built build/anymacs.bundle and build/anymacs-host"
