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

The current metadata accessor verifies membership by enumerating live views on
each call. Reading metadata for `n` tracked terminals among `V` views therefore
does repeated scans, potentially `O(nV)` work, rather than constant-time access
per row. This is a code-derived scaling observation, not a measured bottleneck.
For a few terminals, prefer the public interface and simple code. If profiling
shows collection dominates, batch the membership check in the shared terminal
layer instead of introducing a competing metadata store.
[Terminal accessor](../portal-terminal.el), [view registry](../portal-view.el)

With comparable work per refresh, a two-second interval performs half as many
scheduled refreshes as a one-second interval; five seconds performs one fifth.
That arithmetic does not predict CPU percentages. Likewise, `n` agents sending
one heartbeat each second add approximately `n` reports per second even while
the dashboard is hidden, unless the producer protocol changes. Hiding the list
only removes its own refresh cost.

No dashboard benchmark was run because the dashboard is not implemented. Before
tuning, measure refresh elapsed time, allocation/GC, and interactive latency at
representative terminal counts, comparing unchanged, changing, and hidden lists.
Start with full redraws only on changes; add incremental rendering or event
subscriptions only if measurements justify their additional lifecycle complexity.
