# Live updates for an Emacs agent list

Research date: 2026-10-02

## Recommendation

Build one ordinary, read-only `tabulated-list-mode` buffer, with `g` to refresh,
`RET` to visit the terminal, and a toggle for automatic refresh. Start with a
configurable two-second regular timer while the list is visible. This interval is
a design choice, not a measured performance guarantee. Keep manual refresh useful
even when automatic refresh is enabled.

Live updates fit Emacs well. The question is how much work a refresh does, not
whether Emacs buffers can update themselves. A small table over cached terminal
metadata is a reasonable first implementation. Rich agent status collection,
heartbeats, and native callbacks are separate work; the list does not require
them to update automatically.

## Existing Emacs precedents

| Built-in facility | Update behavior | Implication |
| --- | --- | --- |
| Ibuffer | `ibuffer-auto-mode` uses a post-command hook and checks whether frames or buffers changed before updating. | Automatic updates already exist in Ibuffer, but its trigger is not a general external-agent status subscription. |
| Proced | A regular timer defaults to five seconds; its update policy supports disabled, visible buffers only, or all buffers. | The closest model for a periodically refreshed status list. |
| Auto Revert / Dired | File notifications and polling refresh changed files; Dired also refreshes for directory entry creation/deletion. | Live text buffers are standard Emacs infrastructure. File watching is useful only when the data actually lives in files. |

