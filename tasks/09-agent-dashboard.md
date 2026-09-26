---
status: todo
---

# 09: Live agent dashboard in Emacs

Research and proposed implementation spec · updated 2026-09-27

## Outcome and recommendation

Build `M-x portal-agents`: an Emacs table of agents in local Portal terminal
buffers, showing working or idle, attention, project/path, and available job
text. Refresh every second; `RET` selects and focuses that terminal. Include
Codex CLI, Claude Code, and Pi in the compatibility investigation.

**Use Ghostty as the common event collector.** Portal's pinned dependency
already exposes progress, notification, bell, title, and directory callbacks.
Cache these per terminal surface and expose them to Elisp through native
inspection. This is simpler than requiring a separate provider connection and
matching every conversation back to a terminal.

**Common terminal transport is feasible; universal agent lifecycle semantics
are not established.** A CLI must emit useful signals, and “clear progress” or
“send notification” does not necessarily mean “agent is idle.” Keep collection
generic, select one status authority per tracked terminal, and use small
harness-specific integrations or verified mappings where needed.

Recommended order: generic collector/table, Pi lifecycle producer, then a
bounded Claude/Codex compatibility spike. Support unintegrated terminals as
explicitly unknown or inferred, rather than inventing idle from silence.
Provider APIs remain optional stronger status/metadata sources.

This replaces the earlier API-first proposal. No runtime feature, agent
configuration, extension, naming command, or model call is implemented by this
research change. The spec stays in the user's requested `docs/tasks/` location.

## What the terminal can tell us

OSC means Operating System Command: an escape sequence embedded in terminal
output. Ghostty parses it and delivers an event associated with its surface.
The receiver therefore already knows which Portal terminal produced the event.

| Terminal signal | Meaning | Dashboard use |
| --- | --- | --- |
| OSC `9;4;1;N` / `9;4;3` | Progress percentage / indeterminate progress | Evidence of work in a tracked agent terminal. |
| OSC `9;4;0` | Remove progress | Idle only under a tested producer contract; otherwise unknown. |
| OSC `9;4;4;N` | Progress paused | Preserve raw state; needs-input mapping is harness-specific. |
| OSC `9;4;2;N` | Progress error | Error evidence, not successful completion. |
| OSC `9;message` / `777;notify;title;body` | Desktop notification request | Attention hint; no universal start/stop or reason field. |
| BEL | Bell | Optional attention hint, not lifecycle state. |
| OSC 0 / 2 | Terminal title | Job label or provider-specific status convention. |
| OSC 7 | Reported working directory | Path hint, with launch directory as fallback. |
| OSC 133 / command-finished callback | Shell semantic regions / command completion | Outer shell lifecycle, not every turn inside a persistent CLI. |

