// SPDX-License-Identifier: GPL-3.0-or-later
import hello from "./hello.html" with { type: "text" };

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(request) {
    if (new URL(request.url).pathname !== "/hello") {
      return new Response("Not found", { status: 404 });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }
    return new Response(request.method === "HEAD" ? null : hello, {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    });
  },
});

let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  // Bound shutdown even if a client keeps a request open.
  setTimeout(() => process.exit(0), 1000);
  await server.stop();
  process.exit(0);
}

// The parent's pipe is also our lifetime: EOF covers an abrupt Emacs exit.
process.stdin.on("end", shutdown);
process.stdin.on("error", shutdown);
process.stdin.resume();
for (const signal of ["SIGHUP", "SIGTERM", "SIGINT"] as const) {
  process.on(signal, shutdown);
}
process.stdout.on("error", shutdown);

// stdout is a protocol channel. Send diagnostics to stderr instead.
process.stdout.write(JSON.stringify({ type: "ready", protocol: 1, port: server.port }) + "\n");
