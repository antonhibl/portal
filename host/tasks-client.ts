// SPDX-License-Identifier: GPL-3.0-or-later
// The task browser's page script. Each task page runs it from its source text
// as its only script, so it refers to nothing outside itself.

/** Run the task controls, and refresh the page from saved files in place:
 * when Emacs saves a task file, and when history shows a kept page again.
 * A refresh keeps the URL, history, folds, reading position and focus. */
export function client() {
	let notice: HTMLElement | null = null;
	let clear: ReturnType<typeof setTimeout> | undefined;
	const say = (text: string, error = false) => {
		if (!notice) {
			notice = document.createElement("p");
			notice.className = "task-notice";
			notice.setAttribute("role", "status");
			document.body.append(notice);
		}
		notice.textContent = text;
		notice.classList.toggle("action-error", error);
		clearTimeout(clear);
		if (!error) clear = setTimeout(() => say(""), 8000);
	};
	const report = (error: unknown) =>
		say(`Could not refresh the page: ${(error as Error).message}`, true);

	/** A selector for ELEMENT that finds its counterpart in a refreshed page. */
	const selector = (element: Element | null): string | null => {
		if (element instanceof HTMLButtonElement && element.dataset.op)
			return `button[data-op="${element.dataset.op}"][data-task="${CSS.escape(element.dataset.task ?? "")}"]`;
		if (element instanceof HTMLAnchorElement)
			return `a[href="${CSS.escape(element.getAttribute("href") ?? "")}"]`;
		const item = element?.parentElement?.parentElement;
		if (element?.tagName === "SUMMARY" && item?.id)
			return `#${CSS.escape(item.id)} > details > summary`;
		return null;
	};

	// A hidden page refreshes once it is shown again.
	let stale = false;
	const swap = async () => {
		if (document.visibilityState === "hidden") {
			stale = true;
			return;
		}
		const response = await fetch(location.href, { cache: "no-store" });
		const fresh = new DOMParser().parseFromString(
			await response.text(),
			"text/html",
		);
		const next = fresh.querySelector("main");
		const main = document.querySelector("main");
		if (!next || !main)
			throw new Error("the app host has restarted. Press g to reload.");
		const open = new Map<string, boolean>();
		for (const details of main.querySelectorAll<HTMLDetailsElement>(
			"li[id] > details",
		))
			open.set(details.parentElement?.id ?? "", details.open);
		const focus = document.hasFocus() ? selector(document.activeElement) : null;
		const { scrollX, scrollY } = window;
		main.replaceWith(document.adoptNode(next));
		document.title = fresh.title;
		for (const details of next.querySelectorAll<HTMLDetailsElement>(
			"li[id] > details",
		))
			details.open = open.get(details.parentElement?.id ?? "") ?? details.open;
		window.scrollTo(scrollX, scrollY);
		if (focus)
			document
				.querySelector<HTMLElement>(focus)
				?.focus({ preventScroll: true });
	};
	// Each refresh starts after the call that asks for it; calls made before
	// it starts share it.
	let last: Promise<unknown> = Promise.resolve();
	let queued: Promise<void> | null = null;
	const refresh = (): Promise<void> => {
		if (!queued) {
			const run = last.then(() => {
				queued = null;
				return swap();
			});
			queued = run;
			last = run.catch(() => {});
		}
		return queued;
	};

	let busy = false;
	const operate = async (button: HTMLButtonElement) => {
		if (busy) return;
		busy = true;
		const { op, task = "", status, title } = button.dataset;
		const name = `“${title}”`;
		const label = button.textContent;
		const row = button.parentElement?.previousElementSibling;
		const index = row
			? [...document.querySelectorAll("a.row")].indexOf(row)
			: -1;
		const verb =
			op === "edit" ? "open" : status === "done" ? "complete" : "reopen";
		button.setAttribute("aria-disabled", "true");
		button.textContent =
			op === "edit"
				? "Opening…"
				: status === "done"
					? "Completing…"
					: "Reopening…";
		say(button.textContent);
		try {
			const query = new URLSearchParams(location.search);
			const response = await fetch("tasks/action", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				referrerPolicy: "same-origin",
				body: JSON.stringify({
					root: query.get("root"),
					context: query.get("context"),
					task,
					action: op,
					status,
				}),
			});
			const result = (await response.json().catch(() => ({
				error: "The app host has restarted. Press g to reload.",
			}))) as { error?: string };
			if (!response.ok || result.error)
				throw new Error(
					result.error ?? `The app host answered ${response.status}.`,
				);
		} catch (error) {
			button.textContent = label;
			button.removeAttribute("aria-disabled");
			say(`Could not ${verb} ${name}: ${(error as Error).message}`, true);
			busy = false;
			return;
		}
		busy = false;
		if (op === "edit") {
			button.textContent = label;
			button.removeAttribute("aria-disabled");
			say(`Opened ${name} in Emacs.`);
			return;
		}
		const done = status === "done" ? `Completed ${name}.` : `Reopened ${name}.`;
		try {
			await refresh();
		} catch (error) {
			say(
				`${done} Could not refresh the page: ${(error as Error).message}`,
				true,
			);
			return;
		}
		// A row the filter now hides leaves focus on the row that took its place.
		const shown = document.querySelector(selector(button) ?? "");
		if (!shown && document.hasFocus()) {
			const next = [...document.querySelectorAll<HTMLElement>("a.row")];
			const heading = document.querySelector<HTMLElement>("h1");
			heading?.setAttribute("tabindex", "-1");
			(next[index] ?? next.at(-1) ?? heading)?.focus();
		}
		say(
			shown
				? done
				: `${done} Completed tasks are hidden; Show completed lists them.`,
		);
	};

	document.addEventListener("click", (event) => {
		const button =
			event.target instanceof Element
				? event.target.closest("button[data-op]")
				: null;
		if (!(button instanceof HTMLButtonElement)) return;
		event.preventDefault();
		if (button.getAttribute("aria-disabled") !== "true") void operate(button);
	});
	// Emacs asks for a refresh after saving a file in this task root.
	if (window.portalBridge)
		window.portalBridge.receive = async (message: { type?: unknown }) => {
			if (message?.type === "refresh") await refresh().catch(report);
		};
	// History can show a page kept from before a change; check it again.
	window.addEventListener("pageshow", (event) => {
		if (event.persisted) refresh().catch(report);
	});
	document.addEventListener("visibilitychange", () => {
		if (stale && document.visibilityState === "visible") {
			stale = false;
			refresh().catch(report);
		}
	});
}
