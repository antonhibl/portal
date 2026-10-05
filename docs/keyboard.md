# Keyboard and toolbar controls

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Shared keyboard controls

Emacs is the system, and each native view an app running in it, as a page runs
in a browser. Terminal, Excalidraw, and HTML/Markdown views behave as their apps
do outside Emacs, and a chord the app does not use reaches Emacs:

| Keys in a view | Where they go |
| --- | --- |
| Typing: plain and Shift keys, arrows, Return, Tab, Escape | The app, always |
| A chord (Control, Option or Command with a key that types a character) the app uses | The app |
| Command-C, Command-V | Copy and paste, in every view |
| Command-F, Command-R | Find and reload, in a web view with a toolbar |
| Any other chord | Emacs, as if typed in the view's buffer; Emacs reads the rest of its key sequence |
| Command-Escape | Return to Emacs and stay there |
| `RET`, or a click, while Emacs owns a Portal buffer | Enter the app |

So `s-x`, or any Emacs binding of yours on Command, works inside a terminal
without leaving it, and `C-x b` works on a page that does not use Control-X.
A terminal's program gets every Control and Option chord: tmux keeps `C-b`.
A page gets each chord first, as it would in a browser, and keeps those it uses.
Plain keys never reach Emacs, since Emacs binds single keys too; for an Evil
Space leader, bind a chord to it as well, such as `(evil-set-leader 'normal
(kbd "s-'"))`. Splits, buffers and switching stay Emacs's job: views have no
tab or split keys.

Commands finish their minibuffer interaction before returning to the selected
native view; explicit unfocus, errors, and selecting an ordinary buffer leave
Emacs in control. `C-g` cancels a key sequence Emacs is reading. The native
toolbar's ownership dot is hollow when Emacs owns the keyboard, green when the
view owns it, and blue while Emacs reads a command. Click the dot to enter or
return to Emacs. No global physical keybinding is installed in ordinary buffers.

The 28 pixel toolbar reserves space above the content. Web pages have back,
forward, find, zoom, and reload; Markdown and HTML previews also have a table of
contents, and Markdown previews an **Open in Emacs** button. Terminals have text
size controls. Excalidraw and quick
terminals have no toolbar. The command that opens a web view chooses its toolbar.
`(setq portal-toolbar nil)` hides toolbars live, and `t` restores them. Colors
follow Emacs faces and update after theme changes.

`portal-zoom-in`, `portal-zoom-out`, `portal-zoom-reset`, `portal-toggle-toc`,
`portal-find`, `portal-web-back` (`l`), and `portal-web-forward` (`r`) use the
same state as the buttons. Terminal equivalents are
`portal-terminal-text-size-increase`, `portal-terminal-text-size-decrease`, and
`portal-terminal-text-size-reset`, and in a terminal Command-Plus, Command-Minus
and Command-0 do the same, with or without a toolbar. Command-F runs `portal-find` in a web view
with a toolbar, and Command-R reloads the page as the Reload button does, unless
the page uses those chords itself; in Portal's own web buffers, `s-f` and `s-r`
(`portal-web-reload`) also work while Emacs owns the keyboard. Find opens a field inside the strip; Return
and Shift-Return navigate matches, and Escape closes it. State survives hiding
and redisplaying a pane; reload preserves zoom and the TOC. Killing the buffer
releases it.

A terminal's native bindings can claim a chord its program would otherwise
get, such as a Control chord (see [the input bridge](terminal-input-bridge.md)).
macOS's own shortcuts, such as Command-Space, still come first.

Click inside a page or press `RET` to interact. A click that enters a view also
selects the Emacs pane showing it, so the selected pane and the keyboard always
agree. After returning to Emacs, `q` hides the web view and `g` loads its page
again. The mode line and minibuffer remain available.

Restart Emacs after rebuilding the native module to try these controls.
