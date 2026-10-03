# Application launcher integration

`portal-launcher-command` defaults to `portal-launcher-applications`, which
loads the optional `launcher.el` package and runs its command inside the existing
command session. Portal adds no application catalog, discovery process, native
provider or search implementation. `launcher.el` owns the cache and exact bundle
paths; its annotations are never parsed back into an application identity.

Tested with [launcher.el at 731146d](https://github.com/xiaoxinghu/launcher.el/blob/731146d95d7d1ff16f48e7a200da873c8d8b375c/launcher.el),
GNU Emacs NS 31.1 revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`,
and macOS 27.0.1 (26A434). CMake downloads a hash-checked copy of that dependency
into `build/elpa` for tests. This does not install it into the user's Emacs.
See the [README](../README.md#native-launcher-panel-opt-in) for installation and
the existing native support restriction.

## Input policy and package follow-ups

The adapter delegates to the user's `completing-read-function`. It returns the
chosen string unchanged, including its text properties, so upstream lookup uses
the original candidate label. The package supplies path annotations through
`completion-extra-properties`; it has no completion category. Its bang collection
reads the actual minibuffer contents, which is necessary when Orderless requests
all candidates with an empty string.

Two presentation policies are scoped to this invocation:

- Blank input and a configured bang with no query cancel the command session.
  Input is recorded before the reader inserts a highlighted candidate on Return,
  so an empty Vertico prompt cannot launch its first app. Type a name or insert a
  candidate with Tab before accepting it. Cancellation uses the existing session
  cleanup and focus-return behavior.
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

## Verification on 2026-10-03

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

## Discovery timing

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

Run the repeatable adapter checks with:

```sh
./build.sh
ctest --test-dir build -R '^launcher' --output-on-failure
```

Use the README's graphical command, including the pinned launcher package on
`load-path`, for `portal-launcher-gui-` tests. On this machine, Emacs native
trampolines also require the existing Homebrew GCC library-directory workaround
in `LIBRARY_PATH`; project compiler settings were not changed.
