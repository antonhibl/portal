---
id: testing-strategy
status: todo
---

# Make test selection explicit, headless by default, and coverage-preserving

## Problem and outcome

Native tests repeatedly take desktop focus, and a single implementation task can
run overlapping suites several times. Preserve the project's behavioral coverage
while making ordinary development quiet, focused verification predictable, and
full regression reproducible through one command.

This is one coordinated implementation task: classification, runners, coverage
migration, and agent guidance must agree. Implement it in stages below rather
than splitting policy from the commands that enforce it. This document is a
plan, not permission to start implementation or run disruptive checks.

## Current-main findings

Revalidated against `main` at `879cbfb` after the documentation refactor:

- `docs/testing.md` already exists. It covers testing principles, safety and
  native procedures, but has no unified runner or situation-to-suite policy.
- `CONTRIBUTING.md` owns routine contributor commands and links to that guide.
  `README.md` and `docs/README.md` also link to it. `AGENTS.md` requires reading
  Contributing but does not directly require reading the testing guide.
- `CONTEXT.md` is domain vocabulary, not workflow guidance. Do not put the
  testing strategy there or rely on an optional domain-document link to load it.
- CTest already runs headless C, batch Emacs, Bun and compiled-host integration
  suites. The earlier audit found 33 registered suites and 92 tests in the then
  combined GUI invocation; derive the current inventory, not hard-coded totals.
  Include tests outside CTest, such as `test/list-todo-tasks.test.ts`, Python
  tests, standalone native checks, shell fixtures and optional smoke tests.
- GUI fixtures raise windows and deliberately activate applications. Launcher
  tests include 100 hide/show cycles, lifecycle matrices and focus-settling
  waits. Fake-backend tests cannot replace native focus or rendering evidence.
- Recent task reports record six successful runs of a 25-test GUI selection,
  plus a separate run of daily-use tests already in that selection. Another
  task repeated GUI tests to diagnose and verify a focus flake. Some reruns
  were justified, but there is no explicit repetition/evidence-reuse policy.
- GUI suites import other suites for helpers, so a broad ERT selector can run
  unrelated registered tests. C core tests can also be run twice by executing
  both the standalone core build and the top-level CTest suite.
- Two Evil input cases were skipped in the audited batch run despite CMake
  downloading Evil for other suites. Account for skips, not just suite exits.

## Scope and non-goals

Deliver the test commands, selection policy, focused headless coverage additions,
coverage-preserving GUI reductions, runner regression tests and documentation.
No product-behavior changes, user-config edits, external harness changes,
automatic cloud provisioning, or general-purpose distributed test service.
Do not remove useful native coverage to meet an arbitrary runtime/test-count
budget. Benchmarks remain measurements, not pass/fail tests unless they already
have an explicit invariant; include tests of benchmark tooling in the inventory.

## Command contract

Add a repository-root `./test.sh` entry point. It may delegate to small scripts,
CMake/CTest, ERT and the existing language runners; do not build a second test
framework. Resolve paths from the repository root, honor configured tools and
build directories, and document clean-checkout setup. Build prerequisites once
per invocation, incrementally, without unnecessary native builds for pure tests.

Each category has a dedicated command:

| Category | Command | Boundary and use |
| --- | --- | --- |
| Unit / batch | `./test.sh unit` | Pure logic, real C core with fake platform, batch Lisp behavior and fast isolated language tests. No windows, credentials or foreground changes. |
| Headless integration | `./test.sh integration` | Real compiled host, HTTP/process/PTY interactions, package integration and headless browser behavior. No visible browser or native windows. |
| Native GUI E2E | `./test.sh gui --allow-gui` | Real Emacs/AppKit/WebKit/Ghostty integration, focus and redisplay, plus relevant standalone native checks. Fresh disposable processes. |
| Stress / stability | `./test.sh stress --allow-gui` | Explicitly bounded lifecycle churn and stability cases. Tag headless versus desktop-requiring members; a headless selection must not require GUI permission. |
| External integration | `./test.sh external --allow-external --allow-gui` | Existing live-agent and optional third-party recipe checks, with their pinned/configured prerequisites and explicit resource-use permission. |
| Manual acceptance | `./test.sh manual --interactive --allow-gui` | Guide and record human-only checks: physical keys, Spaces/fullscreen, display changes, IME and VoiceOver where applicable. Never fabricate automated passes. |

