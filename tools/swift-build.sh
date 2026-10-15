#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run `xcrun swift build` with these arguments, without its download progress.
#
# Writing to a pipe, as under Ninja, SwiftPM prints a line for every progress
# update of a download: about 300 for GhosttyKit.  Ninja shows a step's output
# only when it ends, so they are never live.  Like git and cargo in a log, keep
# SwiftPM's lines naming each download and its end, and drop those updates.
# The exit status is swift build's.
set -o pipefail
xcrun swift build "$@" 2>&1 |
    awk '!/^\[[0-9]+\/[0-9]+\] Downloading .* \([^()]* \/ [^()]*\)$/'
