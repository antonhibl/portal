# Draw and save local Excalidraw files

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Local Excalidraw drawings

Run `M-x portal-excalidraw` for a new drawing, then Command-S or `C-x C-s` to
choose its filename and save. Open existing `.excalidraw` files normally with `C-x C-f`
or Dired; they enter `portal-excalidraw-mode` automatically. A prefix argument
to `portal-excalidraw` prompts for an existing or new file.

- Draw, type, paste text/images, and use the normal Excalidraw editing tools.
- Command-S, `C-x C-s` and the drawing's **Save** button save through Emacs.
  The drawing does not use `C-x`, so `C-x C-s` reaches Emacs even while the
  drawing has the keyboard. `C-c C-r` in the buffer reopens the drawing.
- Command-Escape returns keyboard focus to Emacs; `RET` re-enters the drawing.
  Bare Escape remains available for drawing/text editing.
- Each drawing buffer has one web view running the Excalidraw hosted app. It
  opens at once and loads the drawing when the app host is ready. Switching
  buffers hides it without losing its contents, selection, or undo history. In
  splits, the view follows the selected window showing that buffer. Independent
  drawings can be displayed together.
- Drawings use standard Excalidraw JSON, including embedded image data. Emacs owns
  file saving, modified indicators, backup settings, auto-save, and overwrite
  checks. Untitled modified drawings also participate in save/close prompts.
- `M-x revert-buffer` reloads the file from disk. `C-c C-r` reopens a failed
  view using the buffered drawing, preserving unsaved buffered changes but
  resetting undo history. Use it after restarting the app host if more
  Excalidraw assets need loading. A stopped host does not unload an already
  open drawing.

Excalidraw 0.18.1, React, CSS, lazy modules and fonts are bundled into
`portal-host`. The build installs pinned npm dependencies with Bun; runtime use
needs no npm packages or internet connection. The page blocks external asset
requests, CDN font fallbacks and remote embeds. Document persistence uses neither
localStorage nor IndexedDB. The current integration focuses on local documents;
cloud collaboration, online library installation, persistent personal libraries,
and image export are not integrated.

Restart Emacs after rebuilding the native module. See
[the bridge](editor-bridge.md) for implementation and tests.
