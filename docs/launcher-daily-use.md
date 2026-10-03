# Launcher setup and daily-use validation

The launcher remains opt-in and the `launcher-daily-use` task remains open.
Automated checks below establish specific behaviors; physical fullscreen/Spaces,
display changes, full IME composition and VoiceOver have not yet been validated
on the production integration. The prototype's earlier human fullscreen pass
does not certify this integration. No wider input or accessibility support is
claimed until these checks have results and any limitations are accepted.

## Tested environment

| Component | Tested configuration |
| --- | --- |
| Emacs | GNU Emacs NS 31.1, revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`, dynamic modules and native trampolines enabled |
| macOS | 27.0.1 (26A434), Apple Silicon |
| Application picker | `launcher.el` revision `731146d95d7d1ff16f48e7a200da873c8d8b375c` |
| Repeatable completion matrix | Stock completion; Vertico 2.15, Orderless 1.8, Marginalia 2.13 |
| Isolated copy of active settings | Vertico 20260830.123 with multiform and directory bindings, Orderless 20260830.1156, Marginalia 20260821.1231; styles `(orderless partial-completion basic)`, 10 candidates, no cycling or posframe |
| Theme and font in that isolated run | Modus Themes 20260829.1926, `modus-vivendi-tinted`, JetBrainsMono Nerd Font 17 |
| Displays in prior geometry checks | Gigabyte M32U and LG ULTRAFINE, both Retina, unequal origins; logical-point geometry passed, physical unplug/reconnect pending |

The active settings were inspected read-only from the normal Emacs session.
Only the relevant completion/theme configuration was copied into a disposable
process. This is not a full-init or normal-session pass. Other Emacs revisions,
ports and macOS versions are unverified; the runtime restricts the Emacs build.
Outbound native drag-and-drop is cancelled. Commands must be synchronous and
use the panel's minibuffer; commands that choose other frames need wrappers.

## Set up a fresh session

1. Follow [Build and run](../README.md#build-and-run), using the Emacs installation
   that will load the module. Rebuild Portal and restart Emacs after a native
   update. Never mix new Lisp with an old module already loaded in the process.
2. Install the pinned `launcher.el` dependency using the
   [README setup](../README.md#native-launcher-panel-opt-in). The test copy in
   `build/elpa` is not an installation in your normal Emacs.
3. Load Portal and explicitly enable `portal-launcher-mode` in a disposable
   graphical Emacs with your completion/theme configuration. Choose an unused
   chord. Loading `portal-launcher` alone registers nothing. Keep
   `native-comp-enable-subr-trampolines` enabled; address native compiler errors
   before enabling, without bypassing the guard.
4. Try the workflow below, then repeat in a **fresh normal session**, explicitly
   evaluating the README setup. Record the actual packages, theme, input source,
   keyboard and monitor arrangement. A copied settings fragment does not count
   as the complete normal configuration.
5. Keep an ordinary Emacs frame open with a text buffer and live Portal web and
   terminal views. Confirm they remain usable before, during and after launcher
   enable/disable. Do not rebuild the loaded binary during the session.

For the launcher itself, only the shared native module and Emacs are needed.
There is no app host, separate launcher application or `emacsclient` invocation
on its shortcut path. Busy Lisp delays shortcut processing.

## Migrate the M-x.app launcher shortcut

Start Portal on a different chord so either launcher can be restored. In M-x's
Settings, record the launcher row's trigger and Eval expression, for example
`(my/popup-command #'launcher)`. Remove **only that row** using its trash button;
then assign the freed chord with `setopt portal-launcher-shortcut`.

Keep the M-x application, its remaining shortcut rows, its `emacsclient` path
and its URL handlers. `emacs://`, `org-protocol://`, modifier double-taps and
multiple shortcut bindings remain M-x features outside this Portal milestone.
Confirm an existing URL/org-protocol action still works after the migration.
Portal does not read, edit or migrate M-x preferences automatically.

## Roll back

Evaluate `(portal-launcher-mode -1)` and remove the mode-enable call from the
init file so configuration reload cannot register it again. Confirm the panel
disappears and its chord no longer invokes Portal. Disabling during a launcher
prompt cancels the session before deleting the panel. Repeated disable is safe.

The dedicated frame, shortcut registration, launcher hooks and frame guards
are released. Ordinary frames, web views and terminal sessions continue to work.
The shared native module remains loaded for those features; restart Emacs if
you need to replace it. Restore the saved M-x row and its chord if desired.
Do not uninstall M-x or remove its URL handlers as part of this rollback.

## Repeatable checks

After building, run batch checks and the focused graphical checks:

```sh
ctest --test-dir build --output-on-failure
sh test/launcher-daily-use.sh > build/launcher-daily-use.log 2>&1
```

The script compiles the test-only AppKit injector, opens a disposable `emacs -Q`,
runs two tests, prints ERT output and exits nonzero on a failure or skipped test.
It creates native windows and temporarily takes focus; let it finish before
interacting with other apps. `EMACS` can select a different executable, which
must match the build's header and supported revision. Run the README's combined
graphical suite to exercise the existing launcher lifecycle, focus, geometry
and completion matrix as well. Use its selector `"^portal-launcher-"` instead
of `"^portal-"` to run just the 15 launcher tests.

To check an isolated completion/theme fragment without changing your init:

```sh
PORTAL_LAUNCHER_CONFIG=/absolute/path/to/completion-and-theme.el \
  sh test/launcher-daily-use.sh > build/launcher-configured.log 2>&1
```

The fragment should add the desired installed packages to `load-path`, enable
their modes and load the theme. It runs before the tests and its settings are
preserved by the application test. Do not pass a full init file: it may start
unrelated services or open other UI. Use the fresh normal-session procedure for
that acceptance check. The default run uses the packages downloaded by CMake.

On the validation machine, batch tests that compile native trampolines require
the existing Homebrew GCC library-path workaround. A missing `emutls_w` library
is a compiler setup failure. The successful run used:

```sh
export LIBRARY_PATH="/opt/homebrew/lib/gcc/current:/opt/homebrew/lib/gcc/current/gcc/aarch64-apple-darwin25/15${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

This path is machine-specific; verify the installed GCC directory elsewhere.
The checks keep native trampolines enabled and do not change compiler settings.

The combined launcher suite exposed a test-isolation problem: mutating or
deleting an ordinary native window can asynchronously activate the previous
application. A subsequent prompt correctly cancelled on that activation before
the harness finished typing. A four-test reproduction failed before the change
and passed after the shared GUI fixture allowed native events to settle during
cleanup. The full launcher suite passes together. The production
focus-loss observer remains unchanged.

## Hands-on record required before completion

Record date, Portal commit, Emacs revision, macOS build, complete init used,
completion/theme versions, keyboard/input-source names, display layout and the
result of every row. Use **pass**, **fail** or **not tested**, with exact symptoms.
For a failure, record a reproducible case and either fix it or obtain an explicit
scope decision; missing equipment and missing results are not passes.

| Check | Procedure and expected result | Current production evidence |
| --- | --- | --- |
| Normal configuration | Fresh normal Emacs; enable the documented setup. Physically invoke from another app, launch a stopped app, then activate the same running app. Destination gets focus without an ordinary Emacs frame rising. | Pending |
| Selection without typing | Open the launcher and press Return on the highlighted app. Reopen, use Down/Up to choose another app and press Return. Both launch the selected app without requiring typed text. | Pass: user-confirmed manual retest on 2026-10-04 after the selection fix; automated minibuffer and native key checks also pass |
| Refresh and search | `C-u M-x portal-launcher-present` refreshes, `M-x launcher-refresh` works separately. Enter `!gh portal launcher` and unmatched text; check the encoded query and destination focus. A freshly installed/removed test app appears/disappears after refresh. | Prior isolated automated real-app smoke; physical/full-init pending |
| Cancellation | From another app, try Escape, C-g, the global chord again and a bang without a query. Panel closes with no external action and focus returns. Click another app while prompting; it keeps focus. An empty completion result also cancels; Return on a highlighted app accepts it. | Automated session checks; physical checks pending |
| Failure and recovery | Run `(portal-launcher-present (lambda () (interactive) (error "Launcher recovery check")))` from Emacs; it reports the error and hides. Invoke normally again. Repeat a stale bundle/open failure while another app is active. | Automated error/reentry; full-init/external-app case pending |
| Fullscreen and Spaces | Put another app fullscreen. Invoke, type, select and cancel without switching Spaces; repeat in another Space and verify focus return and successful activation. | Prototype human pass only; production physical regression pending |
| Monitor changes | Invoke on each monitor, unplug one while visible and while hidden, reconnect and invoke again. No stranded panel, wrong display or unreachable prompt. Record origins, scale and which monitor was removed. | Automated static geometry only; physical changes pending |
| Chinese/Japanese IME | Name the macOS input source. Type a composition such as Pinyin `nihao`, open its candidate list, navigate and commit `你好`. Confirm marked text/candidate positioning, committed text and cancellation, then restore the prior input source. ASCII, pasted Unicode and dead keys do not satisfy this check. | Not tested; no IME support claim |
| VoiceOver | With VoiceOver enabled, summon the panel; record the spoken prompt, editable input, candidate names, current selection and ability to navigate, accept and cancel. Check focus after dismissal and restore the prior VoiceOver state. An accessibility tree or screenshot alone does not establish spoken output. | Not tested; no VoiceOver support claim |
| Reload and rollback | Re-evaluate launcher setup, disable twice, re-enable and use again. Ordinary text input, web navigation and the same terminal shell work throughout. Disable and confirm the chord is free; restore the M-x launcher row if applicable and test an existing URL binding. | Automated repeated enable/disable with live views; physical/full-init/M-x checks pending |

## Evidence recorded on 2026-10-03

The two new graphical tests pass both with stock completion and with the isolated
copy of active completion/theme settings listed above. Native AppKit events type
an app name and a spaced bang query, cancel empty input and Escape, trigger an
open error, and successfully read another prompt afterward. External launch and
browser calls are fixtures in these tests; they do not prove a human app launch.

The coexistence test opens a second ordinary frame, a live shell and a WebKit
page. Three reload/disable/re-enable cycles preserve the shell PID and both view
identities, execute shell commands and load new pages after each rollback, and
verify removal of the panel, shortcut registration and frame guards. An initial
test-harness error passed a buffer where a window was required; correcting that
assertion made the test pass without changing production code.

The build, all 32 CTest suites, host formatting/type checks, native
failure-reporter tests, changed-test byte compilation and Org structure/identity
checks pass. All 14 launcher GUI tests pass together; the two focused tests also
pass with stock and copied local completion/theme settings in fresh processes.

The [application integration record](launcher-applications.md) retains the
earlier real-app smoke, cold/warm timings and static monitor measurements.
The task in [project.org](../project.org) tracks the remaining acceptance gates.

## Selection correction on 2026-10-04

The user's manual check found that Return on a highlighted app did nothing
until text was typed. The adapter now accepts the completion reader's result;
the earlier empty-input cancellation policy is superseded. The configured
completion test now checks selection without typing, empty results from stock
completion, Escape and a bang without a query. The hands-on matrix above includes
both initial and arrow-key selection.

All 15 combined launcher GUI tests pass with the updated regressions. Launcher
CTest checks, changed-test byte compilation, shell syntax and Org validation
pass. The copied-settings rerun was inconclusive: extra keystrokes changed the
fixture's `Calculator` input, so it is not recorded as a pass. The earlier
configured run above is historical evidence; a fresh configured recheck remains
pending. The GUI checks used an alternate shortcut because the normal chord
was already registered in the user's running Emacs.

## Manual test report on 2026-10-04

After the selection fix was merged in PR #74, the user reported that the manual
tests looked good and asked to proceed with the task. This confirms the reported
Return/arrow-selection regression is resolved in manual use.
