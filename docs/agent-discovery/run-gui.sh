#!/bin/sh
# Agent discovery spike: run gui-run-1.el or gui-run-2.el in a clean graphical
# Emacs.  First apply instrumentation.patch, rebuild, and build the scanner:
#   git apply docs/agent-discovery/instrumentation.patch && ./build.sh
#   cc -O2 -o build/agentscan docs/agent-discovery/agentscan.c
# Then: sh docs/agent-discovery/run-gui.sh gui-run-1.el   (or gui-run-2.el)
# These runs start real agents and make small model requests.
# Traces go to $SPIKE_SCRATCH (default $TMPDIR): native.jsonl and lisp.jsonl.
set -eu
P=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$P/../.." && pwd)
RUN=${1:?usage: run-gui.sh gui-run-1.el}
OUT=${SPIKE_SCRATCH:-${TMPDIR:-/tmp}}
LP=$(zsh -lic 'print -r -- $PATH' </dev/null 2>/dev/null | tail -1)
rm -f "$OUT/native.jsonl" "$OUT/lisp.jsonl"
# env -i: Portal's shells must not inherit a parent Claude Code session.
env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH="$LP" LANG="${LANG:-en_US.UTF-8}" \
  TMPDIR="${TMPDIR:-/tmp}" SHELL=/bin/zsh SPIKE_SCRATCH="$OUT" \
  SPIKE_USE_PROGRESS="${SPIKE_USE_PROGRESS:-}" SPIKE_REPLAY="${SPIKE_REPLAY:-}" \
  PORTAL_SPIKE_TRACE="$OUT/native.jsonl" PORTAL_SPIKE_LISP_TRACE="$OUT/lisp.jsonl" \
  "${EMACS:-emacs}" -Q -L "$W" -l "$W/portal.el" -l "$P/$RUN" &
pid=$!
( sleep 1200; kill $pid 2>/dev/null ) & watchdog=$!
wait $pid || true
kill $watchdog 2>/dev/null || true
echo "Traces: $OUT/native.jsonl $OUT/lisp.jsonl"
