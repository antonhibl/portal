# Automatic agent discovery and status in Portal terminals

Research date: 2026-10-02. Task: `agent-discovery-spike` in `project.org`.

## Decision

Typing `claude`, `codex` or `pi` in an ordinary Portal shell can put the agent
in `portal-agents` with no tracking, label or special launcher. That includes an
agent still waiting at a trust dialog or its first prompt. Identity and activity
come from different sources:

- **Identity, for all three harnesses: the terminal's foreground process.**
  Portal exports `PORTAL_TERMINAL=<emacs-pid>/<view-target>` into each
  terminal's environment. A scan of the user's processes keeps those in their
  TTY's foreground process group whose executable is a known agent, and reads
  the marker from the agent's own environment. The outermost agent per terminal
  wins. An incarnation is the process ID plus start time. Titles, directories,
  progress and notifications never register an agent.
- **Activity, one authority per harness:**

  | Harness | Authority | Setup | Without it |
  | --- | --- | --- | --- |
  | Claude Code | `claude agents --json`, joined by process ID: `busy`, `waiting`, `idle`. Query it when that terminal's title glyph or OSC 9;4 progress state changes, when the list is shown, when a new Claude process appears, and every 30 s while shown. | None | `unknown` (trust dialog, the first ~1.5 s, CLI failure) |
  | Codex CLI | Its default terminal title: a braille spinner means working, `Action Required` means waiting, otherwise idle. Label the source "title". | None | `unknown` when no title |
  | Pi | OSC 9;4 progress written by a small Portal extension: 3 working, 0 idle at `agent_settled`, 4 waiting on an extension dialog. | One-time install of the extension | `unknown` |

- **Unknown policy.** Activity stays `unknown` until the selected authority
  reports for the current incarnation. Silence, notifications, bells, generic
  titles, progress from another program and a running process never establish
  activity. `idle` never means the task succeeded: a failed turn also ends idle.
- **Collection.** Scan only while the dashboard is shown: when it opens or is
  shown again, and on its refresh tick. A hidden dashboard costs nothing beyond
  today's terminal metadata. Because identity is a present-tense fact, an
  agent started while the list was hidden appears as soon as it is shown.
- **Portal needs two new native facts:** the marker in each terminal's
  environment, with a foreground-process report, and each terminal's last OSC
  9;4 progress state, announced through the existing change records.

