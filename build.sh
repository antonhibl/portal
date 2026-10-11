#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

# One build of these outputs at a time: a second one stops at once.
if [ -z "${PORTAL_BUILD_LOCKED:-}" ]; then
    mkdir -p build
    status=0
    PORTAL_BUILD_LOCKED=1 lockf -k -t 0 build/.build.lock /bin/sh "$here/build.sh" "$@" ||
        status=$?
    if [ "$status" -eq 75 ]; then
        echo "build.sh: another Portal build is running in $here" >&2
    fi
    exit "$status"
fi

# BUN, a compatible bun on PATH, Portal's cached Bun, or a verified download;
# see tools/resolve-bun.sh.  A -DBUN argument still takes precedence.
bun=$(/bin/sh tools/resolve-bun.sh)
set -- "-DBUN=$bun" "$@"
# Preserve the existing environment overrides, including on later builds.
if [ -n "${EMACS:-}" ]; then set -- "$@" "-DEMACS=$EMACS"; fi
if [ -n "${EMACS_INCLUDE:-}" ]; then set -- "$@" "-DEMACS_INCLUDE=$EMACS_INCLUDE"; fi
cmake --preset dev "$@"
cmake --build --preset dev
echo "Built build/portal.bundle, build/portal-host and build/licenses"
