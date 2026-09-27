---
id: portable-terminal-adapter
status: done
depends_on:
  - portable-view-lifecycle
---

# Reduce terminal views to platform primitives

## Context and problem

Portal is improving its macOS architecture to make a future Linux port natural.
This task does not implement Linux, prototype another renderer, add Linux CI or
target Windows. Follow ADR 0003 (`docs/adr/0003-platform-interface-primitives.md`).

Portal depends on the pinned Apple-platform `GhosttyTerminal` and
`GhosttyTheme` Swift libraries. `native/Terminal.swift` mixes those types with
Portal's options, text-size behavior and inspection. Ghostty running on Linux
does not make this wrapper portable: its Linux application uses GTK4, while
GTK/PGTK Emacs currently uses GTK3. Full Linux embedding is a future choice, not
a promise that replacing the Swift view is trivial.

## Outcome and scope

The core implements the terminal Lisp functions and asks the platform only for
what a terminal engine must do. The existing Swift wrapper stays the production
macOS terminal, with its rendering and process integration.

- Move Portal's terminal rules into the core. That includes option validation it
  can check, checking a theme name against the platform's list before touching
  any session, and applying a theme to every open terminal. Preserve today's
  behavior, including partial failure when one terminal rejects a theme.
- Keep `TerminalView`, `TerminalSession`, the controller and theme catalog
  types, Metal and display integration, the native clipboard and input, and
  Ghostty configuration inside Swift. Do not reimplement the wrapper or call
  Ghostty's internal C embedding interface just to reduce Swift.
- Preserve the shell working directory, `INSIDE_EMACS`, wait-after-command,
  Emacs ownership of window and tab commands, theme defaults and live changes,
  and the bundled terminfo and shell-integration resources.
- Preserve bracketed paste and Enter as a separate key press. Text extraction
  selects all and leaves the selection active; changing that is a separate
  feature.
- Preserve hidden-session progress and grid size, frame movement, and cleanup.
  Process exit must not silently restart a shell or close its buffer.
- Keep native keyboard text-size shortcuts. Their step and limit rules can stay
  where they are until the toolbar task.

Persistent sessions across Emacs restarts, replacing Ghostty, performance
settings, and packaging for Windows or Linux are outside scope.

## Platform interface

- **Removes** the Lisp-shaped `portal_terminal_paste`, `portal_terminal_text`,
  `portal_terminal_theme` and `portal_terminal_themes`.
- **Adds, implemented by the platform, each on one terminal handle:**
  - paste text;
  - press Enter;
  - read all text;
  - apply a named theme, or the default;
  - set the font size.
- **Also adds** listing the theme names the engine offers. Terminal creation
  options go through the lifecycle's create primitive.
- A terminal's title, grid, readiness and exit status come from the lifecycle's
  describe primitive. Add a call into the core only if the core must react, for
  example to process exit, and follow the channel task's convention.
- Ghostty binding strings, such as `select_all`, stay inside the macOS
  platform.

## Starting points

