---
status: todo
---

# 09: Live agent dashboard in Emacs

Research and proposed implementation spec · 2026-09-27

This document specifies future work; this change implements no dashboard,
agent configuration, hooks, session naming, or model calls. The research assumes
Codex CLI and Claude Code in local Portal terminal buffers. Other Emacs terminal
packages can reuse the polling interface later.

## Recommendation

Build `M-x portal-agents`, an ordinary Emacs buffer derived from
`tabulated-list-mode`. Show every registered agent session across projects and
frames, including idle sessions. Refresh from structured provider snapshots
every second while the dashboard is visible. `RET` selects the associated
terminal buffer and gives its terminal view keyboard focus.

Use **Claude Code's `claude agents --json`** and **Codex's app-server protocol**
as status sources. Keep provider discovery, terminal association, and display
separate. Neither a process being alive nor a quiet terminal proves activity.
Do not build the first version on transcript scraping, spinner recognition,
or a pair of start/stop hooks.

Start with explicit registration of existing terminal sessions. This makes a
useful small implementation possible without changing the terminal engine.
Automatic association and a Portal launcher are options below. Registration is
a real initial usability limitation: opening the dashboard alone cannot reliably
identify every arbitrary agent already running in a terminal.

Reuse existing provider titles where available. A live semantic summary remains
a spike. User-assigned session names are a separate follow-up, researched below.

## Findings and evidence

### Claude Code: a direct polling command exists

`claude agents --json` includes live **interactive** sessions as well as
background sessions. Its documented fields include `cwd`, `kind`, `startedAt`,
live `pid` and `status` (`busy`, `waiting`, `idle`), optional `sessionId` and
`name`, and `waitingFor`. The interactive scope differs from the visual agent
view. `--all` adds completed background sessions. This is the supported external
interface; private job-state files are not stable. Agent view is a research
preview, so probe the response shape rather than assuming every installation
supports it. [Claude JSON interface](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)

Local read-only probe: Claude Code **2.1.283**, `claude agents --json`, exit 0,
about **195 ms** on one invocation. It returned one interactive session with
`cwd`, `kind`, `name`, `pid`, `sessionId`, `startedAt`, and `status: idle`.
This verifies discovery and the installed schema, not latency under load or
every state transition. No prompts or transcripts were printed into this spec.

### Codex: poll the server that owns the session

The app-server exposes `thread/loaded/list`, metadata-only `thread/read`, and
`thread/status/changed`. Runtime states distinguish `active`, `idle`,
`systemError`, and `notLoaded`; active flags identify approval and input waits.
Thread metadata includes `cwd`, optional `name`, and `preview`. Reading a thread
does not resume it. The protocol and WebSocket transport are experimental.
[Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)

Local checks used Codex CLI **0.155.1**:

```sh
codex --version
codex agents --help
codex app-server proxy --help
codex app-server generate-json-schema --out /tmp/portal-codex-schema
codex app-server daemon version
```

The installed CLI has an interactive `agents` overview, with no `--json` flag.
Its `app-server proxy` bridges stdio to an existing daemon control socket and
accepts `--sock`. Generated schemas confirm the status variants, the
`waitingOnApproval` / `waitingOnUserInput` flags, and metadata-only reads.
The schema describes `preview` as usually the first user message; it is not a
generated progress summary. `thread.id`, not the session-tree `sessionId`, is
the polling identity.

**Unverified integration boundary:** the default daemon socket was absent on
this machine. No daemon was started and no running terminal session was moved.
The two-client terminal-plus-observer flow therefore needs the bounded spike
below. Starting a new unrelated stdio server is not a global live-status query;
the observer must reach the owning server. `notLoaded` must not become `idle`.

