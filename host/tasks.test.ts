// SPDX-License-Identifier: GPL-3.0-or-later
import { afterEach, expect, test } from "bun:test";
import {
	mkdir,
	mkdtemp,
	readFile,
	realpath,
	rename,
	rm,
	writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostActions } from "./actions";
import {
	classify,
	statusChange,
	statusEdit,
	TaskActions,
	tasks,
} from "./tasks";

/** BYTES with EDIT applied, as Emacs applies it. */
function apply(
	bytes: Uint8Array,
	edit: { start: number; end: number; text: string },
): Buffer {
	return Buffer.concat([
		bytes.subarray(0, edit.start),
		Buffer.from(edit.text),
		bytes.subarray(edit.end),
	]);
}

/** TEXT with its status set to STATUS, as a string. */
function edited(text: string, status: "todo" | "done"): string {
	const bytes = Buffer.from(text);
	return apply(bytes, statusEdit(bytes, status)).toString();
}

test("status edits change only the status value, in any supported style", () => {
	expect(
		edited(
			"---\nid: a\nstatus: todo # keep\ntitle: 'x'\n---\nstatus: todo\n",
			"done",
		),
	).toBe("---\nid: a\nstatus: done # keep\ntitle: 'x'\n---\nstatus: todo\n");
	expect(edited(`---\n"status": 'done'\nextra: 1\n---\n`, "todo")).toBe(
		`---\n"status": 'todo'\nextra: 1\n---\n`,
	);
	expect(
		edited(
			`---\n{id: a, 'status': "todo", depends_on: [b]}\n---\n# A\n`,
			"done",
		),
	).toBe(`---\n{id: a, 'status': "done", depends_on: [b]}\n---\n# A\n`);
	expect(edited("---\n{\n  id: a,\n  status: todo\n}\n---\n", "done")).toBe(
		"---\n{\n  id: a,\n  status: done\n}\n---\n",
	);
	// A BOM, CRLF and multibyte text before the value keep their bytes.
	const text =
		"﻿---\r\ntitle: Café ✓ 𝄞\r\nstatus: done\r\nunknown: {a: 1}\r\n---\r\n# Body\r\n";
	const bytes = Buffer.from(text);
	const edit = statusEdit(bytes, "todo");
	expect(edit.text).toBe("todo");
	expect(bytes.subarray(edit.start, edit.end).toString()).toBe("done");
	expect(apply(bytes, edit).toString()).toBe(text.replace("done", "todo"));
});

test("ambiguous, unsupported and malformed status edits are refused", () => {
	const refused = (text: string, message: string) =>
		expect(() => statusEdit(Buffer.from(text), "done")).toThrow(message);
	refused("---\nstatus: !!str todo\n---\n", "cannot be changed safely");
	refused("---\nstatus: &s todo\n---\n", "cannot be changed safely");
	refused("---\n? status\n: todo\n---\n", "cannot be changed safely");
	refused("---\nstatus: todo\nstatus: todo\n---\n", "more than one status");
	refused(
		"---\nnotes: |\n  status: todo\nstatus: todo\n---\n",
		"more than one status",
	);
	// The only entry that looks like a status is text in another value.
	refused(
		"---\nnotes: |\n  status: todo\nstatus: !!str todo\n---\n",
		"would change other front matter",
	);
	refused("---\nstatus: todo\n", "no closing");
	refused("# No front matter\n", "has no status");
	expect(() =>
		statusEdit(
			Buffer.concat([
				Buffer.from("---\nstatus: todo\n---\n"),
				Buffer.from([0xff]),
			]),
			"done",
		),
	).toThrow("not valid UTF-8");
});

