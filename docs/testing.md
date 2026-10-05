# Testing Portal

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

Run commands from the repository root after [building Portal](../CONTRIBUTING.md).
Start with [checks before a PR](../CONTRIBUTING.md#checks-before-a-pr), then
choose native checks for the changed area. GUI checks open windows and can take
focus; use a disposable Emacs. Credential-dependent agent smoke tests are opt-in.

The existing validation record reports macOS 27.0, Swift 6.4, and Emacs 31.1
with `--module-assertions`. C and Swift treat warnings as errors; recorded Lisp
byte compilation passed without warnings. Below is coverage, not a new run's results.

- [Terminal graphical checks and event injector](#terminal-graphical-checks)
- [Batch coverage](#batch-coverage) and [graphical coverage](#graphical-coverage)
- [Opt-in agent smoke tests](#opt-in-agent-smoke-tests)
- [Combined graphical suite](#combined-graphical-suite)
- [Standalone AppKit checks](#standalone-appkit-checks)
- [Launcher and global-shortcut graphical coverage](#launcher-and-global-shortcut-graphical-coverage)
- [C core checks](#c-core-checks)
- [Compiled app host integration](#compiled-app-host-integration)

## Terminal graphical checks

Graphical terminal tests cover a real shell, alternate-screen output, native
keyboard/clipboard input, focus return, resizing, hidden-session continuity,
shell termination, and editing/saving in Vim. They verify:

- Percent-encoded directory reports from Ghostty's zsh or bash integration reach
  buffer metadata and `default-directory`.
- Hidden-terminal titles arrive without renaming the buffer; exits are reported
  immediately, retaining the buffer, output and keyboard until the next key.
- Command chords run Emacs commands with rapid follow-up keys; `C-b` and `C-a`
  reach the shell.
- Multiple sessions/splits, runtime binding registration/unbinding, quick-only
  shortcuts, shifted characters, literal binding bytes, cancellation and
  minibuffer focus work.

Batch bindings: `ctest --test-dir build -R terminal-bindings`.
Batch view lifecycle: opening, splits, selection, `quit-window`, showing elsewhere,
moving between frames, deleting a frame and killing the buffer:
`ctest --test-dir build -R view`. Batch Emacs has one frame; these tests open a
second, suspended terminal frame on a pseudo-terminal.
Build the test-only AppKit event injector (no Accessibility permission required):

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
  -I "$(cat build/emacs-include.txt)" test/terminal-input.m \
  -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
  -o build/test-terminal-input.dylib
emacs -Q --module-assertions -L "$PWD" -l "$PWD/portal.el" \
  --eval "(module-load \"$PWD/build/test-terminal-input.dylib\")" \
  -l "$PWD/test/portal-terminal-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-terminal-")'
```

After building, run `sh test/terminal-shell-startup.sh` for controlled-shell
program launches. It starts disposable graphical Emacs with minimal PATH and
temporary zsh dotfiles, verifying shell-side program lookup, login/interactive
startup, literal arguments, terminal metadata and missing-program errors.
Set `EMACS` to choose the executable.

## Batch coverage

`ctest --test-dir build -R startup` loads `portal.el` by absolute path in fresh
`emacs --batch -Q`, without `-L` or a fake backend. It verifies features and
commands are available from an unrelated directory, with no global shortcut registration
or native code loaded.

`ctest --test-dir build -R global-shortcut` runs Lisp on the real C core with a
fake backend that refuses F19 as if another application owned it. It feeds
`shortcut` press records, as sent by the core, to the pipe filter and runs queued work through
command-loop key lookup. Checks cover:

- Two names calling a lambda and a command; resetting a name on the same or
  another chord keeps one registration and frees the old chord.
- Failed unloading retains the feature and unreleasable chord.
- Invalid names, functions and notation, another name's chord in any spelling,
  and refused chords change nothing.
- Function errors produce messages, retain all shortcuts and allow the next
  queued press to run.
- Records split across reads arrive; malformed/stale records and presses while
  one waits are dropped.
- Independent, repeatable removal; unloading and real `kill-emacs` release all chords.

`ctest --test-dir build -R launcher` runs without launcher.el. Loading, enabling
and presenting the panel set no global shortcut; disabling/deleting it retain
all shortcuts. Tests evaluate [launcher guide](launcher.md) examples with native
calls stubbed, loading files under dynamic and lexical binding:

- The picker runs from M-x, its key and its shortcut record through the command loop.
- The persistent hello buffer reads a name from its shortcut and M-x; repeating
  its chord dismisses it. A shortcut presents nothing.
- Reevaluation replaces registrations, invalidating earlier presses; removing
  one leaves the others.
- With a stand-in `launcher`, the launcher.el recipe reads a spaced bang query
  in stock completion, cancels empty/blank results and bangs without queries,
  passes a prefix argument and runs from its shortcut.

`ctest --test-dir build -R web` covers `portal-open-url` opening a new buffer each time,
views following selected split panes, `portal-preview-html` reusing its buffer,
`g`, `q`, buffer killing, per-command toolbars, and Hello and Markdown previews
opening together and loading when a simulated app host becomes ready. Markdown
tests feed the fake native adapter `page`, `follow` and `edit` bridge messages
and `select` records. Checks cover document identity; handoff placement with/without
`display-buffer-alist` rules; line fragments, images and folders; failed handoffs;
paths longer than a record; Open in Emacs; and return tracking across buffers,
previews and frames. One test uses the real app host, passed by `ctest` through
`PORTAL_TEST_HOST`: the preview loads when ready, stays unchanged through host
stop/restart, and reloads with `g`.

`ctest --test-dir build -R tasks` covers project-relative, absolute and
directory-local task roots, auxiliary buffers, explicit/prompted/remote roots,
one buffer per root, `g` and restart recovery of the displayed page, and
attachment handoff. Status edits preserve BOM, CRLF, file modes and every other
byte. They refuse unsaved buffers, read-only files, files changed since planning,
failed saves (leaving no temporary files) and files outside the root. Edit in Emacs
reuses modified buffers beside the page; saving refreshes only loaded views of
that root. One test uses the real app host; `ctest --test-dir build -R actions`
sends status changes, a repeated change, a refusal and Edit in Emacs from the
compiled host through Emacs's command loop.

`ctest --test-dir build -R tasks-view` uses org-ql 0.8.10 and its dependencies
missing from Emacs, Evil 1.15.0 and evil-collection 3.0.3. CMake downloads these
into `build/elpa` from NonGNU ELPA and release tags, verifying hashes. Coverage:

- Project lookup from files, auxiliary buffers, terminals and the view; separation
  of two projects.
- Readiness from unsaved edits, cancelled prerequisites, missing/shared/untagged
  IDs, cycles, non-`TODO` keywords and archived prerequisites.
- Schedules from yesterday to tomorrow, deadlines, ordering and blocker links.
- `g`, saving, a new day and returning preserve each pane's task; empty lists;
  Org agenda keys on a line; view keys in evil-collection normal state retain other keys.

Task detail tests check:

- `RET` shows the whole task with independent folds, leaving the file folded;
  typing at its end touches no folded text; one detail is reused.
- Keys except `M-,` remain Org's; tasks without unique `CUSTOM_ID` open in their
  files, and links to shared IDs are refused.
- Task links, archived tasks and blocker links in the view show their tasks.
  `M-,` returns to each link's position and the view's task, even after another
  pane moves the view or All tasks is killed.
- Typing, `C-c C-t`, undo and saving change the file buffer; unsaved edits survive
  returning and reopening details. Closed tasks reopen; blocked tasks change state.

`portal-tasks-implement` tests start Claude, recorded by the fake terminal, from
a view line, detail and `project.org` in a project path containing spaces and
quotes. They check literal arguments/directory, brief provenance and exact subtree
beside 3000-line neighbors, unchanged files, redisplaying a task's terminal,
explicit second runs and deleting each brief with its terminal. Nothing starts
for blocked, closed, unidentified or other files' tasks, declined/failed saves,
save hooks changing the buffer or file again, disk changes or terminal-start
failures. Accepted saves include edits in the brief.

`ctest --test-dir build -R agents` checks:

- One plain dashboard buffer opens no view or app host.
- Tracking separates two terminals sharing a directory, follows renames, retains
  exited programs and labels, and drops closed/killed/replaced terminals,
  including reset quick terminals and new views in the same buffer. Untracking
  leaves terminals running.
- Rows follow reported titles, directories, exits and project reassignment;
  directory changes never reassign projects.
- Unchanged refreshes rewrite nothing. Changed refreshes retain sort order,
  each window's session/screen line, selected window and focus, querying neither
  native code, user nor system.
- `g` works with live updates off. One timer runs while shown in any number of
  windows; none while hidden, shown only on an invisible frame, killed or with
  live updates off. Showing again refreshes.
- `RET` gives the correct ordinary, quick, hidden or other-frame terminal the
  keyboard. `agents-evil` checks normal-state Enter navigation with pinned Evil
  and evil-collection.

`test/portal-agents-benchmark.el` measures refresh time, allocation and redraws
at 10, 50 and 100 tracked terminals; see its run instructions in the commentary.
`bun test host` checks status-only edits in block/flow YAML with quoted keys and
values, comments, unknown fields, BOM, CRLF and multibyte text. It rejects tagged,
anchored, duplicated or otherwise unsafe entries and bytes no longer representing
the task. The action route resolves moved IDs, serializes repeated requests,
rejects other origins/contexts/roots, and task pages run only their own hashed script.

## Graphical coverage

Web tests await real WebKit loads, checking JavaScript execution, relative local
assets, pages staying loaded while hidden, repeated loading and native URL validation.

Markdown tests use the real app host and real mouse clicks: Back/Forward restore
reading positions; source links hand Emacs the keyboard in one click; preview
clicks select its pane; `portal-preview-return` and `RET` return without reloading;
Command-Escape returns to Emacs and `RET` re-enters. Previews follow system
appearance despite an opposite frame appearance; `portal-web-appearance` changes
the displayed page to light/dark without reloading.

Task browser tests use real list/task pages to check:

- Back/Forward restore filters and reading positions; `g` rereads saved files
  and `g` loads the displayed page after host restart.
- Task links, inline images in both layouts, one-click attachment handoff and
  mock-up HTML opening as source.
- Dimmed blocked rows and their prerequisites, struck-through completed rows,
  links to prerequisites/dependents including completed tasks, view/filter
  preservation across links, and dependents becoming ready after prerequisites
  are saved as done.
- Nested-folder indentation, real-key folding of groups/parents, Back retaining
  folds, completed parents above unfinished work, folder links and reloads after
  saved moves.

Real-click/key task operations cover:

- In-place completion: filters hide the row, focus moves to the next row, scroll
  stays fixed and history gains no entry.
- Tab/Return on row buttons without opening tasks; reopening from task pages
  retains button focus.
- Edit in Emacs hands the source pane the keyboard; saves refresh pages without
  taking it back, including hidden pages once shown.
- Back shows the list without tasks completed on their page; unsaved changes
  cause action refusal.

Toolbar tests type/paste into the real find field and step through matches with
real keys. Closing find leaves the keyboard with Emacs after the user returns
there. Web state survives buffer switches, reloads and theme changes; terminal
grids follow text size and live toolbar visibility; Excalidraw and quick
terminals have no strip.

The combined suite covers web, terminal, Excalidraw, Markdown, toolbar and shared
input, plus coexistence in both startup orders, real keyboard handoff, WebKit
key-up delivery alongside terminals, independent cleanup and shared-frame deletion.
It does not assert Lisp caches, hook names or implementation call counts.

Task view tests check redisplay after edits when a pane is reselected or shows
the view again. `RET` and `M-,` show a task while another pane keeps its file
folded, then return to the redrawn view on that task.

Terminal picker tests type real keys individually into Consult, Vertico and
Orderless from `build/elpa`, starting in ordinary buffers, keyboard-owning terminals
and quick panels. `M-.` moves live terminals, including from another frame, into
the preview window without the keyboard. Typing stays in the minibuffer, reaching
no shell; cancellation restores all views and the keyboard; acceptance gives the
chosen terminal the keyboard after the minibuffer closes.

Automatic discovery batch tests in `ctest --test-dir build -R agent-discovery`
cover real asynchronous pipes, process identity, nested/spoofed controls, PID reuse,
hidden/manual collection, bounded failures, pending triggers, and recorded Claude
lifecycle/compaction/error/trust fixtures replayed through dashboard rows. Codex
fixtures cover startup, working, completion, approvals, denial, cancellation and
model failure. Mixed-agent checks isolate status sources/discovery options, reject
delayed Claude results after Codex replacement, and suppress spinner-frame and
blinking-approval redraws. Pi tests replay recorded tool, cancellation and
provider-error lifecycles; reject pre-discovery/delayed progress; and cover hidden
collection, manual refresh, source loss and repeated-state redraw suppression.
`ctest --test-dir build -R pi-extension` tests the shipped extension's synthetic
retry, compaction, nested UI prompts and conversation/reload events, not
live-provider captures.

Runtime cases cover option values, attached values, short flag clusters,
terminators, execution modes, unknown options and every supported runtime pairing
for Claude, Codex and Pi. With Node installed, CTest runs actual Node processes on
PTYs through the native collector: a preload named `claude` must not be mistaken
for the executed script, nor Node with a spoofed Bash argument name produce an
agent row. `ctest --test-dir build -R processes` checks Darwin argument parsing
(NUL padding/truncation) and real nested PTYs with inherited markers for TTY
ownership. `portal-agents-benchmark-discovery` in `test/portal-agents-benchmark.el`
compares 10, 50 and 100 simulated sessions; pass `"codex"` for title inference or
`"pi"` for progress instead of Claude.

## Opt-in agent smoke tests

For real tmux exclusion, set `PORTAL_TEST_PROCESS_SNAPSHOT` to the absolute path
of `build/portal-process-tests`, put tmux on Emacs's `exec-path`, and run
`portal-discovery-gui-inherited-tmux-marker` from
`test/portal-agent-discovery-gui-tests.el` in fresh graphical Emacs. An isolated
tmux socket and fixture executable need no Claude credentials or requests. It
verifies direct, attached-tmux and detached-tmux runs inheriting their Portal
terminal's marker.

For opt-in real-Claude testing, set `PORTAL_TEST_CLAUDE_DIRECTORY` to an already
trusted project, load `test/portal-agent-discovery-gui-tests.el` in fresh graphical
Emacs, and run `portal-discovery-gui-plain-claude`. It starts plain Claude sessions,
sends one harmless prompt, checks automatic rows, working/idle, navigation and
exit/relaunch, then closes its terminals.

For `portal-discovery-gui-mixed-codex-claude`, also set
`PORTAL_TEST_CODEX_DIRECTORY` to a project both agents already trust. It starts
plain Claude/Codex sessions there, sends Codex a harmless prompt, checks separate
activity and exact navigation, hides/reopens the dashboard, quits/relaunches Codex,
and discovers/visits hidden quick-terminal Codex. A spoofed Codex name with an
approval title is a negative control.

For `portal-discovery-gui-mixed-pi-claude-codex`, also set
`PORTAL_TEST_PI_AGENT_DIR` to a disposable Pi agent directory containing bundled
`portal-pi.ts` in `extensions/`, credentials for one harmless request, and settings
with terminal progress off. A project trust decision (or
`defaultProjectTrust: "never"`) is required to reach the TUI.
Install this additional test-only extension there:

```typescript
export default function (pi) {
  pi.registerCommand("portal-test-prompt", {
    description: "Portal smoke test input",
    handler: async (_args, ctx) => {
      await ctx.ui.input("Portal smoke test", "Type PORTAL_OK");
    },
  });
}
```

It launches plain Pi, Claude and optionally Codex in one directory, checks Pi
work/dialogs, repeats a dialog with the dashboard hidden, tests `/new` and
`/reload`, quits/relaunches Pi and visits a hidden quick Pi terminal. The temporary
Pi directory leaves user settings unchanged.

Dashboard graphical tests use real terminals and redisplay window hooks:

- `RET` gives hidden, other-frame and quick terminals the keyboard; a dashboard
  in another frame pulls a terminal there.
- Shell-set titles appear without `g` while another terminal retains the keyboard;
  unchanged ticks redraw nothing.
- Hiding, showing in another frame, invisible frames and killing leave one timer
  only while shown.

## Combined graphical suite

Build the [test-only event injector](#terminal-graphical-checks), then run in
disposable graphical Emacs. Batch Emacs lacks native windows and cannot exercise
these behaviours:

```sh
emacs -Q --module-assertions -L "$PWD" -L "$PWD/test" \
  -L "$PWD/build/elpa/consult-3.10" -L "$PWD/build/elpa/vertico-2.15" \
  -L "$PWD/build/elpa/orderless-1.8" -L "$PWD/build/elpa/org-ql-0.8.10" \
  -L "$PWD/build/elpa/marginalia-2.13" \
  -L "$PWD/build/elpa/org-super-agenda-1.3" -L "$PWD/build/elpa/ts.el-0.3" \
  -L "$PWD/build/elpa/ov-1.0.6" -L "$PWD/build/elpa/s.el-1.13.1" \
  -L "$PWD/build/elpa/ht.el-2.3" -L "$PWD/build/elpa/dash-2.20.0" -l "$PWD/portal.el" \
  --eval "(module-load \"$PWD/build/test-terminal-input.dylib\")" \
  -l "$PWD/test/portal-tests.el" \
  -l "$PWD/test/portal-terminal-tests.el" \
  -l "$PWD/test/portal-integration-tests.el" \
  -l "$PWD/test/portal-excalidraw-gui-tests.el" \
  -l "$PWD/test/portal-input-gui-tests.el" \
  -l "$PWD/test/portal-toolbar-gui-tests.el" \
  -l "$PWD/test/portal-markdown-gui-tests.el" \
  -l "$PWD/test/portal-tasks-gui-tests.el" \
  -l "$PWD/test/portal-tasks-view-gui-tests.el" \
  -l "$PWD/test/portal-terminal-choose-gui-tests.el" \
  -l "$PWD/test/portal-agents-gui-tests.el" \
  -l "$PWD/test/portal-launcher-gui-tests.el" \
  -l "$PWD/test/portal-launcher-daily-use-tests.el" \
  -l "$PWD/test/portal-global-shortcut-gui-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-")'
```

Except for `build/elpa` packages, Lisp tests use only built-in Emacs libraries.

## Standalone AppKit checks

The standalone AppKit check verifies guest Escape retains focus;
Command-Escape and focused-view removal return it to the editor:

```sh
for core in channel views input terminals web toolbar shortcuts; do
  xcrun clang -std=c11 -Wall -Wextra -Werror -I native/Core/include \
    -c native/Core/$core.c -o build/$core.o
done
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I native/Core/include -import-objc-header test/native-core.h \
  native/Backend.swift native/CoreCalls.swift native/NativeHost.swift native/NativeInput.swift \
  native/Launcher.swift native/Hotkeys.swift \
  native/Views.swift native/Toolbar.swift native/WebToolbar.swift native/WebView.swift \
  test/native-checks.swift test/native-terminal-stub.swift test/native-views.swift \
  test/native-focus.swift build/channel.o build/views.o build/input.o build/terminals.o \
  build/web.o build/toolbar.o build/shortcuts.o \
  -framework AppKit -framework WebKit -framework Carbon -o build/check-focus
build/check-focus
```

Checks open web views through the core registry and macOS primitives, as Emacs
does, substituting `test/native-views.swift` for Emacs bindings. They verify:

- Hosted web views retain no data between sessions; pages outside the app host
  open in the default browser while the app stays.
- Only hosted-app main frames can use the bridge. `portalBridge` is ready before
  page scripts on first load/reload; failed delivery reaches Emacs; hosted apps report
  each committed page over the bridge.
- Reloading the displayed page adds no history entry. Page clicks send `select`;
  local links, even longer than a record, return the keyboard to Emacs and send
  `follow` over the bridge.
- Full notification pipes delay records without loss/reordering, retrying on the
  Swift timer. Pending records follow pipes replaced by Emacs; closed views'
  records never go.

`test/native-terminal-stub.swift` replaces terminals, avoiding Ghostty. Checks
link the core registry, input handoff, terminal/web rules, toolbars and pipe
without Emacs bindings.

Replace `test/native-focus.swift` and `build/check-focus` with
`test/native-toolbar.swift` and `build/check-toolbar` to test real-core toolbar
layout: buttons leave keyboard ownership unchanged; ownership dot; preview back/forward;
zoom limits; TOC across hiding/reload; real find-field typing; Return, Shift-Return
and Escape; Command-F/Command-R after the page; closing find after returning the
keyboard to Emacs; live visibility/colors; toolbar-free views fill their panes;
Markdown Open in Emacs. Keys use the event loop like real presses because the
field reads Shift from the current event.

Both checks use `test/native-checks.swift` to print failures with source locations
and exit with status 1. Use `check`, `require`, and `fail` for expectations and `runChecks` at
the entry point for thrown errors. Ordinary failures avoid macOS crash dialogs;
native-code crashes still trigger macOS reporting. Real windows exercise AppKit
and WebKit.

For launcher checks, substitute `test/native-focus.swift` and `build/check-focus`
with `test/native-launcher.swift` and `build/check-launcher`. Coverage: negative
monitor origins, offset/clamping, display-change notifications, attachment
rejection/rollback, donor restoration, focus-loss records and panel release.

For global shortcuts, use `test/native-shortcuts.swift` and
`build/check-shortcuts`. Like Emacs bindings, they register real Carbon hot keys
through the core on F13 to F16, unlikely to be owned by other apps. A competing
in-process registration simulates another app: its chord is refused and the
previous chord keeps working. Checks cover:

- Chords stay taken while registered and become free after release/replacement.
- Resetting a chord retains its Carbon registration under a new ID and restarts
  it; earlier presses delivered afterward send nothing.
- Pre-registration, unknown and held-repeat events send nothing.
- Records reach the pipe without open views; the last hot key removes the Carbon
  handler, over 20 set/remove cycles.

Events go to the installed handler, not through typing.

## Launcher and global-shortcut graphical coverage

Graphical `portal-launcher-gui-` tests use the real Emacs NS view: repeated
show/hide and delete/recreate, appearance/font changes, child-frame deletion,
native keyboard input and exact geometry on every connected monitor. A test-only
Carbon injector presses shortcuts through the installed callback, pipe parsing
and real command loop; this establishes neither physical-key nor Spaces behavior.
Run with subroutine trampolines enabled.

Command-session tests type native Escape, queue C-g into nested prompts, repeat
launcher shortcuts, delete/disable during prompts and immediately re-enter. They
cover stock completion and Vertico/Orderless/Marginalia, propagate command errors
after hiding, and use running Finder to verify cancellation, successful external
activation and native focus-loss delivery. Focus tests temporarily activate
already-running apps, including Finder. The NS injector holds synthetic C-g even
in ordinary `read-string`, so C-g uses an Emacs command-loop event. Physical C-g
and mouse click-away have the user's recorded daily-use acceptance. Batch ERT
and C notification tests cover session IDs and stale-record policy.

The [documented launchers](launcher.md) run as configured by users, loaded under
dynamic binding on F17 to F20: picker from M-x, its command-loop-queued key and
its shortcut, each with native typing; persistent hello buffer from its shortcut,
dismissed by the same chord; and a shortcut leaving hidden panels alone.
Shortcuts survive panel deletion/disabling, reevaluation retains one registration
each, and removed hot keys are no longer handled. Generic pickers return completion
results: typed names; Return on Vertico's highlight without typing, after Down,
and after Down then Up; stock completion's empty result; and nil after Escape.
The optional launcher.el recipe runs separately, outside CTest, via
`test/launcher-recipe.sh`; see [application notes](launcher-applications.md#optional-integration-smoke-test).

Presentation tests run real Vertico pickers in minibuffer panels at two sizes.
Inside the prompt, checks confirm the minibuffer is the sole window, starts at
the top and fills the panel; ten candidates appear unclipped without a mode line;
and native geometry matches the request. Typing, Down and Return select candidates.
Stock completion in minibuffer panels completes with Tab and never shows
`*Completions*`. Buffer panels show/hide mode lines in their window, splits and
switched buffers; ordinary windows sharing the buffer retain their own.
Alternating kinds and mode-line settings retains one launcher frame and restores
all session settings; later stock/Vertico prompts use the ordinary frame as before.
Dismissal, error, focus-loss and cancellation focus tests run in both kinds.

Persistent hello-world panels accept native keys in local commands and their
prompts. Every dismissal path, from buffer or prompt, leaves no session, recursive
edit or hook, retains the buffer and permits new presentations. Later command
errors leave the panel working; focus lost during a command still hides it when
that command fails. Escape restores the previous app's focus; commands activating
another app leave it frontmost. Set `PORTAL_LAUNCHER_SCREENSHOTS` to a directory
for panel pictures. The injector's `portal-test-capture-target` reads Emacs's drawn
surface without Screen Recording permission; pictures omit shadows and corners.

Graphical `portal-global-shortcut-gui-` tests send hot key events to the installed
Carbon handler via `portal-test-hotkey`, without Portal views or launcher frames.
Two shortcuts (lambda and command) run through the real command loop while another
app stays frontmost, with no frame/window changes. Function errors allow the next
queued press; changing a function on the same chord invalidates earlier presses;
removed hot keys are no longer handled. Held/doubled presses run once; shortcuts
run within minibuffer command loops. This does not establish physical-key delivery:
`test/global-shortcut-smoke.sh` starts disposable Emacs for a person to press two
chords in another app, printing what ran and which app was frontmost.

Verify the failure reporter without opening windows:

```sh
python3 -B -m unittest discover -s test -p 'test_native_checks.py'
```

## C core checks

Core tests load real bindings with `test/portal-fake-backend.c` replacing Swift
into batch Emacs with `--module-assertions`. They require only CMake, a C compiler
and Emacs, not Swift, Apple frameworks, Bun or Ghostty. The application still
requires macOS, as does the core pipe for now through `F_SETNOSIGPIPE`.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```

`ctest --test-dir build/core -R views` runs `test/portal-views-tests.c`, a C program
driving the registry with a fake platform that counts every core primitive call
and any call naming destroyed or wrong-kind views. Checks cover:

- Targets are never reused, even after close/failed open; invalid targets,
  wrong-kind lookups and invalid rectangles reach no platform view.
- Repeated placement attaches the same view; repeated hiding detaches once.
- Failed placement or refused primitives change nothing.
- Hiding retains session/size; moving frames retains the platform view.
- Closing destroys once; neither Lisp calls nor late platform records reach it afterward.

`ctest --test-dir build/core -R input-core` runs `test/portal-input-tests.c`,
pressing keys through a fake platform as users would. It routes like macOS,
holding keys on core instructions and replaying them in its event loop; page
answers and Emacs's side use `portal--input` actions. Checks cover:

- Terminal programs receive typing and all chords except Super's, which fall
  through to Emacs as typed. Pages receive every chord first and keep those they
  use; unused chords go to view shortcuts or Emacs with subsequent keys.
  Super-C/Super-V copy/paste; keyboard ownership can change while a page decides.
- Keys wait for Emacs acknowledgement, replay in order and stay with Emacs when
  its command never reads them.
- Only the first key after a native binding chord, when repeating it, goes to
  the app. After fallthrough, Emacs owns the trigger and repeats are dropped.
- C-g, Command-Escape and Emacs unfocus; clicks abandon handoffs before selecting
  panes, while Emacs focus changes do not.
- Finished/abandoned/other-view handoff serials do nothing; hiding/closing ends handoffs.
- Binding profiles with Shift/punctuation; invalid/colliding bindings preserve
  the previous configuration.

`ctest --test-dir build/core -R terminals` runs `test/portal-terminals-tests.c`
against the same fake platform:

- Invalid options, including unknown/inexact theme names, create nothing; theme
  catalogs are sorted and escaped.
- Themes reach all open terminals, never web views; unknown names reach none;
  rejection by a terminal stops the change there.
- Enter follows paste only on request, never after failed paste.
- Wrong-kind, unknown and closed targets reach no platform view; platform errors
  and refusals reach Lisp; exited terminals stay open/describable until closed.
- Real-pipe records: a change sends one `terminal` record; later changes wait for
  inspection; web views, unknown targets and closed terminals send none.

`ctest --test-dir build/core -R toolbar-core` runs `test/portal-toolbar-tests.c`
with fake-platform find/script responses supplied manually. Coverage:

- Each layout's buttons and availability, toolbar-free views, invalid `:toolbar`;
  zoom steps and text sizes stopping at limits, and refused sizes.
- Keyboard text-size, Command-F and Command-R shortcuts, retained by pages using
  those chords; ownership dot/clicks.
- Ordered, single searches; newer text replaces waiting searches; match counts
  and wrapping; page loads discard old results and search again.
- Cross-page TOC; closing find returns the keyboard only to views already owning it.
- State across hiding, frame moves and hidden toolbars; changed-only drawing and
  redraw after refusal; clicks on absent buttons; closed views hear nothing.

`ctest --test-dir build/core -R web-core` runs `test/portal-web-tests.c`, exercising
web/bridge rules as Lisp and platforms would, with real-pipe records. Checks cover:

- Allowed URLs; new-view about:blank and the displayed document add no history;
  failed loads retain the address.
- Bridge ordering, `change` coalescing, one record until Emacs receives,
  draining/re-arming and payloads exceeding a record.
- Rejection of frames, other pages and core types; ordinary pages get no bridge.
- Every navigation decision, including claimed origins in user names; local
  links/edits send `escape` before `bridge`, even for URLs exceeding a record.
- Delivery failures from departed pages are ignored; closed views hear nothing.
- `:appearance` before opening; appearance reaches every open web view oldest
  first, stopping on failure.

`ctest --test-dir build/core -R shortcuts-core` runs `test/portal-shortcuts-tests.c`,
simulating the platform with real-pipe records. Checks cover notation spellings
and invalid forms including NUL bytes; other registrations' chords, invalid or
refused chords and removed IDs change nothing. The same chord restarts its
platform registration under a new ID; different chords register before releasing
the old one, with both retained if release fails. IDs are never reused. A press
sends one record until released, carries the current ID, and sends nothing once
its shortcut has moved or gone.

The full build runs the same module tests via `ctest --test-dir build -R module`:
30 functions/arities; input chord/binding JSON conversion; toolbar theme face-color
conversion; options, edges and strings including NUL/non-ASCII. Malformed strings
(non-strings, raw bytes, surrogates), vectors, plists and invalid optional arguments
signal without backend calls. Argument-conversion signals reach Lisp unchanged;
backend errors become Lisp `error` with their message. Fake-platform echoing-app
bridge records reach connected pipes, wait while disconnected and survive reader
deletion.

`ctest --test-dir build/core -R channel` runs `test/portal-channel-tests.c`, a C
program using real POSIX pipes and manually fired fake-platform timers. After filling a pipe,
it drains and checks every record kind arrives in order without loss/duplication.
Coverage includes records waiting while disconnected or moving pipes, cancelled
retries, malformed/oversized records, descriptor ownership, and closed readers
with SIGPIPE's default action (which would end the test). A narrow write seam
interrupts/shortens writes, impossible on demand with real pipes.

## Compiled app host integration

Compiled-host integration tests need no graphical display:

```sh
./build.sh
ctest --test-dir build --output-on-failure
```

They cover real HTTP requests, relocated binaries without Bun on PATH, shared
startup, graceful shutdown, restart, crash recovery, startup timeout and
partial/incompatible readiness messages. Checks include Markdown output, local
link rewriting, rereading saved changes, invalid paths, access-token/Host
validation and non-executable raw HTML.

Task browser tests use real folders: recursive discovery of both layouts;
groups/parents; repeated and Unicode names; encoded IDs; unreadable folders;
symlinks; status/title rules; problems/duplicates; filtering; tree and execution
views of one dependency graph; ID-preserving moves/conversion; reloads after edits;
nested-folder link rewriting; missing/invalid roots; and image reads confined to
attachment folders.
