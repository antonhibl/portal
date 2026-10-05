# Application launcher integration

Portal includes no application picker. The current setup is the
[launcher.el recipe](launcher.md#application-launcher-with-launcherel-optional),
in user configuration, with an optional integration smoke test outside the
build. Until 2026-10-05, Portal included an adapter around launcher.el,
`portal-launcher-applications`, ran it by default and downloaded launcher.el
for its tests. The [historical record](#historical-the-built-in-adapter) below
keeps that adapter's design and evidence; it does not describe the current
setup.

## The recipe and launcher.el follow-ups

Inspected on 2026-10-05 at
[launcher.el 731146d](https://github.com/xiaoxinghu/launcher.el/blob/731146d95d7d1ff16f48e7a200da873c8d8b375c/launcher.el),
then the head of its `main`. Its `launcher` command reads one completion result
and acts on it. With completion returning each result, and `open` and the
browser mocked:

| Completion result | What `launcher` does |
| --- | --- |
| `""` | Opens `https://www.google.com/search?q=`, an empty search |
| `"  "` | Searches Google for two spaces |
| `"!g"` | Searches Google for `!g` |
| `"!gh "` | Opens `https://github.com/search?q=`, an empty search |
| `"Calculator"` | Runs `open -a /System/Applications/Calculator.app` |

Its prompt uses stock completion's map, where Space runs
`minibuffer-complete-word`. Typing `!gh portal` there, with Space, searched
Google for `!ghportal`: completion consumed the space.

So launcher.el needs these upstream changes before the documented wrapper,
`my/launcher-read` and its variable `my/launcher-reader`, can go:

1. An empty or blank completion result takes no action.
2. A configured bang with no query, such as `!g` or `!gh `, takes no action.
3. Space inserts a space in its prompt where stock completion would complete a
   word, keeping an explicitly customized binding.
4. Optionally, `if-let` and `when-let`, obsolete in Emacs 31.1, become
   `if-let*` and `when-let*`; loading reports a warning for each.

Selection needs no change: launcher.el acts on the completion result, so Return
on a highlighted candidate works whenever the completion UI returns it, as
Vertico does with no typed text. The earlier failure to accept it was in
Portal's adapter, which checked the typed text; see the selection correction
below.

The wrapper applies rules 1 to 3 in user configuration. For one call,
`my/app-launcher` binds `completing-read-function` to `my/launcher-read` and
keeps the user's reader in the special variable `my/launcher-reader`, which
`my/launcher-read` calls; it returns the reader's result, text properties
included, so launcher.el finds the chosen candidate. It uses no closure, so it
works in a configuration file without `lexical-binding`, which Emacs 31 still
loads with dynamic binding. The first version returned a closure over the
reader, which failed with `void-variable` there; review caught it, and a batch
test now loads the recipe from a file with each binding. An empty
result or a bang without a query signals `quit`, which the panel treats as
cancellation: it closes, and focus returns to the previous app. It changes no
keymap, no global setting and no launcher.el function, so ordinary
`M-x launcher` is unchanged. It reads `launcher-bangs`; the bang test splits
the result into words, so `" !g "` cancels too.

## Optional integration smoke test

[test/launcher-recipe.sh](../test/launcher-recipe.sh) runs
[the recipe tests](../test/portal-launcher-recipe-tests.el) in a disposable
graphical Emacs. It is not part of the build or CTest. Point it at a directory
with launcher.el:

```sh
./build.sh
PORTAL_LAUNCHER_EL=/absolute/path/to/launcher.el-directory sh test/launcher-recipe.sh
```

It loads the launcher guide's recipe from a file with dynamic binding, with its chord
moved to Control-Option-Command-F20, and types native key events into the real
panel.
The input test, with Spotlight, `open` and the browser mocked, checks with
stock completion and with Vertico, Orderless and Marginalia: a typed app, a
spaced `!gh` query, a bang without a query, an empty result and Escape; with
Vertico, Return on the first app and after Down, and Down then Up, with no
typed text; a prefix argument rebuilding the index; the shortcut running the
same command; each prompt being the panel's only window; and the user's
completion reader restored. The launch test activates Safari, or another
running app, then uses real Spotlight and `open`: Escape leaves that app in
front, and typing `Finder` and Return activates the running Finder.

Run on 2026-10-05: both tests passed, with launcher.el 731146d (SHA-256
`7211f80c73a498215fdf1f1bc592c7b9148a965bf91e9da1d18b9df1e87819cb`), GNU Emacs
NS 31.1 revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`, macOS 27.0.1
(26A434), and Vertico 2.15, Orderless 1.8 and Marginalia 2.13 from
`build/elpa`. Spotlight indexed 506 applications; Safari was in front before
the launch. The first run's input test failed in its own fixture, which
counted one Spotlight query per refresh while launcher.el queries each of its
four default directories; it now sets one directory.

## Historical: the built-in adapter

This section records the adapter as it was from 2026-10-03 to 2026-10-05. The
names and commands in it, `portal-launcher-command`, `portal-launcher-applications`,
`portal-launcher-mode`'s shortcut and the `launcher-applications` CTest suite,
are gone.

`portal-launcher-command` defaulted to `portal-launcher-applications`, which
loaded the optional `launcher.el` package and ran its command inside the existing
command session. Portal added no application catalog, discovery process, native
provider or search implementation. `launcher.el` owned the cache and exact bundle
paths; its annotations were never parsed back into an application identity.

Tested with launcher.el at 731146d, GNU Emacs NS 31.1 revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`, and macOS 27.0.1 (26A434). CMake
downloaded a hash-checked copy of that dependency into `build/elpa` for tests.

### Input policy and package follow-ups

The adapter delegates to the user's `completing-read-function`. It returns the
chosen string unchanged, including its text properties, so upstream lookup uses
the original candidate label. The package supplies path annotations through
`completion-extra-properties`; it has no completion category. Its bang collection
reads the actual minibuffer contents, which is necessary when Orderless requests
all candidates with an empty string.

Two presentation policies are scoped to this invocation:

- A blank completion result and a configured bang with no query cancel the
  command session. Return accepts the highlighted app even when the search text
  is empty, including the initial candidate and selection with arrow keys.
  The reader's final result determines the action. Cancellation uses the existing
  session cleanup and focus-return behavior.
- Stock completion's default Space binding completes words and consumes the
  separator needed to enter a bang query. In this prompt, that default binding is
  replaced with literal Space; Tab still completes. An explicitly customized
  binding is retained. The shared minibuffer keymap is never modified.

These problems belong to the input path of the tested `launcher.el` revision:
its unwrapped command searches for empty input and uses the stock Space binding.
A future package change can handle them directly. Portal's scoped adapter keeps
ordinary `M-x launcher` unchanged; no package files or global advice are patched.
An upstream modernization can also replace its obsolete `if-let`/`when-let`
macros; their load warnings do not prevent operation on this Emacs build.

Prefix refresh passes through to the package. `C-u M-x portal-launcher-present`
refreshes before reading, and `M-x launcher-refresh` remains available separately.
No scan occurs per keystroke. A discovery failure retains the previous cache;
an empty index reports an error and retries on the next invocation. A missing
cached bundle or a failed `open` reports an error rather than falling back to a
different app or web search. Refresh after moving an application. A browser
function that signals an error also follows normal session cleanup; asynchronous
failures after a browser accepts a URL remain the browser's responsibility.

### Verification on 2026-10-03

Seven adapter ERT tests use the real pinned package, temporary bundle directories
and mocked Spotlight/open/browser actions. They cover duplicate non-ASCII names,
spaces in paths, decorated strings, actual stock and Vertico/Orderless/Marginalia
completion, encoded fallback and all three bang searches, untouched prompts,
explicit refresh after installation/removal, failed discovery/open/browser calls,
empty indexes, cache reuse and unchanged ordinary `launcher` behavior. The
separate launcher suite checks loading without the package and the setup error.

All 12 launcher graphical tests pass with module assertions. The application test
types native AppKit key events into the real panel with stock completion and with
Vertico 2.15, Orderless 1.8 and Marginalia 2.13. It verifies default-command routing,
app selection, a spaced bang query, empty input, Escape and preserved ordinary
window selection. External actions are mocked in that repeatable suite.

A separate disposable GUI smoke test used real Spotlight and `open -a`:

- Calculator was initially stopped. Typing `Calculator` launched it and gave it
  focus. After switching to Finder, a second invocation activated the same
  Calculator process; the ordinary Emacs frame did not take focus.
- Prefix refresh rebuilt the 506-entry index. Escape returned focus to Calculator.
- `!gh portal launcher` handed the correctly encoded URL to the configured
  OpenIn handler and onward to Chrome. A separate run with a locally bound Chrome
  browser function also passed the browser-focus assertion without changing
  system browser preferences. UI inspection confirmed both GitHub result tabs
  displayed the query `portal launcher`; the test tabs were then closed.

The initial smoke run was dismissed while switching applications. The harness
was changed to wait for asynchronous Finder activation before invoking the next
session, and the rerun passed; no native focus behavior was changed.

The complete graphical suite subsequently passed: 78 expected results, zero
unexpected and one skipped shell-startup test that uses a separate harness.
This includes all seven graphical input tests. An earlier full run overlapped
browser UI inspection and dismissed a nested launcher prompt early; the serial
rerun passed. All 32 CTest suites, host formatting/type checks, native
failure-reporter tests and changed-file byte compilation also pass.

Both connected Retina displays passed the existing exact-geometry tests:
Gigabyte M32U at `(0, 0)` and LG ULTRAFINE at `(2560, -483)`, including 713x407
points. This is automated input and geometry evidence, not human confirmation
of physical shortcut delivery, fullscreen/Spaces, monitor unplugging or click-away.
Those checks, the user's complete configuration, IME and VoiceOver remain in
the `launcher-daily-use` task. The physical GUI acceptance item remains unchecked.

### Selection correction on 2026-10-04

The initial adapter treated empty typed text as cancellation even when completion
returned a valid highlighted app. It now checks the final completion result.
Return on the first app and Down/Up navigation followed by Return work without
typing. Actual empty results and bangs without a query still cancel.

Two regression tests reproduce both reported cases with real Vertico/Orderless
minibuffers and exact fixture paths; both failed before the fix. A native-panel
test covers Return, Down/Return and Down/Up/Return using AppKit key events and
mocked app launches. The original stock/enhanced completion checks now follow
the same policy. No dependency or native implementation changed.

All 32 CTest suites and all 13 launcher GUI tests pass, along with host
format/type checks, native failure-reporter tests, changed-file byte compilation
and Org task validation. The GUI run used a test-only alternate shortcut because
the normal chord was already registered by the user's running Emacs.

### Discovery timing

One fresh batch Emacs process, the default four discovery directories, 506
applications, and the tested package revision:

| Operation | Elapsed time |
| --- | ---: |
| Cold `launcher--ensure-index` | 1.231 seconds |
| Explicit `launcher-refresh` immediately afterwards | 0.431 seconds |
| 1,000 cached `launcher--ensure-index` calls combined | 0.079 milliseconds |

These measure catalog work only, excluding panel creation, human typing and app
startup. The cold and refresh samples each include one garbage collection. The
cached measurement is an aggregate near timer resolution, not an end-to-end
invocation latency claim. A busy Emacs command loop can still delay invocation.

The adapter's checks then ran as the `launcher` and `launcher-applications`
CTest suites and, with the pinned package on `load-path`, the
`portal-launcher-gui-` tests. On this machine, Emacs native trampolines also
required the existing Homebrew GCC library-directory workaround in
`LIBRARY_PATH`; project compiler settings were not changed.
