# Keyboard and toolbar controls

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Shared keyboard controls

Native views run apps inside Emacs, like pages in a browser. Terminal,
Excalidraw and HTML/Markdown views behave as outside Emacs; unused chords
reach Emacs:

| Keys in a view | Where they go |
| --- | --- |
| Typing: plain and Shift keys, arrows, Return, Tab, Escape | The app, always |
| A chord (Control, Option or Command with a key that types a character) the app uses | The app |
| Command-C, Command-V | Copy and paste, in every view |
| Command-F, Command-R | Find and reload, in a web view with a toolbar |
| Any other chord | Emacs, as if typed in the view's buffer; Emacs reads the rest of its key sequence |
| Command-Escape | Return to Emacs and stay there |
| `RET`, or a click, while Emacs owns a Portal buffer | Enter the app |

`s-x` and other Emacs Command bindings work inside terminals; `C-x b` works
on pages that leave Control-X unused. Terminal programs get every Control and
Option chord: tmux keeps `C-b`. Pages get first claim on chords, as in a browser.
Plain keys never reach Emacs, which also binds single keys. Give an Evil Space
leader a chord too, such as `(evil-set-leader 'normal
(kbd "s-'"))`. Emacs handles splits, buffers and switching; views have no tab
or split keys.

Commands finish minibuffer interaction before returning to the selected native
view. Explicit unfocus, errors or selecting an ordinary buffer leave Emacs in
control. `C-g` cancels Emacs key-sequence reading. The toolbar's ownership dot
is hollow for Emacs, green for the view, and blue while Emacs reads a command.
Click it to enter or return to Emacs. Ordinary buffers get no global physical
keybinding.

The 28 pixel toolbar reserves space above content. Web pages have back,
forward, find, zoom and reload; Markdown and HTML previews add a table of
contents, and Markdown adds **Open in Emacs**. Terminals have text size controls;
Excalidraw and quick terminals have no toolbar. The opening command chooses a
web view's toolbar. `(setq portal-toolbar nil)` hides toolbars live; `t`
restores them. Colors follow Emacs faces, including theme changes.

`portal-zoom-in`, `portal-zoom-out`, `portal-zoom-reset`, `portal-toggle-toc`,
`portal-find`, `portal-web-back` (`l`), and `portal-web-forward` (`r`) use the
same state as the buttons. Terminal equivalents are
`portal-terminal-text-size-increase`, `portal-terminal-text-size-decrease`, and
`portal-terminal-text-size-reset`; terminal Command-Plus, Command-Minus and
Command-0 do the same, with or without a toolbar. Command-F runs `portal-find`
in web views with toolbars; Command-R reloads the page, like the Reload button,
unless the page claims those chords. In Portal web buffers, `s-f` and `s-r`
(`portal-web-reload`) also work with Emacs focus. Find opens a toolbar field:
Return/Shift-Return navigate matches; Escape closes it. State survives hiding
and redisplay; reload preserves zoom and the TOC. Killing the buffer releases it.

A terminal's native bindings can claim a chord its program would otherwise
get, such as a Control chord (see [the input bridge](terminal-input-bridge.md)).
macOS's own shortcuts, such as Command-Space, still come first.

Click a page or press `RET` to interact. Entering by click also selects its
Emacs pane, keeping selection and keyboard focus aligned. Back in Emacs, `q`
hides the web view and `g` reloads. The mode line and minibuffer remain available.

Restart Emacs after rebuilding the native module to try these controls.