Aggregate commands:

- `./test.sh` defaults to `./test.sh headless`: unit plus headless integration.
- `./test.sh regression --allow-gui` runs the entire self-contained automated
  regression: unit, integration, native GUI and bounded stress cases, including
  cross-feature coexistence. External credentials and human acceptance are
  explicitly outside this named scope and listed in its report.
- `./test.sh all --allow-gui --allow-external --interactive` is exhaustive:
  regression plus every registered external and manual check. Preflight all
  required tools, optional packages, trusted projects and credentials without
  printing secrets or changing user settings. Missing prerequisites or absent
  human evidence mean **incomplete**, not "all tests passed". The command must
  not silently downgrade to the self-contained regression.

`all` is the literal all-tests entry point; `regression` is the unattended full
self-contained regression. This distinction is necessary because real provider
requests and physical IME/key/display acceptance cannot be made credential-free
or unattended by renaming them E2E tests.

Support `--suite NAME` for explicit feature selection and `--list` for a read-only
execution plan on category/aggregate commands. Print exact suites/tests, category,
desktop/external effects, expected skips and required setup before execution.
Unknown categories/suites and empty selections fail. Use exact identifiers, not
unanchored substring matching. Allow additional repetition only through an
explicit bounded stress option such as `--repeat N`; never retry until green.

## Situation-to-test policy

Put the authoritative policy in `docs/testing.md`, with this minimum matrix:

| Situation | During development | Required final verification |
| --- | --- | --- |
| Task prose / ordinary documentation only | Metadata, discovery, links and diff checks | No native build or GUI suite. Executable examples are not prose-only. |
| Lisp/C/TypeScript logic change | Affected unit and headless integration suites | Full headless aggregate once for the final candidate; affected native tests if the observable native contract changes. |
| Executable launcher examples | Launcher batch suite in both binding modes | Full headless checks; relevant GUI/recipe checks if native interaction or third-party integration behavior changed. |
| Browser script or CSS change | Headless browser integration plus relevant host tests | Full headless checks and affected embedded-WebKit/native handoff cases; retain real rendering assertions. |
| Native view, launcher, terminal, toolbar or input change | Narrowest batch/native regression that demonstrates the change | Full headless plus affected GUI and standalone native suites; broaden to coexistence for shared lifecycle/input/bridge changes. |
| Shared test fixtures, runner/build selection or broad platform change | Runner tests and focused suites | Full self-contained regression, scheduled with desktop permission. |
| Suspected flake / lifecycle leak | Isolated reproducible case first | Explicit bounded stress run after a fix; retain every attempt's result. |
| Release / broad integration validation | Prepare prerequisites and schedule desktop time | Full self-contained regression; exhaustive `all` for acceptance requiring external/manual evidence. Record incomplete acceptance honestly. |

Selection must consider callers, shared fixtures, native boundaries, browser
assets, dependencies and executable docs, not just the filename changed. When
impact is uncertain, broaden the affected suites and explain why. Do not add a
fragile automatic diff-to-test mapper as a substitute for this policy.

GUI permission is specific to a planned run/window of desktop use. Agents must
ask before launching disruptive checks on the user's active desktop, state their
scope, and defer them rather than weaken the acceptance criteria. A user-approved
dedicated graphical runner is the preferred long-term home for routine native
regression; provisioning one is outside this task. A worktree or terminal
session alone does not isolate macOS focus.

## Implementation plan

### 1. Inventory and classify without losing coverage

