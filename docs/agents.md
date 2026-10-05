# Use the agent dashboard

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Agent dashboard

Run `claude`, `codex` or `pi` in an ordinary Portal shell, then open `M-x portal-agents`.
The agent appears automatically, even before its first prompt or while waiting
at a trust dialog. Discovery also finds sessions started before the dashboard
opened, while it was hidden, or before discovery was enabled. No agent setup
or per-session tracking is needed. This is tested with Claude Code 2.1.288 and
Codex CLI 0.155.1 and Pi 0.87.0. Pi activity needs the extension setup below;
its identity is discovered without setup.
Rebuild and restart Emacs to give new terminals the discovery marker.

Each row shows its terminal name, agent, assigned project, terminal process
state, agent activity, current directory and reported title. Claude activity comes
from [`claude agents --json`](https://code.claude.com/docs/en/agent-view#list-sessions-as-json):
`busy` becomes `working`, and `waiting` and `idle` keep their names. **Idle does
not mean success.** At startup, at a trust dialog, on an unsupported status, or
when the status command fails, activity is `unknown`; hover it for the reason.
A process-discovery failure also makes Process `unknown` until recovery.
Set `portal-agents-claude-program` to an absolute path if Claude is not on Emacs's
`exec-path`.

Codex rows are labelled **Codex (title)**: activity is inferred from its default
terminal title. A leading braille spinner means `working`, `Action Required`
means `waiting`, another nonempty title means `idle`, and a missing or blank
title means `unknown`. Hover activity for its source and limitations. Startup
can read as working before the first prompt; non-approval menus and model errors
can read as idle. Custom title settings can invalidate the mapping. Titles are
terminal-wide and carry no process ID, so this is a best-effort inference from
the current cache, not proof that a particular run emitted it. Keep Codex's
default title settings for this source. Notifications and progress do not affect
Codex activity; focus and notification suppression do not imply idle.

Pi rows are labelled **Pi (progress)**. Install the bundled lifecycle extension
once (from the Portal repository root):

```sh
mkdir -p ~/.pi/agent/extensions
cp -i extensions/portal-pi.ts ~/.pi/agent/extensions/portal-pi.ts
```

Keep Pi's `terminal.showTerminalProgress` off (its default), and disable other
extensions that write OSC 9;4 progress. Portal does not change Pi settings.
Then enable this source in Emacs:

```elisp
(setopt portal-agents-pi-progress t)
```

Later plain `pi` launches load the extension automatically. In an existing Pi
session, `/reload` loads it without relaunching. Only Portal TUI sessions emit
reports; RPC, print mode and terminals outside Portal do not. The extension
reports working at `agent_start`, waiting during blocking extension UI prompts,
and idle only when `ctx.isIdle()` agrees, using `agent_settled` after work.
`agent_end` does not settle retries, automatic compaction or queued continuation.
Failures and cancellations can settle to idle; idle does not mean success.

Only native progress reports received **after discovery** count. Until then,
activity is `unknown`, even if an earlier startup report is cached. Opening the
dashboard and using `/reload` or `/new` provides fresh evidence; a later turn
also does. A hidden dashboard preserves evidence for a previously discovered
run and checks its process identity on redisplay. Runs first discovered on
redisplay wait for new evidence. Reports carry native receipt times so delayed
metadata and repeated states cannot reuse a report from before discovery.

This is a configured source, not a sender-authenticated protocol: OSC progress
has no PID. Competing writers or output received late from another process can
mislead it. Keep the extension as the sole progress writer. Unsupported states,
missing reports and extension shutdown become unknown. There is no heartbeat:
silence alone cannot distinguish an unchanged state from a broken extension.
In Pi 0.87.0, manual compaction success precedes the idle flag clearing and has
no subsequent settlement event, so it becomes unknown until another lifecycle
report. Built-in menus are not covered by extension UI prompt events. Hover
activity to see its source or why evidence is missing.

The dashboard is an ordinary Tabulated List buffer with no native view, web
page or app host. Move, isearch, or press `S` to sort; `RET` visits the correct
terminal and gives it the keyboard, including hidden terminals, quick panels,
and terminals in another frame. This also works in Evil's normal state with
evil-collection's Tabulated List bindings. Renaming a buffer or changing
directory does not change its identity. Two agents in the same directory remain
distinct.

Discovery uses foreground processes tied to the exact terminal, never titles,
progress bars or project paths. Exiting an agent removes its automatic row even
while the shell keeps running; relaunching creates a new agent session. A
suspended (Ctrl-Z) agent disappears until foregrounded. Remote agents, agents
inside tmux, or launches that remove `PORTAL_TERMINAL` are not discovered.
The marker must agree with OS ancestry on the same controlling TTY back to
Emacs; inheriting it inside a nested PTY is insufficient. Native agent binaries
and known runtime script launches are recognized. The executable must match the
runtime whose argument grammar is parsed, allowing supported aliases. Runtime
options are parsed by their documented arity; unknown options, inline code and
ambiguous package tasks are not guessed. Such terminals can still be tracked
manually.

Optional `M-x portal-agents-track` (`t`) tracks any terminal; a prefix argument
also asks for a label, and `(portal-agents-track BUFFER LABEL)` works from Lisp.
An explicit label overrides the agent label without creating a second row. Manually
tracked terminals remain after program exit, marked `exited`, until closed or
untracked. Other harnesses have unknown activity. `portal-agents-untrack` (`u`)
leaves the program running and hides a discovered run until it leaves the
foreground or is explicitly tracked again; later runs are discovered normally.

While shown, one two-second timer scans processes and reads cached metadata.
Opening or showing the dashboard scans immediately. Codex activity is read from
cached titles after a successful scan, and Pi reads cached progress without a
status subprocess. Title glyph-class and
progress changes trigger asynchronous Claude status queries; spinner animation
within a class does not. Queries never overlap, time out after five seconds,
and retry after a transition, every four seconds for unknown status, or at a
30-second safety poll. A transition during a query schedules a fresh query;
results cannot attach to a replaced terminal or process. Leading activity
markers are omitted from agent titles so spinner frames do not redraw rows.
Hidden dashboards do no discovery or status collection, and cancel pending
queries. Existing native metadata records continue for hidden terminals.

Rows are rewritten only when displayed facts change, preserving sorting,
selection, each window's position and keyboard focus. `g` refreshes and `q`
hides the dashboard. `portal-agents-toggle-live-update` or
`(setq portal-agents-live-update nil)` leaves collection manual: open, show, or
`g`. Set `portal-agents-live-update-interval` to change the interval the next
time updates start. Set `portal-agents-discover-claude` or
`portal-agents-discover-codex` or `portal-agents-discover-pi` to nil to disable
that agent's automatic discovery; disable all three to retain only manual tracking. Minimized/invisible frames stop
collection at the next tick.

With 100 tracked terminals, a refresh with nothing changed took under 1 ms in
graphical Emacs and redrew nothing. When every title changed, it took about
7 ms plus the redisplay. See the
[measurements](emacs-agent-dashboard-research.md#measurements).
