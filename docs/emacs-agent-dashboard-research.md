# Live updates for an Emacs agent list

Research date: 2026-10-02

## Recommendation

Build one ordinary, read-only `tabulated-list-mode` buffer: `g` refreshes, `RET`
visits the terminal, and a toggle controls automatic refresh. Start with a
configurable two-second regular timer while visible—a design choice, not a
measured performance guarantee. Keep manual refresh useful alongside it.

Emacs supports live buffers; refresh cost is the concern. Start with a small
table over cached terminal metadata. Rich agent status collection, heartbeats,
and native callbacks are separate work, not prerequisites for automatic updates.

## Existing Emacs precedents

| Built-in facility | Update behavior | Implication |
| --- | --- | --- |
| Ibuffer | `ibuffer-auto-mode` uses a post-command hook, checking for frame or buffer changes before updating. | Automatic updates, but not a general external-agent status subscription. |
| Proced | A regular timer defaults to five seconds; updates can be disabled, visible-only, or for all buffers. | The closest model for a periodically refreshed status list. |
| Auto Revert / Dired | File notifications and polling refresh changed files; Dired also refreshes on directory entry creation/deletion. | Standard live-buffer infrastructure; file watching helps only with file-backed data. |

Sources: [Ibuffer source](https://github.com/emacs-mirror/emacs/blob/master/lisp/ibuf-ext.el),
[Proced source](https://github.com/emacs-mirror/emacs/blob/master/lisp/proced.el),
[Auto Revert manual](https://www.gnu.org/software/emacs/manual/html_node/emacs/Auto-Revert.html).

`tabulated-list-mode` supplies rows, columns, sorting, and reverting. Stable IDs
let `tabulated-list-print` restore point to the same entry. Prefer a full,
position-preserving print **only when displayed data changes**. Its optional
`UPDATE` argument currently skips existing rows with matching IDs: verify this
before using incremental updates for mutable columns with stable terminal IDs.
Preserve sorting and window position too.
Sources: [Tabulated List manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tabulated-List-Mode.html),
[printing implementation](https://github.com/emacs-mirror/emacs/blob/master/lisp/emacs-lisp/tabulated-list.el).

Auto Revert supports non-file buffers through `revert-buffer-function` and
`buffer-stale-function`. Use it if it simplifies the code; it need not run
alongside a custom timer. Its documentation stresses preserving point and
avoiding repetitive messages. [Reverting API](https://www.gnu.org/software/emacs/manual/html_node/elisp/Reverting.html)

## Fit with Portal's current implementation

`portal-terminal-buffers` enumerates live terminal buffers, optionally including
quick terminals. `portal-terminal-metadata` returns cached Lisp facts: name,
assigned project, working directory, title, exit state, and quick-terminal
membership. `portal-terminal--changed` updates this cache on native reports,
allowing list refreshes without a fresh native snapshot of every terminal.
[Terminal metadata implementation](../portal-terminal.el)

A live shell and title cannot establish whether an agent is working, idle, or
awaiting input. Keep an explicit unknown state until a supported status source
exists. The original one-second Pi heartbeat proposal concerns status and
liveness, not live UI refresh; keep its freshness policy independent from the
table's refresh interval.
[Metadata contract](../portal-terminal.el), [dashboard task](../project.org)

## Performance implications and refresh policy

Emacs runs timer callbacks when it can accept process output, not in an
independent worker. Busy Lisp can delay timers; expensive callbacks can delay
interaction. Process filters run at these points too, so moving expensive
redraws into a filter does not remove their cost.
[Timer documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Timers.html),
[process output documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Output-from-Processes.html)

Use one refresh path for `g`, opening the list, and automatic updates:

- Refresh immediately on opening, then periodically with a regular timer. Idle
  timers wait for user idleness, postponing updates during continued interaction. [Idle timer documentation](https://www.gnu.org/software/emacs/manual/html_node/elisp/Idle-Timers.html)
- Do no periodic collection or rendering while hidden. Cancel the timer when
  hidden, killed, or automatic refresh is disabled; restore it when appropriate.
  Preserve selected window, row identity, and sort order.
- Compare displayed-value snapshots; print only when changed. Avoid seconds-ticking
  age labels that force redraws every tick. This saves rendering, not collection.
- Limit callbacks to cached metadata and table operations: no subprocesses,
  synchronous network requests, remote filesystem checks, or blocking waits.
  Do not redraw per terminal output chunk or agent token.

The metadata accessor previously enumerated live views on each membership
check: `n` tracked terminals among `V` views cost `O(nV)`. Profiling showed this
scan dominated refreshes (see [Measurements](#measurements)). The accessor now
checks the buffer's own view target, present exactly while registered. Its
interface is unchanged; there is still one metadata store.
[Terminal accessor](../portal-terminal.el), [view registry](../portal-view.el)

For comparable work, a two-second interval halves scheduled refreshes versus
one second; five seconds reduces them to one fifth. This does not predict CPU
percentages. Likewise, `n` agents sending one heartbeat each second add roughly
`n` reports per second, even with a hidden dashboard, unless the producer
protocol changes. Hiding removes only the list's refresh cost.

## Measurements

Measured 2026-10-02 on Emacs 31.1 (macOS 27.0, `emacs -Q`, default
`gc-cons-threshold` of 800000) with
[`test/portal-agents-benchmark.el`](../test/portal-agents-benchmark.el), over the
fake native module: `n` tracked terminals in 10 projects. "Changed" means every
terminal reported a new title before refresh. Batch times average 200 refreshes;
KB is approximate allocation per refresh.

First versus shipped implementation:

| Tracked | Views | First: unchanged ms, KB | Metadata ms | Shipped: unchanged ms, KB | Shipped: changed ms, KB |
| --- | --- | --- | --- | --- | --- |
| 10 | 10 | 0.27, 51 | 0.05 | 0.01, 4 | 0.59, 156 |
| 50 | 50 | 1.46, 131 | 1.02 | 0.07, 19 | 2.17, 520 |
| 100 | 100 | 4.73, 301 | 3.89 | 0.18, 38 | 4.98, 998 |
| 100 | 200 | 8.52, 457 | 7.88 | 0.18, 38 | 4.38, 998 |

Two changes reduced unchanged-refresh costs:

- Membership scans took 82% of an unchanged refresh at 100 terminals, 92% beside
  100 more views. Accessor cost is now independent of `V`.
- Comparing cached facts before formatting rows avoids abbreviating directories
  or naming projects on unchanged refreshes.

Changed refreshes still reprint every row with `tabulated-list-print`, their main
cost: 2.9 ms and 740 KB for 100 rows. Across 30 batch refreshes, unchanged facts
caused no prints; changing every title caused one print per refresh.

Each graphical Emacs configuration ran the event loop for 10 seconds with the
dashboard visible at the default two-second interval. Tick time excludes
separately reported garbage collection. Redisplay is forced after a printed
change. A key typed during a tick waits for that tick, redisplay, then any
collection.

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

Manual mode does no dashboard work; unchanged live lists cost under a
millisecond every two seconds. Manual-row collections come from terminal
metadata reports, which run even when hidden. Individual collections took
10–60 ms and varied more than dashboard costs. The worst case—every title
changing between ticks, as with animation—cost about 7 ms plus up to 12 ms
redisplay for 100 terminals every two seconds. The slowest redisplay, 38 ms,
was at 50 terminals. No interval or default change was needed: live updates
remain on at two seconds, with manual refresh available.

These measure dashboard work, not keystroke-to-screen latency. A 10 ms probe
timer was tried and dropped: outside the command loop, `sit-for` returns
immediately with input pending, spinning the wait loop and allocating about
35 MB/s. With `accept-process-output`, the probe fired only as each wait ended,
measuring the harness rather than Emacs. Tests, not timings, cover hidden
dashboards: hiding or killing cancels the timer; hidden dashboards never redraw.
