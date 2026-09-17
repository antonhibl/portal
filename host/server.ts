// SPDX-License-Identifier: GPL-3.0-or-later
import hello from "./hello.html" with { type: "text" };
import { markdown } from "./markdown";

// A private URL capability, passed only through the parent's readiness pipe.
const token = crypto.randomUUID().replaceAll("-", "");

async function respond(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (request.headers.get("host") !== `127.0.0.1:${server.port}` ||
      !url.pathname.startsWith(`/${token}/`)) {
    return new Response("Not found", { status: 404 });
  }
  const route = url.pathname.slice(token.length + 1);
  if (route !== "/hello" && route !== "/markdown") {
    return new Response("Not found", { status: 404 });
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", {
      status: 405,
      headers: { Allow: "GET, HEAD" },
    });
  }
  if (route === "/markdown") return markdown(url.searchParams.get("path"));
  return new Response(hello, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(request) {
    const response = await respond(request);
    response.headers.set("Cache-Control", "no-store");
    response.headers.set("Referrer-Policy", "no-referrer");
    response.headers.set("X-Content-Type-Options", "nosniff");
    return request.method === "HEAD"
      ? new Response(null, { status: response.status, headers: response.headers })
      : response;
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
process.stdout.write(JSON.stringify({ type: "ready", protocol: 2, port: server.port, token }) + "\n");