Sources: [Ibuffer source](https://github.com/emacs-mirror/emacs/blob/master/lisp/ibuf-ext.el),
[Proced source](https://github.com/emacs-mirror/emacs/blob/master/lisp/proced.el),
[Auto Revert manual](https://www.gnu.org/software/emacs/manual/html_node/emacs/Auto-Revert.html).

`tabulated-list-mode` supplies rows, columns, sorting, and a reverting interface.
Stable entry IDs let `tabulated-list-print` restore point to the same entry.
Prefer a full print with position preservation **only when displayed data changes**.
Do not assume its optional `UPDATE` argument refreshes mutable columns: the
current implementation skips an existing row when its ID matches. Verify that
behavior before using incremental updates for a stable terminal ID whose status
changes. Sorting and window position should survive refreshes too.
Sources: [Tabulated List manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tabulated-List-Mode.html),
[printing implementation](https://github.com/emacs-mirror/emacs/blob/master/lisp/emacs-lisp/tabulated-list.el).

Auto Revert can also support non-file buffers through `revert-buffer-function`
and `buffer-stale-function`. It is a viable alternative if it makes the code
smaller; it is not necessary to run both Auto Revert and a custom timer. Its
documentation explicitly calls out preserving point and avoiding repetitive
messages. [Reverting API](https://www.gnu.org/software/emacs/manual/html_node/elisp/Reverting.html)

## Fit with Portal's current implementation

`portal-terminal-buffers` already enumerates live terminal buffers, optionally
including quick terminals. `portal-terminal-metadata` returns cached Lisp facts:
name, assigned project, working directory, title, exit state, and quick-terminal
membership. `portal-terminal--changed` updates that cache when the native module
reports changes. This supports refreshing the list without asking native code
for a fresh snapshot of every terminal on each tick.
[Terminal metadata implementation](../portal-terminal.el)

There is an important limit: a live shell and its title do not establish whether
an agent is working, idle, or awaiting input. Preserve an explicit unknown state
until a supported status source exists. The original one-second Pi heartbeat
proposal is a status-source and liveness design, not a prerequisite for live UI
refresh. Keep its freshness policy independent from the table's refresh interval.
[Metadata contract](../portal-terminal.el), [dashboard task](../project.org)

## Performance implications and refresh policy

Emacs runs timer callbacks at points where it can accept process output, not in
an independent background worker. Busy Lisp can delay a timer; expensive timer
callbacks can delay interaction. Process filters also run when Emacs accepts
output, so moving expensive redraws into a filter would not make them free.
[Timer documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Timers.html),
[process output documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Output-from-Processes.html)

Use one refresh path for `g`, opening the list, and automatic updates:

- Refresh immediately on opening. Use a regular timer for periodic refresh:
  idle timers wait for user idleness, so they can postpone updates while the user
  keeps interacting. [Idle timer documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Idle-Timers.html)
- Do no periodic collection or rendering while the dashboard is hidden. Cancel
  its timer when hidden, killed, or automatic refresh is disabled; restore it
  when appropriate. Preserve the selected window, row identity, and sort order.
- Build a snapshot of displayed values and compare it with the previous one.
  Skip printing when unchanged. Avoid seconds-ticking age labels that force a
  redraw on every tick. This avoids redraw work, not snapshot collection work.
- Keep the refresh callback to cached metadata and table operations. Do not run
  subprocesses, synchronous network requests, remote filesystem checks, or
  blocking waits. Do not redraw on every terminal output chunk or agent token.

The metadata accessor verified membership by enumerating live views on each
call, so reading metadata for `n` tracked terminals among `V` views did `O(nV)`
work. Profiling the dashboard showed that scan dominated refreshes (see
[Measurements](#measurements)), so the accessor now checks the buffer's own
view target, which a buffer has exactly while it is registered. Its interface
is unchanged, and there is still one metadata store.
[Terminal accessor](../portal-terminal.el), [view registry](../portal-view.el)

With comparable work per refresh, a two-second interval performs half as many
scheduled refreshes as a one-second interval; five seconds performs one fifth.
That arithmetic does not predict CPU percentages. Likewise, `n` agents sending
one heartbeat each second add approximately `n` reports per second even while
the dashboard is hidden, unless the producer protocol changes. Hiding the list
only removes its own refresh cost.

## Measurements

Measured 2026-10-02 on Emacs 31.1 (macOS 27.0, `emacs -Q`, default
`gc-cons-threshold` of 800000) with
[`test/portal-agents-benchmark.el`](../test/portal-agents-benchmark.el), over the
fake native module: `n` tracked terminals in 10 projects. "Changed" means every
terminal reported a new title before the refresh. Batch times are means of
200 refreshes; KB is approximate allocation per refresh.

How the first implementation scaled, compared with the shipped one:

| Tracked | Views | First: unchanged ms, KB | Metadata ms | Shipped: unchanged ms, KB | Shipped: changed ms, KB |
| --- | --- | --- | --- | --- | --- |
| 10 | 10 | 0.27, 51 | 0.05 | 0.01, 4 | 0.59, 156 |
| 50 | 50 | 1.46, 131 | 1.02 | 0.07, 19 | 2.17, 520 |
| 100 | 100 | 4.73, 301 | 3.89 | 0.18, 38 | 4.98, 998 |
| 100 | 200 | 8.52, 457 | 7.88 | 0.18, 38 | 4.38, 998 |

Two changes made unchanged refreshes cheap. The membership scan was 82% of an
unchanged refresh at 100 terminals and 92% beside 100 more views; the accessor
now costs the same whatever `V` is. The dashboard also compares the cached facts
before formatting rows, so an unchanged refresh no longer abbreviates
directories or names projects. A changed refresh still reprints every row with
`tabulated-list-print`, which is most of its cost: 2.9 ms and 740 KB for 100
rows. Over 30 refreshes, the batch run printed nothing while the facts stayed
the same and once per refresh while every title changed.

In graphical Emacs, each configuration ran the event loop for 10 seconds with
the dashboard shown, at the default two-second interval. A tick's time excludes
garbage collection, which is reported separately. Redisplay is the forced
redisplay after a printed change. A key typed during a tick waits for the tick,
then that redisplay, then any collection.

| Tracked | Mode | Titles | Ticks | Prints | Tick mean / max ms | Redisplay max ms | GCs (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | manual | unchanged | 0 | 0 | — | — | 1 (10) |
| 10 | manual | every 0.5 s | 0 | 0 | — | — | 2 (20) |
| 10 | live | unchanged | 5 | 0 | 0.12 / 0.15 | 0.01 | 0 (0) |
| 10 | live | every 0.5 s | 5 | 5 | 2.7 / 4.7 | 7.4 | 3 (30) |
| 50 | manual | unchanged | 0 | 0 | — | — | 1 (12) |
| 50 | manual | every 0.5 s | 0 | 0 | — | — | 6 (138) |
| 50 | live | unchanged | 5 | 0 | 0.59 / 0.67 | 0.01 | 1 (24) |
| 50 | live | every 0.5 s | 5 | 5 | 5.5 / 7.7 | 38 | 10 (322) |
| 100 | manual | unchanged | 0 | 0 | — | — | 0 (0) |
| 100 | manual | every 0.5 s | 0 | 0 | — | — | 15 (878) |
| 100 | live | unchanged | 5 | 0 | 0.82 / 1.0 | 0.01 | 1 (14) |
| 100 | live | every 0.5 s | 5 | 5 | 7.0 / 7.9 | 12 | 23 (274) |

In manual mode the dashboard does no work at all, and in live mode an unchanged
list costs under a millisecond every two seconds. The collections in manual
rows come from the terminals' own metadata reports, which run whether or not
the dashboard is shown; single collections took 10 to 60 ms and varied more
than any dashboard cost. The worst case is every title changing between every
tick, as an animated title would. Even then, 100 terminals cost about 7 ms and
a redisplay of up to 12 ms every two seconds; the slowest redisplay, 38 ms,
was with 50. No interval or default change was
needed, so live updates stay on at two seconds and manual refresh stays
available.

These are timings of the dashboard's own work, not keystroke-to-screen latency.
A 10 ms probe timer was tried and dropped. Outside the command loop, `sit-for`
returns at once while input is pending, so the wait loop spun and allocated
about 35 MB/s. With `accept-process-output` instead, the probe fired only as
each wait ended, so it measured the harness, not Emacs. Hidden dashboards are
covered by the tests rather than timed: hiding or killing one cancels its timer,
and a hidden one redraws nothing.
