// SPDX-License-Identifier: GPL-3.0-or-later
// The task browser: saved Markdown tasks in one task root, read on each request.
// A task is ROOT/NAME.md or ROOT/NAME/content.md with a `status` in its front
// matter. NAME is its location; its ID is its front matter `id`, or else NAME.
import { realpathSync } from "node:fs";
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { attribute, localTarget, page, render } from "./markdown";
import styles from "./tasks.css" with { type: "text" };

type Status = "todo" | "done";
type Task = {
	/** The effective ID: the front matter `id`, or else the location. */
	id: string;
	/** The file stem or folder name the task occupies in its root. */
	location: string;
	source: string;
	status: Status;
	title: string;
	/** Whether the body's first level-one heading supplies the title. */
	headingTitle: boolean;
	/** The distinct IDs in `depends_on`, or null when it is invalid. */
	dependsOn: string[] | null;
	body: string;
};
type Problem = {
	source: string;
	message: string;
	/** The ID the document would most likely have, when that is known. */
	id?: string;
};
/** What one candidate document turned out to be. */
type Reading =
	| { kind: "task"; task: Task }
	| { kind: "document" }
	| ({ kind: "problem" } & Problem);
type Candidate = { location: string; source: string };
/** Task documents sharing an ID or a location, none of which is used. */
type Conflict = { ids: string[]; sources: string[] };

/** Every task in a root, read once for one request. */
type Index = {
	/** The tasks with a unique ID and location, ordered by ID. */
	tasks: Task[];
	byId: Map<string, Task>;
	/** The effective ID of every task document, conflicting or not, by source. */
	bySource: Map<string, string>;
	conflicts: Conflict[];
	problems: Problem[];
};

/** A task named in another's `depends_on`, or why it cannot be used. */
type Reference = { id: string; task: Task | null; problem: string | null };

/** The order in which the unfinished tasks of an index could be completed. */
type Plan = {
	/** Each task's prerequisites, in the order it names them. */
	prerequisites: Map<Task, Reference[]>;
	/** The tasks naming each task as a prerequisite, ordered by ID. */
	dependents: Map<Task, Task[]>;
	/** Cycles of unfinished tasks, each ordered by ID. */
	cycles: Task[][];
	/** The unfinished tasks that can be completed, in order. */
	order: Task[];
	/** The unfinished tasks that cannot, from a dependency problem, by ID. */
	stuck: Task[];
};

// Inline images the file route serves. Nothing else is served.
const images: Record<string, string> = {
	".apng": "image/apng",
	".avif": "image/avif",
	".bmp": "image/bmp",
	".gif": "image/gif",
	".ico": "image/x-icon",
	".jpeg": "image/jpeg",
	".jpg": "image/jpeg",
	".png": "image/png",
	".svg": "image/svg+xml",
	".webp": "image/webp",
};

/** The form of an explicit task ID. */
const idPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

const html = Bun.escapeHTML;
const encode = encodeURIComponent;

function byCodeUnit(a: string, b: string): number {
	return a < b ? -1 : a > b ? 1 : 0;
}

function byId(a: Task, b: Task): number {
	return byCodeUnit(a.id, b.id);
}

function listHref(root: string, all: boolean): string {
	return `tasks?root=${encode(root)}${all ? "&show=all" : ""}`;
}

function taskHref(root: string, id: string, all: boolean, hash = ""): string {
	return `tasks?root=${encode(root)}&task=${encode(id)}${all ? "&show=all" : ""}${hash}`;
}

function errorCode(error: unknown): string | undefined {
	return (error as NodeJS.ErrnoException).code;
}

/** Split TEXT into its YAML front matter, or null without any, and its body.
 * Throws when the front matter is malformed. */
