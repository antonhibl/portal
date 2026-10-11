// SPDX-License-Identifier: GPL-3.0-or-later
import { expect, test } from "bun:test";
import {
	copyFileSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("./vm.sh", import.meta.url).pathname;
const desktop = new URL("./gui-desktop.sh", import.meta.url).pathname;
// Only the scratch clone's own configuration counts.
const gitEnv = {
	...process.env,
	GIT_CONFIG_GLOBAL: "/dev/null",
	GIT_CONFIG_NOSYSTEM: "1",
};

function shell(cwd: string, command: string, ...args: string[]) {
	return Bun.spawnSync(
		[
			"/bin/bash",
			"-c",
			`source "$1"; shift; ${command}`,
			"test",
			script,
			...args,
		],
		{
			cwd,
		},
	);
}

test("sync includes working changes and unusual paths, excluding deleted and ignored files", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-sync-"));
	try {
		Bun.spawnSync(["git", "init", "-q"], { cwd });
		await Bun.write(join(cwd, ".gitignore"), "build/\ntarget/\n");
		await Bun.write(join(cwd, "tracked"), "original");
		await Bun.write(join(cwd, "deleted"), "deleted");
		Bun.spawnSync(["git", "add", "."], { cwd });
		await Bun.write(join(cwd, "tracked"), "uncommitted");
		rmSync(join(cwd, "deleted"));
		await Bun.write(join(cwd, "new\nfile"), "new");
		await Bun.write(join(cwd, "build", "host.dylib"), "wrong machine");
		symlinkSync("tracked", join(cwd, "link"));
		const result = shell(
			cwd,
			"source_files | rsync -a --from0 --files-from=- ./ target/",
		);
		expect(result.exitCode).toBe(0);
		expect(readdirSync(join(cwd, "target")).sort()).toEqual([
			".gitignore",
			"link",
			"new\nfile",
			"tracked",
		]);
		expect(readFileSync(join(cwd, "target", "tracked"), "utf8")).toBe(
			"uncommitted",
		);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("remote-shell quoting preserves literal arguments and command exit status", () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-args-"));
	try {
		const argument = "quote ' spaces\n$(not-a-command)";
		const quoted = shell(
			cwd,
			'quote /bin/bash -c \'printf "%s" "$1"; exit 7\' test "$1"',
			argument,
		);
		const result = shell(
			cwd,
			'timeout=5; run_stage test.log /bin/zsh -c "$1"',
			quoted.stdout.toString(),
		);
		expect(result.exitCode).toBe(7);
		expect(readFileSync(join(cwd, "test.log"), "utf8")).toBe(argument);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("unlaunchable commands record a failure", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-launch-"));
	try {
		await Bun.write(join(cwd, "not-executable"), "#!/bin/sh\nexit 0\n");
		const result = shell(cwd, "timeout=5; run_stage test.log ./not-executable");
		expect(result.exitCode).not.toBe(0);
		expect(readFileSync(join(cwd, "test.log"), "utf8")).toContain(
			"Permission denied",
		);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("timeout kills the command's process group and releases its desktop lock", () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-timeout-"));
	try {
		const result = shell(
			cwd,
			`exec 9>desktop.lock; lockf 9
			timeout=1; run_stage test.log /bin/bash -c 'echo $$ >pid; sleep 60 & wait'`,
		);
		expect(result.exitCode).toBe(124);
		const pid = Number(readFileSync(join(cwd, "pid"), "utf8"));
		expect(() => process.kill(-pid, 0)).toThrow();
		expect(shell(cwd, "lockf -k -t 0 desktop.lock true").exitCode).toBe(0);
		expect(readFileSync(join(cwd, "test.log"), "utf8")).toContain("Timed out");
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

// A clone with a graphical test script that sources gui-desktop.sh, and a
// stand-in test/vm.sh that reports how it was called.
async function guiClone() {
	const cwd = mkdtempSync(join(tmpdir(), "vm-desktop-"));
	mkdirSync(join(cwd, "test"));
	copyFileSync(desktop, join(cwd, "test", "gui-desktop.sh"));
	await Bun.write(
		join(cwd, "test", "vm.sh"),
		'printf "vm %s:" "$PORTAL_TEST_VM"; printf " %s" "$@"; echo\n',
	);
	await Bun.write(
		join(cwd, "test", "check.sh"),
		`set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
echo "here $*"
`,
	);
	Bun.spawnSync(["git", "init", "-q"], { cwd, env: gitEnv });
	return cwd;
}

function runCheck(cwd: string, env = gitEnv) {
	const result = Bun.spawnSync(
		["/bin/sh", join(cwd, "test", "check.sh"), "a b", "c"],
		{ cwd: tmpdir(), env },
	);
	expect(result.exitCode).toBe(0);
	return result.stdout.toString();
}

test("graphical checks run here unless the clone names a test VM", async () => {
	const cwd = await guiClone();
	try {
		expect(runCheck(cwd)).toBe("here a b c\n");
		Bun.spawnSync(["git", "config", "portal.testVm", "guest"], {
			cwd,
			env: gitEnv,
		});
		expect(runCheck(cwd)).toBe("vm guest: sh test/check.sh a b c\n");
		// The VM's copy has no Git metadata, so it never delegates again,
		// even when the guest's own Git configuration names a VM.
		rmSync(join(cwd, ".git"), { recursive: true });
		const global = join(cwd, "gitconfig");
		await Bun.write(global, "[portal]\n\ttestVm = guest\n");
		expect(runCheck(cwd, { ...gitEnv, GIT_CONFIG_GLOBAL: global })).toBe(
			"here a b c\n",
		);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("the runner needs a VM alias", async () => {
	const cwd = await guiClone();
	try {
		copyFileSync(script, join(cwd, "test", "vm.sh"));
		const env = { ...gitEnv, PORTAL_TEST_VM: "" };
		const result = Bun.spawnSync(
			["/bin/bash", join(cwd, "test", "vm.sh"), "true"],
			{ cwd, env },
		);
		expect(result.exitCode).toBe(2);
		expect(result.stderr.toString()).toContain("git config portal.testVm");
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});
