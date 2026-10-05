# Automatic agent discovery and status in Portal terminals

Research date: 2026-10-02. Task: `agent-discovery-spike` in `project.org`.

## Decision

Typing `claude`, `codex` or `pi` in an ordinary Portal shell can add it to
`portal-agents` without tracking, labels or special launchers—even at a trust
dialog or first prompt. Identity and activity have separate sources:

- **Identity, for all three harnesses: the terminal's foreground process.**
  Portal exports `PORTAL_TERMINAL=<emacs-pid>/<view-target>` into each
  terminal's environment. Scan the user's processes for members of their TTY's
  foreground group named `claude`, `codex` or `pi` (by `argv[0]` or runtime script),
  verify the executable agrees, and read the agent's environment marker.
  The outermost agent per terminal wins. Incarnation means process ID plus
  start time. Titles, directories, progress and notifications never register agents.
- **Activity, one authority per harness:**

  | Harness | Authority | Setup | Without it |
  | --- | --- | --- | --- |
  | Claude Code | `claude agents --json`, joined by process ID: `busy`, `waiting`, `idle`. Query it when that terminal's title glyph or OSC 9;4 progress state changes, when the list is shown, when a new Claude process appears, and every 30 s while shown. | None | `unknown` (trust dialog, the first ~1.5 s, CLI failure) |
  | Codex CLI | Its default terminal title: a braille spinner means working, `Action Required` means waiting, otherwise idle. Label the source "title". | None | `unknown` when no title |
  | Pi | OSC 9;4 progress written by a small Portal extension: 3 working, 0 idle at `agent_settled`, 4 waiting on an extension dialog. | One-time install of the extension | `unknown` |

- **Unknown policy.** Activity stays `unknown` until the selected authority
  reports for this incarnation. Silence, notifications, bells, generic titles,
  another program's progress and process liveness never establish activity.
  `idle` does not mean success: failed turns also end idle.
- **Collection.** Scan only on dashboard opening, re-showing and visible refresh
  ticks. Hidden dashboards cost only today's terminal metadata. Identity is a
  present-tense fact: agents started while hidden appear when the list is shown.
- **Portal needs two new native facts:** a terminal environment marker with a
  foreground-process report, and its last OSC 9;4 progress state, announced
  through existing change records.

