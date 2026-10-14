---
status: done
---
# Tint the toolbar strip and label it with its view

# Tint the toolbar strip and label it with its view

The strip over a native view's mode line tells the user that the view, not
Emacs, has the keyboard. Today it draws a 2 px line and a dot in the
`success` face. Make the whole strip the signal, the way an active mode line
differs from an inactive one, and say what the view is.

- Tint: the strip's background blends its mode-line color toward a tint
  color at about 18%, with a 1 px top hairline and the dot in the tint. A
  pending handoff tints toward `link` as the dot does today.
- Tint color: a new face `portal-toolbar-tint`, inheriting from `success`,
  sent with the other theme colors as the role `tint`, so users and themes
  change it like any face. Unset, the platform falls back to `success`.
- Label: text after the dot in the tint color, built in Elisp by
  `portal-toolbar-label-function` and sent to the core per view, which puts
  it in the snapshot; Swift only draws it, truncated in the middle when
  narrow, hidden while find is open. Default: a terminal's buffer name,
  which follows renames; a web view's URL without its scheme; a Markdown or
  HTML render's source file path, abbreviated; a hosted app's path.
- Elisp sends a label only when it changes, from the view sync that already
  runs on redisplay. No new core-to-Lisp messages.

Done when: the C core tests cover the label and the tint color in the
snapshot and the change check; the Swift toolbar check reads the tint and
label; `docs/toolbar-design.md` describes the tint, the face and the label;
and every check in CONTRIBUTING.md passes.
