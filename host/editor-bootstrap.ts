// SPDX-License-Identifier: GPL-3.0-or-later
// Run before importing Excalidraw, including before its font registry loads.
window.EXCALIDRAW_ASSET_PATH = new URL("./assets/", location.href).href;
window.EXCALIDRAW_EXPORT_SOURCE = "portal";
import("./excalidraw").catch((error: unknown) => {
  document.body.textContent = `Unable to load drawing editor: ${String(error)}`;
});
