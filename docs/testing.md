# Testing Portal

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

Run commands from the repository root after [building Portal](../CONTRIBUTING.md).
Start with the [checks before a PR](../CONTRIBUTING.md#checks-before-a-pr), then
choose native checks below for the area changed. GUI checks open windows and can
take focus; use a disposable Emacs. Agent smoke tests using credentials are opt-in.

The existing validation record reports macOS 27.0, Swift 6.4, and Emacs 31.1
with `--module-assertions`. C and Swift compile with warnings treated as errors;
the recorded Lisp byte compilation passed without warnings. The descriptions
below explain coverage, not results of a new run.

- [Terminal graphical checks and event injector](#terminal-graphical-checks)
- [Batch coverage](#batch-coverage) and [graphical coverage](#graphical-coverage)
- [Opt-in agent smoke tests](#opt-in-agent-smoke-tests)
- [Combined graphical suite](#combined-graphical-suite)
- [Standalone AppKit checks](#standalone-appkit-checks)
- [Launcher and global-shortcut graphical coverage](#launcher-and-global-shortcut-graphical-coverage)
- [C core checks](#c-core-checks)
- [Compiled app host integration](#compiled-app-host-integration)

## Terminal graphical checks

The graphical terminal tests exercise a real shell, alternate-screen output,
native keyboard and clipboard input, focus return, resizing, hidden-session
continuity, shell termination, and editing/saving a file in Vim. A real shell's
directory reports, percent-encoded and from Ghostty's zsh or bash integration,
reach the buffer's metadata and `default-directory`; a hidden terminal's title
arrives without renaming it; and an exit is reported when it happens, keeping the
buffer, its output and the keyboard until the next key. They also exercise
Command chords running Emacs commands with rapid follow-up keys, `C-b` and `C-a`
reaching the shell, multiple sessions and splits, runtime binding
registration/unbinding, quick-only shortcuts, shifted characters, literal
binding bytes, cancellation, and minibuffer focus.
Batch binding tests run with `ctest --test-dir build -R terminal-bindings`, and
batch tests of the view lifecycle (opening, splits, selection, `quit-window`,
showing the buffer elsewhere, moving between frames, deleting a frame and
killing the buffer) run with `ctest --test-dir build -R view`. Batch Emacs has
one frame, so these tests open a second, suspended terminal frame on a
pseudo-terminal.
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

To check program launches with a controlled shell environment, run
`sh test/terminal-shell-startup.sh` after building. It starts a disposable graphical
Emacs with a minimal PATH and temporary zsh dotfiles, then verifies shell-side
program lookup, login and interactive startup, literal arguments, terminal
metadata, and missing-program errors. Set `EMACS` to choose its executable.

## Batch coverage

`ctest --test-dir build -R startup` loads `portal.el` by absolute path in a
fresh `emacs --batch -Q`, without `-L` or a fake backend, and verifies that
Portal's features and commands are available from an unrelated directory, and
that loading registers no global shortcut and loads no native code.

`ctest --test-dir build -R global-shortcut` runs the Lisp module on the real C
core, built with the fake backend, whose hot keys refuse F19 as if another
application had it. It feeds `shortcut` records to the pipe's filter as the
core sends them for presses, and runs what the filter queued through the
command loop's key lookup. It checks two names calling a lambda and a command;
that setting a name again, on its chord or another, leaves one registration and
frees the old chord; that unloading fails, keeping the feature and a chord it
cannot release; that invalid names, functions and notation, another name's
chord in any spelling, and a refused chord change nothing; that a function's
error is a message, keeps every shortcut, and lets the press queued behind it
run; that records split across reads arrive, malformed and stale ones do not,
and a press while one waits is dropped; that removal is independent and
repeatable; and that unloading and a real `kill-emacs` release every chord.
`ctest --test-dir build -R launcher` runs without launcher.el. It checks that loading, enabling
and presenting the panel set no global shortcut, and that disabling and
deleting it leave every shortcut set. It evaluates the launcher examples from
[the launcher guide](launcher.md), with native calls stubbed, loading them from a file with dynamic
binding and again with lexical binding: the picker runs from M-x, its key and
its shortcut's record through the command loop; the persistent hello buffer
reads a name from its shortcut and from M-x, and its chord pressed again
dismisses it; a shortcut presents nothing. Evaluating the shortcuts again
replaces each registration, so a press from before calls nothing, and removing
one leaves the others. With a stand-in `launcher`, the launcher.el recipe
reads a spaced bang query in stock completion, cancels empty and blank results
and bangs without a query, passes a prefix argument and runs from its shortcut.

Batch tests of web buffers run with `ctest --test-dir build -R web`. They cover
`portal-open-url` opening a new buffer each time, the view following the selected
pane after a split, `portal-preview-html` reusing its buffer, `g`, `q` and
killing the buffer, the toolbar each command chooses, and Hello and the Markdown
preview opening at once and loading once a simulated app host is ready. Markdown
tests feed the fake native adapter `page`, `follow` and `edit` bridge messages
and `select` records. They check document identity, handoff placement with and without
`display-buffer-alist` rules, line fragments, images and folders, failed
handoffs, paths longer than a record, Open in Emacs, and return tracking across
buffers, previews and frames. One test
opens a Markdown preview with the real app host, which `ctest` passes through
`PORTAL_TEST_HOST`. It checks that the preview loads once the host is ready,
stays as it is while the host stops and restarts, and that `g` reloads it.
Batch task browser tests run with `ctest --test-dir build -R tasks`. They cover
project-relative, absolute and directory-local task roots, auxiliary buffers,
explicit and prompted roots, remote roots, one buffer per root, `g` and restart
recovery of the page on screen, and attachment handoff. Status edits keep a BOM,
CRLF line ends, file modes and every other byte, and refuse buffers with
unsaved changes, read-only files, files changed since the edit was planned,
failed saves (leaving no temporary file) and files outside the root. Edit in Emacs reuses a modified buffer beside the page, and saving a file
refreshes only the loaded views of its root. One test runs the real app host,
and `ctest --test-dir build -R actions` sends status changes, a repeated change, a refusal and
Edit in Emacs from the compiled host through Emacs's command loop.
Batch task view tests run with `ctest --test-dir build -R tasks-view`, against
org-ql 0.8.10 and the libraries it loads that Emacs lacks, and Evil 1.15.0 and
evil-collection 3.0.3, which CMake downloads into `build/elpa` from NonGNU ELPA
and release tags and verifies by hash. They cover the
project from a file, an auxiliary buffer, a terminal and the view itself, and
two projects apart; readiness from unsaved edits, a cancelled prerequisite,
missing, shared and untagged IDs, cycles, a keyword other than `TODO`, and
archived prerequisites; schedules from yesterday to tomorrow, deadlines and
ordering; links to blockers; `g`, saving, a new day and returning, each pane
keeping its task; the empty list; Org's agenda keys on a line; and typing the
view's keys in evil-collection's normal state, its other keys staying. Task detail
tests check that `RET` shows the whole task with its own folds, the file's
staying folded and typing at the task's end touching no folded text, and
reuses one detail; that keys other than `M-,` are Org's;
that tasks without a unique `CUSTOM_ID` open in their file and links to a
shared one are refused; that task links,
archived tasks and blockers' links in the view show their task, and `M-,` goes
back to each link's place and to the view on its task, even after another pane
moved the view, or the All tasks view was killed; that typing, `C-c C-t`, undo and
saving there change the file's buffer, unsaved edits surviving the way back
and a reopened detail; and that closed tasks reopen and blocked tasks change
state. `portal-tasks-implement` tests start Claude, as the fake terminal
records it, from a view line, the detail and `project.org`, in a project
whose path has spaces and quotes. They check the literal arguments and
directory, the brief's provenance and exact subtree beside 3000-line
neighbors, an unchanged file, showing a task's terminal again, an explicit
second run, and each brief deleted with its terminal. Blocked, closed,
unidentified and other files' tasks, declining to save, a failed save, a
save hook that changes the buffer or the file again, a file changed on disk
and a terminal that fails to start each start nothing, and an accepted save
puts the edit in the brief.
Agent dashboard batch tests run with `ctest --test-dir build -R agents`. They
check that the dashboard is one plain buffer that opens no view or app host;
that tracking keeps two terminals in one directory apart, follows renames,
keeps exited programs and labels, and drops closed, killed and replaced
terminals, including a reset quick terminal and a new view in the same buffer,
while untracking leaves terminals running; that rows follow reported titles,
directories, exits and project reassignment, a directory never reassigning a
project; that a refresh with nothing changed rewrites nothing, and one with
changes keeps the sort order, each window's session and screen line, the
selected window and focus, and asks native code, the user and the system
nothing; that `g` works with live updates off; that one timer runs while the
dashboard is shown in any number of windows, none while hidden, shown only on
an invisible frame, killed or with live updates off, and that showing it again
refreshes it; and that `RET` gives the right ordinary, quick, hidden or
other-frame terminal the keyboard. The `agents-evil` test uses the pinned Evil
and evil-collection packages to check Enter navigation in normal state.
`test/portal-agents-benchmark.el` measures
refresh time, allocation and redraws at 10, 50 and 100 tracked terminals; see
its commentary to run it.
`bun test host` checks that status edits change only the status value, in
block and flow YAML, with quoted keys and values, comments, unknown fields, a
BOM, CRLF and multibyte text; that tagged, anchored, duplicated and otherwise
unsafe entries are refused, as are bytes that are no longer the task; and that the action route resolves moved IDs,
serializes repeated requests, rejects other origins, contexts and roots, and
that task pages run only their own hashed script.

## Graphical coverage

The graphical web tests wait for real WebKit page loads. They verify JavaScript
execution, relative local assets, a page staying loaded while hidden, repeated
loading and native URL validation.
The Markdown graphical tests use the real app host and real mouse clicks. They
check that Back and Forward restore reading positions, that a source link hands
the keyboard to Emacs in one click, that clicking the preview selects its pane,
that `portal-preview-return` and `RET` return without reloading, and that
Command-Escape still returns to Emacs, and `RET` re-enters. In a frame forcing the
opposite appearance, a preview follows the system's, and `portal-web-appearance`
turns the page on screen light or dark without reloading it.
The task browser graphical tests check real list and task pages: Back and
Forward restore the filter and reading positions, `g` rereads the saved file,
and `g` loads the page on screen after an app host restart. They also check
task links, inline images in both layouts, and one-click handoff of
attachments, with mock-up HTML opening as source.
They also check dimmed blocked rows and what they wait for, struck-through
completed rows, links to
prerequisites and the tasks they block, including completed ones, the view and
filter across those links, and a dependent becoming ready after its
prerequisite is saved as done. For nested folders they check indentation,
folding groups and parent tasks with real keys, folds kept by Back, completed
parents above unfinished work, folder links, and reloading after a saved move.
Task operations are checked with real clicks and keys: completing a row in
place, with the filter hiding it and focus on the next row, at the same
scroll position and without a new history entry; Tab and Return on a row's
button without opening the task; reopening from a task page, keeping focus on
its button; Edit in Emacs handing the keyboard to the source pane; a save
refreshing the page while Emacs keeps the keyboard, including a hidden page
once it is shown; Back showing the list without a task completed on its page;
and an action refused over unsaved changes.
The graphical toolbar tests type and paste into the real find field and step through matches
with real keys, check that closing find leaves the keyboard with Emacs once the user
returned there, that web state survives buffer switches, reload and a theme change,
that a terminal's grid follows its text size and live toolbar visibility, and that
Excalidraw and a quick terminal have no strip.
The combined graphical suite includes web, terminal, Excalidraw, Markdown, toolbar,
and shared input tests, plus
coexistence checks for both startup orders, real keyboard handoff, WebKit key-up
delivery alongside terminals, independent cleanup, and shared-frame deletion.
They do not assert Lisp caches, hook names, or implementation call counts.
The task view's graphical tests check that redisplay redraws a view after an
edit once its pane is selected again or shows it again, and that typing `RET`
and `M-,` shows a task while another pane keeps the file folded, then returns
to the redrawn view on that task.
The terminal picker's graphical tests type real keys, one at a time as a person
types, into Consult, Vertico and Orderless from `build/elpa`, from an ordinary
buffer, a terminal that has the keyboard and a quick panel. They check that
`M-.` moves the live terminal into the preview window, including from another
frame, without the keyboard, that typing stays in the minibuffer and reaches no
shell, that cancelling puts every view and the keyboard back, and that accepting
gives the chosen terminal the keyboard once the minibuffer closes.
Automatic discovery has batch tests in `ctest --test-dir build -R agent-discovery`:
real asynchronous pipes, process identity, nested/spoofed controls, PID reuse,
hidden/manual collection, bounded failures, pending triggers, and recorded Claude
lifecycle/compaction/error/trust fixtures replayed through dashboard rows. Codex
fixtures cover startup, working, completion, approvals, denial, cancellation and
model failure. Mixed-agent checks isolate status sources and discovery options,
reject delayed Claude results after a Codex replacement, and suppress redraws
for spinner frames and blinking approval markers. Pi tests replay recorded tool,
cancellation and provider-error lifecycles, reject pre-discovery/delayed progress,
and cover hidden collection, manual refresh, source loss and repeated-state
redraw suppression. `ctest --test-dir build -R pi-extension` tests the shipped
extension, including synthetic retry, compaction, nested UI prompts and
conversation/reload events; these simulations are not live-provider captures.
Runtime cases cover option values, attached values, short flag clusters,
terminators, execution modes, unknown options and every supported runtime pairing
for Claude, Codex and Pi. With Node installed, CTest also runs actual Node
processes on PTYs through the native collector and checks
that a preload named `claude` is not mistaken for the executed script, and that
Node with a spoofed Bash argument name does not produce an agent row.
`ctest --test-dir build -R processes` checks Darwin argument parsing, including
NUL padding and truncation, and launches real nested PTYs with an inherited
marker to verify TTY ownership. `portal-agents-benchmark-discovery` in
`test/portal-agents-benchmark.el` compares 10, 50 and 100 simulated sessions;
pass `"codex"` for title inference or `"pi"` for progress instead of Claude.

## Opt-in agent smoke tests

For the real tmux exclusion test, set `PORTAL_TEST_PROCESS_SNAPSHOT` to the
absolute path of `build/portal-process-tests`, have tmux on Emacs's `exec-path`,
and run `portal-discovery-gui-inherited-tmux-marker` from
`test/portal-agent-discovery-gui-tests.el` in a fresh graphical Emacs. It uses
an isolated tmux socket and a fixture executable; no Claude credentials or
requests are needed. It verifies a direct run alongside attached and detached
tmux runs inheriting their Portal terminal's marker.

For the opt-in real-Claude smoke test, set `PORTAL_TEST_CLAUDE_DIRECTORY` to an
already trusted project, load `test/portal-agent-discovery-gui-tests.el` in a
fresh graphical Emacs, and run `portal-discovery-gui-plain-claude`. It starts
plain Claude sessions, sends one harmless prompt, verifies automatic rows and
working/idle, navigation and exit/relaunch, then closes its terminals.

For `portal-discovery-gui-mixed-codex-claude`, also set
`PORTAL_TEST_CODEX_DIRECTORY` to a project already trusted by both agents. It
starts plain Claude and Codex sessions in that directory, sends Codex a harmless
prompt, checks their separate activity and exact navigation, hides/reopens the
dashboard, quits/relaunches Codex, and discovers and visits a hidden quick-terminal
Codex. A spoofed Codex name with an approval title remains a negative control.

For `portal-discovery-gui-mixed-pi-claude-codex`, also set
`PORTAL_TEST_PI_AGENT_DIR` to a disposable Pi agent directory containing the
bundled `portal-pi.ts` in `extensions/`, credentials for one harmless request,
and settings with terminal progress off. The directory must have a project
trust decision (or `defaultProjectTrust: "never"`) so startup can reach the TUI.
Install this additional test-only extension in that directory:

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

It launches plain Pi, Claude and optionally Codex in one directory, verifies
Pi work and dialogs, repeats a dialog with the dashboard hidden, tests `/new`
and `/reload`, quits/relaunches Pi and visits a hidden quick Pi terminal. It
uses that temporary Pi directory without changing the user's settings.

The agent dashboard's graphical tests use real terminals and redisplay's window
hooks. They check that `RET` gives a hidden terminal, one shown in another
frame and a quick terminal the keyboard, and that the dashboard in another frame
pulls a terminal there; that a title a shell sets appears without `g` while
another terminal keeps the keyboard, and unchanged ticks redraw nothing; and
that hiding, showing in another frame, an invisible frame and killing leave one
timer only while shown.

## Combined graphical suite

Build the [test-only event injector](#terminal-graphical-checks), then run the suite in a disposable
graphical Emacs. Batch Emacs has no native window and
cannot exercise these behaviours:

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

Apart from the packages in `build/elpa`, the Lisp tests use only Emacs's
built-in libraries.

## Standalone AppKit checks

A standalone AppKit check
also verifies guest Escape retains focus, while Command-Escape and
focused-view removal return focus to the editor:

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

The checks open web views through the core's registry and the macOS primitives,
as Emacs does, with `test/native-views.swift` in place of the Emacs bindings. They also
check that a hosted web view keeps no data between sessions, that a page
outside the app host goes to the default browser while the app stays, that
only a hosted app's main frame can use the bridge, that `portalBridge` is ready
before the page's scripts on first load and on reload, that a failed delivery
reaches Emacs, and that a hosted app reports each committed page over it.
Loading the page on screen again reloads it without a new history entry. A click on it sends `select`, and a click
on a local link, even one longer than a record, returns the keyboard to Emacs
and sends `follow` over the bridge. A full notification pipe delays records without losing or
reordering them, retried on the Swift timer, and records still waiting when
Emacs replaces the pipe go to the new one; a closed view's records never go.
`test/native-terminal-stub.swift` stands in for the terminal kind, so they build
without Ghostty, and they link the core's registry, input handoff, terminal and web
rules, toolbars and pipe without the Emacs bindings.

Replace `test/native-focus.swift` and `build/check-focus` with
`test/native-toolbar.swift` and `build/check-toolbar` to check toolbar layout with
the real core: buttons that keep the keyboard where it was, the ownership dot, back
and forward in previews, zoom limits, the TOC across hiding and reload, typing into
the real find field, Return, Shift-Return and Escape, Command-F and Command-R after the page,
closing find after the keyboard went back to Emacs, live visibility and colors, a
view without a toolbar filling its pane, and a Markdown preview's Open in Emacs.
Keys reach the find field through the event loop, as real presses do, since the
field reads Shift from the current event.

Both standalone checks use `test/native-checks.swift` to print failures with a
source location and exit with status 1. Use its `check`, `require`, and `fail`
helpers for test expectations, and `runChecks` at the entry point to report thrown
errors. This keeps ordinary test failures from triggering macOS crash dialogs;
crashes in the native code under test are still reported by macOS. The checks
still open real windows to exercise AppKit and WebKit.

For the launcher's native checks, replace `test/native-focus.swift` and
`build/check-focus` in that command with `test/native-launcher.swift` and
`build/check-launcher`. They exercise negative monitor origins, offset/clamping
rules, display-change notifications, attachment rejection and rollback, donor
restoration, focus-loss records and panel release.

For global shortcuts, use `test/native-shortcuts.swift` and
`build/check-shortcuts`. They register real Carbon hot keys through the core's
shortcuts, as the Emacs bindings do, on F13 to F16, which other apps are
unlikely to have. A competing registration in the process stands in for another
application: its chord is refused, and the previous one keeps working. They check
that a chord is taken while registered and free once released or replaced, that
setting the same chord again keeps its Carbon registration under a new ID and
restarts it, so that a press from before the set that Carbon delivers only
afterwards sends nothing, that a hot key event from before its registration, an
unknown one and a held key's repeats send nothing, that records reach the pipe with no view open, and that
the Carbon handler is removed with the last hot key, over 20 set/remove cycles.
Events are sent to the installed handler, not typed.
## Launcher and global-shortcut graphical coverage

The graphical `portal-launcher-gui-` tests use
the real Emacs NS view, including repeated show/hide and delete/recreate,
appearance/font changes, child-frame deletion, native keyboard input and exact
geometry on every connected monitor. A test-only Carbon event injector presses
global shortcuts through the installed native callback, pipe parsing and the
real command loop. This injection does not establish physical-key or Spaces
behavior. Run them with subroutine trampolines enabled.
Command-session tests type native Escape and queue C-g into nested prompts,
press a launcher's shortcut again, delete/disable during a prompt and
immediately re-enter. They
exercise stock completion and Vertico/Orderless/Marginalia, propagate a command
error after hiding, and use the running Finder app to verify cancellation,
successful external activation and actual native focus-loss delivery. The
focus test temporarily activates already-running applications, including Finder.
The NS injector holds synthetic C-g even in an ordinary `read-string`, so that
key is tested as an Emacs command-loop event. Physical C-g and mouse click-away
are covered by the user's recorded daily-use acceptance. Session ID
and stale-record policy are covered by batch ERT and the C notification tests.
The [documented launchers](launcher.md) run as a user configures them, loaded with dynamic
binding, on test chords from F17 to F20: the picker from M-x and its key, queued for the command loop, and from
its shortcut, each typed into with native keys; the persistent hello buffer
from its shortcut, dismissed by the same chord; and a shortcut that leaves the
hidden panel alone. The shortcuts outlast deleting and disabling the panel,
evaluating them again keeps one registration each, and a removed shortcut's
hot key is no longer handled. A generic picker returns what completion
returns: a typed name, Return on Vertico's highlighted candidate with no typed
text, after Down and after Down then Up, stock completion's empty result, and
nil after Escape. The optional launcher.el recipe is tested separately, outside
CTest, by `test/launcher-recipe.sh`; see the
[application notes](launcher-applications.md#optional-integration-smoke-test).

Presentation tests run a real Vertico picker in a minibuffer panel at two
sizes. From inside the prompt they check that the minibuffer is the panel's
only window, starts at the top and fills it, that ten candidates show
unclipped with no mode line, and that the native geometry is as requested;
typing, Down and Return select a candidate. In a minibuffer panel, stock
completion completes with Tab and shows `*Completions*` nowhere. A buffer panel
shows or hides the mode lines of its window, a split and switched buffers,
while the ordinary window on the same buffer keeps its own. Alternating kinds
and mode-line settings keeps one launcher frame and restores every session
setting; afterward, ordinary prompts with stock completion and Vertico use the
ordinary frame as before. The dismissal, error, focus-loss and cancellation
focus tests run in both kinds. A persistent hello-world panel takes native keys
in a local command and the prompt it opens. Each way of dismissing it, from
its buffer and from that prompt, leaves no session, recursive edit or hook,
keeps the buffer and lets a new presentation start. A later command's error
leaves it working, and focus lost while a command runs still hides it when
the command then fails. Escape returns focus to the previous app, and a panel
command that activates another app leaves that app in front. With
`PORTAL_LAUNCHER_SCREENSHOTS` set to a directory, these tests save pictures of
the panel there. The injector's `portal-test-capture-target` reads them from
the surface Emacs drew into, so it needs no Screen Recording permission; they
show no panel shadow or corners.

The graphical `portal-global-shortcut-gui-` tests send hot key events to the
installed Carbon handler with `portal-test-hotkey`, with no Portal view or
launcher frame. Two shortcuts, a lambda and a command, run through the real
command loop while another application stays frontmost, and no frame or window
changes. A function's error leaves the next queued press to run, a press from
before a function changed on the same chord is ignored, and a removed shortcut's
hot key is no longer handled. Held and doubled presses run once, and a shortcut
runs inside a minibuffer prompt's command loop. These do not establish physical
key delivery: `test/global-shortcut-smoke.sh` starts a disposable Emacs for a
person to press two chords in another app, and prints what ran and which app
was in front.

Verify the failure reporter without opening windows:

```sh
python3 -B -m unittest discover -s test -p 'test_native_checks.py'
```

## C core checks

The C core has its own tests. They load the real bindings, compiled
with `test/portal-fake-backend.c` in place of the Swift backend, into batch Emacs
with `--module-assertions`. They need only CMake, a C compiler and Emacs; they do not
use Swift, Apple frameworks, Bun or Ghostty. The application itself still requires
macOS, and so does the core's pipe for now: it relies on `F_SETNOSIGPIPE`.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```

`ctest --test-dir build/core -R views` runs `test/portal-views-tests.c`, a C program that drives the view
registry with the fake platform, which counts every primitive the core calls and any
call that names a destroyed view or a view of the wrong kind. It checks that targets
are never reused, including after close or a failed open; that invalid targets,
wrong-kind lookups and invalid rectangles reach no platform view; that repeated
placement attaches the same platform view each time, and repeated hiding detaches it
once; that a failed placement, or a primitive the platform refuses, changes nothing;
that hiding keeps a session and its size and placing it in another frame keeps the
same platform view; and that closing destroys a view once, after which neither Lisp
calls nor a late record from the platform reach it.

`ctest --test-dir build/core -R input-core` runs `test/portal-input-tests.c`, which presses keys as a
user would through the fake platform. The fake routes each press as the macOS
platform does, holding what the core says to hold and replaying it when the test
runs its event loop, and plays a page's answers and Emacs's side with
`portal--input` actions. It checks who gets each key: a terminal's program gets
typing and every chord but Super's, which falls through to Emacs as typed; a
page is offered each chord, and keeps those it uses, while an unused one goes
to the view's shortcuts or Emacs, with the keys typed after it; Super-C and
Super-V copy and paste; and the keyboard moving while a page decides. It also
checks that keys typed before Emacs acknowledges are held and replayed in
order, and stay with Emacs when its command never read them;
that only the first key after a native binding's chord, when it repeats it,
goes to the app, while after a chord that fell through the trigger is
Emacs's and its repeats are dropped; C-g, Command-Escape and Emacs's unfocus;
that a click abandons a handoff before it selects the pane, while Emacs's own
focus changes do not; that serials of finished or abandoned handoffs, or another
view's, do nothing; that hiding or closing ends a handoff; binding profiles,
with Shift and punctuation; and that an invalid or colliding binding leaves the
previous configuration working.

`ctest --test-dir build/core -R terminals` runs `test/portal-terminals-tests.c`, which drives the core's
terminal rules with the same fake platform. It checks that invalid options, including
unknown or inexact theme names, create nothing; that the theme catalog is sorted and
escaped; that a theme reaches every open terminal and no web view, that an unknown name
reaches none, and that a terminal rejecting it stops the change there; that Enter
follows a paste only when asked and never after a failed paste; that wrong-kind,
unknown and closed targets reach no platform view; that platform errors and refusals
reach Lisp; and that a terminal whose process exited stays open and describable until
closed. Records go to a real pipe: a change sends one `terminal` record, later changes
wait until the view is inspected, and web views, unknown targets and closed terminals
send none.

`ctest --test-dir build/core -R toolbar-core` runs `test/portal-toolbar-tests.c`, which drives the core's
toolbars with the fake platform, answering its finds and script calls by hand. It
checks each layout's buttons and which of them work, including views without a
toolbar and an invalid `:toolbar`; zoom steps and text sizes stopping at their limits,
and a size the platform refuses; the keyboard's text size, Command-F and Command-R shortcuts,
which a page that uses those chords keeps; the ownership dot and its clicks; searches running one at a time in
order, newer text replacing waiting searches, match counting and wrapping; a page
that loads dropping old results and searching again; the table of contents across
pages; closing find only returning the keyboard to a view that has it; state kept
across hiding, another frame and hidden toolbars; drawing only what changed, and
drawing again after a refused draw; clicks on buttons a toolbar does not have; and
that a closed view hears nothing.

`ctest --test-dir build/core -R web-core` runs `test/portal-web-tests.c`, which drives web views' rules and
the bridge as Lisp and a platform would, with records going to a real pipe. It checks
which URLs load, that about:blank in a new view and the document on screen do not add
history entries, and that a failed load keeps the view's address. On the bridge, it
checks message order, `change` coalescing, one record until Emacs receives, draining
and re-arming, and payloads larger than a record. It rejects frames, other pages and
the core's own types, and ordinary pages get no bridge. It checks every navigation
decision, including claimed origins in user names; that a local link or an edit sends
`escape` before `bridge`, even with a URL longer than a record; that a delivery failure
from a page that has gone is ignored; and that a closed view hears nothing. It checks
`:appearance` before a view opens, and that an appearance reaches every open web view,
oldest first, stopping at one that fails.

`ctest --test-dir build/core -R shortcuts-core` runs `test/portal-shortcuts-tests.c`, which plays the
platform for the core's global shortcuts, with records going to a real pipe. It
checks the notation's spellings and its invalid forms, including NUL bytes;
that another registration's chord, an invalid one, one the platform refuses and
a removed ID change nothing; that the same chord restarts its platform
registration under a new ID while another chord is registered before the old
one is released, and that a release the platform refuses keeps both; that IDs
are never reused; and that a press sends one record until released, carries the
current ID, and sends nothing once its shortcut has moved or gone.

The full build runs the same module tests as `ctest --test-dir build -R module`. They check
the 30 functions and their arities, the input functions' conversion of chords and
binding JSON, the toolbar theme's conversion of face colors, and the conversion of
options, edges, and strings,
including NUL bytes and non-ASCII text. They also check that malformed strings (non-strings,
raw bytes, surrogates), vectors, and plists, and invalid optional arguments, signal
without calling the backend. A signal raised while converting an argument reaches
Lisp unchanged, and a backend error becomes a Lisp `error` with its message. A
bridge record for the fake platform's echoing app reaches a connected pipe, waits while
none is, and survives its reader being deleted.

`ctest --test-dir build/core -R channel` runs `test/portal-channel-tests.c`, a C program that drives the
pipe with real POSIX pipes, firing the fake platform's timers by hand. It fills a
pipe and checks that records of every kind arrive in order, none lost or
duplicated, as it drains. It also covers records waiting while disconnected or
moving to a new pipe, cancelled retries, malformed and oversized records,
descriptor ownership, and a closed reader with SIGPIPE's default action, which
would end the test. A narrow write seam interrupts or shortens writes, which a
real pipe cannot do on demand.

## Compiled app host integration

The compiled-host integration tests run without a graphical display:

```sh
./build.sh
ctest --test-dir build --output-on-failure
```

They exercise real HTTP requests, a relocated binary with no Bun on PATH,
shared startup, graceful shutdown, restart, crash recovery, startup timeout,
and partial or incompatible readiness messages.
They also check Markdown output, local link rewriting, rereading saved changes,
invalid paths, access-token and Host validation, and non-executable raw HTML.
Task browser tests use real folders: recursive discovery of both layouts,
groups and parent tasks, repeated names, Unicode names and encoded IDs,
unreadable folders, symbolic links, status and title rules, problems and
duplicates, filtering, the tree and execution views of one dependency graph,
ID-preserving moves and conversion, reloads after edits, link rewriting from
nested folders, missing and invalid roots, and image reads kept inside the
attachment folder.
