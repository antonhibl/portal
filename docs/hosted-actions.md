# Hosted app actions

Server-rendered hosted apps can invoke native operations through the app host.
A task detail's **Implement with Claude** button is the first user. It submits
an ordinary HTML form; task content still cannot execute scripts. The task
browser's **Complete**, **Reopen** and **Edit in Emacs** buttons use the same
path from the task page script (see [task operations](#task-operations)).

```text
Task form POST → Bun task handler → process stdout → Emacs command loop
                                                    ↓
                                              terminal.open
                                                    ↓
Task detail GET ← HTTP 303 ← process stdin ← terminal target / error
```

The hosted-page bridge remains the channel between a page and its buffer for
page-local interactions such as Excalidraw synchronization. App-host actions use
the existing parent/child process pipes; they do not add sockets or WebSockets.
Both paths reach Emacs, which owns buffers, native view lifetime, placement, and
keyboard focus. Bun does not own terminal sessions.

## Registering an instance

A feature calls `portal-actions-enable` in its buffer with JSON properties and
an alist of explicit operation names to Elisp handlers. Each handler accepts an
arguments plist and returns a result plist. Unsupported operations are rejected.

Before loading a hosted page, `portal-web.el` registers the view's properties
with the app host and adds a `context` query parameter to the URL. The context
is the native target, treated as an opaque handle by the page. It identifies a
single live incarnation, independently of buffer names, paths, or selected
panes. Navigation preserves it. Reload after an app host restart registers the
context again before loading the new URL. Closing the view unregisters it;
queued requests also verify the native target is still live before acting.

The task feature captures its project root when opened: the task folder's
project, or the originating editing project for an external task folder. A
folder outside any known project stays browsable but cannot launch Claude.
Configuration of `portal-tasks-claude-program` and
`portal-tasks-claude-arguments` is captured for each newly opened task view.

## Process protocol, version 3

Records are UTF-8 JSON objects, one per line, at most 64 KiB per record. Both
readers handle partial and batched lines. stdout is exclusively protocol;
diagnostics use stderr. EOF on stdin retains its existing shutdown meaning.

Emacs sends:

- `context`: `id` and feature `properties`, registered before page loading.
- `forget`: `id`, when that view closes.
- `result`: request `id` plus either `value` or `error`.

The app host sends its existing `ready` record (now protocol 3), followed by
`request` records carrying `id`, `context`, `operation`, `arguments`, and an
absolute `deadline` in milliseconds. Requests time out after 15 seconds.

The process filter parses and queues requests as `portal-action` input events.
Only the Emacs command loop invokes handlers. It verifies the original app host
process, deadline, live source view, and registered operation, then runs the
handler in the source's buffer with its pane selected. The source keeps the
keyboard unless the handler moves it, as `terminal.open` and `task.edit` do.
A request from a replaced process cannot affect the new host. Repeated request
IDs are ignored within one host lifetime.

Success means the native operation returned successfully. In particular,
`terminal.open` returns a terminal target; it does not prove Claude has logged
in, started responding, or completed the task. Timeouts do not retry a launch.
The UI asks the user to check for an existing result before retrying an uncertain action.

## Task implementation

Task detail responses mint bounded, ten-minute form receipts tied to their
registered context and task ID. The POST accepts only same-origin URL-encoded
forms. Task details use `Referrer-Policy: same-origin` so WebKit sends a
verifiable Origin on the POST while still withholding referrers from external
destinations. It retrieves those server-owned values instead of accepting a program,
project, or operation from the browser. Duplicate POSTs share one result,
including while the first launch is pending. GET, reload, and Back never launch.
The app host retains at most 1024 receipts; older pages may require a reload.

At POST time, the existing task index resolves the ID again. Standalone files,
nested files, explicit IDs, and folder `content.md` tasks use the same resolver
as task details. Missing, conflicting, invalid, or escaping sources fail before
launch. A task moved since rendering launches from its current path.

The request to `terminal.open` supplies the project root as `directory`, the
configured Claude executable, arguments defaulting to
`["--dangerously-skip-permissions"]`, and the initial prompt
`implement @tasks/path/to/task.md`. The task path is relative to that project
root, including `../` for a configured task folder outside it. Whitespace in
references is quoted inside the prompt. Native command quoting is independent.
No worktree is created and no task status is changed by launching.

`portal-terminal-start` accepts directory, program, literal arguments, and an
optional buffer name. It sends a JSON `:argv` array to the native adapter and
opens a dedicated terminal with `pop-to-buffer`, using Emacs display rules. The
adapter starts the user's interactive login shell, lets it load its startup
files, restores the requested working directory, then uses `exec` to run the
requested program. Program names are resolved
on the shell's PATH; Emacs does not need to find them. Arguments are quoted as
literal values, including spaces, quotes, Unicode and shell metacharacters.

The native adapter chooses the shell from the native `SHELL` environment or the
user's login-shell record, as Ghostty does for an ordinary terminal. Program
launches support POSIX-compatible shells (`sh`, `bash`, `zsh`, `dash`, `ksh`) and
fish. The shell owns its environment; Lisp-side `setenv`, buffer-local
`process-environment`, and `exec-path` do not affect the launched program.
Ghostty supplies terminal metadata and shell integration. Portal continues to
supply its own terminal appearance and bindings; it does not import the
standalone Ghostty app's configuration file.

The command is supplied at surface creation, with no delayed paste or simulated
typing. Missing programs are reported by the shell inside the terminal, whose
last output stays visible after exit. Hidden terminals continue running;
closing their buffers ends their sessions. Closing the task browser does not close
a launched terminal. The raw native `:command` option remains available for
callers that intentionally replace the normal shell.

The POST redirects back to the task detail with a receipt showing success or an
escaped error message. Filter, execution/tree mode, and source context are
preserved. This form-only flow navigates the page and may reset its reading
position; a future fetch enhancement can preserve it without changing the
native operation or process protocol.

## Task operations

A task browser registers two more operations, which change nothing but the one
task file and never move the keyboard unless asked to:

- `task.status` with `file`, `start`, `end`, `text` and `before`: replace bytes
  `start` to `end` of `file` with `text`, if `file` still has the SHA-256
  `before`. The app host resolved the task and planned the edit; Emacs refuses
  a buffer with unsaved changes, a file locked by another Emacs, a read-only,
  changed or replaced file, or a file outside the view's root, then replaces
  the file whole, checking its hash again just before the rename, and reverts an unmodified visiting buffer. The page keeps the
  keyboard.
- `task.edit` with `file`: visit it in another pane with the local-file
  handoff, which gives Emacs the keyboard.

The page posts JSON to `/tasks/action` with its `root`, `context`, task ID,
`action` (`status` or `edit`), and for a status change the target `status`. The
route admits requests as the form does (same origin, bounded body, registered
context and root), runs them one at a time, and answers `{}` after Emacs has
finished, or `{error}` with a message to show. A status change to the status a
task already has succeeds without asking Emacs, so a repeated or duplicate
request never toggles a task back. After saving, Emacs asks the root's view to
refresh over the [bridge](editor-bridge.md). The
[task browser specification](task-browser-spec.md#task-operations) has the
patch rules and refresh behavior.

## Verification

`ctest --test-dir build --output-on-failure` includes app-host form/action tests
and the compiled-host → Emacs → fake-native launch flow. They cover ID-preserving
moves, duplicate delivery, errors, closed/expired sources, foreign origins,
root mismatch, reload/restart, literal shell arguments, and failed creation.

The same run sends task status changes, a repeated change, a refusal over
unsaved changes, and Edit in Emacs from the compiled host through the command
loop. `bun test host` covers the task action route and its status planning, and
the task browser's graphical tests click and key the task buttons in WebKit.

`portal-tasks-gui-implement-post-starts-a-native-terminal` exercises a real
WebKit form click, the process pipe, command-loop handoff, and Ghostty PTY. A
local probe executable records cwd and argv, including Unicode, whitespace,
and quotes. It verifies terminal focus, the retained task page, and reload
without a second launch. It never starts Claude or makes a model request.

The pinned Ghostty [embedded surface implementation](https://github.com/ghostty-org/ghostty/blob/82938b633ba6/src/apprt/embedded.zig#L440) accepts a shell command. Its macOS process wrapper supplies `exec`; Portal passes only the quoted executable and arguments.