export function frontMatter(text: string): {
	data: Record<string, unknown> | null;
	body: string;
} {
	const source = text.startsWith("﻿") ? text.slice(1) : text;
	const open = /^---\r?\n/.exec(source);
	if (!open) return { data: null, body: source };
	const rest = source.slice(open[0].length);
	const close = /^---\r?(?:\n|$)/m.exec(rest);
	if (!close) throw new Error("its front matter has no closing --- line");
	let data: unknown;
	try {
		data = Bun.YAML.parse(rest.slice(0, close.index)) ?? {};
	} catch (error) {
		throw new Error(
			`its front matter is not valid YAML: ${(error as Error).message}`,
		);
	}
	if (typeof data !== "object" || Array.isArray(data) || data === null) {
		throw new Error("its front matter is not a YAML mapping");
	}
	return {
		data: data as Record<string, unknown>,
		body: rest.slice(close.index + close[0].length),
	};
}

/** The text of the first nonempty level-one heading in MARKDOWN, or null.
 * Headings inside code fences do not count. */
export function firstHeading(markdown: string): string | null {
	let fence: string | null = null;
	let paragraph: string[] = [];
	for (const line of markdown.split(/\r?\n/)) {
		if (fence !== null) {
			const close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line)?.[1];
			if (close && close[0] === fence[0] && close.length >= fence.length)
				fence = null;
			continue;
		}
		const open = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
		const atx = /^ {0,3}#(?:[ \t]+|$)(.*)$/.exec(line)?.[1];
		const setext = /^ {0,3}=+[ \t]*$/.test(line);
		let text: string | null = null;
		if (open) fence = open;
		else if (atx !== undefined) text = atx.replace(/(?:^|[ \t]+)#+[ \t]*$/, "");
		else if (setext && paragraph.length > 0) text = paragraph.join("\n");
		else if (
			line.trim() &&
			!(paragraph.length === 0 && /^( {4}|\t)/.test(line))
		) {
			paragraph.push(line.trim());
			continue;
		}
		paragraph = [];
		const title = text && inlineText(text);
		if (title) return title;
	}
	return null;
}

