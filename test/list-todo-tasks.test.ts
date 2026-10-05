import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("../list-todo-tasks.ts", import.meta.url).pathname;

test("prints only paths with todo front matter, including nested tasks", async () => {
	const cwd = await mkdtemp(join(tmpdir(), "todo-tasks-"));
	try {
		const files = {
			"plain.md": "---\nstatus: todo\n---\ninvalid: [body\n",
			"nested folder/content.md": '---\nstatus: "todo" # ready\n---\n',
			"quoted.md": "\uFEFF---\r\nstatus: 'todo'\r\n---\r\n",
			".hidden.md": "---\nstatus: todo\n...\n",
			"done.md": "---\nstatus: done\n---\nstatus: todo\n",
			"notes.md": "# Notes\nstatus: todo\n",
			"body.md": "---\ntitle: Notes\n---\nstatus: todo\n",
			"unclosed.md": "---\nstatus: todo\n",
			"nested-status.md": "---\nexample:\n  status: todo\n---\n",
			"scalar.md": "---\ntodo\n---\n",
			"empty.md": "---\n---\n",
			"ignore.txt": "---\nstatus: todo\n---\n",
		};
		for (const [name, content] of Object.entries(files)) {
			await Bun.write(join(cwd, "tasks", name), content);
		}
		const result = Bun.spawnSync([process.execPath, script], { cwd });
		expect(result.exitCode).toBe(0);
		expect(result.stderr.toString()).toBe("");
		expect(result.stdout.toString().trim().split("\n").sort()).toEqual([
			"tasks/.hidden.md",
			"tasks/nested folder/content.md",
			"tasks/plain.md",
			"tasks/quoted.md",
		]);
	} finally {
		await rm(cwd, { recursive: true, force: true });
	}
});
