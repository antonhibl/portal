// Spike only: report Pi's run state as OSC 9;4 progress, only inside Portal.
// 3 = running (agent_start .. agent_settled), 0 = idle, 4 = waiting on an extension dialog.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  if (!process.env.PORTAL_TERMINAL || !process.stdout.isTTY) return;
  let prompts = 0;
  const report = (ctx: any) => {
    const state = prompts > 0 ? "4;0" : ctx.isIdle() ? "0" : "3";
    process.stdout.write(`\x1b]9;4;${state}\x07`);
  };
  pi.on("session_start", (_e, ctx) => { if (ctx.mode === "tui") report(ctx); });
  pi.on("agent_start", (_e, ctx) => report(ctx));
  pi.on("agent_settled", (_e, ctx) => report(ctx));
  pi.on("ui_prompt_start", (_e, ctx) => { prompts++; report(ctx); });
  pi.on("ui_prompt_end", (_e, ctx) => { prompts = Math.max(0, prompts - 1); report(ctx); });
  pi.on("session_shutdown", () => { process.stdout.write("\x1b]9;4;0\x07"); });
}
