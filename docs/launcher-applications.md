# Application launcher integration

Portal has no application picker. Use the
[launcher.el recipe](launcher.md#application-launcher-with-launcherel-optional)
in user configuration; its optional integration smoke test runs outside the
build.

## The recipe and launcher.el follow-ups

Inspected on 2026-10-05 at
[launcher.el 731146d](https://github.com/xiaoxinghu/launcher.el/blob/731146d95d7d1ff16f48e7a200da873c8d8b375c/launcher.el),
then `main`'s head. `launcher` acts on one completion result. With each result
supplied and `open`/browser mocked:

| Completion result | What `launcher` does |
| --- | --- |
| `""` | Opens `https://www.google.com/search?q=`, an empty search |
| `"  "` | Searches Google for two spaces |
| `"!g"` | Searches Google for `!g` |
| `"!gh "` | Opens `https://github.com/search?q=`, an empty search |
| `"Calculator"` | Runs `open -a /System/Applications/Calculator.app` |

Stock completion's prompt map binds Space to `minibuffer-complete-word`.
Typing `!gh portal` searched Google for `!ghportal`: completion consumed Space.

Removing the documented wrapper, `my/launcher-read` and `my/launcher-reader`,
requires these upstream launcher.el changes:

1. An empty or blank completion result takes no action.
2. A configured bang with no query, such as `!g` or `!gh `, takes no action.
3. Space inserts a space in its prompt where stock completion would complete a
   word, keeping an explicitly customized binding.
4. Optionally, `if-let` and `when-let`, obsolete in Emacs 31.1, become
   `if-let*` and `when-let*`; loading reports a warning for each.

Selection needs no change: launcher.el accepts a highlighted candidate whenever
completion returns it, as Vertico does on Return without typing. Portal's adapter
caused the earlier failure by checking typed text; see the correction below.

The wrapper applies rules 1–3 in user configuration. For one call,
`my/app-launcher` binds `completing-read-function` to `my/launcher-read`, saving
the user's reader in special variable `my/launcher-reader`. `my/launcher-read`
calls it and returns its result unchanged, including text properties for candidate
lookup. Without a closure, files lacking `lexical-binding` work under Emacs 31's
dynamic binding. The first version returned a closure over the reader, causing
`void-variable`; review caught it, and a batch test now loads recipe files under
both bindings.
Empty results and queryless bangs signal `quit`: the panel cancels, closes and
returns focus to the previous app. No keymap, global setting or launcher.el
function changes, leaving `M-x launcher` unchanged. The bang test reads
`launcher-bangs` and splits words, so `" !g "` also cancels.

## Optional integration smoke test

[test/launcher-recipe.sh](../test/launcher-recipe.sh) runs
[the recipe tests](../test/portal-launcher-recipe-tests.el) in a disposable
graphical Emacs. It is not part of the build or CTest. Point it at a directory
with launcher.el:

```sh
./build.sh
PORTAL_LAUNCHER_EL=/absolute/path/to/launcher.el-directory sh test/launcher-recipe.sh
```

It loads the guide's recipe from a dynamically bound file, moves its chord to
Control-Option-Command-F20 and types native key events into the real panel.
With Spotlight, `open` and browser mocked, the input test checks:

- Stock completion and Vertico/Orderless/Marginalia: typed app, spaced `!gh`
  query, queryless bang, empty result and Escape.
- Vertico without typing: Return on the first app, after Down, and after Down/Up.
- Prefix-argument index refresh; shortcut running the same command; prompts as
  the panel's only window; restoration of the user's completion reader.

The launch test activates Safari or another running app, then uses real Spotlight
and `open`: Escape keeps that app frontmost; typing `Finder` and Return activates
the running Finder.

Run on 2026-10-05: both tests passed, with launcher.el 731146d (SHA-256
`7211f80c73a498215fdf1f1bc592c7b9148a965bf91e9da1d18b9df1e87819cb`), GNU Emacs
NS 31.1 revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`, macOS 27.0.1
(26A434), and Vertico 2.15, Orderless 1.8 and Marginalia 2.13 from
`build/elpa`.