- Enumerate all current executable tests and manual procedures; record their
  boundary, feature, prerequisites and existing entry point. Keep the executable
  registry as the source of truth, not a growing prose list of every test.
- Give each automated test one primary category and one or more feature labels.
  Use CTest labels and explicit ERT selectors where applicable. Initially classify
  mixed suites conservatively as integration rather than mislabeling them unit.
- Extract shared GUI fixtures into helper-only files. Loading a helper must not
  register unrelated tests. Preserve cross-feature tests as explicit members.
- Prevent overlap inside aggregates: ordinary tests execute once, including core
  tests, daily-use checks and Python/Bun tests currently outside CTest. Deliberate
  stress iterations are separately identified, not accidental duplicate runs.
- Make required dependencies available to their suites, including the audited
  Evil input tests. Unexpected skips fail the required run; declared optional
  skips are visible and cannot satisfy exhaustive acceptance.

### 2. Implement safe runners and repeatable evidence

- Implement the commands above and incremental build targets for the injector
  and standalone native binaries instead of recompiling copied recipes each run.
- Native runs are serial and mutually exclusive across repository worktrees;
  conflicting desktop runs fail clearly. Headless tests may run in parallel
  after checking fixture/port/temp-file isolation.
- Use explicit test selectors, bounded process timeouts, exit-status propagation,
  signal-safe cleanup and disposable Emacs instances with the supported build.
  Do not touch the user's running Emacs, configuration, clipboard permanently,
  terminal sessions or unrelated processes. Restore fixture-owned global state.
- Store per-run results in ignored build output: source/input identity (including
  relevant uncommitted changes), tools/dependency versions, command/selection,
  start/end times, passes/failures/skips, per-suite durations and logs. Record
  build time separately. Check source identity again at completion so concurrent
  edits do not attach results to the wrong tree.
- Reuse successful evidence within a task only when relevant source, tests,
  generated artifacts, dependencies, selection and environment are unchanged.
  No automatic persistent cache is required: comparing recorded inputs and
  citing a valid run is enough. A commit or review transition alone is not a
  reason to rerun. Code or test changes invalidate affected evidence.
- Each rerun states its reason. Do not rerun both an aggregate and a fully covered
  subset for the same unchanged inputs unless investigating a documented issue.
  Do not turn a failed run green by hiding earlier attempts.

### 3. Move suitable permutations to headless tests

- Add a pinned, genuinely headless browser test setup for `host/tasks-client.ts`.
  Exercise the real page script with controlled HTTP/bridge inputs: in-place
  refresh ordering/coalescing, hidden-page refresh, retained folds/history/scroll,
  DOM focus, status/edit actions, error recovery and stale/replaced content.
  Use a real headless browser for layout/focus behavior, not a DOM mock pretending
  to prove rendering. Keep representative embedded WKWebView and Emacs handoff
  checks; browser WebKit is not identical to the native integration.
- Expand batch completion/policy tests using the existing real-minibuffer pattern
  in `test/portal-completion-testing.el`, with native calls faked only at their
  boundary. Move eligible input/result/configuration matrices here while retaining
  native key delivery, panel layout, focus return and command-loop integration.
- Separate pure launcher rectangle/clamping cases from window-creating fixtures
  where feasible. Preserve real placement, attachment, display notification and
  responder-chain checks. Do not distort production architecture merely to move
  a small assertion out of a GUI fixture.
- Move high-cycle lifecycle cases into stress while keeping representative
  lifecycle transitions in routine GUI regression. Exhaustive aggregates still
  execute the existing bounded stress coverage.
- Before removing a GUI assertion/permutation, map the behavior to its replacement
  and retained integration coverage. Demonstrate replacement sensitivity using a
  failing-before test or targeted mutation. Do not delete unique native evidence.
- Measure before/after with the same environment and selection, during approved
  desktop time. Preserve focus-settling waits until a demonstrated synchronization
  improvement replaces them; avoid blanket sleep shortening or repeated full-suite
  baselines. Report GUI launches/activations and repeated work as well as runtime.

