---
id: portable-terminal-adapter
status: todo
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

- [ ] `portal.h` declares none of the removed operations. Its terminal part is
  the primitives above, and it contains no Ghostty, AppKit or Metal types, or
  engine binding strings.
- [ ] C tests with a fake terminal platform exercise the real core. They cover
  wrong-kind and unknown targets, invalid options, unknown and failing themes,
  platform errors, described facts, and calls after destruction, without the
  Ghostty package.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass. The
  graphical terminal and combined suites check paste versus Enter, text
  extraction, theme and text size, hidden output, frame movement, exit and
  cleanup. Quick terminals still use one shell per project without a toolbar.
- [ ] The pinned dependency and bundle resources still work. No Linux renderer
  or new terminal engine has been added.
- [ ] Update the README architecture, record verification, and mark this task
  done; follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  handles, the create and describe primitives, and the registry. Input and web
  extraction are not prerequisites.
