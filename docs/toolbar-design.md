# Native toolbar design

Design date: 23 September 2026. Revised 12 October 2026: the strip moved from
above the content to over the pane's mode line, and shows only while the view
has the keyboard; see [Placement](#placement). The gray inactive overlay is
gone. Revised 14 October 2026: the whole strip tints toward one face and
names what the view shows; see [Tint and label](#tint-and-label). State ownership changed later too: [Ownership](#ownership) and the
[implementation notes](architecture.md#toolbar-state) describe today's code.
[Changes to existing code](#changes-to-existing-code) and
[Rejected alternatives](#rejected-alternatives) are historical.

A thin Swift-drawn toolbar replaces native views' Emacs header line. Its controls
act only on that view; Emacs retains Emacs behavior.

## Decisions

- Remove `portal-input-mode`'s header line, currently a **Return to Emacs** button
  and hint string (`portal-input--header`).
- Swift draws a strip over the pane's mode line while the view has the
  keyboard. It belongs to the view, never overlays content, and never takes
  room from it.
- The strip holds an ownership dot, a label naming what the view shows, and
  view controls. The label stands in for the mode line's buffer name, which
  the strip covers.
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
│                                                             │
│                    native view content                      │
│                                                             │
├─────────────────────────────────────────────────────────────┤  1 px hairline in the tint
│ ● │ ‹ › docs/README.md                 ⌕  ☰ │ −  110%  + │ ⟳    │  tinted strip over the mode line
```

While Emacs has the keyboard, Emacs's own mode line shows in the strip's
place.

| Part | Size |
| --- | --- |
| Strip | The mode line's height and width; its background the `portal-toolbar-tint` background, by default the theme's `highlight`, or without one the tint's hue at the mode line's brightness with 40% of its saturation (25% on a light mode line); a 1 px top hairline in the tint |
| Padding | 5 px left, 6 px right |
| Ownership dot | 8 px dot centered in a 22 × 22 px click target, at the left |
| Label | Emacs's default font in the tint, after the dot or the navigation buttons, truncated in the middle; hidden under 24 px or while find is open |
| Buttons | Up to 22 px high, centered in the strip, minimum 24 px wide, 5 px corner radius, 2 px apart |
| Icons | 14 px stroke icons, stroke width 1.8 |
| Group separator | 1 × 14 px rule with 5 px margin on each side |
| Value readout | Emacs's default font, as wide as its widest value |

Controls sit right; navigation (back/forward), if present, sits left after the
dot, separated by a rule.

### Placement

- Emacs sends the rectangle from `window-inside-pixel-edges` and, when the
  pane has a mode line, the mode line's edges, from `window-pixel-edges` and
  `window-mode-line-height`.
- Swift places a container spanning both: the feature (`WKWebView`, terminal,
  editor) fills the inside rectangle, and the strip covers the mode line.
  Clicks elsewhere in the container, such as beside the fringes, reach Emacs.
- The strip shows while the view has the keyboard, a handoff is pending, or
  find is open; otherwise Emacs's mode line shows. The C core decides.
- Covering the mode line rather than removing it means Emacs's layout never
  changes, so the content never resizes and a terminal's grid stays put.
- Panes without a mode line, such as the quick terminal's and the launcher's,
  show no strip. When `portal-toolbar` is nil, no strip is created.

Why: the gray overlay changed the colors of what people read, and many did not
notice it; the small dot was easy to miss, especially with one window. Moving
the controls into an Emacs-drawn mode line was tried and rejected: a click on
it is a click on Emacs, which takes the keyboard from the view before the
control runs.

## Ownership dot

The dot shows keyboard ownership, already known to the C core through platform
focus reports and per-view handoffs (`native/Core/input.c`). Toolbar snapshots
include it; changes redraw the strip immediately without polling.

| State | Appearance | Tooltip | Click |
| --- | --- | --- | --- |
| The view has the keyboard | Filled in the tint (`portal-toolbar-tint`, by default `success` green), soft halo | Click to return to Emacs | Return to Emacs, same as the configured escape |
| Handoff pending | Filled accent (`link`) | Emacs is reading a command | None; the minibuffer owns the prompt |

Dot clicks reuse existing paths: entering acts like a view click; returning acts
like the configured escape (Command-period by default), sending `escape` to
make Elisp run `portal-input-unfocus`. While Emacs has the keyboard the strip,
and with it the dot, is hidden. No new message types are added. Hovering uses the button hover background.

## Buttons

| State | Appearance |
| --- | --- |
| Default | Icon in the strip's foreground (`portal-toolbar-tint`), the label's color, no background |
| Hover | Subtle background in that color; tooltip after the system delay |
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
| Any | Value in the strip's foreground, like the label; clicking it resets to the default (tooltip "Reset to 100%") |
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

## Tint and label

The dot alone was easy to miss, and said nothing about the view. The whole
strip now carries the signal, the way an active mode line differs from an
inactive one: while the view has the keyboard its background is the
`portal-toolbar-tint` face's background, by default the theme's `highlight`,
the color the theme already gives its active item, so the strip is always a
color the theme shows elsewhere; the hairline, dot and label take the face's
foreground, the default foreground unless set. During a handoff the strip
takes `link`'s hue at the mode line's brightness, which is also what a face
without a background gets from its foreground. Mixing a tint into the mode
line's own color was tried first and turned modus-vivendi's blue-gray mode
line teal; a fixed green ignored the theme's own accents. A border around the content was tried on paper
and rejected as obtrusive.

After the dot, a label names what the view shows, in the tint. The strip is
infrastructure, like a macOS title bar: the core decides what it holds and
Swift paints every view's strip the same way. Each app contributes its
title through one core call, `portal_toolbar_label`, the way a macOS window
takes its title from its document unless the app sets one:

| View | Label | Set by |
| --- | --- | --- |
| Web page | The URL its page committed last, without its scheme, following links and history | The core, from the web module's committed page; nothing crosses to Lisp |
| Terminal | The buffer name, which follows `rename-buffer` | Lisp |
| Markdown or HTML render | The source file, abbreviated | Lisp |
| Hosted app | Its app host path | Lisp; a hosted app's address names the app host, so it has no default |

Lisp's label, when set, replaces the default. `portal-toolbar-label-function`
builds it in the view's buffer, and `portal-toolbar--sync-labels` sends it
with `portal--toolbar-label` only when it changed, after each command, which
is when a new view's buffer is complete and renames have happened, and after
native records (`portal-view-records-hook`, run from a timer once their
process filter has returned), which change what a hosted app shows or a
terminal reports, and may rename its buffer. Label functions never run in a
process filter, so they may prompt. A label the function fails to build is reported
with `with-demoted-errors` and shows the default.

## Theme

Emacs faces supply theme-matching strip colors and the text font, sent at
load and each theme change (`enable-theme-functions` and
`disable-theme-functions`). With the mode line's edges sent at each placement
and the label, this is Elisp's only toolbar data; nothing is sent back.

| Toolbar color | Face attribute |
| --- | --- |
| Strip background | `mode-line-active` background, falling back to `mode-line` |
| Border | `vertical-border` foreground |
| Emacs dot | `shadow` foreground |
| View-has-keyboard strip background | `portal-toolbar-tint` background, which inherits from `highlight` |
| View-has-keyboard hairline, dot, label, icons, values, separators | `portal-toolbar-tint` foreground, the default foreground unless set |
| Handoff tint and dot, toggled-on button | `link` foreground |
| Label, value readout, match count font | `default` family and height |

Swift tints hover, pressed and toggled backgrounds translucently from foreground
and `link` colors. Until colors arrive, built-in dark/light defaults follow
system appearance.

## Configuration

```elisp
;; Show or hide the strip on every native view. Changes apply live.
(setq portal-toolbar t)

;; The strip while a view has the keyboard: by default the theme's
;; `highlight' background with the default foreground.
(set-face-attribute 'portal-toolbar-tint nil :background "#2d3b2d" :foreground "#98be65")

;; What the strip says about its view; the default names the buffer,
;; page or file.
(setq portal-toolbar-label-function
      (lambda () (if (derived-mode-p 'portal-terminal-mode) (abbreviate-file-name default-directory)
                   (portal-toolbar-default-label))))

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
