// SPDX-License-Identifier: GPL-3.0-or-later
// The bridge between a hosted app and the Emacs buffer that presents it
// (docs/editor-bridge.md). Portal defines window.portalBridge in a hosted
// app's page before any of the page's scripts run; elsewhere it is missing.
// The app posts JSON objects with postMessage, and sets receive, which Emacs's
// messages reach in order.
interface PortalBridge {
	postMessage(message: object): void;
	receive?: (message: never) => Promise<void>;
}
interface Window {
	portalBridge?: PortalBridge;
}