Implementation discovery bound: next visible refresh (default 2 s), immediately
on opening or re-showing. Measured process visibility was 0.17–0.74 s after
Enter; scans cost a few milliseconds (see [Cost](#cost)).

## What was run

| Item | Value |
| --- | --- |
| macOS | 27.0.1 (26A434), Apple silicon |
| Emacs | 31.1 (`/Applications/Emacs.app`), graphical `emacs -Q` |
| Ghostty | libghostty-spm 1.6.20260909 (`7e45d27`), Ghostty `82938b633ba6`; `TERM_PROGRAM_VERSION=1.3.2-HEAD-+82938b633` |
| Shell | zsh 5.9, login and interactive, user dotfiles under `ZDOTDIR` |
| Claude Code | 2.1.287 (native binary, `~/.local/share/claude/versions/2.1.287`) |
| Codex CLI | 0.155.1 (native binary from mise; 0.160.0 was available) |
| Pi | 0.87.0 (`@earendil-works/pi-coding-agent`, Node 26.9.0, from mise). A Homebrew Pi 0.80.3 exists but is not first on the login PATH. |

Terminal environment inside Portal: `TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`,
`COLORTERM=truecolor`, `INSIDE_EMACS=portal-ghostty`,
`GHOSTTY_SHELL_FEATURES=cursor:blink,path,title`, and a random
`GHOSTTY_SURFACE_ID` per surface. Ghostty's embedder API does not expose that
ID. `ghostty_surface_foreground_pid` and `ghostty_surface_tty_name` are stubs
returning nothing in the pinned wrapper or any release through 1.6.20261001;
Portal cannot obtain
terminal processes or TTYs from Ghostty.

Effective agent settings, unchanged by the spike:

- Claude: user hooks for workmux and herdr (`Notification`, `PostToolUse`,
  `SessionStart`, `Stop`, `UserPromptSubmit`). Both do nothing outside tmux or
  herdr. `terminalProgressBarEnabled` and `preferredNotifChannel` are at their
  defaults. The Portal checkout is a trusted folder.
- Codex: no `[tui]` settings, a `notify` program, and workmux/herdr hooks in
  `~/.codex/hooks.json`. The Portal checkout is trusted. No app-server daemon
  runs (`codex app-server daemon version` cannot connect).
- Pi: global extensions `fetch.ts`, `herdr-agent-state.ts` and
  `workmux-status.ts`, the last two inert outside herdr and tmux. The Portal
  checkout is untrusted; runs chose "Trust (this
  session only)" or cancelled the dialog. An expired default `openai-codex` refresh token supplied a real
  provider-failure trace; working turns used
  `--model openrouter/anthropic/claude-haiku-4.5`.

Turns used small models to save quota (`claude --model haiku`,
`codex -c model_reasoning_effort=low`). Discovery checks used plain `claude`,
`codex` and `pi`. Model choice does not change terminal signals.

### Method

1. **Headless captures.** [`capture.py`](agent-discovery/capture.py) runs CLIs in
   a pseudo-terminal with Portal's variables. It answers the same queries as Ghostty
   (DA, cursor position, colours, XTVERSION, mode reports), types scripted input,
   and records OSC titles, OSC 9;4 progress, OSC 9/777 notifications, OSC 133
   marks, BEL, focus reporting and `claude agents --json` samples on one monotonic
   clock. Scenarios: [`agent-discovery/scenarios`](agent-discovery/scenarios).
   This harness is not Ghostty: captures establish CLI emissions, not Portal
   reception.
2. **Real agents inside Portal.** [`instrumentation.patch`](agent-discovery/instrumentation.patch)
   temporarily logged every `HostedTerminal` title, directory, progress,
   notification, bell, command-finished and close callback with view target,
   monotonic time and wall-clock time. It exported `PORTAL_TERMINAL`, reported
   progress through `portal--inspect`, and enabled U+E000-prefixed pastes to run
   Ghostty binding actions (`text:\x1b` for Escape) for scripted dialog replies.
   [`prototype.el`](agent-discovery/prototype.el) adds discoveries to
   `portal-agents` using the above activity rules and the
   [`agentscan.c`](agent-discovery/agentscan.c) scanner.
   [`gui-run-1.el`](agent-discovery/gui-run-1.el) and
   [`gui-run-2.el`](agent-discovery/gui-run-2.el) drove clean graphical Emacs via
   [`run-gui.sh`](agent-discovery/run-gui.sh). None is in Portal's build; the patch
   was reverted.
3. **Lifecycle probes for Pi.** [`pi-lifecycle-probe.ts`](agent-discovery/pi-lifecycle-probe.ts),
   loaded for one run with `pi -e`, logged Pi's extension events with
   `ctx.isIdle()`. [`pi-progress.ts`](agent-discovery/pi-progress.ts) is the
   candidate Portal extension.

Reproduce a capture from a shell outside Claude Code (with `pip install pyte`),
from the Portal checkout:

```sh
python3 docs/agent-discovery/capture.py "$TMPDIR/claude" \
  docs/agent-discovery/scenarios/claude-lifecycle.json -- claude --model haiku
python3 docs/agent-discovery/summarize.py "$TMPDIR/claude.jsonl"
```

Scenario files and commands:

| Scenario file | Command |
| --- | --- |
| `claude-lifecycle.json` | `claude --model haiku` |
| `claude-trust-dialog.json` (create `$TMPDIR/portal-untrusted` first) | `claude --model haiku` |
| `claude-model-error.json` | `claude --model claude-nonexistent-spike-model` |
| `claude-queued-compact.json` | `claude --model haiku` |
| `codex-approval.json` (it creates `~/.cache/portal-spike-codex-approved`; delete it afterwards) | `codex -c model_reasoning_effort=low` |
| `codex-model-error.json` | `codex -m spike-nonexistent-model` |
| `pi-turns.json` | `pi --model openrouter/anthropic/claude-haiku-4.5 -e docs/agent-discovery/pi-lifecycle-probe.ts` |
| `pi-progress-extension.json` | `pi --model … -e docs/agent-discovery/pi-progress.ts -e docs/agent-discovery/pi-lifecycle-probe.ts` |
| `startup.json` | `codex` or `pi`, to see startup only |

For graphical runs, apply the patch, rebuild, build the scanner, then run
`sh docs/agent-discovery/run-gui.sh gui-run-1.el` (run 2: `SPIKE_USE_PROGRESS=1`).
These start real agents and make small model requests.
[`fixtures.py`](agent-discovery/fixtures.py) converted raw traces to the fixtures below.

### Replay fixtures

Compact sanitized traces: [`test/fixtures/agent-signals`](../test/fixtures/agent-signals).
Each starts with a metadata line (harness, version, scenario, terminal, clock),
then one event per line. Headless fixtures carry `title`, `progress` (`state` 0–4),
`notification`, `semantic_prompt`, `bell`, `claude_agents_status`, `pi_event` and
`step`. `portal-run-*.jsonl` combine native callbacks with prototype discovery,
query, row and check records from both graphical runs. Raw bytes were discarded:
they contain whole screens, account and usage text.

## Observations

Times are seconds from launch in the headless captures. Each statement below
was observed unless marked as a hypothesis.

### Claude Code 2.1.287

From `claude-lifecycle.jsonl`, `claude-idle-notification.jsonl`,
`claude-trust-dialog.jsonl`, `claude-model-error.jsonl` and
`claude-queued-compact.jsonl`:

| Moment | Title (OSC 0) | Progress (OSC 9;4) | `claude agents --json` |
| --- | --- | --- | --- |
| Launch at a trusted folder's first prompt | `✳ Claude Code` at 1.0 s | remove (0) | listed `idle` at 1.4–2.1 s |
| Launch at an untrusted folder's trust dialog | none | none | not listed |
| Prompt submitted | `◐ …`, alternating with `◑ …` about once a second, then a generated session title | indeterminate (3) | `busy` 0.2–0.6 s later |
| Permission dialog | `✳ …` (the idle glyph) | stays 3 | `waiting` 0.3–0.5 s later |
| Approved | spinner again | 3 | `busy` |
| Denied with Escape | unchanged `✳ …` | remove 0.14 s after Escape | `idle` 0.3 s after Escape |
| Cancelled with Escape | `✳ …` | remove | `idle` |
| Turn fails (unknown model) | as a normal turn | 3, then remove | `busy`, then `idle`; the error is shown as the reply |
| Message queued during a tool call | spinner throughout | 3 throughout | `busy` throughout; one turn |
| `/compact` | spinner for 20 s | 3, then remove | `busy`, then `idle` |
| Unfocused and idle for 60 s | — | — | OSC 777 `Claude is waiting for your input` |
| `/exit` | cleared (empty) | remove ×3 | gone 0.6 s later; process exits 1.0 s after `/exit` |

- At the trust dialog, only the process reveals Claude. Declining wrote no
  trust entry.
- In-band signals cannot establish *waiting*: the title says idle, progress
  working. Combining them infers status from rendering; JSON is the documented
  interface (`claude agents
  --help`: "Print active sessions (interactive and background) as a JSON array
  and exit (for scripting; does not require a TTY)"). Entries carry `pid`, `cwd`,
  `kind`, `startedAt`, `sessionId`, `name` and `status`.
- Every status change coincided with a change in title glyph class (`✳`, spinner,
  empty) or progress. Denial changes only progress.
- Queries cost 190 ms wall, 150 ms CPU and 148 MB peak memory (5 runs).
  Polling every 2 s would consume about 7.5% of a core; query only on triggers.

### Codex CLI 0.155.1

From `codex-turn-notification.jsonl`, `codex-approval.jsonl` and
`codex-model-error.jsonl`:

| Moment | Title | Other signals |
| --- | --- | --- |
| Launch | `portal` (project name) 0.2–1.4 s after launch, then `⠸ portal` braille frames for about a second while MCP servers start, then `portal` | OSC 8 links in the update banner |
| Working | `⠋ <thread> \| portal`, a new frame every ~100 ms; `renaming...` while it names the thread | none |
| Approval wait | `[ . ] Action Required \| <thread> \| portal`, alternating with `[ ! ]` every 1.0 s | none |
| Idle (after a turn, denial or cancel) | `<thread> \| portal`, static | OSC 9 with the last message at turn end, only after focus-out |
| Turn fails, then a "switch model?" menu | idle title while the menu waits | — |
| `/quit` | cleared | — |

- Codex emits no OSC 9;4 progress.
- A sandboxed `touch` under `/tmp` ran without approval; writing under `~/.cache`
  asked for it.
- The startup spinner shows *working* for 1–2 s before the first prompt.
- Gaps: non-approval menus show idle; customized titles would break the mapping
  (hypothesis: untested).
- Plain `codex` runs its app-server in-process. `codex agents` browses only the
  shared daemon's sessions, requiring `codex --remote`. No outside observer for
  ordinary launches was found.
- ChatGPT's desktop app runs its own `codex` outside any terminal: a negative
  control for executable-name-only matching.

### Pi 0.87.0

From `pi-turns.jsonl`, `pi-provider-error.jsonl` and `pi-progress-extension.jsonl`:

- Pi opens a trust dialog for an untrusted folder before `session_start`.
- Title: `π - portal` from session start, unchanged while working and resent,
  not cleared, at exit. It can outlive Pi.
- No progress (`terminal.showTerminalProgress` defaults to false), notifications
  or BEL. OSC 133 A/B/C surrounds each rendered message, not shell commands.
- All runs: `agent_start` (`isIdle` false) → … → `agent_end` →
  `agent_before_settle` → `agent_settled` (`isIdle` true). An Alt-Enter follow-up
  queued during a tool call joined the same run: one `agent_end`. The documented
  `agent_end` before retry, recovery or queued continuation was not reproduced.
  Provider error (expired OAuth token) and tool cancellation both went straight
  to `agent_settled`.
- Pi renames its process to `pi` via Node's `process.title`, overwriting
  arguments with `pi` and NUL padding. The environment, including `PORTAL_TERMINAL`, remains after
  the padding; parsers must skip it.
- [`pi-progress.ts`](agent-discovery/pi-progress.ts), loaded with `-e`, wrote
  9;4;0 at session start, 3 at `agent_start`, 0 at `agent_settled` and on
  cancel, and 0 at shutdown. The TUI rendered normally. Global extensions load
  from `~/.pi/agent/extensions` without flags (herdr and workmux loaded every
  run). Setup is a one-time install there or `pi install`; the spike installed
  nothing.

### Inside Portal

Two graphical runs, `portal-run-discovery.jsonl` and `portal-run-triggers.jsonl`:

- Ghostty delivered the same titles, progress, notifications and bells as
  callbacks. OSC 9 arrives with an empty title; OSC 777 carries one. OSC 9 and
  OSC 777 1.2 s apart were both delivered.
- New terminals report progress *remove* after 0.2 s, before any program runs.
  Ghostty's shell integration sends `command_finished` for every shell command,
  including agent exits, and titles terminals with the command line: `pi`
  showed `pi` until Pi set its title.
- Process facts readable for another process of the same user:
  - path, argument area, environment, process group, TTY and its foreground
    group for user-owned processes;
  - not the root-owned `/usr/bin/login` that Ghostty starts each shell through;
  - not a login zsh's environment, which reads back empty. So the marker must be
    read from the agent, not the shell.
- Claude has `argv[0]` `claude`, executable `.../claude/versions/<version>`,
  and version as `comm`. Codex's executable is `codex`; Pi's is `node`, with
  `argv[0]` `pi` after renaming or `.../pi-coding-agent/...` in arguments before.
- `portal-terminal-start` agents (exec replacing the shell) share the login
  process's foreground group, so discovery finds them too.

## Matrix

| | Claude Code 2.1.287 | Codex CLI 0.155.1 | Pi 0.87.0 |
| --- | --- | --- | --- |
| Identity and terminal binding | Foreground `argv[0]` `claude`, executable under `claude/versions/` (or runtime executing a `claude` script); environment marker. Verified. | Foreground `argv[0]` and executable `codex`; marker. Verified. | Foreground `node`, `argv[0]` `pi` after renaming, 0.1–0.2 s after Node starts; marker after NUL padding. Verified after parser fix. |
| Startup discovery | First prompt and trust dialog; process visible 0.17–0.73 s after Enter. | First prompt; visible 0.62–0.74 s after Enter. | Trust dialog; visible 0.62–0.63 s after Enter. |
| Working | `busy` from the JSON status | Braille spinner title | Extension progress 3; none by default |
| Idle | `idle` (also after errors, denials and cancels) | Title without spinner or `Action Required` | Extension progress 0 at `agent_settled` with `isIdle`; none by default |
| Waiting | `waiting` for permissions; questions (`AskUserQuestion`) untested | `Action Required` for approvals; other menus show idle | Extension progress 4 only for extension dialogs; no Pi permission prompts |
| Exit | Process gone (1.07 s after `/exit` in Portal); JSON entry gone; title cleared | Process gone; title cleared | Process gone (0.15 s after Ctrl-D); title kept |
| Freshness | Query on title-glyph or progress change; 0.44 s from denial to `idle` in Portal (29.9 s with title-only triggers, which miss denial) | Spinner frames every 100 ms; idle title static | Reports at each transition; process liveness covers a crash |
| Setup | None | None | One-time extension install; keep `terminal.showTerminalProgress` off |
| Gaps | Unknown at the trust dialog and in the first ~1.5 s; needs progress collection for denial; idle ≠ success | Custom titles; non-approval menus; startup spinner reads as working; no provider API for plain launches | Unknown without the extension; retry/compaction ordering not reproduced |

Neither notifications, progress clear nor silence alone established completion:
Claude notified 60 s after turn end, Codex sent OSC 9 only while unfocused, Pi
sent none, and Claude cleared progress on both denial and completion.

## Claude launch to row, and controls

Run 1 (`portal-run-discovery.jsonl`), with the prototype in a clean Emacs:

1. Plain `claude` started in T3 before discovery loaded. Opening the dashboard
   found it without a prompt or relaunch.
2. `claude --model haiku` in T1, dashboard never opened: scan-visible 0.52 s
   after Enter. Opening the dashboard 3 s later immediately printed T1 and T3
   (activity `unknown` for one 225 ms query, then `idle`).
3. Controls in T2 never produced a row:
   - a synthetic `✳ Claude Code` title, progress 3 and OSC 9/777 notifications;
   - `cat` of a captured Claude session, which replays its titles and progress
     through Ghostty;
   - progress with percentages, as a build reports it;
   - `sleep` in the foreground;
   - `bash -c 'exec -a claude sleep 4'`, a fake `argv[0]`;
   - a `node` process that is not Pi.

   The scanner also ignored all agents in the user's running Portal, whose
   terminals lacked markers.
4. T1 hidden behind other terminals: `working` 0.37 s after a prompt,
   `waiting` at permission, then `idle` after approval, cancel and denial.
   `RET` visited `*T1 claude*`.
5. A second plain `claude` in the quick terminal produced three distinct Claude
   rows. T1 and T3 shared a directory; the quick shell opened in `~`, leaving
   its Claude at the trust dialog with activity `unknown`.
6. `/exit` in T1 removed its row, not the shell (process gone 1.07 s later).
   Relaunching `claude --model haiku` gave a new PID: activity `unknown` until a
   fresh query, then `idle`, never reusing old status.
7. Killing T3's buffer ended its running Claude and row. A query issued just
   before arrived later with the dead PID but created no row: discovery owns rows.

Run 2 (`portal-run-triggers.jsonl`) added progress triggers: denial to `idle`
took 0.44 s. Pi appeared `unknown` at its trust dialog and disappeared 0.15 s
after Ctrl-D. Codex appeared `idle` at its first prompt and disappeared after
`/quit`. In run 1, pasted `/quit` after a Codex turn inexplicably failed to exit
within 15 s; its row correctly remained while the process ran.

## Cost

| Measurement | Result |
| --- | --- |
| Full scan: all user process paths, then candidate arguments/environment | 4.4–5.9 ms idle (≈960 processes); run 1: median 11.2 ms, p90 23.6 ms, max 47.7 ms over 251 scans (each Claude starts several `node` MCP servers, all candidates) |
| Foreground-only scan: one `KERN_PROC_UID` snapshot, then only processes whose group owns their TTY (12 of 961) | 0.8–1.3 ms idle; 1.8–12 ms (median 2.7 ms) in run 2 |
| Scanner as a subprocess (prototype only) | 5–58 ms per call, mostly process start; an in-process scan avoids it |
| `claude agents --json` | 190 ms wall, 150 ms CPU, 148 MB; 22 queries over run 1's ~140 s with Claude activity |
| Dashboard hidden, a 10 Hz title spinner running for 11 s | 0 scans, 0 Claude queries; 90 terminal change records, 26.7 ms of Lisp in total (0.30 ms each) |
| Dashboard shown, same spinner | 7 scans; 92 change records, 29.3 ms of Lisp |

Any title-animating program already incurs change-record costs: working Codex
costs about 2.4 ms of Lisp per second, with or without discovery.

## Restarts, stale reports and source loss

- **Exit and relaunch.** Rows live while their process is the terminal's
  foreground agent. New processes are new incarnations, even in the same
  terminal: activity starts `unknown`, set only by reports about that process.
- **Stale reports.** PID-keyed Claude results ignore former agents and never
  create rows. Pi progress counts only when reported after process discovery.
  This cutoff needs per-terminal progress sequences or times: Ghostty callbacks
  lack PIDs.
- **Source loss.** Claude CLI failure, timeout or invalid JSON makes its rows
  `unknown`, with the reason. Empty/missing Codex titles yield `unknown`;
  never-reporting Pi extensions leave `unknown`. Crashed agents disappear at
  the next scan.
- **Closed or replaced views.** Rows use buffer and view-target keys. Closing
  views sends agents SIGHUP; they exit, as in run 1. Late callbacks have no
  buffer to update. Same-buffer view replacement was not separately tested;
  it gets a new target and marker.
- **Existing terminals.** Scans cover all terminals started by marker-exporting
  Portal builds. Shell environments cannot change afterwards: agents in
  older-build terminals remain invisible until those terminals restart.
  Restarting Emacs for a new native module restarts them anyway.
- **Not discovered, by design:** an agent started with the marker removed, in
  tmux or over SSH from a Portal shell, or suspended with Ctrl-Z (not in the
  foreground group; untested), and agents in another Emacs.

## Untested and open

- Claude: `AskUserQuestion` and other elicitation waits, background agents and
  MCP tasks still running after a turn (Herdr treats both as working), automatic
  retries, `/clear` and `/resume`, npm installations (Node running
  `@anthropic-ai/claude-code`).
- Codex: queued continuation, compaction, retries and patch approvals (quota
  was low); a customized title; npm installations, where a Node wrapper starts
  the native binary as a child.
- Pi: `agent_end` before an automatic continuation, `ui_prompt_*` dialogs,
  `/new`, `/resume` and reload (each restarts the session in the same process),
  and Pi's own progress setting turned on.
- Portal: several frames, a hidden quick terminal running an agent, sleep and
  wake, two Emacs instances with the marker (the PID prefix separates them by
  construction).
- Decision for the Claude implementation: whether a suspended agent keeps a
  row (as `stopped`) or loses it like an exited one.

## How Herdr does it

[Herdr](https://herdr.dev/) runs agents in its terminal multiplexer and shows
state. Read at installed version v0.9.1, with this machine's integration files.

### Identity: the foreground process

Herdr starts pane shells, so it knows their PIDs and terminals. It reads the
foreground group (`e_tpgid` from `proc_pidinfo`, or `tcgetpgrp`), then lists it
with `proc_listpids(PROC_PGRP_ONLY)`. Process names use `argv[0]` basenames
(from `KERN_PROCARGS2`), falling back to `comm`. For runtimes or shells (`node`,
`bun`, Python, `sh`, `bash`, `zsh`, `fish`), use the script argument's name.
Priority: group leader, then names differing from `comm`, then any non-runtime.
A wrapper process's environment `HERDR_AGENT=<agent>` names an agent hidden in
a sandbox. Herdr does not look inside a pane's tmux.
[detect/mod.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/mod.rs),
[platform/macos.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/platform/macos.rs)

### Status: one authority per pane

- **Lifecycle integrations** (Pi, OMP, Kimi, OpenCode, Kilo, MastraCode): plugins
  report `working`, `idle` or `blocked` over Herdr's Unix socket via
  `pane.report_agent`, with pane `HERDR_PANE_ID`, stable source name and rising
  sequence number. Herdr drops older numbers from the same source.
  `pane.release_agent` returns authority on exit. Pane environments carry
  `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SOCKET_PATH` and `HERDR_BIN_PATH`. Herdr
  reads no screen for a pane while its plugin reports.
  - Its Pi extension in `~/.pi/agent/extensions` reports only in TUI sessions
    (RPC also claims a UI). It publishes `isIdle()` at `session_start` because
    reload replaces the extension mid-run without another `agent_start`.
    `agent_start` means working; `agent_settled` with `isIdle()` means idle.
    Other extensions must emit Herdr's `herdr:blocked` event for blocked status;
    Pi's `ui_prompt_*` events are unused.
- **Screen manifests** (Claude Code, Codex, Pi without the plugin, and most
  others): Herdr emulates terminals, checking per-agent TOML rules, highest
  priority first, against the latest OSC 0/2 title, OSC 9;4 state and live
  bottom-screen regions. Rules update from herdr.dev without restart; local
  overrides win.
  - Claude: a spinner title (braille through 2.1.227, `◐`–`◓` since 2.1.228) or
    an `esc to interrupt` line means working, as do "Waiting for N background
    agents" and "N MCP tasks still running". Permission, question, MCP
    elicitation and workflow dialogs, recognized by their text, mean blocked.
    A `❯` prompt box means idle. A `✳` title and progress `4;0` mean idle only
    at the lowest priority.
  - Codex: `Action Required` in the title means blocked and a braille spinner
    working, matched first. Screen rules then catch the trust prompt, the
    update prompt, approval and question dialogs, and an `esc to interrupt`
    timer. Any other non-empty title means idle.
  - Pi without the plugin: a `Working...` line or border means working.
  - Blocked needs a recognized dialog. A known agent matching no rule is shown
    `idle`, labelled as a fallback.
- **Session-only hooks** (Claude Code, Codex and others): `SessionStart` reports
  only session ID and transcript path for restoration. Herdr documents why
  hooks cannot supply status: they miss permission results and Escape interrupts.
- **Display:** the sidebar can strip one leading activity/spinner glyph from
  titles, avoiding redraws on spinner frames.

[Claude](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/claude.toml),
[Codex](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/codex.toml)
and [Pi](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/pi.toml)
manifests;
[agents](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/preview/website/src/content/docs/agents.mdx)
and [integrations](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/preview/website/src/content/docs/integrations.mdx)
documentation.

### What it changes for Portal

The decision stands: Herdr independently uses foreground-process identity,
the same Codex title rules first, and the same Pi lifecycle events. It also
rejects Claude/Codex status hooks. Its Claude title/progress rules cannot detect
blocked either: Herdr needs the screen; Portal uses `claude agents --json`.

Four refinements to adopt in the implementation tasks:

1. **Classify by `argv[0]`, unwrapping runtimes, and check the executable.**
   Use the `argv[0]` basename, or script basename for `node`, `bun`, Deno,
   Python or shells. Unlike Herdr, require a matching executable: the agent's
   binary (Claude under `claude/versions/`) or a runtime. This covers tested
   native installs (Claude's `comm` is its version, `argv[0]` is `claude`; Pi's
   renamed `argv[0]` is `pi`) and npm shims running `node <bin>/claude`, without
   matching install paths or accepting name-only impostors. `agentscan.c`
   implements this. Real-process tests with a marker found Claude, Codex, Pi
   and `node <dir>/claude`; they rejected `exec -a claude sleep`, equivalents
   for `codex` and `pi`, and `node -e`. Mise-launched Pi runs as
   `node .../cli.js` until renamed; recognition took 0.1–0.2 s after Node started.
2. **Strip one leading activity marker from titles** for the Title column and
   unchanged-facts comparison: spinner frames, `✳`, or Codex's blinking
   `[ . ]` and `[ ! ]`. Otherwise Claude (one frame/second) or Codex (ten/second)
   forces dashboard reprints every refresh: 2.7–7.0 ms/tick plus redisplay at
   10–100 terminals with changing titles (PR #59). `prototype.el` does this.
3. **Claude's trigger glyph classes cover both spinner sets:** braille and
   `◐`–`◓`, as well as `✳`. Claude changed its spinner at 2.1.228; a later change
   still leaves the progress trigger and the 30 s poll. `prototype.el` does this.
4. **Pi extension reports only after a TUI `session_start`.** Keep Portal's
   `ui_prompt_*` mapping, which Herdr lacks. `pi-progress.ts` does this: a TUI
   run reported the same sequence as before, and `pi --mode rpc` reported
   nothing.

Not adopted:

- **Screen rules.** Closing Codex's gaps (trust/update prompts, non-approval
  menus) needs cheap screen reads and maintained regexes. Pinned Ghostty's
  `ghostty_surface_read_text` reads ranges without changing selection, but the
  wrapper exposes it only for in-memory sessions (`readViewportText`). Portal
  offers only select-all (`portal--terminal-text`). Revisit if these gaps matter in
  use, changing the wrapper first.
- **A socket with sequence numbers for Pi.** PTYs deliver OSC in order;
  discovery ends rows on Pi exit. No sequence numbers, release call or Emacs
  server are needed.
- **A wrapper hint such as `HERDR_AGENT`.** No wrapped agent is used; add
  `PORTAL_AGENT` when one is.

## References

Starting evidence:

- [Original signal-driven design](https://github.com/xiaoxinghu/portal/blob/1c04d8af227488dd7758141d84d5b9df77f5c5b7/docs/agent-state-design.md)
  and its [validation task](https://github.com/xiaoxinghu/portal/blob/1c04d8af227488dd7758141d84d5b9df77f5c5b7/docs/tasks/08-agent-signal-spike.md)
  (closed PR #3). This spike measured its hypothesized mappings. Signal-based
  registration is rejected: replays are indistinguishable from real signals.
- [Full September 27 research](https://github.com/xiaoxinghu/portal/blob/b33c92a16e13acb848268b122d82b58072a2a480/tasks/09-agent-dashboard.md):
  the synthetic Ghostty probe, `claude agents --json`, Codex observer limits,
  Pi lifecycle semantics and Herdr's detection. Confirmed here: Claude progress
  3/0 and its JSON states, Codex's spinner and `Action Required` titles (as in
  [Herdr's Codex manifest](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/detect/manifests/codex.toml)),
  Pi's `agent_settled` with `isIdle`. Superseded: "PID/TTY limitations block
  automatic discovery". Ghostty still reports neither; Portal can discover
  processes through its environment marker.
- [Emacs agent dashboard research](emacs-agent-dashboard-research.md): the
  visible-only refresh this design keeps.

Sources checked for this spike:

- [libghostty-spm `TerminalSurface.swift` at 1.6.20260909](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurface.swift#L405):
  the foreground PID and TTY stubs.
- [Ghostty `Surface.zig` at `82938b6`](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/Surface.zig#L58):
  the random `GHOSTTY_SURFACE_ID`.
- [Pi extension events at v0.87.0](https://github.com/earendil-works/pi/blob/v0.87.0/packages/coding-agent/docs/extensions.md#events):
  lifecycle, `agent_settled`, `ui_prompt_*`, `ctx.isIdle()`.
- [Claude Code agent view: list sessions as JSON](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)
  and the CLI's own `claude agents --help`.