### 4. Make the strategy discoverable and mandatory for agents

- Update the existing `docs/testing.md` rather than creating a competing guide.
  Keep testing principles, evidence limits, category meanings, selection matrix,
  permission rules, skip/repetition policy and runner troubleshooting there.
- Update `CONTRIBUTING.md` with the canonical copyable commands and final-check
  policy, linking detailed procedures to the guide. Formatting, type checking,
  changed-Lisp compilation and `git diff --check` remain required where applicable;
  test aggregation does not silently replace these non-test checks.
- Add a direct instruction in `AGENTS.md` to read `docs/testing.md` before selecting
  or running checks, including its desktop-permission rule. Keep this short and
  avoid duplicating the matrix. `CLAUDE.md` already points to `AGENTS.md`; preserve
  that routing. This makes the strategy part of mandatory repository instructions,
  not merely a discoverable link, without claiming any model is mechanically
  guaranteed to obey it.
- Keep `CONTEXT.md` focused on vocabulary. Refresh the testing description in
  `docs/README.md` and relevant current testing links/recipes. Preserve launcher
  example markers in `docs/launcher.md`; do not rewrite historical evidence as
  new verification or recreate the old large README testing section.

## Acceptance

- [ ] Every existing test/procedure is classified, including tests outside CTest;
  no behavior disappears without an evidenced replacement or explicit retained
  native/manual check.
- [ ] Each category has its dedicated command; default/headless commands open no
  windows and make no credentialed requests. A clean checkout has documented,
  reproducible setup and incremental prerequisites.
- [ ] `--list` is non-disruptive; feature selection is exact; invalid/empty
  selections fail. Helper imports cannot broaden the selected suite.
- [ ] Full regression covers all self-contained automated categories once, with
  explicit bounded stress iterations and retained cross-feature coexistence.
  Exhaustive `all` also covers external/manual checks, reporting incomplete and
  exiting nonzero if required prerequisites/evidence are missing.
- [ ] GUI/external/manual execution requires the appropriate explicit gates;
  overlapping GUI runs across worktrees cannot compete for desktop focus.
- [ ] Runner tests cover planning, deduplication, gates, missing dependencies,
  timeouts, failures, skips, cleanup, concurrency and aggregate exit status using
  harmless fake subprocesses. Testing runner safety does not itself steal focus.
- [ ] Required Evil input cases run rather than skip. Reports distinguish passed,
  failed, declared skipped, pending/manual and not selected results.
- [ ] Headless task-client coverage exists; eligible completion/geometry matrices
  and stress separation reduce routine GUI work with a before/after behavioral
  mapping and regression-sensitivity evidence. Native focus/rendering coverage
  remains intact; no arbitrary speed target weakens tests.
- [ ] Per-run evidence identifies tested inputs/environment, records durations and
  all attempts, and supports safe reuse instead of redundant unchanged reruns.
- [ ] `docs/testing.md`, `CONTRIBUTING.md` and `AGENTS.md` agree on selection,
  commands, required gates, repetition and evidence. Existing documentation
  entry points still work; `CONTEXT.md` stays domain-focused.
- [ ] Final implementation verification includes runner/headless tests and one
  approved full self-contained regression on the final candidate. Any subsequent
  change invalidates affected evidence; external/manual outcomes are explicitly
  recorded rather than inferred from the regression result.

## Verification and completion record

Planning only. Keep `status: todo` and acceptance unchecked until implementation
and verification finish. Record chosen browser tooling, final category mapping,
behavior migrations, command results, relevant timings, and external/manual
limitations here when completing the task.

Task-authoring verification: the existing `host/tasks.ts` parser accepts the
front matter, the all-task listing reports no Problems, the task detail renders,
`bun list-todo-tasks.ts` lists this task, and `git diff --check` passes. No product
code, test runner or testing policy was changed, and no GUI tests were launched.