Read ADR 0003, `native/Terminal.swift`, `native/Package.swift`,
`native/Package.resolved`, `portal-terminal.el`, `portal-terminal-quick.el`,
the README's terminal and build sections, and the C files from the
prerequisites. Inspect the resolved Ghostty wrapper only as needed, and do not
upgrade it silently. Use `test/portal-terminal-tests.el`,
`test/portal-terminal-quick-tests.el`, `test/portal-integration-tests.el` and
`test/native-terminal-stub.swift`. Upstream background:
[Ghostty architecture](https://ghostty.org/docs/about) and the
[internal embedding interface](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h).

## Decisions to settle during implementation

Decide whether "press Enter" is its own primitive or a key primitive that input
also needs; pick one and don't keep both. Define failed creation, theme
application, and late platform calls. Distinguish destroying a view from its
process exiting. Record which described facts are diagnostic or macOS-specific,
such as the renderer layer name.

## Acceptance criteria and verification

- [x] `portal.h` declares none of the removed operations. Its terminal part is
  the primitives above, and it contains no Ghostty, AppKit or Metal types, or
  engine binding strings.
- [x] C tests with a fake terminal platform exercise the real core. They cover
  wrong-kind and unknown targets, invalid options, unknown and failing themes,
  platform errors, described facts, and calls after destruction, without the
  Ghostty package.
- [x] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  graphical terminal and combined suites check paste versus Enter, text
  extraction, theme and text size, hidden output, frame movement, exit and
  cleanup. Quick terminals still use one shell per project without a toolbar.
- [x] The pinned dependency and bundle resources still work. No Linux renderer
  or new terminal engine has been added.
- [x] Update the README architecture, record verification, and mark this task
  done; follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  handles, the create and describe primitives, and the registry. Input and web
  extraction are not prerequisites.

## Outcome

- `native/Core/terminals.c` implements the terminal Lisp functions. It checks
  a terminal's options before `portal_view_create`: `:directory` must be a
  string, `:command` and `:theme` a string or nil, and `:theme` a name the
  platform lists, with a later duplicate winning. It checks a theme name
  before touching any terminal, even with none open, then applies it to every
  open terminal, oldest first, and stops at the first that rejects it. It
  sorts the platform's theme names by code point, pastes then presses Enter,
  and reads text. `views.c` calls the option check for terminals and gained
  `portal_views_each`; `native/Core/core.h` holds the error helpers that
  `views.c`, `terminals.c` and `input.c` share.
- `portal.h` no longer declares `portal_terminal_paste`, `_text`, `_theme` or
  `_themes`. Its terminal part is six primitives:
  `portal_terminal_list_themes`, `_apply_theme`, `_paste_text`,
  `_press_enter`, `_read_text` and `_set_font_size`. It names no
  Ghostty, AppKit or Metal type, and no binding string.
- Swift: `TerminalSession` implements the primitives on its own session, and
  `Terminals` only lists the catalog and maps a name to a `TerminalTheme`.
  `select_all` and `set_font_size` stay in Swift. The toolbar's and keyboard's
  text-size steps and limits stay in Swift too, and now set the size through
  the same `setFontSize` as the primitive, instead of Ghostty's increase,
  decrease and reset actions. The Ghostty package pin is unchanged.
- Decisions:
  - **Enter** is its own primitive. Input replays real native events, so no
    other caller needs a synthetic key primitive.
  - **Failed creation.** Invalid options fail before the platform is asked
    and spend no ID; a platform that cannot list its themes creates nothing.
  - **Themes.** An unknown name changes nothing. A terminal that rejects a
    theme returns its own error: terminals before it keep the new theme, it and
    those after keep their old one, as before. The default theme needs no
    lookup, and on macOS follows the system appearance.
  - **Paste.** A failed paste presses no Enter. If Enter fails after a
    successful paste, the text stays pasted and the error reaches Lisp.
  - **Late calls.** The core never passes a closed terminal to the platform:
    stale targets fail with "No Portal view TARGET", and themes reach only open
    terminals.
  - **Exit versus destroy.** A process that exits leaves its view and buffer
    open with its last output; nothing restarts it. The description's
    `closed` fact is now `exited`, so it cannot be confused with closing the
    view, which destroys it and ends the process. The core need not react to
    an exit, so the platform calls nothing new.
  - **Described facts.** Every platform reports `ready`, `title`, `columns`,
    `rows` and `exited`. `layer`, the macOS renderer's layer class, is a
    diagnostic for tests, and `focused` belongs to input.
- Tests: `test/portal-terminals-tests.c` drives the terminal rules with the
  fake platform. The fake's terminals describe the portable facts, list their
  themes out of order with one needing JSON escaping, fail every terminal
  primitive for the option `:broken`, and let a test end a process. The view
  tests share their helpers through `test/portal-core-tests.h`, and the module
  tests cover the new errors and the sorted catalog.
- The README describes the terminal rules, primitives and decisions, and the
  new test and standalone check commands.

## Verification

Run on macOS 27.0 with Emacs 31.1 and CMake 4.4.3 on 2026-09-28:

- `ctest --test-dir build/core --output-on-failure` passed `channel`, `views`,
  `terminals` and `module`. Each of these changes to `terminals.c` makes the
  terminal or module tests fail: applying a theme without checking its name,
  carrying on past a terminal that rejects it, pressing Enter after a failed
  paste or never pressing it, not sorting or not escaping the catalog, letting
  the first duplicate option win, skipping the `:theme` option check,
  matching a theme name by prefix, and reading text from a view of any kind.
  The fake counted no call naming a destroyed or wrong-kind view.
- `./build.sh` built without warnings, with the pinned Ghostty package and its
  bundled resources unchanged. `nm` shows the six `portal_terminal_*`
  primitives in `portal.dylib`, none of the removed operations, and no
  undefined `portal_*` symbols. `ctest --test-dir build --output-on-failure`
  passed 16 of 16, including `quick-terminal`, and 17 of 17 after rebasing
  onto the input task, whose `input-core` test now opens terminals with a
  `:directory`.
- `build/check-focus` and `build/check-toolbar`, now linking `terminals.c`,
  passed.
- The combined graphical suite, run through the production module with
  `--module-assertions`, passed every test that needs no injected key or
  click. These include the live and new-session themes, with unknown and
  non-string names refused; paste with and without Enter, text extraction,
  hidden-shell output and grid resizing, and close ending the shell; the
  alternate screen and buffer cleanup; invalid targets; frame deletion; and
  the toolbar's terminal grid and text size, which now sets the font size.
- The 27 tests that inject native keys or clicks first failed because Emacs
  could not take the keyboard during the run (`portal-test-native-key`
  returned nil), with other sessions' graphical suites running around the
  same time. Unmodified `main` failed the same 15 terminal and integration
  tests in that session. After merging, the combined graphical suite passed
  52 of 52 on merged `main` at 526ae93, with Emacs able to take the keyboard
  and no other suite running. That run includes moving a terminal to another
  frame, native keys and the clipboard, Vim, prefixes, quick-terminal
  toggling, and focus and cleanup in either startup order. `./build.sh`,
  `ctest` (17 of 17), `check-focus` and `check-toolbar` passed on the same
  commit.
