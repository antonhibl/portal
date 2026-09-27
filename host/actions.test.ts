// SPDX-License-Identifier: GPL-3.0-or-later
import { afterEach, expect, test } from "bun:test";
import {
	mkdir,
	mkdtemp,
	realpath,
	rename,
	rm,
	writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostActions } from "./actions";
import { TaskActions, tasks } from "./tasks";

const directories: string[] = [];
afterEach(async () => {
	await Promise.all(
		directories
			.splice(0)
			.map((path) => rm(path, { recursive: true, force: true })),
	);
});

async function fixture() {
	const project = await realpath(
		await mkdtemp(join(tmpdir(), "portal action ' é ")),
	);
	directories.push(project);
	const root = join(project, "tasks");
	await mkdir(root);
	await writeFile(
		join(root, "source.md"),
		"---\nid: stable-task\nstatus: todo\n---\n# Implement me\n",
	);
	const sent: Record<string, unknown>[] = [];
	const host = new HostActions((record) =>
		sent.push(record as Record<string, unknown>),
	);
	host.receive({
		type: "context",
		id: "web:1",
		properties: {
			app: "tasks",
			root,
			project,
			program: "/bin/claude",
			args: ["--dangerously-skip-permissions"],
		},
	});
	const actions = new TaskActions(host);
	const params = new URLSearchParams({
		root,
		task: "stable-task",
		context: "web:1",
		view: "execution",
		show: "all",
	});
	const detail = await tasks(params, actions);
	const html = await detail.text();
	const request = html.match(/name="request" value="([^"]+)"/)?.[1];
	expect(request).toBeString();
	const post = (origin = "http://127.0.0.1:1234") =>
		actions.implement(
			new Request("http://127.0.0.1:1234/token/tasks/implement", {
				method: "POST",
				headers: {
					Origin: origin,
					"Content-Type": "application/x-www-form-urlencoded",
				},
				body: new URLSearchParams({ request: request ?? "" }),
			}),
		);
	return { project, root, sent, host, actions, params, post, detail };
}

async function waitRequest(sent: unknown[]) {
	for (let n = 0; n < 100 && sent.length === 0; n++) await Bun.sleep(5);
	expect(sent).toHaveLength(1);
}

test("POST resolves a moved ID and starts once with project cwd and a relative initial prompt", async () => {
	const f = await fixture();
	expect(f.detail.headers.get("Content-Security-Policy")).toContain(
		"form-action 'self'",
	);
	expect(f.detail.headers.get("Referrer-Policy")).toBe("same-origin");
	expect(f.sent).toHaveLength(0); // GET never launches.
	await mkdir(join(f.root, "nested"));
	await rename(join(f.root, "source.md"), join(f.root, "nested", "content.md"));
	const first = f.post();
	const duplicate = f.post();
	await waitRequest(f.sent);
	const request = f.sent[0];
	if (!request) throw new Error("Missing action request");
	expect(request.context).toBe("web:1");
	expect(request.operation).toBe("terminal.open");
	expect(request.arguments).toEqual({
		directory: f.project,
		program: "/bin/claude",
		args: [
			"--dangerously-skip-permissions",
			"implement @tasks/nested/content.md",
		],
		name: "*claude: stable-task*",
	});
	f.host.receive({
		type: "result",
		id: request.id,
		value: { target: "terminal:2" },
	});
	const [a, b] = await Promise.all([first, duplicate]);
	expect(a.status).toBe(303);
	expect(a.headers.get("Location")).toBe(b.headers.get("Location"));
	const result = new URL(a.headers.get("Location") ?? "");
	expect(result.searchParams.get("context")).toBe("web:1");
	expect(result.searchParams.get("view")).toBe("execution");
	expect(result.searchParams.get("show")).toBe("all");
	expect(await (await tasks(result.searchParams, f.actions)).text()).toContain(
		"Claude terminal opened",
	);
	await f.post();
	expect(f.sent).toHaveLength(1);
});

test("errors return to the detail without interpreting their text as HTML", async () => {
	const f = await fixture();
	const response = f.post();
	await waitRequest(f.sent);
	f.host.receive({
		type: "result",
		id: f.sent[0]?.id,
		error: "Missing <claude>",
	});
	const location = new URL((await response).headers.get("Location") ?? "");
	expect(
		await (await tasks(location.searchParams, f.actions)).text(),
	).toContain("Missing &lt;claude&gt;");
});

test("removed, conflicting and closed sources never reach the terminal operation", async () => {
	for (const state of ["removed", "conflicting", "closed"]) {
		const f = await fixture();
		if (state === "removed") await rm(join(f.root, "source.md"));
		if (state === "conflicting")
			await writeFile(
				join(f.root, "duplicate.md"),
				"---\nid: stable-task\nstatus: todo\n---\n# Duplicate\n",
			);
		if (state === "closed") f.host.receive({ type: "forget", id: "web:1" });
		expect((await f.post()).status).toBe(303);
		expect(f.sent).toHaveLength(0);
	}
});

test("blocked tasks disable Implement and never reach the terminal operation", async () => {
	const f = await fixture();
	await writeFile(
		join(f.root, "source.md"),
		"---\nid: stable-task\nstatus: todo\ndepends_on: [first]\n---\n# Implement me\n",
	);
	await writeFile(
		join(f.root, "first.md"),
		"---\nid: first\nstatus: todo\n---\n# First\n",
	);
	const html = await (await tasks(f.params, f.actions)).text();
	expect(html).toContain(
		'<button type="submit" disabled title="Finish its prerequisites first">Implement with Claude</button>',
	);
	expect(html).not.toContain('name="request"');
	// A form rendered before the task became blocked cannot launch it.
	const location = new URL((await f.post()).headers.get("Location") ?? "");
	expect(f.sent).toHaveLength(0);
	expect(
		await (await tasks(location.searchParams, f.actions)).text(),
	).toContain("This task is blocked.");
	await writeFile(
		join(f.root, "first.md"),
		"---\nid: first\nstatus: done\n---\n# First\n",
	);
	expect(await (await tasks(f.params, f.actions)).text()).toContain(
		'name="request"',
	);
});

test("HTTP callers cannot choose another view's project or invoke an arbitrary operation", async () => {
	const f = await fixture();
	expect((await f.post("https://example.com")).status).toBe(403);
	f.params.set("context", "web:unknown");
	expect(await (await tasks(f.params, f.actions)).text()).not.toContain(
		"<form",
	);
	f.params.set("context", "web:1");
	f.params.set("root", f.project);
	expect(await (await tasks(f.params, f.actions)).text()).not.toContain(
		"<form",
	);
	expect(f.sent).toHaveLength(0);
});

test("forget rejects pending requests; late results cannot revive them", async () => {
	const host = new HostActions(() => {});
	host.receive({ type: "context", id: "web:9", properties: {} });
	const request = host.request("web:9", "terminal.open", {});
	host.receive({ type: "forget", id: "web:9" });
	await expect(request).rejects.toThrow("closed");
	await expect(host.request("web:9", "terminal.open", {})).rejects.toThrow(
		"Reload",
	);
});
