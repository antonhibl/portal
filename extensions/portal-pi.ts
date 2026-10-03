// SPDX-License-Identifier: GPL-3.0-or-later
// Pi 0.87.0: install once in ~/.pi/agent/extensions, then use plain `pi`.
// Keep terminal.showTerminalProgress off and disable competing OSC 9;4 writers.
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";

export default function portalProgress(pi: ExtensionAPI) {
	if (!process.env.PORTAL_TERMINAL || !process.stdout.isTTY) return;
	let tui = false;
	let prompts = 0;
	const write = (state: string) =>
		process.stdout.write(`\x1b]9;4;${state}\x07`);
	const report = (ctx: ExtensionContext) => {
		if (tui) write(prompts > 0 ? "4;0" : ctx.isIdle() ? "0" : "3");
	};
	pi.on("session_start", (_event, ctx) => {
		// RPC also has a UI. Only a real TUI may write terminal escapes.
		tui = ctx.mode === "tui";
		prompts = 0;
		report(ctx);
	});
	pi.on("agent_start", (_event, ctx) => report(ctx));
	// agent_end can precede retries, compaction, or queued continuation.
	pi.on("agent_settled", (_event, ctx) => report(ctx));
	pi.on("session_before_compact", () => {
		if (tui) write(prompts > 0 ? "4;0" : "3");
	});
	const compacted = (event: { reason: string }, ctx: ExtensionContext) => {
		// In 0.87.0 manual success is emitted before isCompacting clears and
		// has no agent_settled event. Do not leave a false working/idle claim.
		if (tui && event.reason === "manual" && !ctx.isIdle()) write("2;0");
		else report(ctx);
	};
	pi.on("session_compact", compacted);
	pi.on("session_compact_failed", compacted);
	pi.on("ui_prompt_start", (_event, ctx) => {
		prompts++;
		report(ctx);
	});
	pi.on("ui_prompt_end", (_event, ctx) => {
		prompts = Math.max(0, prompts - 1);
		report(ctx);
	});
	pi.on("session_shutdown", () => {
		// Source loss, including unload on /reload, is unknown rather than idle.
		if (tui) write("2;0");
		tui = false;
		prompts = 0;
	});
}
