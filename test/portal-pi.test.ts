// SPDX-License-Identifier: GPL-3.0-or-later
import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import portalProgress from "../extensions/portal-pi";

const originalMarker = process.env.PORTAL_TERMINAL;
const originalTTY = Object.getOwnPropertyDescriptor(process.stdout, "isTTY");
let output: ReturnType<typeof spyOn> | undefined;
afterEach(() => {
	output?.mockRestore();
	if (originalMarker === undefined) delete process.env.PORTAL_TERMINAL;
	else process.env.PORTAL_TERMINAL = originalMarker;
	if (originalTTY) Object.defineProperty(process.stdout, "isTTY", originalTTY);
	else Reflect.deleteProperty(process.stdout, "isTTY");
});

function harness(marker: string | undefined = "42/terminal:1", tty = true) {
	if (marker === undefined) delete process.env.PORTAL_TERMINAL;
	else process.env.PORTAL_TERMINAL = marker;
	Object.defineProperty(process.stdout, "isTTY", {
		configurable: true,
		value: tty,
	});
	const reports: string[] = [];
	output = spyOn(process.stdout, "write").mockImplementation((text) => {
		reports.push(String(text));
		return true;
	});
	type API = Parameters<typeof portalProgress>[0];
	type Context = { mode: string; isIdle(): boolean };
	type Handler = (event: Record<string, unknown>, ctx: Context) => unknown;
	const handlers = new Map<string, Handler>();
	portalProgress({
		on: (name: string, handler: Handler) => handlers.set(name, handler),
	} as unknown as API);
	return {
		reports,
		handlers,
		emit(name: string, idle: boolean, event: object = {}, mode = "tui") {
			handlers.get(name)?.(
				{ type: name, ...event },
				{ mode, isIdle: () => idle },
			);
		},
		last: () => reports.at(-1),
	};
}

const osc = (state: string) => `\x1b]9;4;${state}\x07`;

test("only Portal TUI sessions write progress; shutdown stops reporting", () => {
	for (const [marker, tty] of [
		["", true],
		["marker", false],
	] as const) {
		const h = harness(marker, tty);
		expect(h.handlers.size).toBe(0);
		output?.mockRestore();
	}
	const h = harness();
	h.emit("agent_start", false);
	h.emit("session_start", true, {}, "rpc");
	h.emit("agent_start", false, {}, "rpc");
	expect(h.reports).toEqual([]);
	h.emit("session_start", true);
	expect(h.last()).toBe(osc("0"));
	h.emit("session_shutdown", true, { reason: "reload" });
	expect(h.last()).toBe(osc("2;0"));
	const count = h.reports.length;
	h.emit("agent_settled", true);
	expect(h.reports.length).toBe(count);
});

test("retries, queued continuation and automatic compaction stay busy until settlement", () => {
	const h = harness();
	h.emit("session_start", true);
	h.emit("agent_start", false);
	for (const name of [
		"agent_end",
		"auto_retry_start",
		"auto_retry_end",
		"agent_before_settle",
		"agent_start",
	]) {
		h.emit(name, false);
		expect(h.last()).toBe(osc("3"));
	}
	h.emit("session_before_compact", false, { reason: "threshold" });
	h.emit("session_compact", false, { reason: "threshold", willRetry: true });
	expect(h.last()).toBe(osc("3"));
	// Even an unexpected settled callback cannot claim idle while ctx disagrees.
	h.emit("agent_settled", false);
	expect(h.last()).toBe(osc("3"));
	h.emit("agent_settled", true);
	expect(h.last()).toBe(osc("0"));
});

test("nested dialogs restore current activity; reload/new/resume reset prompt state", () => {
	const h = harness();
	h.emit("session_start", true);
	h.emit("ui_prompt_start", false);
	h.emit("ui_prompt_start", false);
	h.emit("ui_prompt_end", false);
	expect(h.last()).toBe(osc("4;0"));
	h.emit("ui_prompt_end", false);
	expect(h.last()).toBe(osc("3"));
	h.emit("ui_prompt_end", true);
	expect(h.last()).toBe(osc("0"));
	for (const reason of ["reload", "new", "resume", "fork"]) {
		h.emit("ui_prompt_start", true);
		h.emit("session_start", true, { reason });
		expect(h.last()).toBe(osc("0"));
	}
});

test("manual compaction's premature success is unknown; failure uses verified idle", () => {
	const h = harness();
	h.emit("session_start", true);
	h.emit("session_before_compact", false, { reason: "manual" });
	expect(h.last()).toBe(osc("3"));
	h.emit("session_compact", false, { reason: "manual" });
	expect(h.last()).toBe(osc("2;0"));
	h.emit("session_compact_failed", true, { reason: "manual", aborted: true });
	expect(h.last()).toBe(osc("0"));
});

test("replays recorded Pi 0.87.0 tool, cancellation, queued and provider-failure lifecycles", () => {
	for (const file of [
		"pi-progress-extension",
		"pi-turns",
		"pi-provider-error",
	]) {
		const h = harness();
		const events = readFileSync(
			new URL(`./fixtures/agent-signals/${file}.jsonl`, import.meta.url),
			"utf8",
		)
			.trim()
			.split("\n")
			.map((line) => JSON.parse(line));
		let settled = 0;
		for (const event of events) {
			if (event.kind !== "pi_event") continue;
			h.emit(event.event, event.idle);
			if (event.event === "agent_end") expect(h.last()).toBe(osc("3"));
			if (event.event === "agent_settled") {
				expect(event.idle).toBe(true);
				expect(h.last()).toBe(osc("0"));
				settled++;
			}
		}
		expect(settled).toBeGreaterThan(0);
		output?.mockRestore();
	}
});