These are established terminal conventions, not an agent-status standard.
For OSC 9;4, Ghostty recommends periodic refresh, approximately once per
second, because the protocol itself has no liveness mechanism.
[Ghostty progress protocol](https://ghostty.org/docs/vt/osc/conemu)

Notifications are supported, including the kind agents use when awaiting
input. But agents may suppress them while focused, disable them in settings,
or send a bell instead. No notification means nothing conclusive.
[Ghostty notification protocol](https://ghostty.org/docs/vt/osc/9),
[Ghostty notification settings](https://ghostty.org/docs/config/reference#desktop-notifications)

Important limits:

- The pinned engine throttles notifications **before** the host callback:
  one per second across the Ghostty app, with additional suppression of repeated
  identical content for five seconds. Concurrent terminal alerts can collide.
  Never encode a lossless status stream in notification text.
  [Pinned notification implementation](https://github.com/ghostty-org/ghostty/blob/82938b633ba6/src/Surface.zig#L6462)
- Clearing progress can also result from a terminal reset. Generic progress
  has no agent ID, producer ID, run ID, sequence number, or exit reason.
  Child tools sharing a PTY can overwrite it.
- Ghostty's documented progress-display timeout is not an agent completion
  event. Silence, quiet output, a live process, or a missing spinner cannot
  establish idle.
- OSC 133 is not a generic agent lifecycle solution: Pi even uses its markers
  around rendered user/assistant messages.
  [Pi user-message markers](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/modes/interactive/components/user-message.ts#L60)
- SSH may carry escape sequences, but tmux/screen and configuration can filter
  them. Remote paths and nested/multiplexed terminals need separate support.

## Verified Portal/Ghostty integration seam

Portal pins libghostty-spm **1.6.20260909**, revision
`7e45d27160f9b34aca9ca5c9820e9207482f9f04`. Its bundled Ghostty binary identifies
upstream revision `82938b633ba6`.

The Swift wrapper offers these delegates:

- `TerminalSurfaceProgressReportDelegate`: `remove`, `set`, `error`,
  `indeterminate`, `pause`, plus an optional percentage.
- `TerminalSurfaceDesktopNotificationDelegate`: title and body.
- `TerminalSurfaceBellDelegate`.
- `TerminalSurfacePwdDelegate`.
- `TerminalSurfaceCommandFinishedDelegate`.
- `TerminalSurfaceTitleDelegate`, already used by Portal.

[Delegate definitions](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift)

The callback bridge forwards these actions to the originating surface on the
main actor. Despite its source directory being named `InMemory`, the bridge
also handles ordinary process-backed terminal surfaces. An engine replacement
or raw PTY parser is unnecessary.
[Callback dispatch](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Controller/TerminalController%2BCallbacks.swift),
[delegate forwarding](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/InMemory/TerminalCallbackBridge.swift)

Repository seams:

| Existing code | Proposed use |
| --- | --- |
| `native/Terminal.swift`, `HostedTerminal` | Adopt progress, notification, bell, and directory delegates; cache raw events. |
| `TerminalSession.inspect()` / `portal--inspect` | Return a bounded snapshot for the terminal, including telemetry generation. |
| `portal-view.el`, `portal-view-buffers` | Enumerate live terminal buffers across frames, including hidden ones. |
| `portal-terminal.el`, `portal-terminal--new` | Retain launch directory as an explicitly labelled fallback. |
| `portal-terminal-focus`, `portal-terminal-quick.el` | Reuse ordinary and quick-terminal display/focus paths. |
| `native/NativeEventChannel.swift` | Optional later “snapshot changed” hint; polling remains sufficient. |

There is no Emacs subprocess attached to these terminal buffers: Ghostty owns
the PTY. Ordinary comint filters or `get-buffer-process` are not the integration
point. The wrapper's PID/TTY accessors are currently stubs, but **that does not
block surface-to-buffer event routing**. It does limit automatic foreground
agent discovery and PID-based provider joins.
[Pinned accessors](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurface.swift#L405)

### Executed native probe

A disposable Objective-C/AppKit program linked Portal's actual pinned
`libghostty.a`, created an offscreen host-managed surface, fed synthetic bytes,
and recorded action callbacks. It did not run an agent or alter user settings.

| Input / experiment | Observed result |
| --- | --- |
| `ESC ] 9;4;3 BEL` | Progress state 3, unspecified percent. |
| `ESC ] 9;4;4;0 BEL` | Progress state 4, percent 0. |
| `ESC ] 9;4;0 BEL` | Progress state 0. |
| OSC 9 notification | Notification callback; message was in body. |
| OSC 777 immediately after OSC 9 | Dropped before callback. |
| Same OSC 777 after 1.2 seconds | Notification callback with title/body. |
| OSC 2, OSC 7, bare BEL | Title, `/tmp` directory, and bell callbacks. |
| Indeterminate progress followed by 16 seconds without output | No automatic remove callback observed. |
| Full terminal reset, `ESC c` | Progress state 0 callback. |

This validates engine parsing and the event seam, not real harness lifecycle,
Swift delegate adoption, OS notification delivery, or focus behavior. The
wrapper dispatch was source-checked separately. A future integration test can
reproduce these bytes without credentials or model requests.

## Harness compatibility

### Claude Code

Claude documents terminal progress enabled by default through
`terminalProgressBarEnabled`, including Ghostty support. Its progress remains
visible for background work after a turn ends and clears when idle. This makes
native progress promising, but exact raw idle/paused values, permission waits,
interrupts, terminal detection, and version behavior still need a real TUI probe.
[Claude progress setting](https://code.claude.com/docs/en/settings-reference#terminalprogressbarenabled)

Claude also documents terminal notifications on completion/permission waits
when the user appears away. Ghostty is one of the default notification
destinations. `preferredNotifChannel` and tmux passthrough affect delivery.
These alerts augment attention; they cannot drive a complete activity model.
[Claude terminal configuration](https://code.claude.com/docs/en/terminal-config#get-a-terminal-bell-or-notification)

Fallback already verified locally: **Claude 2.1.283**, `claude agents --json`,
returned an interactive session with `cwd`, `pid`, `sessionId`, `name`,
`startedAt`, and `status: idle` in approximately 195 ms for one invocation.
Documented states include `busy`, `waiting`, and `idle`. This can be a stronger
optional authority, but requires exact session-to-buffer association. Do not
join by directory alone or read private job-state files.
[Claude JSON interface](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)

### Codex CLI

Codex documents terminal notifications using OSC 9 or BEL, configurable by
`tui.notifications`, `tui.notification_method`, and
`tui.notification_condition` (`unfocused` or `always`). Completion and
approval notifications are available, but these docs do not establish a
complete OSC progress lifecycle. Terminal titles are configurable too.
[Codex notification configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications)

Herdr's Codex detector uses a title spinner for working and `Action Required`
for blocked, with screen rules as fallback. Portal can test the same title
conventions, but must label them inferred and account for user title settings.
Do not claim every Codex version emits a universal progress state.
[Codex detection manifest](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/detect/manifests/codex.toml)

Optional stronger source: the app-server owning the terminal session exposes
`thread/read`, `thread/loaded/list`, and `thread/status/changed`, distinguishing
active, idle, system error, and not loaded, with approval/input flags.
Local **Codex 0.155.1** schema generation verified these fields and the
`app-server proxy --sock` command. The default daemon socket was absent; an
independent observer of existing terminal sessions was **not** verified.
Starting another server is not a global status query.
[Codex app-server](https://learn.chatgpt.com/docs/app-server)

Keep that ownership/observer spike optional. The terminal collector and table
do not need an app-server connection, a new daemon, or a replacement Codex UI.

### Pi

Source inspected at revision `2b0a123de98318c2ff8069661721ce0c3794c34e`, a
post-release checkout reporting package version **0.87.1**; locally installed
Pi is **0.87.0**. The changelog places `agent_settled` in **0.80.4** and UI prompt
events in **0.84.4**, so both predate the local installation. Real lifecycle
behavior still needs validation; the inspected checkout is not a release tag.
[Pi changelog](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/CHANGELOG.md)

- Built-in `terminal.showTerminalProgress` is **false by default**. When enabled,
  Pi emits OSC `9;4;3` immediately and every 1,000 ms, then OSC `9;4;0` to clear.
  This path is gated by the setting, not `TERM_PROGRAM=ghostty`.
  [Progress writer](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/tui/src/terminal.ts#L532),
  [default setting](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/core/settings-manager.ts#L1252)
- The TUI clears progress at `agent_end`, which can precede retries, recovery,
  compaction, or queued continuation. **`agent_settled` is the full-run idle
  boundary.** Native progress clear alone can therefore show false idle.
  [TUI lifecycle](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L3519),
  [extension lifecycle documentation](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/docs/extensions.md#L54)
- The official optional notification extension uses `agent_settled`. It chooses
  Windows toast, Kitty OSC 99, or otherwise OSC 777. A bare Pi installation is
  not guaranteed to send completion notifications.
  [Notification example](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/examples/extensions/notify.ts#L26)
- Pi's title includes an available session name and directory basename. Useful
  job text is possible without another LLM call.
  [Title construction](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L1075)

## How Herdr gets status

Herdr first identifies the foreground agent. It then chooses **one status
authority**: a complete actively reporting lifecycle integration, or
agent-specific rules over the live bottom of the terminal buffer plus
title/progress evidence. Scrolling the viewport does not change that snapshot.
[Herdr status authority](https://herdr.dev/docs/agents/#status-authority)

At Herdr revision `fff6c820aa45f4eabb9b2e0456326dc74cca5a25`:

| Harness | Actual Herdr mechanism |
| --- | --- |
| Pi with integration | A Pi extension reports `agent_start` / `agent_settled`, initializes from `ctx.isIdle()`, and reports session identity. It sends JSON via a local socket using `HERDR_PANE_ID`, source, and sequence number. |
| Pi without integration | Screen rules recognize its working display. |
| Claude | Hooks report session identity; screen/title/progress rules decide status. Its manifest treats the OSC 9 payload `4;0` (progress subcommand 4, remove state 0) as low-priority idle evidence. This means OSC `9;4;0`, not paused state 4. |
| Codex | Hooks report session identity; screen/title rules decide status. |

[Pi integration](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/integration/assets/pi/herdr-agent-state.ts),
[Pi manifest](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/detect/manifests/pi.toml),
[Claude manifest](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/detect/manifests/claude.toml),
[integration roles](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/docs/preview/website/src/content/docs/integrations.mdx#L60)

Herdr's Pi extension uses a Herdr-specific `herdr:blocked` event bus for blocked
state; it does not yet use Pi's newer UI prompt events. Its “done” presentation
means idle and not yet seen, not proven successful task completion.
[Done mapping](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/app/api_helpers.rs#L94)

Borrow the separation of collector, authority, and display. Adopting Herdr as
a backend would require Herdr-owned terminals and a different terminal workflow;
it is not a passive status service for Portal's existing surfaces.

## Proposed architecture and status contract

```text
CLI / optional lifecycle producer
        │ terminal escape sequences
        ▼
Ghostty parser → surface delegates → bounded TerminalSession snapshot
                                              │ portal--inspect
                                              ▼
                             one Emacs timer (1 second)
                                              │
                              normalize chosen authority
                                              ▼
                          *Portal Agents* → RET → terminal buffer
```

Store two normal activity values, **working** and **idle**. Idle means no current
work, including a known wait for user input; it does not certify success.
Separately retain attention, evidence source, and telemetry health.
Display `unknown` when activity cannot be established.

| Observation | Normalization |
| --- | --- |
| Known producer says active | Working. |
| Known producer says settled / ready | Idle. |
| Known producer says awaiting input | Idle with attention and reason. |
| Generic tracked-terminal active progress | Working, labelled observed progress rather than proven full-run state. |
| Generic clear / pause without a verified mapping | Unknown; retain raw observation. |
| Notification / bell | Set an attention hint; do not change activity or infer a specific reason from generic transport alone. |
| Error, unsupported source, stale promised heartbeat, missing provider record | Unknown with diagnostic; keep last observation for inspection. |
| Terminal closes | Remove live row and binding; never infer successful completion. |

Choose one authority explicitly: lifecycle integration, verified harness
mapping, optional native provider API, or opt-in heuristic. Do not continuously
mix competing start/stop sources. Notifications may augment attention independently.
Display source/confidence in row details; inferred rows get a visible marker.

### Minimal common producer contract

For cooperative harness integrations, propose OSC `9;4;3` for working,
`9;4;0` for idle, and optionally `9;4;4;0` for awaiting input.
The meanings assigned to clear and paused are **Portal's producer convention**.
They are not guaranteed for arbitrary applications emitting those sequences.

For Pi, a small opt-in extension can implement this without a model call:

1. Activate only in the root TUI (`ctx.mode === "tui"`) with a Portal launch
   marker. On `session_start`, publish a baseline from `ctx.isIdle()`.
2. Publish working at `agent_start`. Publish idle at `agent_settled` only when
   `ctx.isIdle()` confirms it. Do not use `agent_end` as completion.
3. Every second, recompute and publish the state, including idle. This recovers
   from a missed transition and detects standalone compaction. Use a monotonic
   age locally; a missed heartbeat makes status stale, never idle.
4. Optionally map `ui_prompt_start` / `ui_prompt_end` using a pending-prompt
   flag. At end, recompute idle instead of blindly restoring working. These
   events cover blocking extension UI, not all possible native dialogs.
5. Dispose timers on `session_shutdown`; replace safely on reload. Reinitialize
   on conversation changes. Disable Pi's native progress writer for this
   integration to avoid its earlier `agent_end` clear racing with the producer.

[Pi idle query](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/core/agent-session.ts#L1231),
[UI event types](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/core/extensions/types.ts#L837),
[UI event emission](https://github.com/earendil-works/pi/blob/2b0a123de98318c2ff8069661721ce0c3794c34e/packages/coding-agent/src/core/extensions/runner.ts#L527)

This is a cooperative, best-effort terminal contract. It assumes one status
writer and cannot distinguish reset-generated clears or rogue child-tool
progress. Heartbeats repair transient interference; they do not make OSC an
authoritative machine protocol. Do not claim strict correctness under these
conditions or automate agent actions based on this dashboard.

If exact identity, exit detection, and interference-free status become
requirements, use a small structured per-terminal reporter with source,
generation, sequence, and lease over local IPC, as Herdr does. Keep the same
Elisp snapshot/table. Alternatively use native provider snapshots with explicit
binding. Do not invent a private OSC number and call it a standard.

Claude/Codex hooks need a separate lifecycle audit before implementing this
contract. Captured hook stdout is not necessarily terminal output: emission
would require the actual controlling TTY or an explicit reporter. Hooks running
in a detached server may have neither the TTY nor its launch environment.
A simple prompt-start/stop pair misses interruption and continuation paths.
[Claude hook lifecycle](https://code.claude.com/docs/en/hooks#hook-lifecycle),
[Codex hooks](https://learn.chatgpt.com/docs/hooks)

### Identity, discovery, and paths

Use `(terminal-target, incarnation)` as the row ID and store the actual Emacs
buffer object. Never match rows by buffer name, title, or path. Two agents in
the same worktree must remain independent.

Initially `portal-agent-track` marks the current Portal terminal and selects a
harness and available mapping. It does not ask for a native session ID unless
an optional provider API needs one. Enumerate every tracked live terminal,
including idle and hidden terminals. Registration is necessary because a
progress bar from curl or a build does not identify a coding agent.

A later Portal launcher can set a terminal marker and register automatically.
Auto-detecting every agent launched manually requires foreground-process
discovery not currently exposed by the pinned wrapper. For v1, stopping the
CLI inside a still-running shell requires untracking/retracking; heartbeats
can mark a departed producer stale but cannot prove what replaced it.
Registration alone must not imply a healthy connected agent.

Remove bindings when the view closes, is replaced, or its buffer is killed.
Renaming/moving a buffer preserves its identity. A terminal incarnation change
invalidates all cached events. Native conversation IDs are optional metadata,
needed later for persistent names/resume, not for `RET`.

Path precedence: integrated agent cwd, reported OSC 7 directory, launch
directory. Record which source supplied it. OSC 7 is only the latest report;
shell integration may not emit while a CLI changes directory. Resolve local
project/worktree root on path change and preserve the full cwd in details.
Cache project lookup; never run Git or probe remote/missing paths on every
timer tick. Ghostty validates OSC 7's hostname as local and passes a decoded
path to the callback; this does not provide general remote-directory discovery.
Show the launch-path fallback when no usable report exists. If a later adapter
supplies an explicitly remote path, display it without resolving it locally.
[Pinned directory parser](https://github.com/ghostty-org/ghostty/blob/82938b633ba6/src/termio/stream_handler.zig)

### Snapshot and Elisp polling

Add `portal-agents.el` for tracking, normalization, snapshots, the table, and
timer ownership. Keep native collection in `native/Terminal.swift`; add small
per-harness mapping modules only as needed. Load through `portal.el`.

Proposed public functions, not existing APIs:

```elisp
(portal-agents)                  ; open/reuse *Portal Agents*
(portal-agent-track)             ; track this terminal and choose its source
(portal-agent-untrack)           ; remove tracking, never stop the CLI
(portal-agents-refresh)          ; refresh cached native snapshots
(portal-agents-snapshot)         ; return copies of normalized cached rows
```

Native snapshot fields: terminal generation, monotonic event sequence,
raw progress/percent and receive time, title, cwd, last bounded notification
title/body/time plus a counter, bell counter/time, and closed state. These are
local counters, not producer identity or a promise of lossless notifications.
Raw callback collection continues when terminals/dashboard are hidden.
Sanitize/truncate text for display and avoid unbounded event history.

Elisp adds buffer, harness, selected authority, activity, attention, health,
source/confidence, project root, path source, and observation time. Read-only
raw telemetry must be inspectable when diagnosing a wrong status.

Use one normal timer, default 1 second, while the dashboard is visible in any
frame. Refresh immediately on opening or `g`; stop the UI timer when hidden
everywhere/killed. Other Lisp can request snapshots without opening the UI.
Native inspection reads memory and does not spawn a CLI. Skip redraw when the
displayed data has not changed. Target an update within 2 seconds while Emacs
is responsive, not a hard real-time guarantee.
[Emacs timers](https://www.gnu.org/s/emacs/manual/html_node/elisp/Timers.html)

Only sources that promise heartbeats get a heartbeat lease (initially 5 seconds).
A long-lived cached title/cwd is not stale merely because it is unchanged.
After sleep/reconnect, an integrated producer needs a fresh report; never
convert stale working to idle. Ignore late events from old incarnations.

If native provider polling is enabled, run it asynchronously, once per
provider/endpoint rather than per row; use bounded output, timeouts, generation
checks, and no overlapping requests. It must not block Emacs's timer or input.
For Claude, use `make-process` and `agents --json`. For Codex, first prove
an observer can query the owning server without taking over approvals or
resuming a thread. Map missing/not-loaded sessions to unknown.

## Dashboard behavior

```text
*Portal Agents*                            2 working, 2 idle, 1 unknown

Status      Agent   Project / path                   Task                     Terminal
working     Pi      ~/work/portal                    Dashboard research       *portal-terminal*
idle        Claude  ~/work/api                       Fix login tests          *portal-terminal*<2>
idle !      Pi      ~/work/docs                      Update deployment guide  *portal-quick:…*
working ~   Codex   ~/work/portal/.worktrees/search   Search results           *portal-terminal*<3>
unknown     Codex   ~/work/other                      No supported signal      *portal-terminal*<4>

RET visit terminal   g refresh   a track   d untrack   q quit
! attention    ~ inferred
```

Illustrative output. Use built-in `tabulated-list-mode` with stable row IDs.
Preserve row selection, sorting, point, and window start during refresh.
Default to registration order. Never steal focus on an update.
[Emacs tabulated lists](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tabulated-List-Mode.html)

`RET` selects an existing window displaying the target buffer, even on another
frame, or displays it if hidden, then calls `portal-terminal-focus`. Use the
existing quick-terminal panel path for quick buffers. A dead target reports a
clear error; it must not silently create a new terminal. Visiting acknowledges
a generic attention hint; a producer still awaiting input retains its reason.

The empty state explains tracking. Unsupported/disabled signals show a reason
and setup guidance. Opening the dashboard twice must not create duplicate
timers. `q` quits the dashboard only; `d` removes tracking only.

## Summary spike and naming follow-up

A stable task title and a live semantic progress summary are different fields.

| Job text source | Extra Portal LLM call? | Recommendation |
| --- | --- | --- |
| OSC title or existing provider/session name | No | First choice; may be generic or user-assigned. Strip only verified harness status decoration. |
| Known first-prompt excerpt | No | Optional bounded fallback if an API already provides it; label its source. |
| Public tool/progress event | No | Optional factual hint such as “Running tests,” when available. |
| Fresh semantic summary of recent work | Usually | Separate opt-in feature with cost, privacy, and caching decisions. |

Codex's `preview` is generally first-prompt text, not a live generated summary.
Claude's agent-view summaries use a Haiku-class model, but its documented JSON
list does not expose them. Its status-line JSON can expose a session name; do
not replace the user's status-line configuration merely to obtain it.
[Claude summaries](https://code.claude.com/docs/en/agent-view#row-summaries),
[status-line metadata](https://code.claude.com/docs/en/statusline#available-data)

The checked sources do not establish ChatGPT's internal title-generation model.
No new LLM is needed for useful initial job identification. Do not fetch whole
transcripts every second.

**Manual session naming remains a follow-up only.** Herdr separates display
aliases from semantic activity; its live-agent alias is tied to the occupant.
Portal already offers terminal buffer renaming, which is not conversation
naming. [Herdr naming](https://herdr.dev/docs/agent-automation/)

Recommend a local Portal label first: user label > provider/session title >
known prompt excerpt > terminal buffer name. Persist a conversation label only
when a stable provider/profile/session ID is available. A terminal-only label
belongs to its incarnation and must not silently transfer to a new agent.
Provider-side renaming is an alternative when the name should appear in other
clients; it requires provider-specific writes. Neither option, persistence,
nor a rename command is part of the dashboard implementation.

## Decisions and delivery slices

| Decision | Recommended default | Alternative / tradeoff |
| --- | --- | --- |
| Common receiver | Ghostty callbacks and cached snapshots. | External agent API polling adds connection and binding work. |
| First complete lifecycle producer | Opt-in Pi extension, using settled/idle semantics. | Native Pi progress alone is smaller but has known false-idle gaps. |
| Claude/Codex compatibility | Probe actual progress/title behavior; mark verified mappings versus inference explicitly. Use Claude JSON optionally. | Full Herdr-like screen detection improves coverage but adds parsers and ongoing maintenance. |
| Accuracy beyond cooperative OSC | Explicitly document best-effort limits. | Structured local reporter or authoritative native API when strict state/identity is required. |
| Discovery | Track current terminal; add launcher later. | Foreground process discovery requires additional native support. |
| UI state | Working/idle plus attention and unknown health. | Dedicated waiting state later. |
| Job text | Existing title/name, no new model call. | Semantic summaries later. |
| Names | Research only in this task. | Separate naming implementation after identity design. |

Delivery slices:

1. Capture native callbacks, expose snapshots, and build the generic table,
   polling, tracking, path display, and `RET`. Validate with synthetic bytes.
2. Add the opt-in Pi producer and its lifecycle fixtures; retain known OSC
   interference limits. Verify supported Pi versions before claiming coverage.
3. Run Claude/Codex compatibility probes; implement the selected minimal
   mappings/adapters. Report unsupported versions/settings explicitly.
4. Revisit structured reporting or screen heuristics only if observed gaps
   prevent the user's daily workflow. Naming and semantic summaries stay separate.

## Acceptance and remaining experiments

- [ ] A single dashboard lists every tracked live Portal agent terminal across
  projects and frames, including idle, hidden, and quick terminals.
- [ ] Synthetic sequences reproduce progress/notification/bell/title/cwd
  callbacks using the pinned engine. Collection works on ordinary process-backed
  surfaces; no OS notification permission or paid model request is required.
- [ ] Capture actual Claude, Codex, and Pi behavior with recorded versions and
  effective terminal identity/configuration. Test focused and unfocused states;
  verify `TERM_PROGRAM`/version negotiation rather than assuming standalone
  Ghostty settings apply to embedded Portal.
- [ ] Harness fixtures cover prompt submission, tools, completion, permission
  waits, user questions, cancellation, API failure, retries, compaction, queued
  continuation, reload, and conversation change. Unsupported cases show unknown
  or documented inference, never an unqualified claim of correctness.
- [ ] Pi full-run idle uses settled plus `isIdle()`; native `agent_end` cannot
  falsely complete an integrated run. Idle extension dialogs do not resume
  working when dismissed. Version-gate newer UI events.
- [ ] Notification suppression/throttling does not alter activity. A missing
  signal, long silence, terminal reset, or another tool's progress does not
  become proof of successful completion. Expose OSC ambiguity and verify
  producer heartbeats recover from transient interference.
- [ ] A fresh report normally appears within 2 seconds on a responsive machine.
  One timer, no subprocess in the default refresh, and no overlapping optional
  API polls; hidden dashboard stops UI polling but native collection continues.
- [ ] Two agents in the same directory have separate rows and destinations.
  Renames, terminal replacement, stale heartbeats, sleep/wake, close, and late
  events cannot silently redirect or retain a healthy-looking dead binding.
- [ ] Directory source and project/worktree are correct; spaces, Unicode,
  non-project, missing, and remote paths are handled without blocking polls.
- [ ] `RET` focuses the correct ordinary/quick terminal in visible, hidden,
  and other-frame cases. Refresh preserves selection, scroll, and sorting.
- [ ] ERT covers normalization, incarnation identity, lease/timer lifetime,
  and redraw behavior. A graphical check verifies real terminal focus.
- [ ] README documents tracking, supported versions/settings, confidence,
  polling semantics, manual-untracking limits, and setup/recovery.
- [ ] No session naming, persistent labels, transcript summary job, or new LLM
  call is introduced.

Out of scope: controlling agents, sending prompts/approvals, replacement chat
frontends, detached jobs, internal subagent rows without separate terminals,
desktop-app tasks, historical sessions, non-Portal terminal packages, and
automatic SSH/container/tmux discovery.
