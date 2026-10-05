# Automatic agent discovery and status in Portal terminals

Research date: 2026-10-02. This records the evidence and tradeoffs behind the
design, not current implementation behavior or test coverage. For those, see
[the user guide](agents.md), [discovery policy](../portal-agent-discovery.el)
and [process collection](../native/Processes/Processes.c).

## Decision

Separate **identity** from **activity**. A foreground process establishes that
an agent is running in a Portal terminal; a harness-specific source describes
its activity. Terminal output cannot establish identity: replaying a captured
session reproduces its titles and progress without running an agent.

Use one activity authority per harness rather than merging conflicting hints:

| Harness | Chosen authority | Why |
| --- | --- | --- |
| Claude Code | `claude agents --json` | Titles and progress disagree at permission prompts; the JSON interface distinguishes waiting. |
| Codex CLI | Default terminal title, explicitly labelled as inference | No outside observer for ordinary launches was found. The shared daemon requires `codex --remote`. |
| Pi | A one-time lifecycle extension | Its default title does not change with activity, and it emits no progress by default. |

Missing evidence means `unknown`, not idle. Idle does not mean success: errors,
denials and cancellations can all end idle. Notifications are unsuitable as
completion signals: Claude notified after 60 s idle, Codex notified only while
unfocused, and Pi sent none.

