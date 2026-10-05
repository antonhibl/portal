# Work with terminals

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

- [Quick project terminal](#quick-project-terminal)
- [Independent terminals](#native-ghostty-terminal)
- [Names, projects and directories](#names-projects-and-directories)
- [Choosing terminals](#choosing-terminals)
- [Consult and Embark](#consult-and-embark)
- [Appearance and native bindings](#appearance-and-native-bindings)

For coding agents running in these terminals, see the [agent dashboard](agents.md).
For native test procedures, see [Testing Portal](testing.md#terminal-graphical-checks).

## Quick project terminal

Run `M-x portal-terminal-toggle` to summon a scratch terminal in the bottom half
of the frame. Run it again to dismiss the panel and return to your editing
window, even if the terminal no longer has keyboard focus. No global shortcut
is installed. Call `(portal-terminal-toggle)` from Lisp or bind the command to
whatever Emacs key sequence you prefer. For example, in your own configuration:

```elisp
(keymap-global-set "s-`" #'portal-terminal-toggle)
```

A Command chord reaches Emacs from a terminal, so the same key dismisses the
panel while Ghostty has keyboard focus. See [the input
bridge](terminal-input-bridge.md) for how native events reach Elisp, and
for native bindings, which claim a chord such as a Control chord that the
terminal's program would otherwise get.

Each project has one quick shell, which you can summon from any Emacs frame.
The panel and its remembered height belong to each frame, but summoning the
shell in another frame brings the same shell into that frame's panel. A new
shell starts at the project root of the current file or Dired buffer, which
`portal-project-function` finds, with `project.el` by default. Help
and other auxiliary buffers use the most recently selected file/Dired directory
in that frame.
Outside a project, the file's directory is used; with no editing context,
`portal-terminal-quick-directory` defaults to home. Remote contexts are rejected.

Dismissal only hides the panel: the shell, current directory, environment,
partially typed input, scrollback, and foreground programs remain intact.
Reopening never sends `cd` or starts a replacement shell. A command such as
`npm run dev` keeps running while hidden; reopen and use `C-c` to interrupt it.
Switching files or projects does not automatically change an already visible
panel. Dismiss it, then summon again to select the new project's quick shell.

Quick terminals have these commands, which you can bind to Command chords:
`portal-terminal-quick-dismiss` dismisses without ending the shell,
`portal-terminal-quick-reset` confirms and resets to a fresh shell at this
project's root, and `portal-terminal-quick-forget` confirms and forgets this
project's quick shell. Reset/forget target the visible panel when there is
one, otherwise the current editing project. Escape, `q`, and `C-g` remain
terminal input. Clicking into the
editor leaves the panel visible. Its initial height is controlled by
`portal-terminal-quick-height` (default `0.5`); dismissal remembers manual resizing.

Quick terminals are excluded from ordinary Portal terminal selection, numbering,
and cycling. They have no naming or multiple-instance workflow. A busy quick
shell remains busy until its command finishes or you interrupt/reset it.
Deleting a frame only hides its panel's shell. Quitting Emacs ends the session;
this does not provide persistence across Emacs restarts. A shell that exits is
not silently restarted: use reset when you want a new one.

Run the buffer/window/project tests with `ctest --test-dir build -R quick-terminal`.
`ctest --test-dir build -R terminal-metadata` checks terminal names, projects and
directory reports with the fake native module: names that tell projects named alike
apart, lookups by root after renames, reports while hidden, changes made while a
terminal opens, ignored directory reports, reassignment, exits and kills, completion over every field with Emacs's own
styles, and quick terminals keeping their names and projects.
The graphical terminal suite also tests a Command chord toggling the panel from inside
it, and a real foreground process continuing while the quick panel is hidden.

## Native Ghostty terminal

To compare terminal performance, run `./benchmark.sh --label portal` inside the
embedded shell and `./benchmark.sh --label ghostty` in standalone Ghostty.
See [benchmark methodology and FPS research](terminal-benchmark.md) for
latency, frame timing, optional Instruments captures and interpretation limits.

After `./build.sh`, load `portal.el` and run `M-x portal-terminal`, or launch a
fresh graphical Emacs:

```sh
emacs -Q -L "$PWD" -l "$PWD/portal.el" --eval '(portal-terminal)'
```

This embeds a real Ghostty Metal terminal surface inside the pane. Ghostty owns
the PTY, shell, terminal state, fonts, rendering, selection and scrollback.
It starts your normal shell in the current local `default-directory`; interactive
commands, Vim and other TUIs use the real terminal protocol engine. It does not
convert output to Emacs text or use WebKit or the Bun server.

- Click the terminal or press `RET` in its buffer to give it keyboard focus.
- The shell gets typing and every Control and Option chord, including Escape,
  `C-g`, `C-c` and tmux's `C-b`. A Command chord reaches Emacs, which runs it in
  the terminal's buffer, then gives the terminal the keyboard back.
- `Command-Escape`, or clicking **Return to Emacs**, leaves keyboard control
  with Emacs. Use normal Emacs bindings, then `RET` to re-enter Ghostty.
- Select with the mouse and use `Command-C` / `Command-V` for the macOS clipboard.
  Scroll with the trackpad or mouse wheel. Non-Latin IME composition has not
  been manually verified.
- Hidden buffers keep their shells running: `quit-window` or switching buffers
  hides the terminal, and showing the buffer again brings the same shell back.
  Deleting the frame showing a terminal also only hides it. Killing a terminal
  buffer or running `portal-terminal-close` in it ends that shell.
  `portal-terminal-close-all` ends all embedded shells.

Terminals come with these commands, and no keys: bind the ones you use in
Emacs, on Command chords to reach them from inside a terminal too.

| Command | Action |
| --- | --- |
| `portal-terminal-new` | New independent terminal buffer |
| `portal-terminal-split-below` / `-split-right` | Split below / right with a new shell |
| `portal-terminal-next` / `-previous` / `-last` | Next / previous / last terminal buffer |
| `portal-terminal-select-index` | Select a terminal by the digit of its key, such as `s-1` |
| `portal-terminal-choose` | Choose a terminal by name, project, directory or title |
| `portal-terminal-rename` | Rename the terminal buffer |
| `portal-terminal-zoom` | Zoom the pane; repeat to restore the layout |
| `portal-terminal-kill-pane` | End the shell, asking first while it runs, and close its pane |

```elisp
(keymap-global-set "s-n" #'portal-terminal-new)
(keymap-global-set "s-]" #'portal-terminal-next)
(keymap-global-set "s-[" #'portal-terminal-previous)
(keymap-global-set "s-w" #'portal-terminal-choose)
```

These are Emacs operations: terminal buffers stand in for tmux windows and Emacs
windows stand in for panes. Splits, buffers and switching stay Emacs's job, and
a terminal has no tab or split keys of its own. For tmux itself, run it inside
a terminal: it gets its `C-b`. There are no saved per-terminal pane layouts or
tmux copy mode. Each terminal buffer has one Portal view,
which appears in the selected pane showing the buffer; other panes showing the
same buffer display only its text ([ADR 0001](adr/0001-one-portal-view-per-buffer.md)).
Terminals belong to no frame: show a terminal buffer in another frame and its
view moves there, with the same shell and scrollback. Selection, numbering and
cycling cover every terminal. Different terminal buffers can display and run
simultaneously.

### Names, projects and directories

Portal names a terminal buffer once, when it starts: `*terminal: portal*` for a
shell in project `portal`, `*claude: portal*` for `portal-terminal-start`
running `claude`, and Emacs adds `<2>` to repeats. Projects whose roots end the
same way, such as two worktrees both called `portal`, read `research/portal`;
outside a project, the abbreviated start directory stands in. Rename a
terminal with `portal-terminal-rename` or `rename-buffer`: Portal never renames it again,
whatever title its programs set.

A terminal belongs to the project of the directory it started in, which
`portal-project-function` finds. The default uses `project.el`; Projectile
users can set it to `projectile-project-root`. Changing directory in the shell
leaves the project alone. `M-x portal-terminal-set-project` assigns another
project, or none with a prefix argument. Quick terminals always belong to the
project they were opened for.

When the shell reports its directory, the buffer follows it. Its
`default-directory` changes, so `C-x C-f`, Dired and new terminals start there,
and so does `list-buffers-directory`, which Ibuffer and `list-buffers` show.
Ghostty's bundled shell integration reports the directory at every zsh or bash
prompt, and any program can report one with OSC 7. Ghostty accepts reports only
from this host. Portal also ignores one that is not an existing local directory,
such as a path inside a container, and never lets a report reach TRAMP. Until
a report arrives, the buffer keeps the directory the terminal started in.

The mode line shows `:exited` once a terminal's program ends; the buffer and its
last output stay until you kill it.

Other packages can use the same facts. `(portal-terminal-buffers PROJECT QUICK)`
lists terminals in creation order: with PROJECT, a root, only that project's,
wherever their shells are now, and with QUICK, quick terminals too.
`(portal-terminal-metadata BUFFER)` returns a terminal's `:name`, `:project`,
`:directory`, `:title`, `:exited` and `:quick`. Portal caches these as the
native terminal reports changes, including while it is hidden. They are only
facts: a title is whatever a program set, not a process name, and a live shell
may be busy or idle.

### Choosing terminals

`M-x portal-terminal-choose` lists every terminal.
`M-x portal-terminal-choose-project` lists the current project's: run from a
terminal, the project it belongs to, and otherwise the project of the file or
Dired buffer you are editing, however far its shells have moved. `M-a` switches
between the two lists and keeps what you typed. Each candidate shows the
terminal's name, project, directory and title, and completion matches any of
them, out of the box: its category, `portal-terminal`, tries the `basic` and
`substring` styles before your own, as Emacs does for buffers, and
`completion-category-overrides` can change that. With Orderless,
`portal api npm` finds a terminal titled `npm run dev` in project `portal`'s
`api/` directory. Exited and quick terminals are annotated.

The terminals you selected most recently come first, and `RET` on empty input
takes the first; the current terminal comes last. The order is fixed when the
list opens, and previews never count as selecting. Cycling with
`portal-terminal-next`, `-previous` and `-select-index` keeps creation order.

The New group starts a terminal at the project's root, or outside a project in
the current directory; "New named terminal…" asks for a name first, and
`server` gives `*server: portal*`. Completion requires a listed entry, so typing
alone never starts a shell. Quick terminals are left out unless
`portal-terminal-choose-quick` is set, and a chosen one opens in its panel. From
a quick panel, the choice opens in the editing window behind the panel, which
stays; cancelling returns to the panel.

Killing a terminal buffer whose program is still running asks first, however it
is killed: `C-x k`, Ibuffer, Embark or `portal-terminal-kill-pane`. Ghostty's program is not an
Emacs process, so Emacs's own question for a running process never comes up.
Set `portal-terminal-confirm-kill` to nil to kill without asking. A terminal
whose program exited goes without asking, and quick reset and forget keep their
own question. `M-x portal-terminal-select` selects a terminal by name, where
terminals of its kind show.

### Consult and Embark

Loading `portal.el` automatically enables `portal-terminal-consult-mode` when
Consult is loaded, in either load order. No extra configuration is needed:
`consult-buffer` then accepts `t SPC` to show only Portal terminals, and the
terminal pickers use Consult with your existing completion UI. Portal does
not load Consult itself or require it to be installed. Vertico, Orderless and
Marginalia work through ordinary completion.

To opt out, set `portal-terminal-consult-auto-enable` to nil before loading
Portal and Consult. You can also disable the active integration with
`M-x portal-terminal-consult-mode`.

The optional Embark adapter and a project picker binding can be enabled in
your configuration:

```elisp
(with-eval-after-load 'embark
  (require 'portal-terminal-embark)
  (portal-terminal-embark-mode))
(keymap-set project-prefix-map "t" #'portal-terminal-choose-project) ; C-x p t
```

With `portal-terminal-consult-mode`, the pickers read with Consult, which adds
preview and narrowing: `t` narrows to terminals and `n` to the New group.
`consult-buffer` and `consult-project-buffer` gain a Terminal group, hidden
until you narrow with `t` (type `t SPC`, or your `consult-narrow-key` then
`t`). There it holds every terminal, or the terminals assigned to Consult's
project, and the default list still shows each terminal once, as a buffer.

`M-.` previews the terminal at point in the window you started from, or in the
editing window behind a quick panel. Its live view moves there, even from
another frame, and goes back when you move on or cancel; nothing counts as
selected until you accept. The program sees the preview window's size
meanwhile, which is why preview waits for `M-.` by default. A preview never
takes the keyboard: typing stays in the minibuffer. Quick terminals are not
previewed. To preview as you move, or change the narrowing key:

```elisp
(consult-customize portal-terminal-consult-source portal-terminal-consult-project-source
                   :preview-key '(:debounce 0.3 any) :narrow ?T)
```

`consult-buffer`'s own Buffer group previews terminals as it does any buffer,
following `consult-preview-key`. Marginalia annotates terminal candidates as
buffers, with their mode and directory, in place of Portal's exited and quick
notes.

With `portal-terminal-embark-mode`, terminal candidates stay buffer candidates,
so Embark's buffer actions work, and `E` exports them to Ibuffer. A target that
is a live terminal, in any prompt, Ibuffer or Embark Collect, also has these
actions; any other buffer keeps Embark's buffer map:

| Key | Action |
| --- | --- |
| `RET` | Select it where terminals of its kind show |
| `r` | Rename it |
| `d` | Open Dired in its directory |
| `c` | Start another shell in its directory: a new shell, not a copy |
| `W` | Copy its directory |
| `p` | Assign it to another project, or with `C-u` to none |
| `k` | End it, asking as killing it asks |

Actions reach the session itself, even after a rename in the same prompt.
Candidates mixed with the New group export to Embark Collect, as mixed Consult
lists do; narrow with `t` first for Ibuffer.

Projectile users set both project functions. Consult's current hook is
`consult-project-function`, which takes MAY-PROMPT; the older
`consult-project-root-function` no longer exists.

```elisp
(setq portal-project-function #'projectile-project-root
      consult-project-function (lambda (_may-prompt) (projectile-project-root)))
```

While a terminal has the keyboard, your Command bindings for these commands
reach Emacs, in quick terminals too:

```elisp
(keymap-global-set "s-b" #'consult-buffer)
(keymap-global-set "s-t" #'portal-terminal-choose-project)
```

The chosen terminal gets the keyboard once the minibuffer closes, and cancelling
returns it to the terminal you came from.

The adapters are tested with GNU ELPA Consult 3.10, Embark 1.2, Vertico 2.15
and Orderless 1.8, and with MELPA Consult 20260829.1558 and Embark
20260610.302. They use Consult's source helpers, such as `consult--multi` and
`consult--buffer-preview`, and Embark's `embark--targets`: internal API,
confined to `portal-terminal-consult.el` and `portal-terminal-embark.el`.

`ctest --test-dir build -R terminal-choose` checks the pickers with Emacs's own
completion and the fake native module: recent-use order and creation-order
cycling, projects by assignment, `M-a`, the New group, quick panels, closed
terminals and the question before killing. `-R 'terminal-(consult|embark)'`
checks the adapters against the releases above, which CMake downloads into
`build/elpa` and verifies by hash. A keyboard macro types into a real
minibuffer, so Consult's narrowing, preview and lookup, and Embark's targets,
actions and export to Ibuffer, run as they do for you.

## Appearance and native bindings

Configure in Lisp after loading `portal.el` (changes apply to running terminals):

```elisp
(setq portal-terminal-theme "Dracula") ; nil follows system light/dark appearance
```

`portal-terminal-theme` accepts an exact, case-sensitive name from
`(portal-terminal-themes)`. Set it with `setq` or Customize, including in your
init file before loading Portal. Changes recolor all running terminals, including
hidden ones, and apply to new terminals without restarting existing shells.
Set it to `nil` to restore Alabaster in light mode and Afterglow in dark mode.
Named themes stay fixed across system appearance changes.

A Command chord from a terminal runs in its buffer, with its keymaps. Commands
finish their minibuffer interaction before focus returns to the selected
terminal. Switching to an ordinary buffer keeps Emacs in control. A custom
command can call `portal-terminal-unfocus` to stay in Emacs even when a terminal
is selected. Errors also leave focus in Emacs.

`portal-terminal-native-map` adds opt-in standalone or nested shortcuts to all
terminals, claiming chords their programs would otherwise get, such as Control
chords; `portal-terminal-quick-native-map` overlays it for quick terminals.
Use `portal-terminal-bind-key` / `portal-terminal-unbind-key` for live changes,
or call `portal-terminal-refresh-bindings` after direct keymap edits. These maps
start empty and do not install global shortcuts. First chords are one modified
ASCII key in `kbd` notation, where Meta means Option and Super means Command;
the rest of a sequence uses normal Emacs keys.

The module's C core catches Command chords and registered first chords, and notifies Emacs through the
notification pipe that every Portal view shares
([details](terminal-input-bridge.md#the-notification-pipe)). It holds fast follow-up keys until Lisp is ready, and Lisp reads the keymap and runs the
command. Ordinary terminal input and output stay native; there is no polling timer
or terminal redraw through Lisp.

The terminal uses the pinned [GhosttyTerminal Swift wrapper](https://github.com/Lakr233/libghostty-spm/tree/1.6.20260909)
and its Ghostty build. Themes come from the wrapper's bundled catalog; standalone
Ghostty preferences are not loaded. Ghostty's
app-level window/tab commands are not implemented here, and its own Command-key
bindings never apply: the core gives Command chords to Portal's shortcuts or Emacs. The Emacs buffer contains
instructions, not live terminal text, so ordinary Emacs search and movement do not
operate on the terminal. The native view still shares Emacs's main thread for
input and presentation; this is not a guarantee of latency parity during Emacs GC
or long-running Lisp.

`(portal--inspect (portal-view-target))` reports the selected terminal's actual
native surface, grid, bounds, focus and title. `(portal--terminal-text TARGET)`
selects all native scrollback and returns its text for inspection; it leaves
that selection active. Neither is polled during normal use. Restart Emacs after
rebuilding a module it has already loaded.
