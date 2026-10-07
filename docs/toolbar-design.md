# Native toolbar design

Design date: 23 September 2026. The look and controls below are implemented.
State ownership changed later: [Ownership](#ownership) and the
[implementation notes](architecture.md#toolbar-state) describe today's code.
[Changes to existing code](#changes-to-existing-code) and
[Rejected alternatives](#rejected-alternatives) are historical.

A thin Swift-drawn toolbar replaces native views' Emacs header line. Its controls
act only on that view; Emacs retains Emacs behavior.

## Decisions

- Remove `portal-input-mode`'s header line, currently a **Return to Emacs** button
  and hint string (`portal-input--header`).
- Swift draws a 28 px strip atop each toolbar-bearing native view. It belongs
  to the view, never overlays content.
- The strip holds an ownership dot and view controls, but no file name: the
  mode line already shows it.
- Buttons call the C core, which asks the platform to act on WebKit, Ghostty or
  the page, without messaging Elisp. The sole exception, Markdown's **Open in
  Emacs**, returns the keyboard and sends an `edit` message over the preview's
  bridge, like a source-file link.
- Only the C core holds toolbar state. Equivalent Elisp commands, such as zoom
  or TOC, run the same code and read back values.
- One option, `portal-toolbar`, shows or hides the strip.

## What belongs in the toolbar

Toolbar controls must meet all three criteria:

1. It acts only on this native view.
2. The platform can do it by itself through WebKit, Ghostty, or JavaScript in the page.
3. It changes no Emacs state: no windows, buffers, files, keymaps, or focus
   decisions that Elisp makes.

These fail the test and stay in Emacs:

| Excluded | Why |
| --- | --- |
| Split, new terminal, switch terminal | Emacs windows and buffers |
| Save, revert | Emacs owns files, modified state, and backups |
| Close | `quit-window` / `kill-buffer`, including save prompts |
| Key help, command prompt | The keybinding UI belongs to the minibuffer |
| File name, modified marker | The mode line already shows them |

Only the ownership dot relates to Emacs, adding no new messages;
see [Ownership dot](#ownership-dot).

## Anatomy

```
┌─────────────────────────────────────────────────────────────┐
│ ●                                  ⌕  ☰ │ −  110%  + │ ⟳    │  28 px strip (native)
├─────────────────────────────────────────────────────────────┤
│                                                             │
│                    native view content                      │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ -:%%-  *portal: README.md*   Top   (Portal)                 │  Emacs mode line
```

| Part | Size |
| --- | --- |
| Strip | 28 px high, 1 px bottom border, full width of the view |
| Padding | 5 px left, 6 px right |
| Ownership dot | 8 px dot centered in a 22 × 22 px click target, at the left |
| Buttons | 22 px high, minimum 24 px wide, 5 px corner radius, 2 px apart |
| Icons | 14 px stroke icons, stroke width 1.8 |
| Group separator | 1 × 14 px rule with 5 px margin on each side |
| Value readout | JetBrains Mono (or the system monospace font) 11 px, minimum 40 px wide |

Controls sit right; navigation (back/forward), if present, sits left after the
dot, separated by a rule.

### Layout mechanics

- Emacs still sends the rectangle from `window-inside-pixel-edges`; Elisp
  geometry is unchanged.
- Swift places a container there: the strip takes the top 28 px, the feature
  (`WKWebView`, terminal, editor) the rest.
- Terminals compute their grid from the smaller view, requiring no Elisp changes.
- Strip height is fixed at runtime. Even without controls it keeps 28 px, so
  appearing/disappearing controls never resize content. When `portal-toolbar`
  is nil, no strip is created.

## Ownership dot

The dot shows keyboard ownership, already known to the C core through platform
focus reports and per-view handoffs (`native/Core/input.c`). Toolbar snapshots
include it; changes redraw the strip immediately without polling.

| State | Appearance | Tooltip | Click |
| --- | --- | --- | --- |
| Emacs has the keyboard | Hollow ring, `shadow` color | Click to enter | Focus the view, same as clicking the view or `RET` |
| The view has the keyboard | Filled `success` green, soft halo | Click to return to Emacs | Return to Emacs, same as the configured escape |
| Handoff pending | Filled accent (`link`) | Emacs is reading a command | None; the minibuffer owns the prompt |

Dot clicks reuse existing paths: entering acts like a view click; returning acts
like the configured escape (Command-period by default), sending `escape` to
make Elisp run `portal-input-unfocus`. Content is subtly grayed out while Emacs
owns the keyboard, including command handoffs and views without a toolbar.
No new message types are added. Hovering uses the button hover background.

## Buttons

| State | Appearance |
| --- | --- |
| Default | Icon in `shadow` color, no background |
| Hover | Subtle background, foreground-colored icon; tooltip after the system delay |
| Pressed | Stronger background |
| Toggled on | Accent-tinted background, accent icon (for example TOC open) |
| On + hover | Stronger accent tint |
| Disabled | Icon at low contrast, no hover (for example zoom in at the maximum) |

- Buttons refuse first responder; clicks never move focus or change the dot.
- Tooltips use plain names ("Zoom in", "Table of contents"). Swift knows no Emacs
  bindings; key help stays in Emacs.
- Accessibility labels match tooltips; toggles report state.

### Value readout

Zoom and text size show their current value between the − and + buttons.

| State | Appearance |
| --- | --- |
| At default | Value dimmed (`shadow`) |
| Changed | Value in the foreground color; clicking it resets to the default (tooltip "Reset to 100%") |
| At a limit | The − or + button at that end is disabled |

## Controls by view

| View | Controls | Native mechanism |
| --- | --- | --- |
| Markdown / HTML preview | Back, forward (left); find, TOC, zoom − / value / +, reload (right). Markdown adds Open in Emacs beside the TOC | As for web pages, plus page JavaScript for the TOC; Open in Emacs sends an `edit` bridge message |
| Web page (`portal-open-url`) | Back, forward (left); find, zoom, reload (right) | `goBack()` / `goForward()` with `canGoBack` / `canGoForward` observed |
| Terminal | Text size − / value / + | `performBindingAction("increase_font_size:1")`, `decrease_font_size:1`, `reset_font_size` |
| Excalidraw | None; the dot only | The editor has its own tools. Its in-page Save button stays as it is |
| Quick terminal | No strip | Transient panel; the view fills the window body |
| AppKit square demo | No strip | Nothing to control; Hello World is a web page and gets the web controls |

Zoom steps: 50, 67, 75, 85, 100, 110, 125, 150, 175, 200, 250, 300%. Text size
steps by 1 pt within 1 to 255 pt; reset restores the initial 14 pt.

### TOC

The page, not the platform, draws the TOC. The button toggles it through the
core's shared contents script, which reports heading counts. Without headings,
the button is disabled.

### Find in page

Find replaces strip controls with a field, match count ("3 of 12"), previous/next
buttons and close button, never covering the page. The open field has focus;
the dot shows view ownership. Return advances to the next match. Escape or close
restores the controls.

## State

- Each view has its own state: zoom, TOC open, text size, find text.
- Retained hidden views preserve state. Reload preserves zoom; new previews use
  defaults.
- State does not persist across Emacs sessions.
- Elisp commands share state, never copying it: `portal-zoom-in`,
  `portal-zoom-out`, `portal-zoom-reset`,
  `portal-toggle-toc`, `portal-find`, and `portal-terminal-text-size-increase` /
  `-decrease` / `-reset`.

## Ownership

The C core owns toolbar state in `native/Core/toolbar.c`; platforms only draw it
([ADR 0003](adr/0003-platform-interface-primitives.md)).

| State | Owner |
| --- | --- |
| Layout: which buttons a view has | `toolbar.c`, fixed at open from `:toolbar`, `:hosted` and `:quick` |
| Zoom, text size, their steps and limits | `toolbar.c`; the platform sets them with `portal_web_zoom` and `portal_terminal_set_font_size` |
| TOC open, heading count | `toolbar.c`; the contents script shows the TOC and reports headings |
| Find text, matches, waiting searches | `toolbar.c`; the platform finds with `portal_web_find`, and the contents script counts |
| Who has the keyboard (the dot) | `input.c`; the toolbar reads it when it draws |
| Back and forward availability | `web.c`, as the platform reports it; the toolbar reads it when it draws |
| Visibility and colors | `toolbar.c`, from `portal-toolbar` and Emacs faces |
| Layout in points, symbols, tooltips, hover, `NSColor`s | The platform |

The core draws `portal_toolbar` snapshots only when changed. The platform reports
clicks and find text; Return, Shift-Return and Escape act as next, previous and
close clicks. Opening find focuses the field (`portal_toolbar_focus`); closing
focuses the page (`portal_view_focus`) only if the view still owns the keyboard,
never reclaiming it from Emacs or another view.

## Theme

Emacs faces supply theme-matching strip colors, sent at load and each theme
change (`enable-theme-functions` and `disable-theme-functions`). This is Elisp's
only toolbar data; nothing is sent back.

| Toolbar color | Face attribute |
| --- | --- |
| Strip background | `header-line` background, falling back to `mode-line-inactive` |
| Border | `vertical-border` foreground |
| Icons, dimmed values, Emacs dot | `shadow` foreground |
| Hovered icon, values | `default` foreground |
| View-has-keyboard dot | `success` foreground |
| Handoff dot, toggled-on tint | `link` foreground |

Swift tints hover, pressed and toggled backgrounds translucently from foreground
and `link` colors. Until colors arrive, built-in dark/light defaults follow
system appearance.

## Configuration

```elisp
;; Show or hide the strip on every native view. Changes apply live.
(setq portal-toolbar t)

;; The toolbar's functions are also reachable from Emacs.
(keymap-set portal-web-mode-map "+" #'portal-zoom-in)
(keymap-set portal-web-mode-map "t" #'portal-toggle-toc)
```

`portal-toolbar` is a defcustom with a variable watcher, like
`portal-terminal-theme`. Setting it calls one native function. When nil, the view fills the window body
without a dot; input destination alone reveals keyboard ownership. Per-view
strip hiding is outside this design.

## Changes to existing code

Historical: the changes this design first asked for.

- `portal-input.el`: remove the `header-line-format` setting in
  `portal-input-mode`, `portal-input--header`, and the `[header-line mouse-1]`
  binding in `portal-input--read`.
- `native/NativeHost.swift`: place a container (strip plus feature view) instead
  of the bare feature view, and publish ownership changes to the strip.
- New `native/Toolbar.swift`: the strip, buttons, dot, find field, and theme colors.
- `native/WebView.swift`, `native/Terminal.swift`: provide each view's controls
  and state. The state later moved into the C core.
- README: replace the description of the header's **Return to Emacs** control.

## Rejected alternatives

Initial options (the design canvas's "Explorations" page) were rejected as follows:

| Direction | Why it was rejected |
| --- | --- |
| Floating capsule (Island), corner menu | Floating controls cover content |
| Leader sheet (clickable key help on the former prefix) | The keybinding UI belongs in Emacs |
| Emacs actions in the toolbar (split, new, close, save) | They are Emacs behavior; clicks would have to go back to Elisp |
| Keep drawing it as an Emacs header line | Limited to text, and it needs `:eval` to catch native state |
| Edge rail | Kept as a possible later position: the same strip on another edge |

## Open questions

- Whether `pageZoom` should also apply to the hosted Excalidraw page, which
  currently has no zoom button because the editor has its own zoom.

Settled: the TOC uses the core's shared contents script in an isolated world.
Terminals start at `PORTAL_TERMINAL_POINTS`; the core tracks changes because
Ghostty has no getter.