Collect discovery and Claude status only while the dashboard is visible.
Discovery is a present-tense observation, not an event history: opening the
list can find an agent started earlier without monitoring the hidden dashboard.
The [cost measurements](#cost) argue against continuous CLI polling.

## Why process discovery was feasible

The pinned Ghostty wrapper's foreground-PID and TTY APIs were stubs, including
releases through 1.6.20261001. Its random surface ID was not exposed to the
embedder. This ruled out using Ghostty directly to bind processes to views.

A terminal-specific environment marker survived into agent processes and was
readable by another process of the same user. A login zsh's environment read
back empty, and the root-owned `/usr/bin/login` was inaccessible: read the marker
from the agent, not its shell. This overturned the earlier conclusion that
Ghostty's missing APIs blocked automatic discovery.

Names alone were insufficient: `exec -a claude sleep` supplied a false name,
and ChatGPT's desktop app ran a real `codex` outside any terminal. The prototype
combined foreground-process facts, executable checks and the terminal marker.
Synthetic titles, replayed sessions and unrelated progress never produced rows.
It also found agents at trust dialogs and several agents sharing one directory,
where title- or project-based identity would be ambiguous.

Process visibility was measured at 0.17–0.74 s after Enter, independently of the
dashboard refresh interval. Pi's process rename took 0.1–0.2 s after Node started;
its environment remained readable after the argument area's NUL padding.

## Evidence and limits

### Environment

| Component | Recorded version |
| --- | --- |
| macOS / hardware | 27.0.1 (26A434), Apple silicon |
| Emacs / shell | Graphical Emacs 31.1, `emacs -Q`; zsh 5.9, login and interactive |
| Ghostty | libghostty-spm 1.6.20260909 (`7e45d27`), Ghostty `82938b633ba6` |
| Claude Code | 2.1.287, native binary |
| Codex CLI | 0.155.1, native binary from mise |
| Pi | 0.87.0, Node 26.9.0, from mise |

Existing workmux/herdr integrations were inert outside their environments.
Claude's progress/notification settings and Codex's TUI settings were defaults;
Codex had a notify program but no shared app-server daemon. Claude and Codex
used a trusted checkout; Pi exercised the trust dialog with session-only trust
or cancellation. An expired Pi OAuth token supplied a real provider-error trace;
working turns used `openrouter/anthropic/claude-haiku-4.5`. Claude used Haiku and
Codex low reasoning effort to save quota; discovery checks used plain commands.

### Method

- [Headless captures](agent-discovery/capture.py) recorded CLI emissions against
  a simulated terminal. They establish what the CLI sent, not what Ghostty received.
- Two [graphical runs](agent-discovery/run-gui.sh) exercised real agents in Portal
  with a temporary [instrumentation patch](agent-discovery/instrumentation.patch)
  and [prototype](agent-discovery/prototype.el). The patch was reverted; these
  artifacts are historical, not part of the build.
- A [Pi lifecycle probe](agent-discovery/pi-lifecycle-probe.ts) compared extension
  events with `ctx.isIdle()`; a [candidate extension](agent-discovery/pi-progress.ts)
  tested progress transport.

The [sanitized replay fixtures](../test/fixtures/agent-signals) retain version,
scenario and clock metadata. Raw screens were discarded because they contained
account and usage text. Capture usage and prerequisites live in the scripts;
[scenarios](agent-discovery/scenarios) contain the inputs. Reproduction starts
real agents and makes model requests; some scenarios write under `~/.cache`.
For the historical second graphical run, set `SPIKE_USE_PROGRESS=1`.

### Findings that determine the design

**Claude:** permission prompts used the idle title glyph while progress still
said working. JSON reported `waiting` 0.3–0.5 s later. Denial changed progress
but not the title: title-only triggers left activity stale for 29.9 s in Portal;
adding progress triggers reduced that to 0.44 s. Thus terminal signals trigger
a query but do not supply Claude's status. At the trust dialog, Claude was absent
from JSON; at a trusted first prompt, listing took 1.4–2.1 s. Process identity
must not depend on that listing.

**Codex:** the title distinguished working and approval waits, but not every
interaction. MCP startup showed a working spinner for 1–2 s before the first
prompt; a model-failure menu showed idle. Customized titles were an untested
risk. This is useful, labelled inference—not a complete activity API.

**Pi:** the title stayed unchanged during work and remained after exit. OSC 133
marks surrounded rendered messages, not shell commands. Lifecycle probes ended
at `agent_settled` with `isIdle()` true, including provider failure and cancellation;
an Alt-Enter continuation joined the same run. The documented possibility of
`agent_end` preceding retry/recovery/continuation was not reproduced. Settled
state, not merely a turn-end event, was therefore the intended idle boundary.
The candidate extension rendered normally in the TUI and emitted nothing in RPC.

**Portal:** real Ghostty callbacks delivered titles, progress, notifications and
bells. New terminals emitted progress removal before any program ran, and shell
integration supplied command-line titles. Neither is evidence of an agent's
activity. OSC reports carry no PID: ordered delivery does not authenticate their
sender, and cached reports cannot establish a newly discovered process's state.

### What this spike did not establish

These are limits of the recorded research, not claims about today's test suite:

- Claude question/elicitation waits, background/MCP work after a turn, automatic
  retries, `/clear`, `/resume`, or the npm installation.
- Codex queued continuation, compaction, retries, patch approvals, customized
  titles or the npm wrapper; quota limited these checks.
- Pi automatic continuation ordering, `ui_prompt_*` dialogs, `/new`, `/resume`,
  reload or built-in progress enabled. The extension's waiting mapping remained
  a proposal, not a live-dialog result.
- Several frames, hidden quick-terminal discovery, sleep/wake, same-buffer view
  replacement or two marker-exporting Emacs instances. A suspended agent was
  untested, and whether to retain it as stopped was still an implementation choice.

## Cost

Measurements belong to the prototype and environment above, not a performance
promise for the current implementation.

| Measurement | Result |
| --- | --- |
| Full scan: all user process paths, then candidate arguments/environment | 4.4–5.9 ms idle (≈960 processes); run 1: median 11.2 ms, p90 23.6 ms, max 47.7 ms over 251 scans (each Claude starts several `node` MCP servers, all candidates) |
| Foreground-only scan: one `KERN_PROC_UID` snapshot, then only processes whose group owns their TTY (12 of 961) | 0.8–1.3 ms idle; 1.8–12 ms (median 2.7 ms) in run 2 |
| Scanner as a subprocess (prototype only) | 5–58 ms per call, mostly process start; an in-process scan avoids it |
| `claude agents --json` | 190 ms wall, 150 ms CPU, 148 MB; 22 queries over run 1's ~140 s with Claude activity |
| Dashboard hidden, a 10 Hz title spinner running for 11 s | 0 scans, 0 Claude queries; 90 terminal change records, 26.7 ms of Lisp in total (0.30 ms each) |
| Dashboard shown, same spinner | 7 scans; 92 change records, 29.3 ms of Lisp |

The CLI cost sample used five queries; polling every 2 s would consume about
7.5% of a core. Triggered queries with a 30 s visible safety poll were preferable.
Hidden collection can stop without eliminating existing terminal-metadata costs:
a working Codex spinner already cost about 2.4 ms of Lisp per second.

Strip activity animation before comparing dashboard rows. Otherwise working
Claude (one frame/second) or Codex (ten/second) causes repeated redraws of
unchanged facts: 2.7–7.0 ms/tick plus redisplay at 10–100 terminals (PR #59).
See [dashboard measurements](emacs-agent-dashboard-research.md#measurements).

## Alternatives considered

[Herdr v0.9.1](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/preview/website/src/content/docs/agents.mdx)
independently used foreground-process identity and Pi's settled lifecycle.
Its [integration rationale](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/preview/website/src/content/docs/integrations.mdx)
rejects status hooks because they miss permission results and Escape interrupts.
This supported the separation of identity from one activity authority, without
requiring Portal to copy Herdr's machinery.

- **Screen matching:** Herdr supplements
  [Claude](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/claude.toml)
  and [Codex](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/codex.toml)
  titles with screen rules for dialogs. That could close Codex's gaps, but adds
  maintained regexes and needs cheap screen reads. The pinned wrapper exposed
  range reads only for in-memory sessions; Portal offered select-all. Revisit
  only if the gaps justify changing the wrapper.
- **Pi socket protocol:** a single extension writer and ordered PTY delivery
  avoided a separate socket, sequence numbers, release calls and an Emacs server.
  This did not make OSC sender-authenticated. Keep other progress writers off.
- **Wrapper identity hints:** Herdr's `HERDR_AGENT` handles sandbox-hidden agents.
  None was in use here; an extra Portal hint was deferred until needed.
- **Rendering-dependent Claude triggers:** spinner glyphs changed at 2.1.228.
  Progress triggers and the safety poll hedge against future title changes;
  the title is never the Claude activity authority.

## Sources

- [Original signal-driven design](https://github.com/xiaoxinghu/portal/blob/1c04d8af227488dd7758141d84d5b9df77f5c5b7/docs/agent-state-design.md)
  and [validation task](https://github.com/xiaoxinghu/portal/blob/1c04d8af227488dd7758141d84d5b9df77f5c5b7/docs/tasks/08-agent-signal-spike.md)
  (closed PR #3): superseded for identity because signals can be replayed.
- [September 27 research](https://github.com/xiaoxinghu/portal/blob/b33c92a16e13acb848268b122d82b58072a2a480/tasks/09-agent-dashboard.md):
  prior observer/API findings; its PID/TTY obstacle was overcome by the marker.
- [libghostty-spm `TerminalSurface.swift` at 1.6.20260909](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurface.swift#L405):
  foreground PID and TTY stubs.
- [Ghostty `Surface.zig` at `82938b6`](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/Surface.zig#L58):
  random surface ID.
- [Pi extension events at v0.87.0](https://github.com/earendil-works/pi/blob/v0.87.0/packages/coding-agent/docs/extensions.md#events):
  the documented lifecycle semantics, distinct from what this spike reproduced.
- [Claude Code agent view](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)
  and `claude agents --help`: the supported JSON observer.