/** Heading MARKDOWN as plain text, as it reads in the list. */
function inlineText(markdown: string): string {
	return render(`# ${markdown.replace(/\n/g, " ")}`)
		.replace(/<[^>]*>/g, "")
		.replace(
			/&(?:#(\d+)|#x([\da-f]+)|(amp|lt|gt|quot));/gi,
			(_, dec, hex, name) => {
				if (dec || hex)
					return String.fromCodePoint(
						Number.parseInt(dec ?? hex, dec ? 10 : 16),
					);
				return { amp: "&", lt: "<", gt: ">", quot: '"' }[name as string] ?? "";
			},
		)
		.trim();
}

/** Whether ID can name a task and its detail URL. */
function validId(id: string): boolean {
	return (
		!!id && id !== "." && id !== ".." && !id.includes("/") && !id.includes("\0")
	);
}

/** NAME, a file name or ID, in one Unicode form. macOS keeps names in either
 * form and treats both alike, so IDs take one of them, NFC, as Emacs does. */
function asId(name: string): string {
	return name.normalize("NFC");
}

/** The distinct IDs in the `depends_on` of front matter DATA, or null when
 * it is not a list of nonempty strings. */
function dependencies(data: Record<string, unknown>): string[] | null {
	if (!Object.hasOwn(data, "depends_on")) return [];
	const value = data.depends_on;
	if (
		!Array.isArray(value) ||
		!value.every((id) => typeof id === "string" && id !== "")
	) {
		return null;
	}
	return [...new Set(value.map(asId))];
}

/** What the saved TEXT of the candidate at LOCATION and SOURCE is. */
export function classify(
	location: string,
	source: string,
	text: string,
): Reading {
	let parsed: ReturnType<typeof frontMatter>;
	try {
		parsed = frontMatter(text);
	} catch (error) {
		return {
			kind: "problem",
			source,
			id: location,
			message: `Malformed front matter: ${(error as Error).message}.`,
		};
	}
	const { data, body } = parsed;
	if (!data || !Object.hasOwn(data, "status")) return { kind: "document" };
	const explicit = Object.hasOwn(data, "id");
	const id =
		explicit && typeof data.id === "string" && idPattern.test(data.id)
			? data.id
			: location;
	const problem = (message: string): Reading => ({
		kind: "problem",
		source,
		id,
		message,
	});
	const status = data.status;
	if (status !== "todo" && status !== "done") {
		return problem(
			`Invalid status ${JSON.stringify(status) ?? String(status)}: use todo or done.`,
		);
	}
	let title: string | null = null;
	if (Object.hasOwn(data, "title")) {
		if (typeof data.title !== "string" || !data.title.trim()) {
			return problem("Invalid title: it must be a nonempty string.");
		}
		title = data.title.trim();
	}
	if (explicit && id !== data.id) {
		return problem(
			`Invalid id ${JSON.stringify(data.id) ?? String(data.id)}: use lowercase letters and digits in words joined by single hyphens, such as fix-search-2.`,
		);
	}
	if (!validId(id)) {
		return problem(
			`The task ID ${JSON.stringify(id)}, its file or folder name, is empty or reserved. Give it an id in its front matter.`,
		);
	}
	const heading = title === null ? firstHeading(body) : null;
	return {
		kind: "task",
		task: {
			id,
			location,
			source,
			status,
			title: title ?? heading ?? id,
			headingTitle: heading !== null,
			dependsOn: dependencies(data),
			body,
		},
	};
}

async function read({ location, source }: Candidate): Promise<Reading> {
	try {
		return classify(location, source, await readFile(source, "utf8"));
	} catch (error) {
		return {
			kind: "problem",
			source,
			id: location,
			message: `The file could not be read (${errorCode(error) ?? String(error)}).`,
		};
	}
}

/** The candidate documents directly in ROOT. Symbolic links are not
 * followed, and names are compared exactly. */
async function candidates(root: string): Promise<Candidate[]> {
	const found: Candidate[] = [];
	for (const entry of await readdir(root, { withFileTypes: true })) {
		const location = asId(
			entry.isFile() ? entry.name.slice(0, -3) : entry.name,
		);
		if (entry.isFile() && entry.name.endsWith(".md")) {
			found.push({ location, source: join(root, entry.name) });
		} else if (entry.isDirectory()) {
			const folder = join(root, entry.name);
			try {
				const content = await readdir(folder, { withFileTypes: true });
				if (
					content.some((file) => file.isFile() && file.name === "content.md")
				) {
					found.push({ location, source: join(folder, "content.md") });
				}
			} catch {
				// An unreadable folder is supporting material, like any other.
			}
		}
	}
	return found;
}

/** TASKS split into those that are usable and the conflicts among the rest:
 * tasks sharing an ID or a location, and any task sharing one with those. */
function separate(tasks: Task[]): { usable: Task[]; conflicts: Conflict[] } {
	const parent = tasks.map((_, i) => i);
	const find = (i: number): number => {
		let top = i;
		while (parent[top] !== top) top = parent[top] ?? top;
		return top;
	};
	const first = new Map<string, number>();
	tasks.forEach((task, i) => {
		for (const key of [`id ${task.id}`, `location ${task.location}`]) {
			const other = first.get(key);
			if (other === undefined) first.set(key, i);
			else parent[find(i)] = find(other);
		}
	});
	const groups = new Map<number, Task[]>();
	tasks.forEach((task, i) => {
		groups.set(find(i), [...(groups.get(find(i)) ?? []), task]);
	});
	const usable: Task[] = [];
	const conflicts: Conflict[] = [];
	for (const group of groups.values()) {
		const [task, ...others] = group;
		if (!task) continue;
		if (others.length === 0) usable.push(task);
		else
			conflicts.push({
				ids: [...new Set(group.map((t) => t.id))].sort(byCodeUnit),
				sources: group.map((t) => t.source).sort(byCodeUnit),
			});
	}
	conflicts.sort((a, b) => byCodeUnit(a.ids[0] ?? "", b.ids[0] ?? ""));
	return { usable: usable.sort(byId), conflicts };
}

/** Read every candidate in ROOT, completed or not. */
async function discover(root: string): Promise<Index> {
	const readings = await Promise.all((await candidates(root)).map(read));
	const all: Task[] = [];
	const problems: Problem[] = [];
	for (const reading of readings) {
		if (reading.kind === "task") all.push(reading.task);
		else if (reading.kind === "problem") {
			const { kind: _, ...problem } = reading;
			problems.push(problem);
		}
	}
	problems.sort((a, b) => byCodeUnit(a.source, b.source));
	const { usable, conflicts } = separate(all);
	return {
		tasks: usable,
		byId: new Map(usable.map((task) => [task.id, task])),
		bySource: new Map(all.map((task) => [asId(task.source), task.id])),
		conflicts,
		problems,
	};
}

/** The cycles among TASKS, where each waits for the tasks WAITS gives: groups
 * of tasks that each wait for all the others, directly or not, and a task
 * that waits for itself. */
function cycles(tasks: Task[], waits: (task: Task) => Task[]): Task[][] {
	let visited = 0;
	const order = new Map<Task, number>();
	const low = new Map<Task, number>();
	const stack: Task[] = [];
	const found: Task[][] = [];
	const visit = (task: Task) => {
		order.set(task, visited);
		low.set(task, visited);
		visited++;
		stack.push(task);
		for (const other of waits(task)) {
			if (!order.has(other)) visit(other);
			else if (!stack.includes(other)) continue;
			low.set(task, Math.min(low.get(task) ?? 0, low.get(other) ?? 0));
		}
		if (low.get(task) !== order.get(task)) return;
		const component = stack.splice(stack.indexOf(task));
		if (component.length > 1 || waits(task).includes(task)) {
			found.push(component.sort(byId));
		}
	};
	for (const task of tasks) if (!order.has(task)) visit(task);
	return found.sort((a, b) => byCodeUnit(a[0]?.id ?? "", b[0]?.id ?? ""));
}

/** Resolve the dependencies in INDEX and order its unfinished tasks. */
function plan(index: Index): Plan {
	const conflicting = new Set(index.conflicts.flatMap(({ ids }) => ids));
	const invalid = new Set(index.problems.map(({ id }) => id));
	const prerequisites = new Map<Task, Reference[]>();
	const dependents = new Map<Task, Task[]>(index.tasks.map((t) => [t, []]));
	for (const task of index.tasks) {
		prerequisites.set(
			task,
			(task.dependsOn ?? []).map((id) => {
				const target = index.byId.get(id);
				if (target) {
					dependents.get(target)?.push(task);
					return { id, task: target, problem: null };
				}
				const problem = conflicting.has(id)
					? "is defined more than once"
					: invalid.has(id)
						? "is not a valid task"
						: "does not exist";
				return { id, task: null, problem };
			}),
		);
	}
	// Done prerequisites are satisfied and leave the graph, with their own.
	const unfinished = index.tasks.filter((task) => task.status === "todo");
	const waits = (task: Task) =>
		(prerequisites.get(task) ?? []).flatMap((reference) =>
			reference.task?.status === "todo" ? [reference.task] : [],
		);
	const loops = cycles(unfinished, waits);
	const broken = new Set([
		...unfinished.filter(
			(task) =>
				task.dependsOn === null ||
				prerequisites.get(task)?.some((reference) => !reference.task),
		),
		...loops.flat(),
	]);
	for (const task of broken) {
		for (const dependent of dependents.get(task) ?? []) {
			if (dependent.status === "todo") broken.add(dependent);
		}
	}
	// Order the rest, taking the smallest ID whenever there is a choice.
	const remaining = new Map(
		unfinished
			.filter((task) => !broken.has(task))
			.map((task) => [task, waits(task).length]),
	);
	const eligible = [...remaining].flatMap(([task, n]) => (n ? [] : [task]));
	const order: Task[] = [];
	for (let next = eligible.shift(); next; next = eligible.shift()) {
		order.push(next);
		for (const dependent of dependents.get(next) ?? []) {
			const count = remaining.get(dependent);
			if (count === undefined) continue;
			remaining.set(dependent, count - 1);
			if (count === 1) {
				eligible.push(dependent);
				eligible.sort(byId);
			}
		}
	}
	return {
		prerequisites,
		dependents,
		cycles: loops,
		order,
		stuck: unfinished.filter((task) => broken.has(task)),
	};
}

/** A root's index and plan, read once for one request. */
type Snapshot = Index & { plan: Plan };

async function snapshot(root: string): Promise<Snapshot> {
	const index = await discover(root);
	return { ...index, plan: plan(index) };
}

/** Whether TASK, unfinished, can be started now. */
function ready({ plan }: Snapshot, task: Task): boolean {
	return (
		task.dependsOn !== null &&
		(plan.prerequisites.get(task) ?? []).every(
			(reference) => reference.task?.status === "done",
		)
	);
}

/** Why TASK, unfinished, cannot be started now, in short phrases. */
function blockers({ plan }: Snapshot, task: Task): string[] {
	const cycle = plan.cycles.find((members) => members.includes(task)) ?? [];
	const reasons: string[] = [];
	if (task.dependsOn === null) reasons.push("invalid depends_on");
	for (const { id, task: target, problem } of plan.prerequisites.get(task) ??
		[]) {
		if (!target) reasons.push(`${id} (${problem})`);
		else if (target.status === "todo" && !cycle.includes(target))
			reasons.push(target.title);
	}
	const others = cycle.filter((member) => member !== task);
	if (cycle.length === 1) reasons.push("a cycle on itself");
	else if (others.length > 0)
		reasons.push(`a cycle with ${and(others.map((t) => t.id))}`);
	return reasons;
}

/** Why ROOT cannot list tasks, as a page, or null when it can. */
async function unusable(root: string): Promise<Response | null> {
	try {
		if ((await stat(root)).isDirectory()) return null;
		return failure("The task root is a file, not a folder.", root, 400);
	} catch (error) {
		const code = errorCode(error);
		if (code === "ENOENT") {
			return page(
				"Tasks",
				`${header(root)}<p class="empty">This task folder does not exist yet. ` +
					"Create it and save a Markdown file there with <code>status: todo</code> " +
					"in its front matter, then press <kbd>g</kbd> to reload.</p>",
				200,
				styles,
			);
		}
		if (code === "ENOTDIR")
			return failure("A parent of the task root is a file.", root, 400);
		if (code === "EACCES" || code === "EPERM") {
			return failure("The task root is not readable.", root, 403);
		}
		throw error;
	}
}

function header(root: string, filter = ""): string {
	return `<header class="tasks-header"><h1>Tasks</h1>${filter}<p class="root"><code>${html(root)}</code></p></header>`;
}

function failure(message: string, root: string, status: number): Response {
	return page(
		"Tasks unavailable",
		`${header(root)}<p class="error">${html(message)}</p>`,
		status,
		styles,
	);
}

function badge(status: Status): string {
	return `<span class="status status-${status}">${status}</span>`;
}

function source(path: string): string {
	return `<code>${html(path)}</code>`;
}

function idLink(root: string, id: string, all: boolean): string {
	return `<a href="${html(taskHref(root, id, all))}">${html(id)}</a>`;
}

function and(items: string[]): string {
	return items.length < 3
		? items.join(" and ")
		: `${items.slice(0, -1).join(", ")}, and ${items.at(-1)}`;
}

function problemList(root: string, found: Snapshot, all: boolean): string {
	const id = (task: Task) => idLink(root, task.id, all);
	const items = [
		...found.conflicts.map(({ ids, sources }) =>
			ids.length === 1
				? `<li>${idLink(root, ids[0] ?? "", all)} is defined more than once: ` +
					`${and(sources.map(source))}</li>`
				: `<li>${and(ids.map((i) => idLink(root, i, all)))} conflict: ` +
					`${and(sources.map(source))} share a task ID or location</li>`,
		),
		...found.problems.map(
			(problem) =>
				`<li>${source(problem.source)}: ${html(problem.message)}</li>`,
		),
		...found.tasks.flatMap((task) => {
			const at = `<li>${source(task.source)} (${id(task)}): `;
			if (task.dependsOn === null)
				return [`${at}Invalid depends_on: use a YAML list of task IDs.</li>`];
			return (found.plan.prerequisites.get(task) ?? []).flatMap(
				({ id: target, problem }) =>
					problem
						? [
								`${at}It depends on <code>${html(target)}</code>, which ${html(problem)}.</li>`,
							]
						: [],
			);
		}),
		...found.plan.cycles.map(([first, ...others]) =>
			first && others.length === 0
				? `<li>${source(first.source)} (${id(first)}): It depends on itself.</li>`
				: `<li>${and([first, ...others].flatMap((t) => (t ? [id(t)] : [])))} ` +
					"depend on each other in a cycle: " +
					`${and([first, ...others].flatMap((t) => (t ? [source(t.source)] : [])))}</li>`,
		),
	];
	return items.length === 0
		? ""
		: `<section class="problems"><h2>Problems</h2><ul>${items.join("")}</ul></section>`;
}

/** TASK's row in the list, with its execution position RANK when it has one. */
function row(
	root: string,
	found: Snapshot,
	task: Task,
	all: boolean,
	rank?: number,
): string {
	let readiness = "";
	if (task.status === "todo") {
		readiness = ready(found, task)
			? `<span class="readiness readiness-ready">Ready</span>`
			: `<span class="readiness readiness-blocked">Blocked by ${html(and(blockers(found, task)))}</span>`;
	}
	return (
		`<li><a href="${html(taskHref(root, task.id, all))}">` +
		(rank === undefined ? "" : `<span class="rank">${rank}</span>`) +
		`${badge(task.status)}<span class="title">${html(task.title)}</span>${readiness}</a></li>`
	);
}

function list(root: string, found: Snapshot, all: boolean): Response {
	const { order, stuck } = found.plan;
	const toggle = `<p class="filter"><a href="${html(listHref(root, !all))}">${all ? "Hide completed" : "Show completed"}</a></p>`;
	const rows = (tasks: Task[], ranked = false) =>
		tasks
			.map((task, i) => row(root, found, task, all, ranked ? i + 1 : undefined))
			.join("");
	let content = "";
	if (order.length > 0) {
		content += `<ol class="tasks">${rows(order, true)}</ol>`;
	} else if (stuck.length > 0) {
		content += `<p class="empty">No task can be ordered until its dependency problems are fixed.</p>`;
	}
	if (stuck.length > 0) {
		content +=
			`<section class="stuck"><h2>Blocked by dependency problems</h2>` +
			`<ul class="tasks">${rows(stuck)}</ul></section>`;
	}
	const done = found.tasks.filter((task) => task.status === "done");
	if (found.tasks.length === 0) {
		content = `<p class="empty">No tasks</p>`;
	} else if (order.length + stuck.length === 0) {
		content = all
			? `<p class="empty">No unfinished tasks.</p>`
			: `<p class="empty">No unfinished tasks. <a href="${html(listHref(root, true))}">Show completed</a></p>`;
	}
	if (all && done.length > 0) {
		content += `<section class="completed"><h2>Completed</h2><ul class="tasks">${rows(done)}</ul></section>`;
	}
	return page(
		"Tasks",
		header(root, toggle) + problemList(root, found, all) + content,
		200,
		styles,
	);
}

/** A detail page's recoverable error, with a way back to the task list. */
function detailFailure(
	root: string,
	all: boolean,
	body: string,
	status: number,
): Response {
	return page(
		"Task unavailable",
		`<nav class="task-nav"><a href="${html(listHref(root, all))}">Tasks</a></nav>` +
			`<h1>Task unavailable</h1>${body}`,
		status,
		styles,
	);
}

/** Whether PATH is BASE or inside it. Both are real paths. */
function inside(path: string, base: string): boolean {
	const rest = relative(base, path);
	return (
		rest === "" ||
		(rest !== ".." && !rest.startsWith(`..${sep}`) && !isAbsolute(rest))
	);
}

/** TASK's body as HTML, with local links and images made to work here. */
function body(root: string, found: Snapshot, task: Task, all: boolean): string {
	const realRoot = realpathSync(root);
	const base = realpathSync(dirname(task.source));
	// Emacs visits the file under the root it named, in its Unicode form.
	const named = (real: string) =>
		join(root, relative(realRoot, real)).normalize("NFC");
	const broken = (link: HTMLRewriterTypes.Element, reason: string) => {
		link.removeAttribute("href");
		link.setAttribute("class", "broken-link");
		link.setAttribute("title", reason);
	};
	return new HTMLRewriter()
		.on("a[href]", {
			element(link) {
				const target = localTarget(attribute(link, "href"), task.source);
				if (!target) return;
				let real: string;
				try {
					real = realpathSync(target.file);
				} catch {
					return broken(link, "The linked file does not exist.");
				}
				// Only a discovered task's source, by its exact name, is a task.
				const id = inside(real, realRoot)
					? found.bySource.get(named(real))
					: undefined;
				// HTMLRewriter escapes only quotes in the values it writes.
				if (id !== undefined) {
					link.setAttribute(
						"href",
						taskHref(root, id, all, target.hash).replaceAll("&", "&amp;"),
					);
				} else if (inside(real, base)) {
					link.setAttribute(
						"href",
						(pathToFileURL(named(real)).href + target.hash).replaceAll(
							"&",
							"&amp;",
						),
					);
				} else {
					broken(link, "The link leads outside this task's folder.");
				}
			},
		})
		.on("img[src]", {
			element(image) {
				const target = localTarget(attribute(image, "src"), task.source);
				if (!target) return;
				const src = `tasks/file?root=${encode(root)}&task=${encode(task.id)}&path=${encode(target.file)}`;
				image.setAttribute("src", src.replaceAll("&", "&amp;"));
			},
		})
		.transform(render(task.body));
}

/** Task ID in FOUND, or the page that explains why it cannot be shown. */
function resolve(
	root: string,
	found: Index,
	id: string,
	all: boolean,
): Task | Response {
	const wanted = asId(id);
	if (!validId(wanted)) {
		return detailFailure(root, all, "<p>This is not a valid task ID.</p>", 400);
	}
	const task = found.byId.get(wanted);
	if (task) return task;
	const conflicts = found.conflicts.filter(({ ids }) => ids.includes(wanted));
	if (conflicts.length > 0) {
		const sources = [...new Set(conflicts.flatMap((c) => c.sources))];
		return detailFailure(
			root,
			all,
			`<p>Task ${source(wanted)} is defined more than once, or shares its location with another task. Keep one of these and reload:</p>` +
				`<ul>${sources.map((path) => `<li>${source(path)}</li>`).join("")}</ul>`,
			409,
		);
	}
	const problems = found.problems.filter((problem) => problem.id === wanted);
	if (problems.length > 0) {
		return detailFailure(
			root,
			all,
			`<ul>${problems
				.map(
					(problem) =>
						`<li>${source(problem.source)}: ${html(problem.message)}</li>`,
				)
				.join("")}</ul>`,
			422,
		);
	}
	return detailFailure(
		root,
		all,
		`<p>There is no task ${source(wanted)} in this folder.</p>`,
		404,
	);
}

/** TASK as a link, with its ID and saved status. */
function reference(root: string, task: Task, all: boolean): string {
	return (
		`<li><a href="${html(taskHref(root, task.id, all))}">${html(task.title)}</a> ` +
		`<code>${html(task.id)}</code> ${badge(task.status)}</li>`
	);
}

/** TASK's ID and the tasks it depends on and blocks. */
function metadata(
	root: string,
	found: Snapshot,
	task: Task,
	all: boolean,
): string {
	const { prerequisites, dependents, cycles } = found.plan;
	let items = `<dt>ID</dt><dd><code>${html(task.id)}</code></dd>`;
	if (task.dependsOn === null) {
		items +=
			`<dt>Depends on</dt><dd class="dependency-problem">Its <code>depends_on</code> ` +
			"is invalid: use a YAML list of task IDs.</dd>";
	} else if (task.dependsOn.length > 0) {
		const references = (prerequisites.get(task) ?? []).map(
			({ id, task: target, problem }) =>
				target
					? reference(root, target, all)
					: `<li><code>${html(id)}</code> <span class="dependency-problem">This task ${html(problem ?? "")}.</span></li>`,
		);
		items += `<dt>Depends on</dt><dd><ul class="references">${references.join("")}</ul></dd>`;
	}
	const cycle = cycles.find((members) => members.includes(task));
	if (cycle) {
		const others = cycle.filter((member) => member !== task);
		items +=
			`<dt>Cycle</dt><dd class="dependency-problem">` +
			(others.length === 0
				? "It depends on itself."
				: `It depends on itself through ${and(others.map((t) => idLink(root, t.id, all)))}.`) +
			"</dd>";
	}
	const blocked = dependents.get(task) ?? [];
	if (blocked.length > 0) {
		items += `<dt>Blocks</dt><dd><ul class="references">${blocked
			.map((dependent) => reference(root, dependent, all))
			.join("")}</ul></dd>`;
	}
	return `<dl class="task-meta">${items}</dl>`;
}

function detail(
	root: string,
	found: Snapshot,
	id: string,
	all: boolean,
): Response {
	const task = resolve(root, found, id, all);
	if (task instanceof Response) return task;
	const title = task.headingTitle ? "" : `<h1>${html(task.title)}</h1>`;
	let readiness = "";
	if (task.status === "todo") {
		readiness = ready(found, task)
			? `<span class="readiness readiness-ready">ready</span>`
			: `<span class="readiness readiness-blocked">blocked</span>`;
	}
	return page(
		task.title,
		`<nav class="task-nav"><a href="${html(listHref(root, all))}">Tasks</a>` +
			`<span class="task-state">${badge(task.status)}${readiness}</span></nav>` +
			metadata(root, found, task, all) +
			`<article>${title}${body(root, found, task, all)}</article>`,
		200,
		styles,
	);
}

function validRoot(root: string | null): root is string {
	return !!root && isAbsolute(root) && !root.includes("\0");
}

/** The task list or, with `task`, one task's detail page. */
export async function tasks(params: URLSearchParams): Promise<Response> {
	const root = params.get("root");
	if (!validRoot(root)) {
		return page(
			"Tasks unavailable",
			"<p>Provide an absolute task folder.</p>",
			400,
			styles,
		);
	}
	const all = params.get("show") === "all";
	const id = params.get("task");
	try {
		const problem = await unusable(root);
		if (problem) return problem;
		const found = await snapshot(root);
		return id === null ? list(root, found, all) : detail(root, found, id, all);
	} catch (error) {
		const code = errorCode(error);
		if (code === "EACCES" || code === "EPERM") {
			return failure("The task root is not readable.", root, 403);
		}
		console.error("Task browser failed:", error);
		return failure("The tasks could not be read.", root, 500);
	}
}

/** An image in a task's attachment folder, for its detail page. */
export async function taskFile(params: URLSearchParams): Promise<Response> {
	const root = params.get("root");
	const id = params.get("task");
	const path = params.get("path");
	const refuse = (status: number) => new Response(null, { status });
	if (
		!validRoot(root) ||
		id === null ||
		!path ||
		!isAbsolute(path) ||
		path.includes("\0")
	) {
		return refuse(400);
	}
	try {
		const task = resolve(root, await discover(root), id, false);
		if (task instanceof Response) return refuse(404);
		const real = await realpath(path);
		// A task's attachments are beside its source: the root for a file.
		if (!inside(real, await realpath(dirname(task.source)))) return refuse(403);
		const type = images[extname(real).toLowerCase()];
		if (!type) return refuse(415);
		if (!(await stat(real)).isFile()) return refuse(404);
		return new Response(Bun.file(real), {
			headers: {
				"Content-Type": type,
				// Opened on its own, an SVG must not run scripts on the app host.
				"Content-Security-Policy":
					"default-src 'none'; style-src 'unsafe-inline'; sandbox",
			},
		});
	} catch (error) {
		const code = errorCode(error);
		if (code === "ENOENT" || code === "ENOTDIR") return refuse(404);
		if (code === "EACCES" || code === "EPERM") return refuse(403);
		console.error("Task attachment failed:", error);
		return refuse(500);
	}
}
