// SPDX-License-Identifier: GPL-3.0-or-later
// The task browser: saved Markdown tasks in one task root, read on each request.
// A task is ROOT/ID.md or ROOT/ID/content.md with a `status` in its front matter.
import { readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { attribute, localTarget, page, render } from "./markdown";
import styles from "./tasks.css" with { type: "text" };

type Status = "todo" | "done";
type Task = {
	id: string;
	source: string;
	status: Status;
	title: string;
	/** Whether the body's first level-one heading supplies the title. */
	headingTitle: boolean;
	body: string;
};
/** What one candidate document turned out to be. */
type Reading =
	| { kind: "task"; task: Task }
	| { kind: "document" }
	| { kind: "problem"; source: string; message: string };
type Candidate = { id: string; source: string };

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

const html = Bun.escapeHTML;
const encode = encodeURIComponent;

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

/** What the saved TEXT of candidate ID at SOURCE is. */
export function classify(id: string, source: string, text: string): Reading {
	const problem = (message: string): Reading => ({
		kind: "problem",
		source,
		message,
	});
	let parsed: ReturnType<typeof frontMatter>;
	try {
		parsed = frontMatter(text);
	} catch (error) {
		return problem(`Malformed front matter: ${(error as Error).message}.`);
	}
	const { data, body } = parsed;
	if (!data || !Object.hasOwn(data, "status")) return { kind: "document" };
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
	if (!validId(id)) {
		return problem(
			`The task ID ${JSON.stringify(id)}, its file or folder name, is empty or reserved.`,
		);
	}
	const heading = title === null ? firstHeading(body) : null;
	return {
		kind: "task",
		task: {
			id,
			source,
			status,
			title: title ?? heading ?? id,
			headingTitle: heading !== null,
			body,
		},
	};
}

async function read({ id, source }: Candidate): Promise<Reading> {
	try {
		return classify(id, source, await readFile(source, "utf8"));
	} catch (error) {
		return {
			kind: "problem",
			source,
			message: `The file could not be read (${errorCode(error) ?? String(error)}).`,
		};
	}
}

/** NAME, a file name, as an ID. macOS keeps names in either Unicode form
 * and treats both alike, so IDs take one of them, NFC, as Emacs does. */
function asId(name: string): string {
	return name.normalize("NFC");
}

/** The candidate documents directly in ROOT, for task ID only when given.
 * Symbolic links are not followed, and names are compared exactly. */
async function candidates(root: string, only?: string): Promise<Candidate[]> {
	const found: Candidate[] = [];
	const wanted = only === undefined ? undefined : asId(only);
	for (const entry of await readdir(root, { withFileTypes: true })) {
		const id = asId(entry.isFile() ? entry.name.slice(0, -3) : entry.name);
		if (wanted !== undefined && id !== wanted) continue;
		if (entry.isFile() && entry.name.endsWith(".md")) {
			found.push({ id, source: join(root, entry.name) });
		} else if (entry.isDirectory()) {
			const folder = join(root, entry.name);
			try {
				const content = await readdir(folder, { withFileTypes: true });
				if (
					content.some((file) => file.isFile() && file.name === "content.md")
				) {
					found.push({ id, source: join(folder, "content.md") });
				}
			} catch {
				// An unreadable folder is supporting material, like any other.
			}
		}
	}
	return found;
}

type Discovery = {
	tasks: Task[];
	conflicts: { id: string; sources: string[] }[];
	problems: { source: string; message: string }[];
};

/** Read the candidates in ROOT, for task ID only when given. */
async function discover(root: string, only?: string): Promise<Discovery> {
	const readings = await Promise.all((await candidates(root, only)).map(read));
	const byId = new Map<string, Task[]>();
	const problems: Discovery["problems"] = [];
	for (const reading of readings) {
		if (reading.kind === "task") {
			const tasks = byId.get(reading.task.id) ?? [];
			byId.set(reading.task.id, [...tasks, reading.task]);
		} else if (reading.kind === "problem") {
			problems.push({ source: reading.source, message: reading.message });
		}
	}
	const byCodeUnit = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
	const found: Discovery = { tasks: [], conflicts: [], problems };
	for (const [id, [task, ...others]] of [...byId].sort(([a], [b]) =>
		byCodeUnit(a, b),
	)) {
		if (!task) continue;
		if (others.length === 0) found.tasks.push(task);
		else
			found.conflicts.push({
				id,
				sources: [task, ...others].map((t) => t.source).sort(byCodeUnit),
			});
	}
	problems.sort((a, b) => byCodeUnit(a.source, b.source));
	return found;
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

function problemList(root: string, found: Discovery, all: boolean): string {
	const items = [
		...found.conflicts.map(
			({ id, sources }) =>
				`<li><a href="${html(taskHref(root, id, all))}">${html(id)}</a> ` +
				`is defined more than once: ${sources.map(source).join(" and ")}</li>`,
		),
		...found.problems.map(
			(problem) =>
				`<li>${source(problem.source)}: ${html(problem.message)}</li>`,
		),
	];
	return items.length === 0
		? ""
		: `<section class="problems"><h2>Problems</h2><ul>${items.join("")}</ul></section>`;
}

async function list(root: string, all: boolean): Promise<Response> {
	const found = await discover(root);
	const shown = found.tasks.filter((task) => all || task.status === "todo");
	const toggle = `<p class="filter"><a href="${html(listHref(root, !all))}">${all ? "Hide completed" : "Show completed"}</a></p>`;
	let rows: string;
	if (shown.length > 0) {
		rows = `<ul class="tasks">${shown
			.map(
				(task) =>
					`<li><a href="${html(taskHref(root, task.id, all))}">${badge(task.status)}` +
					`<span class="title">${html(task.title)}</span></a></li>`,
			)
			.join("")}</ul>`;
	} else if (found.tasks.length > 0) {
		rows = `<p class="empty">No unfinished tasks. <a href="${html(listHref(root, true))}">Show completed</a></p>`;
	} else {
		rows = `<p class="empty">No tasks</p>`;
	}
	return page(
		"Tasks",
		header(root, toggle) + problemList(root, found, all) + rows,
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

/** The ID of the task whose source is at REAL, a real path, or null. */
function taskAt(real: string, root: string): string | null {
	if (!inside(real, root)) return null;
	const [first = "", second, ...more] = relative(root, real)
		.normalize("NFC")
		.split(sep);
	let id: string | undefined;
	if (second === undefined && first.endsWith(".md")) id = first.slice(0, -3);
	else if (second === "content.md" && more.length === 0) id = first;
	if (id === undefined) return null;
	try {
		// REAL has no symbolic links left; its name must match exactly, as in
		// discovery, even on a case-insensitive file system.
		const names = readdirSync(dirname(real)).map(asId);
		if (!names.includes(second ?? first)) return null;
		if (!statSync(real).isFile()) return null;
		const reading = classify(id, real, readFileSync(real, "utf8"));
		return reading.kind === "task" ? id : null;
	} catch {
		return null;
	}
}

/** The folder the relative links of TASK, in ROOT, resolve from. */
function attachmentBase(task: Task, root: string): string {
	return task.source === join(root, `${task.id}.md`)
		? root
		: dirname(task.source);
}

/** TASK's body as HTML, with local links and images made to work here. */
function body(task: Task, root: string, all: boolean): string {
	const realRoot = realpathSync(root);
	const base = realpathSync(attachmentBase(task, root));
	// Emacs visits the file under the root it named, in its Unicode form.
	const visit = (real: string) =>
		pathToFileURL(join(root, relative(realRoot, real)).normalize("NFC")).href;
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
				const id = taskAt(real, realRoot);
				// HTMLRewriter escapes only quotes in the values it writes.
				if (id !== null) {
					link.setAttribute(
						"href",
						taskHref(root, id, all, target.hash).replaceAll("&", "&amp;"),
					);
				} else if (inside(real, base)) {
					link.setAttribute(
						"href",
						(visit(real) + target.hash).replaceAll("&", "&amp;"),
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

/** Resolve task ID in ROOT, or return the page that explains why not. */
async function resolve(
	root: string,
	id: string,
	all: boolean,
): Promise<Task | Response> {
	if (!validId(id)) {
		return detailFailure(root, all, "<p>This is not a valid task ID.</p>", 400);
	}
	const found = await discover(root, id);
	const task = found.tasks[0];
	if (task) return task;
	const conflict = found.conflicts[0]?.sources;
	if (conflict) {
		return detailFailure(
			root,
			all,
			`<p>Task ${source(id)} is defined more than once. Keep one of these and reload:</p>` +
				`<ul>${conflict.map((path) => `<li>${source(path)}</li>`).join("")}</ul>`,
			409,
		);
	}
	if (found.problems.length > 0) {
		return detailFailure(
			root,
			all,
			`<ul>${found.problems
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
		`<p>There is no task ${source(id)} in this folder.</p>`,
		404,
	);
}

async function detail(
	root: string,
	id: string,
	all: boolean,
): Promise<Response> {
	const task = await resolve(root, id, all);
	if (task instanceof Response) return task;
	const title = task.headingTitle ? "" : `<h1>${html(task.title)}</h1>`;
	return page(
		task.title,
		`<nav class="task-nav"><a href="${html(listHref(root, all))}">Tasks</a>${badge(task.status)}</nav>` +
			`<article>${title}${body(task, root, all)}</article>`,
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
		return id === null ? await list(root, all) : await detail(root, id, all);
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
		const task = await resolve(root, id, false);
		if (task instanceof Response) return refuse(404);
		const real = await realpath(path);
		if (!inside(real, await realpath(attachmentBase(task, root))))
			return refuse(403);
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
