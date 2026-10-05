# Run and troubleshoot the app host

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Bun UI host

Loading the Lisp package or native module does not start a server. The first
`portal-hello`, `portal-preview-markdown`, `portal-tasks-browser`, or drawing buffer starts one shared
child process asynchronously. Hello, the Markdown preview and the task browser are hosted apps: each opens its
web view at once, at `about:blank`, and loads its page as soon as the host sends
its readiness message. Opening external URLs does not require the server.

- The host binds to `127.0.0.1` on an OS-assigned port. Each Emacs process owns
  its own host; all its web views reuse that host.
- Each host generates a fresh access token and sends it through the readiness
  pipe. URLs have the form `http://127.0.0.1:PORT/TOKEN/hello` or
  `http://127.0.0.1:PORT/TOKEN/markdown?path=ENCODED_ABSOLUTE_PATH`, and task
  pages `http://127.0.0.1:PORT/TOKEN/tasks?root=ENCODED_ABSOLUTE_PATH`. The host
  validates the token and Host header; responses suppress outgoing referrers.
- Closing or hiding a view keeps the server running. `M-x portal-start-server`
  can prewarm it explicitly; `M-x portal-stop-server` stops it, and
  `M-x portal-restart-server` starts a replacement. Hosted apps that have
  already loaded keep their page while the host stops or restarts; press `g` in
  one's buffer to reload it from the host, starting the host first if needed.
- Startup is bounded by `portal-server-start-timeout` (five seconds by default).
  Failures leave diagnostics in `*portal-server*`, and a hosted app that was
  waiting stays at `about:blank`; press `g` in its buffer, or run
  `portal-hello`, to retry.
  There is no automatic restart loop.
- Emacs supervises the child through a pipe. stdout carries a versioned JSON
  readiness line and hosted action requests; stdin carries contexts and action
  results. stderr carries diagnostics. Closing stdin requests shutdown,
  including when Emacs exits unexpectedly. Normal shutdown also handles OS
  termination signals and has a forced-termination fallback.
- `portal-server-program` selects the standalone executable. At runtime it is
  launched directly, without a shell or any lookup of Bun on PATH. Runtime
  loading of `.env` and `bunfig.toml` is disabled in the compiled binary.

Control protocol version 3 announces readiness, port, and access token and
supports [hosted app actions](hosted-actions.md). The app host sends `ready`
and `request` records; Emacs sends `context`, `forget`, and `result` records.
Rebuilding publishes the host executable atomically. An already running host
keeps its old code until `portal-restart-server` is called.
