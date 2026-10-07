# Use the agent dashboard

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Agent dashboard

Run `claude`, `codex` or `pi` in an ordinary Portal shell, then open `M-x portal-agents`.
Agents appear automatically, even before their first prompt or at trust dialogs.
Discovery includes sessions started before the dashboard opened, while hidden,
or before discovery was enabled. No agent setup or per-session tracking is
needed. Tested versions: Claude Code 2.1.288, Codex CLI 0.155.1 and Pi 0.87.0.
Pi activity needs the extension below; identity discovery needs no setup.
Rebuild and restart Emacs to give new terminals the discovery marker.

Rows show terminal name, agent, assigned project, terminal process state,
activity, current directory and reported title. Claude activity uses
[`claude agents --json`](https://code.claude.com/docs/en/agent-view#list-sessions-as-json):
`busy` becomes `working`; `waiting` and `idle` retain their names. **Idle does
not mean success.** Startup, trust dialogs, unsupported statuses and status
command failures yield `unknown`; hover for the reason. Process-discovery
failure makes Process `unknown` until recovery. Set `portal-agents-claude-program`
to an absolute path if Claude is absent from Emacs's `exec-path`.

**Codex (title)** rows infer activity from the default terminal title: a leading
braille spinner means `working`, `Action Required` means `waiting`, another
nonempty title means `idle`, and missing/blank means `unknown`. Hover activity
for its source and limitations. Startup can read as working before the first
prompt; non-approval menus and model errors can read as idle. Keep default title
settings: custom settings can invalidate this mapping. Terminal-wide titles have
no process ID; the current cache supports best-effort inference, not proof of
which run emitted it. Notifications and progress do not affect Codex activity;
focus and notification suppression do not imply idle.

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

Later plain `pi` launches load the extension automatically; existing sessions
can use `/reload`. Only Portal TUI sessions report, not RPC, print mode or
non-Portal terminals. Reports say working at `agent_start`, waiting during
blocking extension UI prompts, and idle only when `ctx.isIdle()` agrees, using
`agent_settled` after work. `agent_end` does not settle retries, automatic
compaction or queued continuation. Failures and cancellations can settle to
idle; idle does not mean success.

Only native progress reports received **after discovery** count; until then,
activity is `unknown`, even with cached startup reports. Open the dashboard and
use `/reload` or `/new`, or take a later turn, for fresh evidence. Hidden
dashboards preserve discovered runs' evidence and check process identity on
redisplay; newly discovered runs wait for fresh evidence. Native receipt times
prevent delayed metadata or repeated states from reusing pre-discovery reports.

This configured source is not sender-authenticated: OSC progress has no PID.
Competing writers or late output from other processes can mislead it; keep the
extension the sole progress writer. Unsupported states, missing reports and
extension shutdown become unknown. Without a heartbeat, silence cannot
distinguish unchanged state from a broken extension. In Pi 0.87.0, manual
compaction success precedes idle-flag clearing with no subsequent settlement
event, leaving activity unknown until another lifecycle report. Extension UI
prompt events exclude built-in menus. Hover activity for its source or missing
evidence reason.

The dashboard is a Tabulated List buffer: no native view, web page or app host.
Move, isearch, or sort with `S`; `RET` visits and focuses the correct terminal,
even hidden, in quick panels or another frame. Evil's normal state with
evil-collection's Tabulated List bindings also works. Buffer renames and
directory changes preserve identity; agents sharing a directory remain distinct.

Discovery uses foreground processes tied to the exact terminal, never titles,
progress bars or project paths. Agent exit removes its automatic row even if
the shell continues; relaunch creates a new session. Suspended (Ctrl-Z) agents
disappear until foregrounded. Remote agents, tmux agents and launches removing
`PORTAL_TERMINAL` are not discovered. The marker must match OS ancestry back to
Emacs on the same controlling TTY; nested-PTY inheritance is insufficient.
Discovery recognizes native agent binaries and known runtime script launches.
The executable must match the runtime whose argument grammar is parsed,
allowing supported aliases.
Runtime options use documented arity; unknown options, inline code and ambiguous
package tasks are not guessed. These terminals still support manual tracking.

Optional `M-x portal-agents-track` (`t`) tracks any terminal; a prefix requests
a label. Lisp can use `(portal-agents-track BUFFER LABEL)`. Explicit labels
override agent labels without adding rows. Manually tracked terminals remain,
marked `exited` after program exit, until closed or untracked. Other harnesses have unknown
activity. `portal-agents-untrack` (`u`) leaves programs running, hiding a
discovered run until it leaves the foreground or is explicitly tracked again.
Later runs are discovered normally.

While shown, one two-second timer scans processes and cached metadata; opening
or showing scans immediately. After successful scans, Codex uses cached titles;
Pi uses cached progress without a status subprocess. Title glyph-class and
progress changes trigger asynchronous Claude queries, but within-class spinner
animation does not. Queries never overlap, time out after five seconds, and
retry after transitions, every four seconds for unknown status, or at a
30-second safety poll. Mid-query transitions schedule fresh queries; results
cannot attach to replaced terminals or processes. Titles omit leading activity
markers to avoid spinner-driven redraws. Hidden dashboards stop discovery and
status collection and cancel pending queries; existing native metadata records
continue for hidden terminals.

Rows update only when displayed facts change, preserving sorting, selection,
each window's position and keyboard focus. `g` refreshes; `q` hides.
`portal-agents-toggle-live-update` or `(setq portal-agents-live-update nil)`
makes collection manual: open, show, or `g`. `portal-agents-live-update-interval`
changes the interval when updates next start. Set `portal-agents-discover-claude`,
`portal-agents-discover-codex` or `portal-agents-discover-pi` to nil to disable
that agent's discovery; disable all three for manual-only tracking.
Minimized/invisible frames stop collection at the next tick.

With 100 tracked terminals, a refresh with nothing changed took under 1 ms in
graphical Emacs and redrew nothing. When every title changed, it took about
7 ms plus the redisplay.
