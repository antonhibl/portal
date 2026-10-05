---
id: launcher-user-configuration
status: done
depends_on:
  - launcher-persistent-buffer
---

# Compose application launchers entirely in user configuration

Reconciled from the completed historical task in `project.org`.
Org `CUSTOM_ID`: `launcher-user-configuration`.
Org `ID`: `51adf5cf-063f-4ae1-8c07-9b646becc88b`.
This Markdown document is the task's source of truth.

## Problem and outcome

Portal currently defaults to `portal-launcher-applications`, contains
application-specific input policies and downloads `launcher.el` for its tests.
Finish the separation: Portal exposes reusable presentation and shortcut
functions, while user configuration chooses and connects application commands.

## Blocked by

- Independent named shortcuts supplies optional system-wide invocation.
  Completed in PR #76; historical record: `project.org`,
  `CUSTOM_ID: global-shortcut-registrations`.
- Presentation options supplies compact pickers and buffer presentation.
  Completed in PR #77; historical record: `project.org`,
  `CUSTOM_ID: launcher-presentation-options`.
- [Persistent buffer interaction](launcher-persistent-buffer.md) supplies the
  custom UI example and lifecycle; it is complete.

## Plan and decisions

- Remove `portal-launcher-applications`, the default application command and
  application-package loading from Portal. Presenting a panel must not
  implicitly register any chord; loading either infrastructure module is inert.
- Replace the old mode/shortcut/command setup with documented explicit calls.
  Before removal, inventory existing public entry points and record which are
  retained, deprecated or removed, with migration examples. Any compatibility
  support must not retain an implicit application action or shortcut binding.
- Move the application's responsibility for accepting highlighted selections,
  empty results, bang queries and stock Space input out of Portal. Inspect the
  current `launcher.el` behavior; record required upstream fixes or provide an
  explicit user-config wrapper recipe when still needed. Do not silently drop
  the existing selection behavior or edit the user's configuration in this task.
- Remove the pinned application package download and application-specific test
  target from `CMakeLists.txt`. Replace presentation coverage with generic prompt
  and buffer fixtures, preserving tests of completion, focus and dismissal.
  Optional completion-library fixtures may remain for infrastructure coverage.
- Update `README.md` and `docs/launcher-native-panel.md` with a minimal picker,
  persistent hello-world buffer, separate shortcut setup/removal and an optional
  `launcher.el` recipe. Clearly separate historical integration evidence in
  `docs/launcher-applications.md` from the new setup.
- Exercise two user-defined launchers plus a shortcut that does not present a
  panel. Scope this work to launcher infrastructure; leave unrelated Portal
  features and external repositories unchanged.

## Acceptance

- [x] With `launcher.el` absent, Portal loads and all infrastructure examples
  and automated checks run; loading/presenting claims no global key by default.
- [x] The same user command works via M-x, an ordinary Emacs binding and a
  named global shortcut, with presentation options supplied in user config.
- [x] The documented application recipe shows only its minibuffer, accepts
  Return and arrow selection without typed text, and preserves documented
  refresh, cancellation, search and focus behavior. Any required external
  version or wrapper is stated explicitly.
- [x] Named shortcuts remain independent across panel dismissal, deletion and
  configuration reload; the persistent hello-world recipe stays usable.
- [x] No application discovery/search policy or mandatory `launcher.el` build
  dependency remains in Portal; relevant project, native and graphical checks
  pass using generic fixtures. Record the separate optional integration smoke
  test and its exact environment rather than claiming it as a core dependency.
- [x] Migration examples identify replacements for the old defaults, mode and
  shortcut settings, and provide explicit cleanup/rollback instructions.

## Outcome

Implemented in [PR #81](https://github.com/xiaoxinghu/portal/pull/81), commits
`9855cd0` and `ef2c3af`. Portal no longer has `portal-launcher-applications`,
`portal-launcher-command`, `portal-launcher-shortcut` or
`portal-launcher-toggle`. `portal-launcher-present` requires a function and is
no longer an interactive command. `portal-launcher-mode` manages panel state,
not shortcuts; presenting and loading claim no chord.

`CMakeLists.txt` no longer downloads `launcher.el` or runs an application-specific
suite. Generic fixtures exercise infrastructure. `README.md` contains the
picker, persistent hello buffer, independent shortcuts, optional application
recipe, migration table and cleanup/rollback instructions. The recipe's reader
wrapper works in both dynamically and lexically bound configuration files.
No native code or external repository changed.

## Completion evidence

The matching DONE task in `project.org` has all six acceptance items checked
and records these historical results (not new runs for this reconciliation):

- `./build.sh` and all 33 CTest suites passed without `launcher.el` on the test
  load path; the launcher suite had 30 tests.
- All 25 launcher, daily-use and global-shortcut GUI tests passed in six runs,
  the last two after the dynamic-binding review fix.
- `sh test/launcher-daily-use.sh`, `check-launcher` and `check-shortcuts` passed;
  changed Lisp byte-compiled without warnings.
- The separate optional recipe smoke test passed 2/2 with `launcher.el`
  `731146d`, Emacs 31.1 revision `a360712c`, macOS 27.0.1 (26A434), Vertico
  2.15, Orderless 1.8 and Marginalia 2.13, before and after review. It covered
  selection without typed text, spaced bang queries, cancellation and refresh;
  real Spotlight/Finder checks also passed. This is not a core dependency.