test("an edited document reads back as the same task, with the other status", () => {
	const text =
		"---\n# comment\nid: fix-search\nstatus: todo\ndepends_on:\n  - a\n---\n# Fix search\n\nBody.\n";
	const candidate = { location: "fix-search", source: "/x.md", folder: false };
	const before = classify(candidate, text);
	const after = classify(candidate, edited(text, "done"));
	if (before.kind !== "task" || after.kind !== "task")
		throw new Error("no task");
	expect(after.task).toEqual({ ...before.task, status: "done" });
});

test("a status change is planned only from bytes that are still the task", () => {
	const task = {
		id: "fix-search",
		location: "fix-search",
		source: "/t/fix-search.md",
		folder: false,
	};
	const bytes = (text: string) => Buffer.from(text);
	expect(statusChange(task, bytes("---\nstatus: todo\n---\n"), "done")).toEqual(
		statusEdit(bytes("---\nstatus: todo\n---\n"), "done"),
	);
	expect(
		statusChange(task, bytes("---\nstatus: done\n---\n"), "done"),
	).toBeNull();
	// Another task, or no task, has taken the file since discovery.
	for (const text of [
		"---\nid: other-task\nstatus: todo\n---\n",
		"# Notes\n",
		"---\nstatus: later\n---\n",
	])
		expect(() => statusChange(task, bytes(text), "done")).toThrow(
			"changed while the action ran",
		);
});

const directories: string[] = [];
afterEach(async () => {
	await Promise.all(
		directories
			.splice(0)
			.map((path) => rm(path, { recursive: true, force: true })),
	);
});

async function fixture() {
	const root = join(
		await realpath(await mkdtemp(join(tmpdir(), "portal act é "))),
		"tasks",
	);
	directories.push(join(root, ".."));
	await mkdir(root);
	const source = join(root, "source.md");
	await writeFile(
		source,
		"---\nid: stable-task\nstatus: todo\n---\n# Act on me\n",
	);
	const sent: Record<string, unknown>[] = [];
	const host = new HostActions((record) =>
		sent.push(record as Record<string, unknown>),
	);
	host.receive({
		type: "context",
		id: "web:1",
		properties: { app: "tasks", root },
	});
	const actions = new TaskActions(host);
	const post = (body: object, headers: Record<string, string> = {}) =>
		actions.act(
			new Request("http://127.0.0.1:1234/token/tasks/action", {
				method: "POST",
				headers: {
					Origin: "http://127.0.0.1:1234",
					"Content-Type": "application/json",
					...headers,
				},
				body: JSON.stringify({
					root,
					context: "web:1",
					task: "stable-task",
					...body,
				}),
			}),
		);
	/** Answer the next request as Emacs would, applying a status edit. */
	const answer = async (error?: string) => {
		for (let n = 0; n < 100 && sent.length === 0; n++) await Bun.sleep(5);
		const request = sent.shift();
		if (!request) throw new Error("Missing request");
		const args = request.arguments as {
			file: string;
			start: number;
			end: number;
			text: string;
		};
		if (!error && request.operation === "task.status")
			await writeFile(args.file, apply(await readFile(args.file), args));
		host.receive({
			type: "result",
			id: request.id,
			...(error ? { error } : { value: {} }),
		});
		return request;
	};
	return { root, source, sent, host, actions, post, answer };
}

test("a status change resolves the moved source, is planned from its bytes, and is idempotent", async () => {
	const f = await fixture();
	await mkdir(join(f.root, "nested"));
	const source = join(f.root, "nested", "content.md");
	await rename(f.source, source);
	const first = f.post({ action: "status", status: "done" });
	const repeated = f.post({ action: "status", status: "done" });
	const request = await f.answer();
	expect(request.operation).toBe("task.status");
	expect(request.context).toBe("web:1");
	const bytes = Buffer.from(
		"---\nid: stable-task\nstatus: todo\n---\n# Act on me\n",
	);
	expect(request.arguments).toEqual({
		file: source,
		...statusEdit(bytes, "done"),
		before: new Bun.CryptoHasher("sha256").update(bytes).digest("hex"),
	});
	expect((await first).status).toBe(200);
	// The repeated request runs after the first, finds its work done, and
	// never toggles the task back.
	expect(await (await repeated).json()).toEqual({});
	expect(f.sent).toHaveLength(0);
	expect(await readFile(source, "utf8")).toContain("status: done");
});

