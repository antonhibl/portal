# Native toolbar design

Design date: 23 September 2026. This is a specification, not implemented behavior.
Mockups: [toolbar-mockup.html](toolbar-mockup.html) (open it in a browser).

Portal replaces the Emacs header line on native views with a thin toolbar that
Swift draws at the top of each view. The toolbar holds only controls that act on
the view itself. Emacs keeps everything that is Emacs behavior.

## Decisions

- Remove the header line that `portal-input-mode` installs. It currently shows a
  **Return to Emacs** button and a hint string (`portal-input--header`).
- Swift draws a 28 px strip at the top of every native view that has one. It is
  part of the native view, not an overlay, and never covers content.
- The strip contains an ownership dot and the view's own controls. It shows no
  file name, because the mode line already shows it.
- Clicking a toolbar button never sends a message to Elisp. Buttons call Swift,
  which calls WebKit, Ghostty, or the page. The one exception is a Markdown
  preview's **Open in Emacs**, which gives Emacs the keyboard and sends an
  `edit` message over the preview's bridge, as a link to a source file does.
- Swift is the only place view state lives. Elisp commands that do the same thing,
  such as zoom or TOC, call the same native functions and read the value back.
- A single option, `portal-toolbar`, shows or hides the strip.

## What belongs in the toolbar

A control belongs in the toolbar only if all of these are true:

1. It acts only on this native view.
2. Swift can do it by itself through WebKit, Ghostty, or JavaScript in the page.
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

