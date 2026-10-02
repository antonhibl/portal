// Spike only: log Pi lifecycle events with ctx.isIdle() to SPIKE_PI_LOG.
// Loaded for one run with `pi -e`; writes nothing to the terminal.
import { appendFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const file = process.env.SPIKE_PI_LOG;
  const t0 = Number(process.env.SPIKE_T0_MS || Date.now());
  const log = (event: string, ctx?: any, extra: object = {}) => {
    if (!file) return;
    let idle: boolean | string = "n/a";
    try { idle = ctx?.isIdle?.(); } catch (e) { idle = "error"; }
    appendFileSync(file, JSON.stringify({ wall: Date.now(), event, idle, pid: process.pid,
      portal: process.env.PORTAL_TERMINAL ?? null, ...extra }) + "\n");
  };
  for (const name of ["session_start", "session_shutdown", "agent_start", "agent_end",
                      "agent_before_settle", "agent_settled", "turn_start", "turn_end",
                      "ui_prompt_start", "ui_prompt_end", "session_compact", "session_compact_failed",
                      "tool_execution_start", "tool_execution_end", "input"] as const) {
    pi.on(name as any, (event: any, ctx: any) => {
      log(name, ctx, name === "session_start" ? { reason: event?.reason, mode: ctx?.mode } : {});
    });
  }
}