Discovery bound for the implementation: an agent appears at the next refresh
while the dashboard is shown (default interval 2 s), and at once when it is
opened or shown again. Measured, the agent process was visible to a scan
0.17–0.74 s after Enter, and a scan costs a few milliseconds (see
[Cost](#cost)).

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
ID, and `ghostty_surface_foreground_pid` and `ghostty_surface_tty_name` are stubs
returning nothing in the pinned wrapper and in every release through
1.6.20261001, so Portal cannot learn a terminal's process or TTY from Ghostty.

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
  checkout is not trusted, so Pi opens a trust dialog; runs chose "Trust (this
  session only)" or cancelled. The default `openai-codex` login had an expired
  refresh token, which gave a real provider-failure trace; working turns used
  `--model openrouter/anthropic/claude-haiku-4.5`.

Turns used small models to save quota (`claude --model haiku`,
`codex -c model_reasoning_effort=low`). Discovery checks used plain `claude`,
`codex` and `pi`. Model choice does not change terminal signals.

### Method

1. **Headless captures.** [`capture.py`](agent-discovery/capture.py) runs a CLI
   in a pseudo-terminal with Portal's terminal variables. It answers the queries
   Ghostty answers (DA, cursor position, colours, XTVERSION, mode reports),
   types scripted input and records OSC titles, OSC 9;4 progress, OSC 9 and 777
   notifications, OSC 133 marks, BEL, focus reporting and `claude agents --json`
   samples on one monotonic clock. Scenarios are in
   [`agent-discovery/scenarios`](agent-discovery/scenarios). The harness is not
   Ghostty, so these captures establish what each CLI emits, not what Portal
   receives.
2. **Real agents inside Portal.** [`instrumentation.patch`](agent-discovery/instrumentation.patch)
   temporarily made `HostedTerminal` log every title, directory, progress,
   notification, bell, command-finished and close callback, with its view
   target and both monotonic and wall-clock times. It also exported
   `PORTAL_TERMINAL`, reported progress through `portal--inspect`, and let a
   paste starting with U+E000 run a Ghostty binding action (`text:\x1b` for
   Escape), so a script could answer dialogs. [`prototype.el`](agent-discovery/prototype.el)
   adds discovered agents to `portal-agents` with the activity rules above,
   using [`agentscan.c`](agent-discovery/agentscan.c) as the scanner.
   [`gui-run-1.el`](agent-discovery/gui-run-1.el) and
   [`gui-run-2.el`](agent-discovery/gui-run-2.el) drove a clean graphical Emacs
   through [`run-gui.sh`](agent-discovery/run-gui.sh). None of this is in the
   Portal build; the patch was reverted.
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

For the graphical runs, apply the patch, rebuild, build the scanner, and run
`sh docs/agent-discovery/run-gui.sh gui-run-1.el` (run 2 with
`SPIKE_USE_PROGRESS=1`). They start real agents and make small model requests.
[`fixtures.py`](agent-discovery/fixtures.py) turned the raw traces into the
fixtures below.

### Replay fixtures

Compact, sanitized traces are in [`test/fixtures/agent-signals`](../test/fixtures/agent-signals).
Each file starts with a metadata line (harness, version, scenario, terminal,
clock), followed by one event per line. Headless fixtures carry `title`,
`progress` (`state` 0–4), `notification`, `semantic_prompt`, `bell`,
`claude_agents_status`, `pi_event` and `step`. `portal-run-*.jsonl` merge the
native callbacks and the prototype's discovery, query, row and check records
from the two graphical runs. Raw output bytes were not kept: they hold whole
screens, account and usage text.

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

- The trust dialog matters: there, only the process shows that Claude is
  running. Declining it wrote no trust entry.
- In-band signals alone cannot say *waiting*: the title shows the idle glyph
  while progress still says working. Combining them would be an inference from
  rendering; the JSON status is the documented interface (`claude agents
  --help`: "Print active sessions (interactive and background) as a JSON array
  and exit (for scripting; does not require a TTY)"). Its entries carry `pid`,
  `cwd`, `kind`, `startedAt`, `sessionId`, `name` and `status`.
- Every status change coincided with a change in the title glyph class (`✳`,
  spinner, empty) or in the progress state. Denial changes only progress.
- The query costs 190 ms wall, 150 ms CPU and 148 MB peak memory (5 runs).
  Polling it every 2 s would cost about 7.5% of a core, so it runs only when a
  trigger fires.

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
- Gaps: a menu that is not an approval shows the idle title, and a customized
  title setting would break the mapping (hypothesis: not tested).
- A plain `codex` runs its app-server in-process. `codex agents` browses only
  sessions on the shared daemon, which needs `codex --remote`, not an ordinary
  launch. No outside observer for a plain launch was found.
- The ChatGPT desktop app runs its own `codex` binary outside any terminal: a
  negative control for matching by executable name alone.

### Pi 0.87.0

From `pi-turns.jsonl`, `pi-provider-error.jsonl` and `pi-progress-extension.jsonl`:

- Pi opens a trust dialog for an untrusted folder before `session_start`.
- Its title is `π - portal` from session start. It never changes while
  working, and Pi sends it again at exit instead of clearing it, so a title can
  outlive Pi.
- No progress (`terminal.showTerminalProgress` defaults to false), no
  notifications, no BEL. OSC 133 A/B/C marks surround each rendered message,
  so OSC 133 is not a shell-command boundary inside Pi.
- Lifecycle, all runs: `agent_start` (`isIdle` false) → … → `agent_end` →
  `agent_before_settle` → `agent_settled` (`isIdle` true). A follow-up queued
  with Alt-Enter during a tool call joined the same run: one `agent_end`. The
  documented case where `agent_end` precedes a retry, recovery or queued
  continuation was not reproduced. A provider error (expired OAuth token) and
  a cancelled tool call both went straight to `agent_settled`.
- Pi renames its process to `pi` through Node's `process.title`. That
  overwrites its argument area with `pi` followed by NUL padding. The
  environment, including `PORTAL_TERMINAL`, is still there after the padding;
  a parser must skip the padding.
- [`pi-progress.ts`](agent-discovery/pi-progress.ts), loaded with `-e`, wrote
  9;4;0 at session start, 3 at `agent_start`, 0 at `agent_settled` and on
  cancel, and 0 at shutdown. The TUI rendered normally. Pi loads global
  extensions from `~/.pi/agent/extensions` without flags (the herdr and workmux
  extensions there loaded in every run), so a one-time install there, or
  `pi install`, is the setup. The spike installed nothing.

### Inside Portal

Two graphical runs, `portal-run-discovery.jsonl` and `portal-run-triggers.jsonl`:

- Ghostty delivered the same titles, progress, notifications and bells as
  callbacks. OSC 9 arrives with an empty title; OSC 777 carries one. OSC 9 and
  OSC 777 1.2 s apart were both delivered.
- Every new terminal reports progress *remove* 0.2 s after it starts, before
  any program runs. Ghostty's shell integration sends `command_finished` for
  each shell command, including an agent exiting; it also renames the title to
  the command line, so `pi` showed the title `pi` until Pi set its own.
- Process facts readable for another process of the same user:
  - path, argument area, environment, process group, TTY and its foreground
    group for user-owned processes;
  - not the root-owned `/usr/bin/login` that Ghostty starts each shell through;
  - not a login zsh's environment, which reads back empty. So the marker must be
    read from the agent, not the shell.
- Claude's process shows `argv[0]` `claude`, its executable under
  `.../claude/versions/<version>`, and the version as its `comm`. Codex's
  executable is `codex`. Pi's executable is `node`, with `argv[0]` `pi` after
  it renames itself or `.../pi-coding-agent/...` in its arguments before.
- An agent started by `portal-terminal-start` (an exec in place of the shell)
  shares the login process's group, which is still the foreground group, so it
  is found too.

## Matrix

| | Claude Code 2.1.287 | Codex CLI 0.155.1 | Pi 0.87.0 |
| --- | --- | --- | --- |
| Identity and terminal binding | Foreground process; exe under `claude/versions/` or named `claude`; marker in its environment. Verified. | Foreground process named `codex`; marker. Verified. | Foreground `node` with `argv[0]` `pi` or the package path; marker after NUL padding. Verified after a parser fix. |
| Startup discovery | At the first prompt and at the trust dialog. Process visible 0.17–0.73 s after Enter. | At the first prompt; visible 0.62–0.74 s after Enter. | At the trust dialog; visible 0.62–0.63 s after Enter. |
| Working | `busy` from the JSON status | Braille spinner title | Extension progress 3; none by default |
| Idle | `idle` (also after errors, denials and cancels) | Title without spinner or `Action Required` | Extension progress 0 at `agent_settled` with `isIdle`; none by default |
| Waiting | `waiting` for permission dialogs. Questions (`AskUserQuestion`) untested. | `Action Required` for approvals; other menus show idle | Extension progress 4 for extension dialogs only; Pi has no permission prompts |
| Exit | Process gone (1.07 s after `/exit` in Portal); JSON entry gone; title cleared | Process gone; title cleared | Process gone (0.15 s after Ctrl-D); title kept |
| Freshness | Query on title-glyph or progress change; 0.44 s from denial to `idle` in Portal (29.9 s with title-only triggers, which miss denial) | Spinner frames every 100 ms; idle title static | Reports at each transition; process liveness covers a crash |
| Setup | None | None | One-time extension install; keep `terminal.showTerminalProgress` off |
| Gaps | Unknown at the trust dialog and in the first ~1.5 s; needs progress collection for denial; idle ≠ success | Custom titles; non-approval menus; startup spinner reads as working; no provider API for plain launches | Unknown without the extension; retry/compaction ordering not reproduced |

Notifications, a progress clear and silence each failed to mean completion on
their own: Claude's idle notification came 60 s after the turn ended, Codex's
OSC 9 only came while unfocused, Pi sent none, and Claude cleared progress on
denial as well as on completion.

## Claude launch to row, and controls

Run 1 (`portal-run-discovery.jsonl`), with the prototype in a clean Emacs:

1. A plain `claude` was started in T3 before discovery was loaded. When the
   dashboard first opened, T3's row was there: an agent already running is
   found without a prompt or relaunch.
2. `claude --model haiku` typed in T1, dashboard never opened: the process was
   visible to a scan 0.52 s after Enter. Opening the dashboard 3 s later
   printed rows for T1 and T3 at once (activity `unknown` for one query,
   225 ms, then `idle`).
3. Controls in T2 never produced a row:
   - a synthetic `✳ Claude Code` title, progress 3 and OSC 9/777 notifications;
   - `cat` of a captured Claude session, which replays its titles and progress
     through Ghostty;
   - progress with percentages, as a build reports it;
   - `sleep` in the foreground;
   - `bash -c 'exec -a claude sleep 4'`, a fake `argv[0]`;
   - a `node` process that is not Pi.

   The scanner itself also ignored every agent in the user's own running
   Portal, whose terminals carry no marker.
4. With T1 hidden behind other terminals, its row went `working` 0.37 s after
   a prompt, `waiting` at the permission dialog, back to `idle` after approval,
   cancel and denial. `RET` on its row visited `*T1 claude*`.
5. A second plain `claude` in the quick terminal gave three distinct Claude
   rows. T1 and T3 shared one directory. The quick shell had opened in `~`, so
   that Claude sat at its trust dialog with activity `unknown`.
6. `/exit` in T1 removed its row while the shell kept running (process gone
   1.07 s later). `claude --model haiku` again in T1 gave a new PID, activity
   `unknown` until a fresh query (no reuse of the old status), then `idle`.
7. Killing T3's buffer while its Claude ran ended the process and its row. A
   query issued just before arrived afterwards and listed the dead PID; it
   created no row, because rows come from discovery.

Run 2 (`portal-run-triggers.jsonl`) added the progress state to the trigger:
denial to `idle` took 0.44 s. Pi appeared at its trust dialog with activity
`unknown` and disappeared 0.15 s after Ctrl-D. Codex appeared `idle` at its
first prompt and disappeared after `/quit`. In run 1 a pasted `/quit` after a
Codex turn did not exit within 15 s for an unexplained reason. Its row stayed
correctly while the process ran.

## Cost

| Measurement | Result |
| --- | --- |
| Full scan: every user process's path, then arguments and environment of candidates | 4.4–5.9 ms idle (≈960 processes); in run 1 median 11.2 ms, p90 23.6 ms, max 47.7 ms over 251 scans (each Claude starts several `node` MCP servers, all candidates) |
| Foreground-only scan: one `KERN_PROC_UID` snapshot, then only processes whose group owns their TTY (12 of 961) | 0.8–1.3 ms idle; 1.8–12 ms (median 2.7 ms) in run 2 |
| Scanner as a subprocess (prototype only) | 5–58 ms per call, mostly process start; an in-process scan avoids it |
| `claude agents --json` | 190 ms wall, 150 ms CPU, 148 MB; 22 queries over run 1's ~140 s with Claude activity |
| Dashboard hidden, a 10 Hz title spinner running for 11 s | 0 scans, 0 Claude queries; 90 terminal change records, 26.7 ms of Lisp in total (0.30 ms each) |
| Dashboard shown, same spinner | 7 scans; 92 change records, 29.3 ms of Lisp |

The change-record cost exists today for any title-animating program; a working
Codex costs about 2.4 ms of Lisp per second this way, discovery or not.

## Restarts, stale reports and source loss

- **Exit and relaunch.** A row lives while its process is the terminal's
  foreground agent. A new process in the same terminal is a new incarnation:
  its activity starts `unknown` and only a report about the new process can
  set it.
- **Stale reports.** Claude results are keyed by PID; results for processes
  that are no longer agents are ignored, and they can never create rows.
  Pi progress counts only when reported after its process was discovered. The
  implementation needs a per-terminal progress sequence or time for this
  cutoff, because Ghostty callbacks carry no process ID.
- **Source loss.** Claude's CLI failing, timing out or returning invalid JSON
  makes Claude rows `unknown` with that reason. A Codex title that is empty or
  missing gives `unknown`. A Pi extension that never reported leaves `unknown`.
  A crashed agent's row goes at the next scan.
- **Closed or replaced views.** Rows are keyed by buffer and view target. When
  a view closes, its agents receive SIGHUP and exit, as in run 1. Late
  callbacks for a closed target have no buffer to update. Replacing a view in
  the same buffer was not run separately; it gets a new target and marker.
- **Existing terminals.** Every terminal started by a Portal build that exports
  the marker is covered, whenever the scan runs. A shell's environment cannot
  change afterwards, so agents in terminals from an older build stay invisible
  until those terminals restart. Restarting Emacs to load a new native module
  restarts them anyway.
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

[Herdr](https://herdr.dev/) runs agents in its own terminal multiplexer and
shows their state. Read at v0.9.1, the version installed here, with its
integration files as installed on this machine.

### Identity: the foreground process

Herdr starts every pane's shell itself, so it knows the shell's process ID and
terminal. It reads the terminal's foreground process group (`e_tpgid` from
`proc_pidinfo`, or `tcgetpgrp`) and lists that group with
`proc_listpids(PROC_PGRP_ONLY)`. It names each process by the basename of
`argv[0]` (from `KERN_PROCARGS2`), falling back to its `comm`. When that name
is a runtime or shell (`node`, `bun`, Python, `sh`, `bash`, `zsh`, `fish`), it
takes the name of the script argument instead. The group leader wins, then a
process whose name differs from its `comm`, then any non-runtime process.
`HERDR_AGENT=<agent>` on a wrapper command, read from that process's
environment, names an agent hidden inside a sandbox wrapper. It does not look
inside tmux running in a pane.
[detect/mod.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/mod.rs),
[platform/macos.rs](https://github.com/herdrdev/herdr/blob/v0.9.1/src/platform/macos.rs)

### Status: one authority per pane

- **Lifecycle integrations** (Pi, OMP, Kimi, OpenCode, Kilo, MastraCode): a
  plugin reports `working`, `idle` or `blocked` over Herdr's Unix socket as
  `pane.report_agent`, with the pane from `HERDR_PANE_ID`, a stable source name
  and a rising sequence number; Herdr drops older sequence numbers from the same
  source. `pane.release_agent` gives authority back on exit. Each pane's
  environment carries `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SOCKET_PATH` and
  `HERDR_BIN_PATH`. While a plugin reports, Herdr reads no screen for it.
  - The Pi extension it installs in `~/.pi/agent/extensions` reports nothing
    outside a TUI session (RPC mode also claims a UI). It publishes a baseline
    from `isIdle()` at `session_start`, because a reload replaces the extension
    mid-run without another `agent_start`. `agent_start` means working;
    `agent_settled` with `isIdle()` means idle. Blocked comes from a
    Herdr-specific `herdr:blocked` event that other extensions must emit; it does
    not use Pi's `ui_prompt_*` events.
- **Screen manifests** (Claude Code, Codex, Pi without the plugin, and most
  others): Herdr emulates each pane's terminal, so it checks per-agent TOML
  rules, highest priority first, against the latest OSC 0/2 title, the OSC 9;4
  state and regions of the live bottom of the screen. Herdr updates these rules
  from herdr.dev without a restart; local overrides win.
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
- **Session-only hooks** (Claude Code, Codex and others): `SessionStart` hooks
  report only the session ID and transcript path, for restoring sessions. Herdr's
  documentation explains why they are not a status source: they miss permission
  results and Escape interrupts.
- **Display:** a sidebar can show the title with one leading activity or
  spinner glyph removed, so spinner frames do not redraw the row.

[Claude](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/claude.toml),
[Codex](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/codex.toml)
and [Pi](https://github.com/herdrdev/herdr/blob/v0.9.1/src/detect/manifests/pi.toml)
manifests;
[agents](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/preview/website/src/content/docs/agents.mdx)
and [integrations](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/preview/website/src/content/docs/integrations.mdx)
documentation.

### What it changes for Portal

The decision stands. Herdr independently uses the foreground process for
identity, the same Codex title rules first, and the same Pi lifecycle events,
and it also refuses hooks as a Claude or Codex status source. Its Claude title
and progress rules cannot say blocked either: it needs the screen, where Portal
uses `claude agents --json`.

Four refinements to adopt in the implementation tasks:

1. **Classify by `argv[0]`, unwrapping runtimes.** Name a process by the
   basename of `argv[0]`, or of its script argument when that name is `node`,
   `bun`, Python or a shell, and prefer the group leader. This covers the native
   installs tested here (Claude's `comm` is its version number, but its
   `argv[0]` is `claude`; Pi's renamed `argv[0]` is `pi`) and npm installs, whose
   shims run `node <bin>/claude`, without matching install paths.
2. **Strip one leading activity glyph from titles** for the Title column and
   the unchanged-facts comparison. Otherwise a working Claude (a frame a second)
   or Codex (ten a second) makes every refresh reprint the dashboard, which cost
   2.7–7.0 ms per tick, plus redisplay, at 10–100 terminals when titles changed
   (PR #59).
3. **Claude's trigger glyph classes cover both spinner sets:** braille and
   `◐`–`◓`, as well as `✳`. Claude changed its spinner at 2.1.228; a later change
   still leaves the progress trigger and the 30 s poll.
4. **Pi extension reports only after a TUI `session_start`.** Keep Portal's
   `ui_prompt_*` mapping, which Herdr lacks.

Not adopted:

- **Screen rules.** They would close Codex's gaps (trust and update prompts,
  menus that are not approvals) but need a cheap screen read and maintained
  regexes. Pinned Ghostty has `ghostty_surface_read_text`, which reads a range
  without touching the selection, but the wrapper exposes it only for in-memory
  sessions (`readViewportText`); Portal's surfaces offer only select-all
  (`portal--terminal-text`). Revisit only if those gaps matter in use, with a
  wrapper change first.
- **A socket with sequence numbers for Pi.** A PTY delivers OSC in order, and
  process discovery ends a row when Pi exits, so Portal needs neither the
  sequence numbers nor a release call, nor a server in Emacs.
- **A wrapper hint such as `HERDR_AGENT`.** No wrapped agent is in use; add a
  `PORTAL_AGENT` hint when one is.

## References

Starting evidence:

- [Original signal-driven design](https://github.com/xiaoxinghu/portal/blob/1c04d8af227488dd7758141d84d5b9df77f5c5b7/docs/agent-state-design.md)
  and its [validation task](https://github.com/xiaoxinghu/portal/blob/1c04d8af227488dd7758141d84d5b9df77f5c5b7/docs/tasks/08-agent-signal-spike.md)
  (closed PR #3). Its mappings were hypotheses; this spike measured them.
  Registration on an agent signal is rejected: a replayed signal is
  indistinguishable from a real one.
- [Full September 27 research](https://github.com/xiaoxinghu/portal/blob/b33c92a16e13acb848268b122d82b58072a2a480/tasks/09-agent-dashboard.md):
  the synthetic Ghostty probe, `claude agents --json`, Codex observer limits,
  Pi lifecycle semantics and Herdr's detection. Confirmed here: Claude progress
  3/0 and its JSON states, Codex's spinner and `Action Required` titles (as in
  [Herdr's Codex manifest](https://github.com/herdrdev/herdr/blob/fff6c820aa45f4eabb9b2e0456326dc74cca5a25/src/detect/manifests/codex.toml)),
  Pi's `agent_settled` with `isIdle`. Superseded: "PID/TTY limitations block
  automatic discovery". Ghostty still reports neither, but Portal can find the
  process itself through its own environment marker.
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