The ownership dot is the one element that relates to Emacs. It adds no new
messages; see [Ownership dot](#ownership-dot).

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

Controls sit on the right. Navigation (back/forward), where present, sits on the
left after the dot, separated by a rule.

### Layout mechanics

- Emacs still sends the rectangle from `window-inside-pixel-edges`. Nothing
  changes in Elisp geometry.
- Swift places a container view in that rectangle. The strip takes the top 28 px
  and the feature view (`WKWebView`, terminal, editor) takes the rest.
- The terminal computes its grid from the smaller view, so no Elisp changes are needed.
- The strip height never changes at runtime. A view with no controls still gets
  the full 28 px, so its content never resizes when controls appear or
  disappear. When `portal-toolbar` is nil, the strip is not created at all.

## Ownership dot

The dot shows who receives the keyboard. Swift already knows this through
`NativeHost.ownsFocus` and `NativeInput`'s pending and passthrough states, so
the dot updates immediately with no polling.

| State | Appearance | Tooltip | Click |
| --- | --- | --- | --- |
| Emacs has the keyboard | Hollow ring, `shadow` color | Click to enter | Focus the view, same as clicking the view or `RET` |
| The view has the keyboard | Filled `success` green, soft halo | Click to return to Emacs · ⌘⎋ | Return to Emacs, same as Command-Escape |
| Prefix pending | Filled accent (`link`) | Emacs is reading a command | None; the minibuffer owns the prompt |
| Passthrough | Filled amber (`warning`) | Passthrough · ⌘⎋ returns to Emacs | Return to Emacs, same as Command-Escape |

Clicking the dot uses the paths that already exist. Entering is the same as
clicking the view. Returning is the same as Command-Escape, which already sends
the `escape` notification that makes Elisp run `portal-input-unfocus`. The dot
adds no new message types. When the dot is hovered, it gets the button hover background.

## Buttons

| State | Appearance |
| --- | --- |
| Default | Icon in `shadow` color, no background |
| Hover | Subtle background, foreground-colored icon; tooltip after the system delay |
| Pressed | Stronger background |
| Toggled on | Accent-tinted background, accent icon (for example TOC open) |
| On + hover | Stronger accent tint |
| Disabled | Icon at low contrast, no hover (for example zoom in at the maximum) |

- Buttons refuse first responder. Clicking one never moves keyboard focus, so
  the dot doesn't change.
- Tooltips show plain names ("Zoom in", "Table of contents"). Swift doesn't know
  Emacs key bindings, and key help stays in Emacs.
- Every button has an accessibility label equal to its tooltip. Toggles report
  their state.

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
changes by 1 pt, and resetting returns to the size from the terminal
configuration.

### TOC

The TOC is drawn by the page, not by Swift. The button toggles it through
JavaScript, and the page reports whether headings exist. If a page has no
headings, the button is disabled. This needs page support first; see
`tasks.md`.

### Find in page

The find button replaces the controls inside the strip with a field, a match
count ("3 of 12"), previous/next buttons, and a close button. Find stays inside
the strip, so the page is never covered. While the field is open it has
keyboard focus and the dot shows the view as the owner. Return goes to the next
match. Escape or the close button closes find, and the controls come back.

## State

- Each native view instance owns its state: zoom, TOC open, text size, find text.
- State survives hiding and showing, because hidden views are kept. A reload
  keeps the zoom. A new preview starts from the defaults.
- State is not saved across Emacs sessions.
- Elisp commands are another way to reach the same native functions, and never
  keep their own copy. Proposed names: `portal-zoom-in`, `portal-zoom-out`,
  `portal-zoom-reset`, `portal-toggle-toc`, `portal-find`, and
  `portal-terminal-text-size-increase` / `-decrease` / `-reset`.

## Theme

The strip takes its colors from Emacs faces so it matches the current theme.
Elisp sends them once at load and again after each theme change
(`enable-theme-functions` and `disable-theme-functions`). This is the only data
Elisp sends for the toolbar, and nothing is sent back.

| Toolbar color | Face attribute |
| --- | --- |
| Strip background | `header-line` background, falling back to `mode-line-inactive` |
| Border | `vertical-border` foreground |
| Icons, dimmed values, Emacs dot | `shadow` foreground |
| Hovered icon, values | `default` foreground |
| View-has-keyboard dot | `success` foreground |
| Prefix dot, toggled-on tint | `link` foreground |
| Passthrough dot | `warning` foreground |

Swift derives the hover, pressed, and toggled backgrounds as translucent tints of
the foreground and `link` colors. Before any colors arrive, it uses built-in
dark or light defaults that follow the system appearance.

## Configuration

```elisp
;; Show or hide the strip on every native view. Changes apply live.
(setq portal-toolbar t)

;; The toolbar's functions are also reachable from Emacs.
(keymap-set portal-web-mode-map "+" #'portal-zoom-in)
(keymap-set portal-web-mode-map "t" #'portal-toggle-toc)
```

`portal-toolbar` is a defcustom with a variable watcher, like
`portal-input-prefix`. Setting it calls one native function. When it is nil, the
view fills the whole window body and there is no dot. Keyboard ownership is then
visible only from where input goes. Hiding the strip for particular views is not
part of this design.

## Changes to existing code

- `portal-input.el`: remove the `header-line-format` setting in
  `portal-input-mode`, `portal-input--header`, and the `[header-line mouse-1]`
  binding in `portal-input--read`.
- `native/NativeHost.swift`: place a container (strip plus feature view) instead
  of the bare feature view, and publish ownership changes to the strip.
- New `native/Toolbar.swift`: the strip, buttons, dot, find field, and theme colors.
- `native/WebView.swift`, `native/Terminal.swift`: provide each view's controls
  and state.
- README: replace the description of the header's **Return to Emacs** control.

## Rejected alternatives

The first explorations (see the "Explorations" page on the design canvas) were
rejected for these reasons:

| Direction | Why it was rejected |
| --- | --- |
| Floating capsule (Island), corner menu | Floating controls cover content |
| Leader sheet (clickable key help on the prefix) | The keybinding UI belongs in Emacs |
| Emacs actions in the toolbar (split, new, close, save) | They are Emacs behavior; clicks would have to go back to Elisp |
| Keep drawing it as an Emacs header line | Limited to text, and it needs `:eval` to catch native state |
| Edge rail | Kept as a possible later position: the same strip on another edge |

## Open questions

- TOC needs page support: heading extraction and a toggle in the Markdown page.
- Ghostty's Swift wrapper has font-size actions but no obvious getter. Swift may
  need to count steps from the configured size to show the value.
- Whether `pageZoom` should also apply to the hosted Excalidraw page, which
  currently has no zoom button because the editor has its own zoom.
