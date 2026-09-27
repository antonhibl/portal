// SPDX-License-Identifier: GPL-3.0-or-later

import {
	Excalidraw,
	loadFromBlob,
	MainMenu,
	serializeAsJSON,
} from "@excalidraw/excalidraw";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import type {
	AppState,
	BinaryFiles,
	ExcalidrawImperativeAPI,
} from "@excalidraw/excalidraw/types";
import { useState, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import "@excalidraw/excalidraw/index.css";
import "./excalidraw.css";

type Message = {
	type: string;
	json?: string;
	request?: number;
	name?: string;
	message?: string;
};

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing editor root element");
const root = createRoot(rootElement);
const darkScheme = window.matchMedia("(prefers-color-scheme: dark)");
const prefersDarkScheme = () => darkScheme.matches;
function subscribeToColorScheme(onChange: () => void) {
	darkScheme.addEventListener("change", onChange);
	return () => darkScheme.removeEventListener("change", onChange);
}

let api: ExcalidrawImperativeAPI | undefined;
let lastJSON = "";
let savedJSON = "";
let initialized = false;
let dirtyPending = false;
let contentKey = "";
let previousFiles: BinaryFiles | undefined;
let changeTimer: ReturnType<typeof setTimeout> | undefined;
let setStatus: (value: string) => void = () => {};
const post = (message: object) => window.portalBridge?.postMessage(message);

function currentJSON() {
	if (!api || !initialized) throw new Error("The drawing is still loading");
	return serializeAsJSON(
		api.getSceneElements(),
		api.getAppState(),
		api.getFiles(),
		"local",
	);
}

function publish(json = currentJSON()) {
	clearTimeout(changeTimer);
	if (json !== lastJSON || dirtyPending) {
		dirtyPending = false;
		lastJSON = json;
		setStatus(json === savedJSON ? "Saved" : "Modified");
		post({ type: "change", json });
	}
}

function onChange(
	elements: readonly ExcalidrawElement[],
	state: AppState,
	files: BinaryFiles,
) {
	if (!initialized) return;
	// Compare only exported data. Leave potentially large base64 image payloads
	// out of this per-interaction check; Excalidraw replaces its files map when
	// adding files. Full serialization and bridge traffic are debounced below.
	const key = serializeAsJSON(elements, state, {}, "local");
	if (key === contentKey && files === previousFiles) return;
	contentKey = key;
	previousFiles = files;
	if (!dirtyPending) {
		dirtyPending = true;
		post({ type: "dirty" });
	}
	// onChange also fires for selection and viewport changes. The local serializer
	// excludes transient UI state, so those changes do not dirty the document.
	clearTimeout(changeTimer);
	changeTimer = setTimeout(
		() => publish(serializeAsJSON(elements, state, files, "local")),
		150,
	);
}

function requestSave() {
	post({ type: "save" });
}

function Editor({
	initialData,
	name,
}: {
	initialData: Awaited<ReturnType<typeof loadFromBlob>> & {
		scrollToContent: boolean;
	};
	name: string;
}) {
	const isDark = useSyncExternalStore(
		subscribeToColorScheme,
		prefersDarkScheme,
	);
	const [status, updateStatus] = useState("Saved");
	setStatus = updateStatus;
	return (
		<Excalidraw
			theme={isDark ? "dark" : "light"}
			initialData={initialData}
			name={name}
			excalidrawAPI={(value) => {
				api = value;
				// Initial data is applied after the imperative API becomes available.
				// The first onChange below establishes the normalized document baseline.
			}}
			onChange={(elements, state, files) => {
				if (state.isLoading) return;
				if (!initialized) {
					initialized = true;
					contentKey = serializeAsJSON(elements, state, {}, "local");
					previousFiles = files;
					savedJSON = lastJSON = serializeAsJSON(
						elements,
						state,
						files,
						"local",
					);
					post({ type: "loaded", json: lastJSON });
				} else onChange(elements, state, files);
			}}
			autoFocus
			validateEmbeddable={false}
			onLinkOpen={(_element, event) => event.preventDefault()}
			UIOptions={{
				canvasActions: {
					loadScene: false,
					saveToActiveFile: false,
					export: false,
					saveAsImage: false,
				},
				welcomeScreen: false,
			}}
			renderTopRightUI={() => (
				<div className="portal-save">
					<span role="status">{status}</span>
					<button type="button" onClick={requestSave}>
						Save
					</button>
				</div>
			)}
		>
			<MainMenu>
				<MainMenu.Item onSelect={requestSave}>Save drawing</MainMenu.Item>
				<MainMenu.DefaultItems.ClearCanvas />
				<MainMenu.DefaultItems.ChangeCanvasBackground />
			</MainMenu>
		</Excalidraw>
	);
}

async function receive(message: Message) {
	try {
		if (message.type === "load") {
			if (api) throw new Error("This editor already has a document");
			const scene = await loadFromBlob(
				new Blob([message.json ?? ""]),
				null,
				null,
			);
			root.render(
				<Editor
					initialData={{ ...scene, scrollToContent: true }}
					name={message.name ?? "Drawing"}
				/>,
			);
		} else if (message.type === "snapshot") {
			// Commit an active text editor before serializing. A timeout also works
			// while the webview is hidden, where animation frames can be suspended.
			(document.activeElement as HTMLElement | null)?.blur();
			await new Promise((resolve) => setTimeout(resolve, 0));
			const json = currentJSON();
			publish(json);
			post({ type: "snapshot", request: message.request, json });
		} else if (message.type === "saved") {
			savedJSON = message.json?.trim() ?? "";
			setStatus(currentJSON() === savedJSON ? "Saved" : "Modified");
		} else if (message.type === "error") {
			setStatus(message.message ?? "Save failed");
		}
	} catch (error) {
		const text = error instanceof Error ? error.message : String(error);
		if (!api)
			root.render(
				<div className="portal-error">Unable to open drawing: {text}</div>,
			);
		post({ type: "error", message: text, request: message.request });
	}
}

if (window.portalBridge) window.portalBridge.receive = receive;

document.addEventListener(
	"keydown",
	(event) => {
		if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
			event.preventDefault();
			event.stopImmediatePropagation();
			requestSave();
		}
	},
	true,
);
// Flush promptly before focus returns to Emacs or the editor becomes hidden.
window.addEventListener("blur", () => {
	if (initialized) publish();
});
post({ type: "ready" });
