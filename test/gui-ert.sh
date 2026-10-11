#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run graphical ERT suites in one fresh Emacs, after ./build.sh, in a
# desktop session. Portal, the test-only event injector and
# portal-gui-ert.el load first; the arguments, passed on to Emacs, load the
# suites and call portal-gui-ert-start. Each test's start and end reach
# standard error as they happen.
#
# A stuck native call can stop every Lisp timer, so a watchdog here bounds
# each test: when no test starts or ends for PORTAL_GUI_TEST_TIMEOUT seconds
# (default 60), it samples Emacs, kills it and its subprocesses, names the
# test, and exits 124.
# The progress records and the sample go to PORTAL_TEST_LOGS, which
# test/vm.sh copies back, or to build/.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
budget=${PORTAL_GUI_TEST_TIMEOUT:-60}
logs=${PORTAL_TEST_LOGS:-$root/build}
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
    -I "$(cat "$root/build/emacs-include.txt")" "$root/test/terminal-input.m" \
    -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
    -o "$root/build/test-terminal-input.dylib"
progress=$logs/gui-progress.log
: >"$progress"
export PORTAL_GUI_PROGRESS="$progress" PORTAL_GUI_ROOT="$root"
# Emacs's own arguments go first: append them, then move the caller's
# arguments after them.
count=$#
set -- "$@" -Q --module-assertions -L "$root" -L "$root/test"
for package in "$root"/build/elpa/*; do
    if [ -d "$package" ]; then set -- "$@" -L "$package"; fi
done
set -- "$@" -l "$root/portal.el" \
    --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"
                                         (getenv "PORTAL_GUI_ROOT")))' \
    -l "$root/test/portal-gui-ert.el"
while [ "$count" -gt 0 ]; do set -- "$@" "$1"; shift; count=$((count - 1)); done
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" "$@" &
pid=$!
# Emacs starts each subprocess in a process group of its own, which outlives
# Emacs and the caller's group; an orphan would keep test/vm.sh's desktop lock.
stop() {
    children=$(pgrep -P "$pid" || :)
    kill -KILL "$pid" 2>/dev/null || :
    for child in $children; do kill -KILL -- "-$child" "$child" 2>/dev/null || :; done
}
trap stop EXIT
started=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    stamp=$started event=launch test=
    if [ -s "$progress" ]; then
        read -r stamp event test <<EOF
$(tail -n 1 "$progress")
EOF
    fi
    if [ $(($(date +%s) - stamp)) -lt "$budget" ]; then continue; fi
    case $event in
        start) what="$test did not finish" ;;
        end) what="no test started after $test" ;;
        exit) what="Emacs did not exit" ;;
        loaded) what="no test started" ;;
        *) what="the suites did not load" ;;
    esac
    echo "GUI checks timed out: $what within ${budget}s" >&2
    sample "$pid" 2 -file "$logs/emacs-sample.log" >/dev/null 2>&1 &&
        echo "Sampled Emacs to $logs/emacs-sample.log" >&2
    stop
    wait "$pid" 2>/dev/null || :
    exit 124
done
status=0
wait "$pid" || status=$?
exit "$status"