test("errors from Emacs and the planner reach the page as text, with nothing sent", async () => {
	const f = await fixture();
	const failed = f.post({ action: "status", status: "done" });
	await f.answer(
		"source.md has unsaved changes; save it in Emacs, then try again",
	);
	const reply = await failed;
	expect(reply.status).toBe(409);
	expect(await reply.json()).toEqual({
		error: "source.md has unsaved changes; save it in Emacs, then try again",
	});
	await writeFile(f.source, "---\nid: stable-task\nstatus: !!str todo\n---\n");
	const unsafe = await f.post({ action: "status", status: "done" });
	expect(unsafe.status).toBe(409);
	expect((await unsafe.json()).error).toContain("Edit it in Emacs");
	await writeFile(
		join(f.root, "copy.md"),
		"---\nid: stable-task\nstatus: todo\n---\n",
	);
	expect((await (await f.post({ action: "edit" })).json()).error).toContain(
		"conflicting ID",
	);
	expect(f.sent).toHaveLength(0);
});

test("Edit in Emacs asks for the current source", async () => {
	const f = await fixture();
	const reply = f.post({ action: "edit" });
	const request = await f.answer();
	expect(request.operation).toBe("task.edit");
	expect(request.arguments).toEqual({ file: f.source });
	expect((await reply).status).toBe(200);
});

test("only the registered view's page, from its origin, can act", async () => {
	const f = await fixture();
	const status = { action: "status", status: "done" };
	expect((await f.post(status, { Origin: "https://example.com" })).status).toBe(
		403,
	);
	expect((await f.post(status, { "Content-Type": "text/plain" })).status).toBe(
		415,
	);
	expect(
		(await f.post({ action: "status", status: "in-progress" })).status,
	).toBe(400);
	expect((await f.post({ action: "delete" })).status).toBe(400);
	expect((await f.post({ ...status, context: "web:2" })).status).toBe(409);
	expect((await f.post({ ...status, root: join(f.root, "..") })).status).toBe(
		409,
	);
	f.host.receive({ type: "forget", id: "web:1" });
	expect((await f.post(status)).status).toBe(409);
	expect(f.sent).toHaveLength(0);
	expect(await readFile(f.source, "utf8")).toContain("status: todo");
});

test("task pages run only their own script and show controls to their registered view", async () => {
	const f = await fixture();
	const params = new URLSearchParams({ root: f.root, context: "web:1" });
	const list = await tasks(params, f.actions);
	const html = await list.text();
	const script = html.match(/<script>([^<]*)<\/script>/)?.[1] ?? "";
	const hash = new Bun.CryptoHasher("sha256").update(script).digest("base64");
	expect(list.headers.get("Content-Security-Policy")).toContain(
		`script-src 'sha256-${hash}'; connect-src 'self'`,
	);
	expect(list.headers.get("Referrer-Policy")).toBe("same-origin");
	expect(html).toContain(
		'</a><span class="row-actions"><button type="button" class="task-op" tabindex="0" data-task="stable-task" data-title="Act on me" data-op="status" data-status="done" aria-label="Complete Act on me">Complete</button>',
	);
	params.set("task", "stable-task");
	const detail = await (await tasks(params, f.actions)).text();
	expect(detail).toContain(
		'data-op="status" data-status="done">Complete</button>',
	);
	expect(detail).toContain('data-op="edit">Edit in Emacs</button>');
	params.set("context", "web:2");
	expect(await (await tasks(params, f.actions)).text()).not.toContain(
		'class="task-op"',
	);
	params.delete("task");
	expect(await (await tasks(params, f.actions)).text()).not.toContain(
		'class="task-op"',
	);
});