Codex supports connecting its terminal UI to a specified server using
`--remote unix://PATH` or a WebSocket URL. This gives a controlled route if
ordinary standalone sessions cannot be observed. Do not silently migrate them
or enable remote control. [Codex CLI connection options](https://learn.chatgpt.com/docs/developer-commands#codex-interactive)

### Why not infer state from terminal output or hooks?

Claude's `Stop` excludes user interruption; other failure and permission paths
have different events. A `UserPromptSubmit` → `Stop` file can remain working
after cancellation. [Claude hook lifecycle](https://code.claude.com/docs/en/hooks#hook-lifecycle)

Current Codex hooks include `Interrupt`, `Stop`, session identity, and `cwd`,
but hooks require trust and stop hooks can request continuation. These are
useful integration signals, not a reason to replace an available authoritative
snapshot. Its transcript format is explicitly unstable.
[Codex hooks](https://learn.chatgpt.com/docs/hooks)

Herdr identifies foreground agents and applies screen/OSC manifests for Claude
and Codex. Their hooks provide session identity rather than full status. It
reads the live bottom of the terminal, independent of scroll position. This is
a workable compatibility strategy with ongoing parser maintenance, not evidence
that hooks alone cover all transitions. [Herdr status authority](https://herdr.dev/docs/agents/#status-authority)

### What Portal already provides

| Existing code | Consequence for this feature |
| --- | --- |
| [`portal-view-buffers`](../../portal-view.el) | Enumerates all live terminal views, including hidden ones and quick terminals. |
| [`portal-terminal-focus`](../../portal-terminal.el) | Provides the final focus handoff after selecting a buffer. |
| [`portal-terminal--new`](../../portal-terminal.el) | Records the launch `default-directory`; it does not track later shell or agent directory changes. |
| [`TerminalSession.inspect()`](../../native/Terminal.swift) | Exposes title and closed state, but no agent identity, activity, process ID, or current directory. |
| [`portal-terminal-rename`](../../portal-terminal.el) | Already renames ordinary terminal buffers. It is separate from provider conversation naming. |

There is no Emacs subprocess attached to these terminal buffers: Ghostty owns
the PTY and scrollback. `get-buffer-process` and ordinary comint output filters
cannot observe the agent. The pinned libghostty wrapper's foreground PID and
TTY accessors are stubs that return no value. A plan to join Claude's PID to a
terminal cannot simply expose those accessors and expect it to work.
[Pinned dependency source](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurface.swift#L405)

## User experience

```text
*Portal Agents*                         2 working, 2 idle · refreshed 0.4s ago

Status    Agent   Project / path                      Task                         Terminal
working   Codex   ~/work/portal                       Markdown navigation          *portal-terminal*
idle      Claude  ~/work/api                          Fix login tests              *portal-terminal*<2>
idle !    Codex   ~/work/portal/.worktrees/search      Search results               *portal-terminal*<3>
working   Claude  ~/work/docs                         Update deployment guide      *portal-quick:…*

RET visit terminal   g refresh   a register   d unregister   q quit
```

The example is illustrative, not observed output. An `idle !` row has stopped
for input; its help text/detail says `needs approval` or `needs input`.

- Include working and idle registered sessions. Completion does not remove an
  interactive session that is ready for another prompt.
- Default ordering is registration order; allow normal column sorting.
  Refresh preserves the selected row, point, window start, and selected sort.
  It never selects another buffer, raises a frame, or steals terminal focus.
- Show the project/worktree root resolved from the provider's current `cwd`.
  Outside a project, show `cwd` itself. Keep the full directory in row details;
  shorten only its display. Cache project lookup until `cwd` changes. Different
  linked worktrees must remain distinguishable.
- Use a read-only Task column for a provider title or known prompt excerpt;
  fall back to the terminal buffer name. Do not manufacture a semantic summary.
- `RET` reuses a window already showing the buffer, including another frame,
  or displays it if hidden, then calls `portal-terminal-focus`. Quick terminals
  use their existing panel display path. The dashboard stays available.
- `g` requests fresh data immediately. `q` quits only the dashboard.
  `d` removes a registration only; it never terminates an agent.
- Empty state explains how to register a session. Missing binaries, unsupported
  APIs, and inaccessible Codex endpoints appear as actionable diagnostics.

Use `tabulated-list-mode`, stable row IDs and `tabulated-list-print` with
position preservation. These are built-in Emacs facilities; no hosted app or
web view is needed. [Emacs tabulated lists](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tabulated-List-Mode.html)

## Status contract

Keep two normal activity values: **working** and **idle**. Here idle means
the agent is not currently doing work; it does not certify task success.
Keep a separate attention reason and telemetry health. `unknown` is a lack of
valid observation, not a third agent activity or a synonym for idle.

| Provider observation | Activity | Detail / health |
| --- | --- | --- |
| Claude `busy` | working | Normal |
| Claude `waiting` | idle | Attention; retain `waitingFor` |
| Claude `idle` | idle | Ready for another prompt |
| Codex `active`, no wait flags | working | Normal |
| Codex `active`, approval/input flag | idle | Attention; preserve all flags |
| Codex `idle` | idle | Ready for another prompt |
| Codex `systemError` | unknown | Error; never label done |
| Codex `notLoaded`, missing record, parse failure, or disconnected provider | unknown | Explain unavailable, exited, or stale as evidence permits |

This is a proposed normalization policy. Retain the raw provider state so a
later three-state display can distinguish waiting without changing adapters.
Do not infer success from process exit. A successful snapshot missing a
previously registered session immediately invalidates its current activity.
Keep its row as unavailable until it is unregistered or its terminal is closed.

Background sessions with no corresponding terminal, child agents without their
own terminal, and scheduled jobs are outside the first dashboard. Their richer
job state is not interchangeable with the interactive activity column.

## Identity and terminal association

Use a registration key `(provider, endpoint-or-profile, native-thread-id,
terminal-incarnation)`. Store the actual Emacs buffer object, not its name.
The incarnation changes when a terminal view is replaced, even in the same
buffer. Directory and title are presentation fields and never matching keys.

The smallest reliable version provides `portal-agent-register` in a Portal
terminal buffer. Select the provider and its live session ID with completion
showing title, path and short ID; for Codex also select/configure the owning
endpoint. Registration must show the chosen binding clearly. A fresh Claude
session lacking `sessionId` can temporarily use `(pid, startedAt)` and upgrade
when an ID appears. Never identify it by PID alone.

`portal-agents` lists all registrations in this Emacs instance. Its registration
picker may discover other sessions but must not pretend they already have an
Emacs terminal. Allow one selected session per terminal incarnation initially.
If the user switches the CLI to another conversation, they must re-register;
manual bindings cannot reliably detect that transition. State this limitation
in command help. Closing/killing/changing the mode of a terminal removes its
binding. Renaming the buffer or moving it between frames preserves it.

Options to remove the manual step:

| Option | Benefit | Cost / limitation |
| --- | --- | --- |
| **Explicit registration first (recommended)** | Elisp-only association; works without a terminal-engine upgrade. | One setup action per session; rebind after changing conversations. |
| Portal-owned launch/resume | Bind the native session ID before launching its terminal UI. | New launch workflow; Codex needs a known shared endpoint and verified attach behavior. Claude can use an explicit session ID if supported. |
| Terminal token plus session-identity hook | Agents launched manually can register automatically. | Requires per-terminal environment injection, hook setup/trust, and lifecycle validation. Hooks in an existing Codex daemon may not inherit the terminal's environment. |
| Foreground PID/TTY matching | Can discover existing interactive Claude sessions automatically. | Current pinned Ghostty support is missing; needs an engine/API change or another independently verified registration mechanism. Codex metadata does not provide a terminal PID binding. |

Do not claim automatic coverage until one of these mechanisms is implemented
and tested with two sessions in the same directory. Shell wrappers, tmux, SSH,
containers, and detached workers require additional identity handling.

## Elisp polling and provider boundaries

Add `portal-agents.el` for registrations, normalization, the cache, refresh
scheduling, and the list buffer. Keep provider-specific transport/parsing in
small adapters, initially `portal-agents-claude.el` and
`portal-agents-codex.el`. Load the feature through `portal.el` using the repo's
existing conventions. The baseline needs no Swift or app-host changes.

Proposed public interface, not existing functions:

```elisp
(portal-agents)                   ; open/reuse *Portal Agents*
(portal-agent-register)           ; bind a provider session to this terminal
(portal-agents-refresh)           ; start asynchronous refresh; return promptly
(portal-agents-snapshot)          ; return copies of normalized cached rows
```

A snapshot row contains `:id`, `:buffer`, `:terminal-incarnation`, `:provider`,
`:native-id`, `:endpoint`, `:cwd`, `:project-root`, `:activity`, `:attention`,
`:health`, `:raw-status`, `:title`, `:title-source`, and `:observed-at`.
The facade lets other Elisp callers schedule refreshes without opening the UI.
It never waits synchronously for a provider.

```text
one Emacs timer
  -> asynchronous provider snapshots
  -> validate and normalize
  -> join exact registrations
  -> cache rows
  -> redraw changed table, preserving selection
```

### Scheduling and failure handling

- Default `portal-agents-refresh-interval` is 1 second, customizable. Target a
  visible update within 2 seconds on a responsive local machine. This is near
  real time, not a hard deadline: Emacs timers run when its event loop can
  service them. Use a normal timer, not an idle-only timer that waits for typing
  to stop. [Emacs timers](https://www.gnu.org/s/emacs/manual/html_node/elisp/Timers.html)
- One timer per Emacs instance, one in-flight refresh per provider endpoint,
  and one Claude subprocess per snapshot, not per row. Never run blocking
  `shell-command-to-string`, `call-process`, Git, or network I/O in a timer.
- Start on dashboard display, stop polling when it is hidden in every frame,
  and refresh immediately when shown again. Registered terminal sessions keep
  running. A caller of the facade can request refresh while the UI is hidden.
- Use `make-process` with argv lists, separate stderr, exit-status checking,
  bounded output and a timeout (initially 3 seconds). On failure retain previous
  data for inspection but mark it unavailable. Mark a snapshot older than
  5 seconds stale; never turn an old working observation into idle by timeout.
- Discard late responses from an old connection generation or removed binding.
  On sleep/wake or reconnect, mark stale first and replace it after fresh data.
  Bound retries with backoff and reset them on a manual refresh.
- Timer/filter callbacks preserve current buffer and match data. Changes to
  task text, buffer names, Unicode paths, or control characters must not corrupt
  table layout. Treat all provider strings as data, never executable Elisp.

### Claude adapter

Run the configured executable with `agents --json` asynchronously and parse the
completed JSON array. Check supported fields and ignore unknown fields. Use
the configured provider environment, including any selected Claude profile;
never rewrite the user's settings or status line. Match registrations exactly,
normalize through the table above, and distinguish command failure from an
empty successful result. Record observed binary version for diagnostics.

### Codex adapter and required spike

Keep one connection to each configured owning server. Prefer the installed
`codex app-server proxy --sock PATH` as an Elisp subprocess when available;
its purpose and flags were verified locally, but its wire behavior still needs
the spike. Otherwise a Unix-socket WebSocket client is an additional dependency,
not a plain newline socket connection.

The protocol requires `initialize` then `initialized`. Poll
`thread/read` with `includeTurns: false` for registered IDs; discovery can use
`thread/loaded/list` with pagination. Handle partial/coalesced JSONL messages
and request IDs. Notifications may accelerate updates if delivered to the
observer, but polling remains sufficient. Do not resume a thread just to obtain
status or take responsibility for its approvals.
[Protocol and lifecycle](https://learn.chatgpt.com/docs/app-server#protocol)

Before declaring Codex support complete, verify in two disposable terminal
sessions connected to one known endpoint that an independent observer reads
their status without taking over either conversation. Test prompt submission,
normal completion, tool execution, approvals, user questions, cancellation,
API failure, terminal detachment, and server reconnect. Prove how changing the
conversation invalidates or replaces its terminal binding. Save sanitized
responses as future adapter fixtures and record CLI/server versions.

If ordinary sessions have no observable endpoint, the recommended next choice
is an opt-in Portal launch/resume command using a known server. Until then mark
them unsupported; do not query a new server and present its stored history as
live status. Claude plus the common dashboard can ship as the first vertical
slice while this Codex spike is resolved.

## Summary spike: title, prompt excerpt, and current activity

These serve different purposes. A title identifies the job; a progress summary
describes what is happening now. Do not imply the former is the latter.

| Approach | Extra Portal model call? | Recommendation |
| --- | --- | --- |
| Existing provider `name` / title | No | Display when available; it may be generic or user-assigned. |
| Whitespace-normalized, truncated first prompt | No | Useful fallback if already available through the adapter; label its source. |
| Recent public tool/progress event | No | Optional activity hint such as `Running tests`; not a semantic task summary. |
| Fresh semantic summary of recent work | Usually | Follow-up opt-in design with a model, cost budget, cache and refresh policy. |

Claude's native agent-view summaries use a Haiku-class model, but its documented
JSON list schema does **not** expose that summary. Do not scrape its private
job files to obtain it. [Claude row summaries](https://code.claude.com/docs/en/agent-view#row-summaries)

Claude's optional status-line JSON separately exposes `session_name`, including
its generated title when available, and directory metadata. It has no documented
busy boolean. Composing an existing status-line command could supply richer
titles later, but replacing the user's status line is unnecessary for v1.
[Claude status-line fields](https://code.claude.com/docs/en/statusline#available-data)

For Codex, use `name` when present, otherwise a bounded `preview` excerpt.
Neither field proves what the agent is doing at this instant. The checked
sources do not establish ChatGPT's internal title-generation model, so choosing
a particular cheap model based on that assumption is not justified.

Spike outcome: **job identification is feasible without adding any LLM call**.
Continuously updated semantic summaries are optional further work. Do not
fetch complete transcripts each second merely to populate a table cell.

## Session naming: researched follow-up only

Herdr separates an agent alias from pane labels and status. Its alias identifies
a live agent occupant and clears when that occupant changes; display metadata
does not alter semantic activity.
[Herdr agent naming](https://herdr.dev/docs/agent-automation/)

Portal already supports terminal buffer renaming, but a buffer can later host
a different conversation. Recommend a separate, optional user-owned session
label keyed by provider, profile/endpoint and native conversation ID. It should
survive resume, remain unchanged by generated titles, and stay independent of
buffer renaming. Display precedence would be user label, provider title, known
prompt excerpt, terminal buffer name.

Two follow-up choices:

- **Local Portal label (recommended):** consistent across providers; persist in
  Emacs user data, outside repositories. Need rules for clearing labels and
  removing stale entries.
- **Rename in the provider:** visible in that provider's other clients, but
  changes shared conversation metadata and requires provider-specific writes.
  Codex exposes `thread/name/set`; Claude supports native session naming.
  [Codex naming API](https://learn.chatgpt.com/docs/app-server#api-overview),
  [Claude session names](https://code.claude.com/docs/en/statusline#available-data)

Do not implement either naming option, persistent label storage, or a rename
command as part of the dashboard. Reading existing titles is allowed.

## Decisions before implementation

| Decision | Proposed default | Alternative |
| --- | --- | --- |
| Initial providers | Claude and Codex adapters; deliver Claude slice first if Codex ownership spike fails. | Codex-only priority requires resolving its server connection first. |
| Association | Explicit registration of existing Portal terminals. | Add a launch/resume workflow if automatic registration is required immediately. |
| Unsupported/older agents | Show unsupported/unknown with the reason. | A separately maintained screen/OSC fallback, or best-effort hooks clearly labelled as such. |
| Waiting on the user | Idle with an attention reason. | Add a third visible `waiting` activity later. |
| Refresh | 1-second asynchronous polling while visible. | Slower cadence for resource use; Codex notifications for lower latency after validation. |
| Task text | Existing titles or known prompt excerpts. | Optional provider-specific activity hints; LLM summaries later. |

A Herdr-backed alternative would poll its agent API and attach Herdr-owned
terminals. It supplies detection and metadata but adds a terminal manager and
changes session ownership. It is not a passive backend for current Portal
terminals, so it is not the recommended first version.
[Herdr socket API](https://herdr.dev/docs/socket-api)

## Acceptance criteria for the future implementation

- [ ] One Emacs dashboard lists all registered live Portal agent sessions across
  projects and frames; ordinary and quick terminals work, including hidden ones.
- [ ] Successful Claude polling and the Codex ownership spike establish the
  supported versions and connection requirements; unsupported cases are explicit.
- [ ] Working, idle, approval/input waits, cancellation and errors follow the
  normalization contract. Idle never claims success, and unavailable never
  silently becomes idle.
- [ ] A fresh status normally appears within 2 seconds while Emacs is responsive.
  Slow providers cannot block typing or cause overlapping polls.
- [ ] Two agents in the same directory keep separate IDs, rows and destinations.
  Re-registration, changed conversations, reused PIDs and terminal replacement
  cannot silently redirect a row.
- [ ] Paths reflect provider `cwd` and the correct project/worktree; spaces,
  Unicode, missing directories and non-project directories work.
- [ ] `RET` selects and focuses the correct terminal from a visible or hidden
  state, including other frames and quick panels. Dead bindings report a clear
  error without creating a new terminal.
- [ ] Refresh preserves selection, scroll and sorting. Opening the dashboard
  twice does not create duplicate timers; hiding/killing it stops UI polling.
- [ ] Timeout, malformed JSON, split protocol messages, a missing session,
  late responses, disconnection and reconnect have fixture-based coverage.
- [ ] ERT covers normalization, exact binding, polling lifetime and redraw
  behavior. A focused graphical check covers real terminal focus and frame
  handoff. No test depends on paid model requests.
- [ ] Existing provider titles are shown when available. No naming feature,
  transcript-wide summary job, or additional LLM call is introduced.
- [ ] README documents setup/registration, commands, supported providers,
  refresh semantics, and the limits of automatic discovery.

## Out of scope

Controlling or stopping agents from the dashboard; sending prompts or approving
tools; launching a replacement chat frontend; remote/container/tmux discovery;
other terminal packages; detached jobs without terminal buffers; historical
session browsing; internal subagent rows; desktop-app task monitoring; manual
session naming; automatic semantic summaries.
