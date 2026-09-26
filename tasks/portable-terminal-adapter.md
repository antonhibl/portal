---
status: todo
---

# Confine Ghostty integration to the macOS terminal adapter

## Context and problem

Portal is improving its macOS architecture to make a future Linux port natural.
This task does not implement Linux, prototype another renderer, add Linux CI,
or target Windows. The prerequisites provide C bindings and shared lifecycle.

Portal depends on the pinned Apple-platform `GhosttyTerminal` and `GhosttyTheme`
Swift libraries. `native/Terminal.swift` mixes those types with Portal options,
text-size behavior, target lookup, and session inspection. Ghostty running on
Linux does not make this wrapper portable: its Linux application uses GTK4,
while GTK/PGTK Emacs currently uses GTK3. Treat full Linux embedding as a future
implementation choice, not a promise that replacing the Swift view is trivial.

## Outcome and scope

The C core and Emacs bindings express Portal terminal operations without knowing
Ghostty or AppKit types. The existing Swift wrapper remains the production
macOS implementation, retaining its rendering and process integration.

- Define typed terminal operations for existing behavior: create options,
  paste with optional Enter, text extraction, theme enumeration/application,
  and text-size changes. Common place/hide/focus/close operations use the
  existing view/host seam; do not create a competing terminal lifecycle.
- Report title, grid size, readiness, process exit, and errors as plain data or
  typed events. Keep any existing macOS-only inspection field, such as the
  renderer layer name, as adapter diagnostic data rather than a required
  portable concept. Preserve the external inspect shape on macOS.
- Keep `TerminalView`, `TerminalSurface`, controller/theme catalog types,
  Metal/display integration, native clipboard/input, and Ghostty configuration
  calls inside Swift. Do not reimplement the wrapper or call the internal
  Ghostty C embedding interface directly merely to reduce Swift line count.
- Let C perform shared option/target validation where it owns that information;
  translate typed operations to Ghostty binding strings only in the adapter.
  Retain current native keyboard/text-size shortcuts. Their shared value/limit
  model can remain with the existing toolbar until the toolbar extraction.
- Preserve shell working directory, `INSIDE_EMACS`, wait-after-command behavior,
  Emacs ownership of window/tab commands, theme defaults/live changes, and
  package resources for terminfo/shell integration.
- Preserve bracketed paste semantics and explicit Enter as a key operation.
  Text extraction currently selects all and leaves the selection active;
  changing that behavior is a separate feature.
- Preserve hidden-session progress and grid size, frame movement, and cleanup.
  Process exit must not silently restart a shell or close its buffer. Keep
  parking-window mechanics in the macOS adapter and shared identity in C.

Persistent sessions across Emacs restarts, replacing Ghostty, changing terminal
performance settings, and Windows/Linux dependency packaging are outside scope.

## Starting points

Read `native/Terminal.swift`, `native/Package.swift`, `native/Package.resolved`,
`portal-terminal.el`, `portal-terminal-quick.el`, and the README's terminal
behavior/build sections. Inspect the resolved Ghostty wrapper only as needed;
do not silently upgrade it. Use `test/portal-terminal-tests.el`,
`test/portal-terminal-quick-tests.el`, `test/portal-integration-tests.el`, and
`test/native-terminal-stub.swift`. Follow the prerequisites' C binding, registry,
and host declarations. Upstream background: [Ghostty architecture](https://ghostty.org/docs/about)
and [internal embedding interface](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h).

## Decisions to settle during implementation

Choose the smallest typed option/state representation and define failed creation,
theme application, and late callback behavior. Distinguish view destruction from
process exit. Preserve observable behavior, including any non-atomic multi-view
theme failure semantics, rather than promising new guarantees without evidence.
Record which fields are diagnostic or macOS-specific.

## Acceptance criteria and verification

- [ ] Shared C declarations and Emacs bindings contain no Ghostty/AppKit/Metal
  types or engine binding strings. One adapter owns each terminal resource.
- [ ] Fake-terminal tests exercise the real C operations, wrong-kind/unknown
  targets, invalid options, backend errors, title/grid/exit events, and callbacks
  after destruction without depending on the Ghostty package.
- [ ] `./build.sh` and `ctest --test-dir build --output-on-failure` pass.
  Graphical terminal/combined suites verify real paste versus Enter, text
  extraction, theme/text size, hidden output, frame movement, exit, and cleanup.
  Confirm quick terminals still use the same per-project shell without a toolbar.
- [ ] The existing pinned dependency and bundle resources remain usable; no
  Linux renderer or new terminal engine has been added.
- [ ] Update README architecture, record verification, and mark this task done;
  follow `AGENTS.md` for the implementation worktree and PR.

## Blocked by

- [Own native view lifetime in the C core](portable-view-lifecycle.md) supplies
  typed ownership and lifecycle operations. Input and web extraction are not
  prerequisites; use their existing interfaces until those tasks merge.
