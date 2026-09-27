// SPDX-License-Identifier: GPL-3.0-or-later
// The task browser: saved Markdown tasks in one task root, read on each request.
// A task is a Markdown file at any depth under the root, with a `status` in its
// front matter. A folder's content.md is that folder's own task. Its location
// is its root-relative path without `.md` or `/content.md`; its ID is its
// front matter `id`, or else that location.
import { type Dirent, realpathSync } from "node:fs";
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";
import type { HostActions } from "./actions";
import { attribute, localTarget, page, render } from "./markdown";
import styles from "./tasks.css" with { type: "text" };
import { client } from "./tasks-client";

type Status = "todo" | "done";
type Task = {
	/** The effective ID: the front matter `id`, or else the location. */
	id: string;
	/** Its logical path in the root: `a/b` for a/b.md or a/b/content.md. */
	location: string;
	source: string;
	/** Whether it is its folder's content.md, and so that folder's task. */
	folder: boolean;
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
type Candidate = { location: string; source: string; folder: boolean };
/** Task documents sharing an ID or a location, none of which is used. */
type Conflict = { ids: string[]; sources: string[] };

/** Every task in a root, read once for one request. */
type Index = {
	/** The tasks with a unique ID and location, ordered by ID. */
	tasks: Task[];
	byId: Map<string, Task>;
	/** The effective ID of every task document, conflicting or not, by source. */
	bySource: Map<string, string>;
	/** The usable tasks that are a folder's content.md, by location. */
	byFolder: Map<string, Task>;
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

/** Every task page's script, as source text. */
const script = `(${client})();`;

/** A task browser page. Its script is its only code; task content runs none. */
function taskPage(title: string, body: string, status = 200): Response {
	return page(title, body, status, { css: styles, script });
}

function isStatus(value: unknown): value is Status {
	return value === "todo" || value === "done";
}

function byCodeUnit(a: string, b: string): number {
	return a < b ? -1 : a > b ? 1 : 0;
}

function byId(a: Task, b: Task): number {
	return byCodeUnit(a.id, b.id);
}

/** What the list shows: a root, in the tree or execution view, with or
 * without completed tasks. Every task browser link keeps it. */
type Listing = {
	root: string;
	execution: boolean;
	all: boolean;
	context?: string;
	/** Whether its Portal view is registered to change and open tasks. */
	operable?: boolean;
};

function listHref(
	{ root, execution, all, context }: Listing,
	id?: string,
): string {
	return (
		`tasks?root=${encode(root)}` +
		(id === undefined ? "" : `&task=${encode(id)}`) +
		(execution ? "&view=execution" : "") +
		(all ? "&show=all" : "") +
		(context ? `&context=${encode(context)}` : "")
	);
}

function taskHref(listing: Listing, id: string, hash = ""): string {
	return listHref(listing, id) + hash;
}

/** The fragment of folder LOCATION's row in the tree view. */
function folderAnchor(location: string): string {
	return `folder-${encode(location)}`;
}

function errorCode(error: unknown): string | undefined {
	return (error as NodeJS.ErrnoException).code;
}

/** Where the YAML of TEXT's front matter starts and ends, and its body starts,
 * as offsets into TEXT; or null without front matter. Throws when unclosed. */
function frontMatterSpan(
	text: string,
): { start: number; end: number; body: number } | null {
	const bom = text.startsWith("﻿") ? 1 : 0;
	const open = /^---\r?\n/.exec(text.slice(bom));
	if (!open) return null;
	const start = bom + open[0].length;
	const close = /^---\r?(?:\n|$)/m.exec(text.slice(start));
	if (!close) throw new Error("its front matter has no closing --- line");
	const end = start + close.index;
	return { start, end, body: end + close[0].length };
}

/** Split TEXT into its YAML front matter, or null without any, and its body.
 * Throws when the front matter is malformed. */
export function frontMatter(text: string): {
	data: Record<string, unknown> | null;
	body: string;
} {
	const span = frontMatterSpan(text);
	if (!span) return { data: null, body: text.replace(/^﻿/, "") };
	let data: unknown;
	try {
		data = Bun.YAML.parse(text.slice(span.start, span.end)) ?? {};
	} catch (error) {
		throw new Error(
			`its front matter is not valid YAML: ${(error as Error).message}`,
		);
	}
	if (typeof data !== "object" || Array.isArray(data) || data === null) {
		throw new Error("its front matter is not a YAML mapping");
	}
	return { data: data as Record<string, unknown>, body: text.slice(span.body) };
}

/** The edit that gives TASK STATUS, planned from BYTES read from its source
 * after discovery found it there; or null when it has STATUS already. Throws
 * when BYTES are no longer that task, such as after another replaced it. */
export function statusChange(
	task: Candidate & { id: string },
	bytes: Buffer,
	status: Status,
): { start: number; end: number; text: string } | null {
	const reading = classify(task, bytes.toString("utf8"));
	if (reading.kind !== "task" || reading.task.id !== task.id)
		throw new Error(
			"The task file changed while the action ran. Reload the page and try again.",
		);
	return reading.task.status === status ? null : statusEdit(bytes, status);
}

/** A `status` key and its todo or done value, plain or quoted, in block or
 * flow style: the only form the status edit changes. */
const statusEntry =
	/(?<=^[ \t]*|[{,][ \t]*)(?:status|'status'|"status")[ \t]*:[ \t]*(todo|done|'todo'|'done'|"todo"|"done")(?=[ \t]*(?:[,}#]|\r?$))/gm;

/** The edit that gives the task document BYTES STATUS, touching nothing but
 * its status value: bytes START to END become TEXT. Throws, explaining why,
 * when the edit would be ambiguous or would change anything else; the
 * document is then left for editing in Emacs. */
export function statusEdit(
	bytes: Uint8Array,
	status: Status,
): { start: number; end: number; text: string } {
	let text: string;
	try {
		text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
			bytes,
		);
	} catch {
		throw new Error("The task file is not valid UTF-8. Edit it in Emacs.");
	}
	const before = frontMatter(text);
	const span = frontMatterSpan(text);
	if (!before.data || !span || !Object.hasOwn(before.data, "status"))
		throw new Error("The task file has no status. Reload the page.");
	const entries = [...text.slice(span.start, span.end).matchAll(statusEntry)];
	const [entry] = entries;
	const value = entry?.[1];
	if (!entry || value === undefined)
		throw new Error(
			"The task's status is not written as a plain `status: todo` or `status: done` entry, so it cannot be changed safely. Edit it in Emacs.",
		);
	// With this entry's key renamed, no status may remain: YAML keeps only the
	// last of duplicate keys, however each is written.
	const key = span.start + entry.index;
	const renamed = `${text.slice(0, key)}portal-probe${text.slice(key + entry[0].indexOf(":"))}`;
	let probe: Record<string, unknown> | null = null;
	try {
		probe = frontMatter(renamed).data;
	} catch {}
	if (entries.length > 1 || !probe || Object.hasOwn(probe, "status"))
		throw new Error(
			"The task's front matter has more than one status entry, so the change would be ambiguous. Edit it in Emacs.",
		);
	const start = span.start + entry.index + entry[0].length - value.length;
	const replacement = value.replace(/todo|done/, status);
	const patched =
		text.slice(0, start) + replacement + text.slice(start + value.length);
	// Accept the edit only if it reads back as the same document, but for status.
	let after: ReturnType<typeof frontMatter> | null = null;
	try {
		after = frontMatter(patched);
	} catch {}
	if (
		!after?.data ||
		after.body !== before.body ||
		!Bun.deepEquals(after.data, { ...before.data, status }, true)
	) {
		throw new Error(
			"Changing the status would change other front matter, so it was not saved. Edit it in Emacs.",
		);
	}
	const offset = Buffer.byteLength(text.slice(0, start));
	return {
		start: offset,
		end: offset + Buffer.byteLength(value),
		text: replacement,
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

/** Whether ID can name a task and its detail URL: `/`-separated segments,
 * none empty, `.` or `..`. It is never used as a path. */
function validId(id: string): boolean {
	return (
		!id.includes("\0") &&
		id.split("/").every((segment) => !["", ".", ".."].includes(segment))
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

/** What the saved TEXT of a candidate document is. */
export function classify(
	{ location, source, folder }: Candidate,
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
	if (!isStatus(status)) {
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
			folder,
			status,
			title: title ?? heading ?? id,
			headingTitle: heading !== null,
			dependsOn: dependencies(data),
			body,
		},
	};
}

async function read(candidate: Candidate): Promise<Reading> {
	try {
		return classify(candidate, await readFile(candidate.source, "utf8"));
	} catch (error) {
		return {
			kind: "problem",
			source: candidate.source,
			id: candidate.location,
			message: `The file could not be read (${errorCode(error) ?? String(error)}).`,
		};
	}
}

/** How many folders and files discovery reads at once. */
const concurrency = 16;

/** Run WORK on each of JOBS, and on each job it adds, LIMIT at a time.
 * Rejects with the first failure. */
function drain<Job>(
	jobs: Job[],
	limit: number,
	work: (job: Job, add: (job: Job) => void) => Promise<void>,
): Promise<void> {
	return new Promise((resolve, reject) => {
		let active = 0;
		let failed = false;
		const next = () => {
			while (!failed && active < limit && jobs.length > 0) {
				const job = jobs.pop() as Job;
				active++;
				work(job, add).then(
					() => {
						active--;
						next();
					},
					(error) => {
						failed = true;
						reject(error);
					},
				);
			}
			if (active === 0 && jobs.length === 0) resolve();
		};
		const add = (job: Job) => {
			jobs.push(job);
			next();
		};
		next();
	});
}

/** A folder to list, at its logical path LOCATION, or a document to read. */
type Job = { directory: string; location: string } | Candidate;

/** The job for ENTRY in folder JOB: a folder, a candidate document, or
 * nothing. Symbolic links are not followed, and names are compared exactly. */
function entryJob(
	job: { directory: string; location: string },
	entry: Dirent,
): Job | null {
	const path = join(job.directory, entry.name);
	const name = asId(entry.name);
	const prefix = job.location ? `${job.location}/` : "";
	if (entry.isDirectory()) return { directory: path, location: prefix + name };
	if (!entry.isFile() || !entry.name.endsWith(".md")) return null;
	// A folder's content.md is its task; the root's is a task of its own.
	if (entry.name === "content.md" && job.location) {
		return { location: job.location, source: path, folder: true };
	}
	return { location: prefix + name.slice(0, -3), source: path, folder: false };
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

/** Read every candidate at any depth in ROOT, completed or not. An
 * unreadable folder below ROOT is a problem; the other folders still load. */
async function discover(root: string): Promise<Index> {
	const all: Task[] = [];
	const problems: Problem[] = [];
	await drain<Job>(
		[{ directory: root, location: "" }],
		concurrency,
		async (job, add) => {
			if ("source" in job) {
				const reading = await read(job);
				if (reading.kind === "task") all.push(reading.task);
				else if (reading.kind === "problem") {
					const { kind: _, ...problem } = reading;
					problems.push(problem);
				}
				return;
			}
			let entries: Dirent[];
			try {
				entries = await readdir(job.directory, { withFileTypes: true });
			} catch (error) {
				if (!job.location) throw error;
				problems.push({
					source: job.directory,
					message: `The folder could not be read (${errorCode(error) ?? String(error)}).`,
				});
				return;
			}
			for (const entry of entries) {
				const next = entryJob(job, entry);
				if (next) add(next);
			}
		},
	);
	problems.sort((a, b) => byCodeUnit(a.source, b.source));
	const { usable, conflicts } = separate(all);
	return {
		tasks: usable,
		byId: new Map(usable.map((task) => [task.id, task])),
		bySource: new Map(all.map((task) => [asId(task.source), task.id])),
		byFolder: new Map(
			usable.flatMap((task) => (task.folder ? [[task.location, task]] : [])),
		),
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

/** The most prerequisites a list row names before summarizing the rest. */
const shownPrerequisites = 3;

/** What TASK, unfinished, waits for, as short text for its list row, or ""
 * when it is ready: its unfinished prerequisites by RANKS, nearest first, then
 * by ID, and then its own dependency problems, which PROBLEM reports. */
function waits(
	{ plan }: Snapshot,
	task: Task,
	ranks: Map<Task, number>,
): { text: string; problem: boolean } {
	const cycle = plan.cycles.find((members) => members.includes(task)) ?? [];
	const ranked: number[] = [];
	const unranked: string[] = [];
	const problems: string[] = [];
	if (task.dependsOn === null) problems.push("invalid depends_on");
	for (const { id, task: target, problem } of plan.prerequisites.get(task) ??
		[]) {
		if (!target) problems.push(`${id} (${problem})`);
		else if (target.status === "todo" && !cycle.includes(target)) {
			const rank = ranks.get(target);
			if (rank === undefined) unranked.push(target.id);
			else ranked.push(rank);
		}
	}
	const others = cycle.filter((member) => member !== task);
	if (cycle.length === 1) problems.push("a cycle on itself");
	else if (others.length > 0)
		problems.push(`a cycle with ${and(others.map((t) => t.id))}`);
	const refs = [...ranked.sort((a, b) => b - a).map(String), ...unranked];
	const parts = [...problems];
	if (refs.length > 0) {
		const rest = refs.length - shownPrerequisites;
		parts.unshift(
			`after ${refs.slice(0, shownPrerequisites).join(", ")}${rest > 0 ? ` +${rest}` : ""}`,
		);
	}
	return { text: parts.join(" · "), problem: problems.length > 0 };
}

/** Why ROOT cannot list tasks, as a page, or null when it can. */
async function unusable(root: string): Promise<Response | null> {
	try {
		if ((await stat(root)).isDirectory()) return null;
		return failure("The task root is a file, not a folder.", root, 400);
	} catch (error) {
		const code = errorCode(error);
		if (code === "ENOENT") {
			return taskPage(
				"Tasks",
				`${header(root)}<p class="empty">This task folder does not exist yet. ` +
					"Create it and save a Markdown file there with <code>status: todo</code> " +
					"in its front matter, then press <kbd>g</kbd> to reload.</p>",
				200,
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

function header(root: string, controls = ""): string {
	return `<header class="tasks-header"><h1>Tasks</h1>${controls}<p class="root"><code>${html(root)}</code></p></header>`;
}

function failure(message: string, root: string, status: number): Response {
	return taskPage(
		"Tasks unavailable",
		`${header(root)}<p class="error">${html(message)}</p>`,
		status,
	);
}

function badge(status: Status): string {
	return `<span class="status status-${status}">${status}</span>`;
}

function source(path: string): string {
	return `<code>${html(path)}</code>`;
}

function idLink(listing: Listing, id: string): string {
	return `<a href="${html(taskHref(listing, id))}">${html(id)}</a>`;
}

function and(items: string[]): string {
	return items.length < 3
		? items.join(" and ")
		: `${items.slice(0, -1).join(", ")}, and ${items.at(-1)}`;
}

function problemList(listing: Listing, found: Snapshot): string {
	const id = (task: Task) => idLink(listing, task.id);
	const items = [
		...found.conflicts.map(({ ids, sources }) =>
			ids.length === 1
				? `<li>${idLink(listing, ids[0] ?? "")} is defined more than once: ` +
					`${and(sources.map(source))}</li>`
				: `<li>${and(ids.map((i) => idLink(listing, i)))} conflict: ` +
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

/** The folders holding TASK, outermost first: each folder's location, and
 * its name or, when it is a task's folder, that task. */
function folders(
	found: Snapshot,
	task: Task,
): { location: string; name: string; task: Task | undefined }[] {
	const names = task.location.split("/").slice(0, -1);
	return names.map((name, i) => {
		const location = names.slice(0, i + 1).join("/");
		return { location, name, task: found.byFolder.get(location) };
	});
}

/** TASK's Complete or Reopen and Edit in Emacs buttons, which the page script
 * runs. In a list ROW, their names include the task's title. WebKit tabs to
 * buttons only with an explicit tabindex, unless macOS keyboard navigation
 * is on. */
function operations(task: Task, row: boolean): string {
	const status: Status = task.status === "todo" ? "done" : "todo";
	const verb = status === "done" ? "Complete" : "Reopen";
	const data = `class="task-op" tabindex="0" data-task="${html(task.id)}" data-title="${html(task.title)}"`;
	const named = (label: string) => (row ? ` aria-label="${html(label)}"` : "");
	return (
		`<button type="button" ${data} data-op="status" data-status="${status}"` +
		`${named(`${verb} ${task.title}`)}>${verb}</button>` +
		`<button type="button" ${data} data-op="edit"` +
		`${named(`Edit ${task.title} in Emacs`)}${row ? ` title="Edit in Emacs"` : ""}>` +
		`${row ? "Edit" : "Edit in Emacs"}</button>`
	);
}

/** TASK's row, a link to its page, with RANKS giving execution positions, and
 * then its buttons. A blocked row is dimmed and says what it waits for, and a
 * completed row's title is struck through. The execution view shows the
 * folders holding it; the tree, which mixes statuses, marks it done. */
function row(
	listing: Listing,
	found: Snapshot,
	task: Task,
	ranks: Map<Task, number>,
): string {
	const rank = ranks.get(task);
	const { text, problem } =
		task.status === "todo"
			? waits(found, task, ranks)
			: { text: "", problem: false };
	const path = listing.execution
		? folders(found, task).map((folder) => folder.task?.title ?? folder.name)
		: [];
	return (
		`<a class="row${text ? " blocked" : ""}${task.status === "done" ? " done" : ""}" href="${html(taskHref(listing, task.id))}">` +
		(rank === undefined ? "" : `<span class="rank">${rank}</span>`) +
		(!listing.execution && task.status === "done" ? badge(task.status) : "") +
		`<span class="title">${html(task.title)}</span>` +
		(path.length === 0
			? ""
			: `<span class="folder">${path.map(html).join(" › ")}</span>`) +
		(text
			? `<span class="waits${problem ? " dependency-problem" : ""}">${html(text)}</span>`
			: "") +
		"</a>" +
		(listing.operable
			? `<span class="row-actions">${operations(task, true)}</span>`
			: "")
	);
}

/** The execution view: unfinished tasks in order, then those with dependency
 * problems, then, when shown, completed tasks. */
function executionView(
	listing: Listing,
	found: Snapshot,
	ranks: Map<Task, number>,
): string {
	const { order, stuck } = found.plan;
	const rows = (tasks: Task[]) =>
		tasks
			.map((task) => `<li>${row(listing, found, task, ranks)}</li>`)
			.join("");
	let content = "";
	if (order.length > 0) {
		content += `<ol class="tasks">${rows(order)}</ol>`;
	} else if (stuck.length > 0) {
		content += `<p class="empty">No task can be ordered until its dependency problems are fixed.</p>`;
	} else {
		content += `<p class="empty">No unfinished tasks.</p>`;
	}
	if (stuck.length > 0) {
		content +=
			`<section class="stuck"><h2>Blocked by dependency problems</h2>` +
			`<ul class="tasks">${rows(stuck)}</ul></section>`;
	}
	const done = found.tasks.filter((task) => task.status === "done");
	if (listing.all && done.length > 0) {
		content += `<section class="completed"><h2>Completed</h2><ul class="tasks">${rows(done)}</ul></section>`;
	}
	return content;
}

/** A folder or a task in the tree. A folder is a group unless it has a TASK
 * of its own; a task file holds nothing, so its CHILDREN are null. */
type Node = {
	location: string;
	name: string;
	task: Task | null;
	children: Node[] | null;
};

/** The usable tasks in FOUND in their folders, under a nameless root. */
function tree(found: Snapshot): Node {
	const root: Node = { location: "", name: "", task: null, children: [] };
	const directories = new Map([["", root]]);
	const parent = (location: string) =>
		directory(location.slice(0, Math.max(location.lastIndexOf("/"), 0)));
	const directory = (location: string): Node => {
		let node = directories.get(location);
		if (!node) {
			const name = location.slice(location.lastIndexOf("/") + 1);
			node = { location, name, task: null, children: [] };
			directories.set(location, node);
			parent(location).children?.push(node);
		}
		return node;
	};
	for (const task of found.tasks) {
		if (task.folder) directory(task.location).task = task;
		else {
			const name = task.location.slice(task.location.lastIndexOf("/") + 1);
			parent(task.location).children?.push({
				location: task.location,
				name,
				task,
				children: null,
			});
		}
	}
	return root;
}

/** The shown part of a node, with the smallest execution rank in it. */
type Branch = { node: Node; children: Branch[]; rank: number };

/** Earliest rank first, then by location and, for a folder and a task
 * file at one location, the folder first. */
function byBranch(a: Branch, b: Branch): number {
	if (a.rank !== b.rank) return a.rank < b.rank ? -1 : 1;
	return (
		byCodeUnit(a.node.location, b.node.location) ||
		Number(a.node.children === null) - Number(b.node.children === null)
	);
}

/** What the tree shows of NODE, or null for nothing. A task shows when it is
 * unfinished or completed tasks are shown, and a completed task still shows
 * above the tasks in its folder that do. A group shows only around tasks. */
function prune(
	node: Node,
	listing: Listing,
	ranks: Map<Task, number>,
): Branch | null {
	const children = (node.children ?? [])
		.flatMap((child) => prune(child, listing, ranks) ?? [])
		.sort(byBranch);
	const shown =
		node.task !== null && (listing.all || node.task.status === "todo");
	if (!shown && children.length === 0) return null;
	const own = (node.task && ranks.get(node.task)) ?? Infinity;
	const rank = Math.min(own, ...children.map((child) => child.rank));
	return { node, children, rank };
}

/** BRANCH as a tree item: a task row or a group name, and a disclosure of
 * what it holds. */
function treeItem(
	listing: Listing,
	found: Snapshot,
	{ node, children }: Branch,
	ranks: Map<Task, number>,
): string {
	const items = children
		.map((child) => treeItem(listing, found, child, ranks))
		.join("");
	const inner = `<ul class="tree">${items}</ul>`;
	const anchor = `id="${html(folderAnchor(node.location))}"`;
	if (!node.task) {
		return (
			`<li class="group" ${anchor}><details open>` +
			`<summary class="row"><span class="name">${html(node.name)}</span></summary>` +
			`${inner}</details></li>`
		);
	}
	const link = row(listing, found, node.task, ranks);
	if (children.length === 0) return `<li class="task">${link}</li>`;
	return (
		`<li class="task parent" ${anchor}>${link}<details open>` +
		`<summary class="toggle" aria-label="Tasks in ${html(node.task.title)}"></summary>` +
		`${inner}</details></li>`
	);
}

/** The tree view: every shown task once, in its folders. */
function treeView(
	listing: Listing,
	found: Snapshot,
	ranks: Map<Task, number>,
): string {
	const root = prune(tree(found), listing, ranks);
	const items = (root?.children ?? [])
		.map((branch) => treeItem(listing, found, branch, ranks))
		.join("");
	return (
		`<p class="view-note">Browsing by folder: each folder follows its earliest ` +
		`task in the execution order, which only the Execution view lists in order.</p>` +
		`<ul class="tree">${items}</ul>`
	);
}

/** The view switch and the completion filter. */
function controls(listing: Listing): string {
	const view = (execution: boolean, label: string) =>
		listing.execution === execution
			? `<span aria-current="page">${label}</span>`
			: `<a href="${html(listHref({ ...listing, execution }))}">${label}</a>`;
	return (
		`<nav class="views" aria-label="View">${view(false, "Tree")}${view(true, "Execution")}</nav>` +
		`<p class="filter"><a href="${html(listHref({ ...listing, all: !listing.all }))}">` +
		`${listing.all ? "Hide completed" : "Show completed"}</a></p>`
	);
}

function list(listing: Listing, found: Snapshot): Response {
	const { order, stuck } = found.plan;
	const ranks = new Map(order.map((task, i) => [task, i + 1]));
	let content: string;
	if (found.tasks.length === 0) {
		content = `<p class="empty">No tasks</p>`;
	} else if (!listing.all && order.length + stuck.length === 0) {
		content = `<p class="empty">No unfinished tasks. <a href="${html(listHref({ ...listing, all: true }))}">Show completed</a></p>`;
	} else if (listing.execution) {
		content = executionView(listing, found, ranks);
	} else {
		content = treeView(listing, found, ranks);
	}
	return taskPage(
		"Tasks",
		header(listing.root, controls(listing)) +
			problemList(listing, found) +
			content,
		200,
	);
}

/** The way back from a task page: the list, then the folders holding TASK,
 * each a link to its task or, for a group, to the list: in the tree view, at
 * the group's row, which the execution view does not have. */
function breadcrumbs(listing: Listing, found?: Snapshot, task?: Task): string {
	const links = [`<a href="${html(listHref(listing))}">Tasks</a>`];
	for (const folder of found && task ? folders(found, task) : []) {
		let href = listHref(listing);
		if (folder.task) href = taskHref(listing, folder.task.id);
		else if (!listing.execution) href += `#${folderAnchor(folder.location)}`;
		links.push(
			`<a href="${html(href)}">${html(folder.task?.title ?? folder.name)}</a>`,
		);
	}
	return `<span class="breadcrumbs">${links.join(" › ")}</span>`;
}

/** A detail page's recoverable error, with a way back to the task list. */
function detailFailure(
	listing: Listing,
	body: string,
	status: number,
): Response {
	return taskPage(
		"Task unavailable",
		`<nav class="task-nav">${breadcrumbs(listing)}</nav>` +
			`<h1>Task unavailable</h1>${body}`,
		status,
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

/** TASK's body as HTML, with local links and images made to work here.
 * Relative links resolve from its document's folder, whatever its depth. */
function body(listing: Listing, found: Snapshot, task: Task): string {
	const { root } = listing;
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
						taskHref(listing, id, target.hash).replaceAll("&", "&amp;"),
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
function resolve(listing: Listing, found: Index, id: string): Task | Response {
	const wanted = asId(id);
	if (!validId(wanted)) {
		return detailFailure(listing, "<p>This is not a valid task ID.</p>", 400);
	}
	const task = found.byId.get(wanted);
	if (task) return task;
	const conflicts = found.conflicts.filter(({ ids }) => ids.includes(wanted));
	if (conflicts.length > 0) {
		const sources = [...new Set(conflicts.flatMap((c) => c.sources))];
		return detailFailure(
			listing,
			`<p>Task ${source(wanted)} is defined more than once, or shares its location with another task. Keep one of these and reload:</p>` +
				`<ul>${sources.map((path) => `<li>${source(path)}</li>`).join("")}</ul>`,
			409,
		);
	}
	const problems = found.problems.filter((problem) => problem.id === wanted);
	if (problems.length > 0) {
		return detailFailure(
			listing,
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
		listing,
		`<p>There is no task ${source(wanted)} in this folder.</p>`,
		404,
	);
}

/** TASK as a link, with its ID and saved status. */
function reference(listing: Listing, task: Task): string {
	return (
		`<li><a href="${html(taskHref(listing, task.id))}">${html(task.title)}</a> ` +
		`<code>${html(task.id)}</code> ${badge(task.status)}</li>`
	);
}

/** TASK's ID and the tasks it depends on and blocks. */
function metadata(listing: Listing, found: Snapshot, task: Task): string {
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
					? reference(listing, target)
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
				: `It depends on itself through ${and(others.map((t) => idLink(listing, t.id)))}.`) +
			"</dd>";
	}
	const blocked = dependents.get(task) ?? [];
	if (blocked.length > 0) {
		items += `<dt>Blocks</dt><dd><ul class="references">${blocked
			.map((dependent) => reference(listing, dependent))
			.join("")}</ul></dd>`;
	}
	return `<dl class="task-meta">${items}</dl>`;
}

function detail(
	listing: Listing,
	found: Snapshot,
	id: string,
	actions?: TaskActions,
	result?: string | null,
): Response {
	const task = resolve(listing, found, id);
	if (task instanceof Response) return task;
	const title = task.headingTitle ? "" : `<h1>${html(task.title)}</h1>`;
	let readiness = "";
	if (task.status === "todo") {
		readiness = ready(found, task)
			? `<span class="readiness readiness-ready">ready</span>`
			: `<span class="readiness readiness-blocked">blocked</span>`;
	}
	return taskPage(
		task.title,
		`<nav class="task-nav">${breadcrumbs(listing, found, task)}` +
			`<span class="task-state">${badge(task.status)}${readiness}</span></nav>` +
			(actions?.controls(listing, task, result) ?? "") +
			metadata(listing, found, task) +
			`<article>${title}${body(listing, found, task)}</article>`,
		200,
	);
}

function validRoot(root: string | null): root is string {
	return !!root && isAbsolute(root) && !root.includes("\0");
}

/** The task list or, with `task`, one task's detail page. The list is the
 * tree unless `view` is `execution`. */
export async function tasks(
	params: URLSearchParams,
	actions?: TaskActions,
): Promise<Response> {
	const root = params.get("root");
	if (!validRoot(root)) {
		return taskPage(
			"Tasks unavailable",
			"<p>Provide an absolute task folder.</p>",
			400,
		);
	}
	const listing: Listing = {
		root,
		execution: params.get("view") === "execution",
		all: params.get("show") === "all",
		context: params.get("context") ?? undefined,
	};
	listing.operable = actions?.operable(listing) ?? false;
	const id = params.get("task");
	try {
		const problem = await unusable(root);
		if (problem) return problem;
		const found = await snapshot(root);
		return id === null
			? list(listing, found)
			: detail(listing, found, id, actions, params.get("action"));
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
		const listing = { root, execution: false, all: false };
		const task = resolve(listing, await discover(root), id);
		if (task instanceof Response) return refuse(404);
		const real = await realpath(path);
		// A task's attachments are beside its source, in its document's folder.
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

/** The body of REQUEST, a POST of TYPE from a task page; or why it is refused.
 * The body is read within a bound, even when chunked. */
async function admit(
	request: Request,
	type: string,
): Promise<string | { status: number; error: string }> {
	if (request.headers.get("origin") !== new URL(request.url).origin)
		return { status: 403, error: "Invalid action origin." };
	if (request.headers.get("content-type")?.split(";")[0] !== type)
		return { status: 415, error: `Expected ${type}.` };
	const reader = request.body?.getReader();
	let body = "";
	if (reader) {
		const decoder = new TextDecoder();
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			body += decoder.decode(value, { stream: true });
			if (body.length > 4096) {
				await reader.cancel();
				return { status: 413, error: "The request is too large." };
			}
		}
		body += decoder.decode();
	}
	return body;
}

type Implementation = {
	listing: Listing;
	task: string;
	created: number;
	pending?: Promise<void>;
	message?: string;
	failed?: boolean;
};

/** Server-rendered forms with bounded, single-use launch receipts. Resubmitting
 * the same form returns the same result, even while its first POST is pending. */
export class TaskActions {
	private forms = new Map<string, Implementation>();

	constructor(private host: HostActions) {}

	/** Whether LISTING's page is in the Portal view registered for its root. */
	operable(listing: Listing): boolean {
		const context = this.host.context(listing.context ?? null);
		return context?.app === "tasks" && context.root === listing.root;
	}

	controls(listing: Listing, task: Task, result?: string | null): string {
		if (!this.operable(listing))
			return `<p class="action-note">Reload this task view in Portal to change, edit or implement this task.</p>`;
		const buttons = `<div class="task-controls">${operations(task, false)}`;
		if (typeof this.host.context(listing.context ?? null)?.project !== "string")
			return `${buttons}</div><p class="action-note">Open this task folder from a project to implement it.</p>`;
		for (const [id, form] of this.forms) {
			if (Date.now() - form.created > 600_000) this.forms.delete(id);
		}
		while (this.forms.size >= 1024) {
			const first = this.forms.keys().next().value;
			if (first) this.forms.delete(first);
		}
		const previous = result ? this.forms.get(result) : undefined;
		const notice =
			previous &&
			previous.listing.context === listing.context &&
			previous.task === task.id &&
			previous.message
				? `<p role="status" class="action-note${previous.failed ? " action-error" : ""}">${html(previous.message)}</p>`
				: "";
		const id = crypto.randomUUID();
		this.forms.set(id, { listing, task: task.id, created: Date.now() });
		return (
			`${notice}${buttons}<form class="task-action" method="post" action="tasks/implement">` +
			`<input type="hidden" name="request" value="${id}">` +
			`<button type="submit">Implement with Claude</button></form></div>`
		);
	}

	async implement(request: Request): Promise<Response> {
		const body = await admit(request, "application/x-www-form-urlencoded");
		if (typeof body !== "string")
			return new Response(body.error, { status: body.status });
		const id = new URLSearchParams(body).get("request") ?? "";
		const form = this.forms.get(id);
		if (!form || Date.now() - form.created > 600_000)
			return page(
				"Action expired",
				"<h1>Action expired</h1><p>Go back and reload the task before trying again.</p>",
				409,
			);
		form.pending ??= this.launch(form).catch((error: unknown) => {
			form.failed = true;
			form.message =
				error instanceof Error ? error.message : "Could not open the terminal.";
		});
		await form.pending;
		return new Response(null, {
			status: 303,
			headers: {
				Location: new URL(
					`../${listHref(form.listing, form.task)}&action=${id}`,
					request.url,
				).href,
			},
		});
	}

	/** A task page's status change or Edit in Emacs, posted as JSON: the page's
	 * root and context, the task ID, the action, and for a status change the
	 * status to set. Answers `{}`, or `{error}` to show. Actions run one at a
	 * time, so a repeated status change finds its work already done. */
	async act(request: Request): Promise<Response> {
		const body = await admit(request, "application/json");
		if (typeof body !== "string")
			return Response.json({ error: body.error }, { status: body.status });
		let input: Record<string, unknown> = {};
		try {
			input = JSON.parse(body) ?? {};
		} catch {}
		const { root, context, task, action, status } = input;
		if (
			typeof root !== "string" ||
			typeof context !== "string" ||
			typeof task !== "string" ||
			!(action === "edit" || (action === "status" && isStatus(status)))
		)
			return Response.json({ error: "Invalid task action." }, { status: 400 });
		const listing: Listing = { root, context, execution: false, all: false };
		const run = this.queue.then(() =>
			action === "edit"
				? this.edit(listing, task)
				: this.change(listing, task, status as Status),
		);
		this.queue = run.catch(() => {});
		try {
			await run;
			return Response.json({});
		} catch (error) {
			return Response.json(
				{ error: (error as Error).message },
				{ status: 409 },
			);
		}
	}

	private queue: Promise<unknown> = Promise.resolve();

	/** Open task ID's current source in Emacs, in another pane. */
	private async edit(listing: Listing, id: string) {
		const task = await this.locate(listing, id);
		await this.host.request(listing.context ?? "", "task.edit", {
			file: task.source,
		});
	}

	/** Give task ID STATUS, when it has another. The app host plans the edit
	 * against the bytes it read, and Emacs saves it only if the file still
	 * has them. */
	private async change(listing: Listing, id: string, status: Status) {
		const task = await this.locate(listing, id);
		const bytes = await readFile(task.source);
		const edit = statusChange(task, bytes, status);
		if (!edit) return;
		await this.host.request(listing.context ?? "", "task.status", {
			file: task.source,
			...edit,
			before: new Bun.CryptoHasher("sha256").update(bytes).digest("hex"),
		});
	}

	/** Task ID's current source in LISTING's root, for its registered view. */
	private async locate(listing: Listing, id: string): Promise<Task> {
		if (!listing.context || !this.operable(listing))
			throw new Error(
				"The task view has closed or expired. Reload before trying again.",
			);
		const task = resolve(listing, await discover(listing.root), id);
		if (task instanceof Response)
			throw new Error(
				"The task was removed, became invalid, or has a conflicting ID. Reload the page.",
			);
		const source = await realpath(task.source);
		if (!inside(source, await realpath(listing.root)))
			throw new Error("The task source is outside its task folder.");
		return task;
	}

	private async launch(form: Implementation) {
		const { listing } = form;
		const task = await this.locate(listing, form.task);
		const context = this.host.context(listing.context ?? null) ?? {};
		if (
			typeof context.project !== "string" ||
			!isAbsolute(context.project) ||
			typeof context.program !== "string" ||
			!Array.isArray(context.args) ||
			!context.args.every((arg) => typeof arg === "string")
		)
			throw new Error(
				"This task view needs a project and a Claude executable.",
			);
		const source = await realpath(task.source);
		const project = await realpath(context.project);
		const path = relative(project, source).normalize("NFC");
		// Quoted @ references preserve whitespace inside the initial prompt;
		// shell quoting is a separate concern handled by the terminal launcher.
		const mention = /[\s"\\]/.test(path) ? JSON.stringify(path) : path;
		await this.host.request(listing.context ?? "", "terminal.open", {
			directory: project,
			program: context.program,
			args: [...context.args, `implement @${mention}`],
			name: `*claude: ${task.id}*`,
		});
		form.message = "Claude terminal opened for this task.";
	}
}
