# Plain-text task browser: v1 specification

Design date: 26 September 2026. This specifies behavior to implement; it does
not describe an existing feature.

Portal presents the current project's saved Markdown tasks as a list and detail
pages in a hosted app. A task can be a single file or a folder containing its
document and attachments. Both forms have the same metadata and UI behavior.
Emacs remains the editor: v1 reads files and never writes task content or status.
[Task operations](#task-operations), added later, let Emacs save a status change.

## Entry point and launch flow

The user-facing entry point is a new interactive Elisp function, `portal-tasks`,
in `portal-tasks.el`, loaded by `portal.el`. After loading Portal, users can run
`M-x portal-tasks` or call `(portal-tasks)` from Lisp. It follows the same hosted-app
launch pattern as [`portal-excalidraw`](../portal-excalidraw.el): an Emacs command
opens an embedded Portal web view served by the bundled Bun app host.

```text
M-x portal-tasks / (portal-tasks)
  resolve the current Emacs project and its configured task root
  open or reuse that root's task buffer and Portal web view
  start the shared app host if needed; load /tasks when it is ready
  app host reads the task root and serves the list
  click a task to read its detail in the same web view
```

On first opening a root, use `portal-web-open-hosted` with the task-list route
and the `navigation` toolbar. Its existing startup lifecycle opens the view
immediately, starts the shared app host when needed, and loads the page once the
host announces readiness. Users need only invoke the Elisp command. Reopening
an existing task buffer retains its current page as specified below.

Elisp determines which project the user is working in and passes its resolved
task-root path to the app host. Bun performs discovery and rendering within that
root using the file and folder conventions below. With the default configuration,
invoking the command in a project reads that project's `tasks/` directory.

## Storage and discovery

```text
tasks/                          # configurable task root
  fix-search.md                 # standalone task
  markdown-navigation/          # task with attachments
    content.md
    mockup.png
    implementation-notes.md      # supporting document, not another task
    prototype/
      index.html
  assets/
    search.png                  # attachment used by a standalone task
  README.md                     # ordinary document if it has no status
```

Inspect only these candidate documents:

- Regular files directly under the task root with the extension `.md`.
- The regular file named exactly `content.md` in each immediate child directory.

Discovery is shallow, uses these case-sensitive names, and does not follow
symlink entries. Other files and deeper directories are supporting material.
(Nested folders replace shallow discovery with recursion; see below.)
A child directory without `content.md` is not a task or an error. A root-level
`content.md` follows the ordinary standalone-file rule.

A candidate is a task only when its opening YAML front matter contains a valid
`status`. Text in the Markdown body does not determine task status. A document
without front matter, or with valid front matter that omits `status`, is ordinary
documentation and is omitted. Malformed front matter, an invalid status, or an
unreadable candidate produces a diagnostic naming the source path. Other tasks
still load. Do not infer a default status or hide diagnostics behind the
completed-task filter.

Front matter is a YAML mapping between opening and closing `---` lines at the
start of the file; accept LF and CRLF line endings and an optional UTF-8 BOM.
An unclosed front matter block is malformed. Use Bun's YAML parser and validate
the resulting values. Unknown keys have no behavior and do not prevent discovery.

## Minimal task document

```markdown
---
status: todo
---

# Fix search

Searching with spaces returns no results.

![Search example](assets/search.png)
```

The only required metadata is `status`, a string with exactly one of these values:

| Value | Meaning | Default list |
| --- | --- | --- |
| `todo` | Work remains | Included |
| `done` | Work is complete | Hidden |

Status values are case-sensitive. A present but empty, null, or unsupported
status is invalid. Completing or reopening a task means editing this value and
saving the document. No file is moved or deleted.

Choose the display title in this order:

1. A nonempty string in the optional front matter `title` field.
2. The first level-one Markdown heading, interpreted as text for the list.
3. The task ID.

If a `title` field is present but is not a nonempty string, report invalid
metadata instead of silently falling back. Headings inside code fences do not
count. Front matter is removed before rendering the body. The detail page shows
the resolved title; when the first heading supplies it, reuse that heading
rather than displaying the same title twice. Preserve the rest of the body.

There are no required IDs, timestamps, labels, priorities, ordering fields, or
attachment manifests in the document. Optional `id` and `depends_on` fields,
added later, are described below.

## Identity and conversion

The task ID is the standalone filename with its final `.md` removed, or the
task folder's name. It must be nonempty. IDs are case-sensitive and unique within
one task root. Distinct roots may contain identical IDs.

```text
fix-search.md  ->  fix-search/content.md
task ID: fix-search in either form
```

Converting between forms keeps the task ID and detail URL. Resolve that ID to
its current source file on each request; do not encode the storage form into
the task URL. Relative attachment links may need updating when moving the
document because their base directory changes.

If both forms define the same ID, report a duplicate with both source paths.
Neither wins: omit that ID from the ordinary task rows and show a conflict on
its detail page until resolved. Detect duplicates before filtering completed
tasks. Changing a title or status preserves identity; renaming the file stem or
folder changes identity and may break references. No redirect registry is added.

### Explicit IDs

Added by [task dependencies](../tasks/task-dependencies.md). An optional
front matter `id`, a string matching `^[a-z0-9]+(?:-[a-z0-9]+)*$`, becomes the
task's effective ID in place of its file stem or folder name, which remains
its location. Renaming or converting such a task keeps its ID, detail URL,
image requests, and the dependencies on it. Explicit and name-derived IDs share
one namespace: any duplicate effective ID, and two documents at one location
even with different IDs, is a conflict naming every source, and every involved
detail URL reports it. Detail and image requests resolve the effective ID
through the per-request index; links to a task's source resolve through the
same index. An invalid `id` is a diagnostic, like an invalid status.

## Dependencies and execution order

`depends_on` is an optional YAML list of nonempty effective IDs, compared
after NFC normalization, case-sensitively, and deduplicated. Anything else
leaves the task and its body visible, marked with a dependency problem. Body
links and `Blocked by` prose create no dependency.

Status is still only `todo` or `done`. A todo task is ready when its metadata
is valid and every prerequisite resolves uniquely to a done task; otherwise it
is blocked, with reasons. A missing, invalid, or conflicting prerequisite is
unresolved, never satisfied.

The execution graph holds unfinished tasks, with edges from prerequisite to
dependent. Done prerequisites satisfy their dependents and leave the graph with
their own dependencies. A stable topological sort ranks the rest, choosing the
smallest ID by code unit when several are eligible. Tasks with invalid
metadata, unresolved prerequisites, or in a cycle of unfinished tasks
(including a self-dependency), and every unfinished task depending on them,
have no rank: they follow under **Blocked by dependency problems**, by ID.
**Problems** reports each dependency problem with source paths and IDs,
including historical ones on done tasks, whatever the filter.

The list is this execution view: position and title. Status is implied by the
section. A ready row has no label. A blocked row is dimmed and ends with a
short summary instead of blocker titles: `after` and the ranks of its
unfinished prerequisites, nearest first, then the IDs of unranked ones, at most
three and then `+N`; then its own dependency problems, such as a missing ID or
a cycle, marked as problems. Every prerequisite of a ranked task ranks above
it, so ranks always point up the list. Ranks are recomputed on each request
and are valid only for the page they appear on.

**Show completed** adds a separate completed section by ID without changing
any rank. A detail page shows the effective ID, a **Depends on** list with linked
titles, IDs, and statuses (explaining unresolved references inline), and the
reverse **Blocks** list. A done task shows its dependencies but no readiness.
Each request builds one index and graph and uses it for resolution, links, and
rendering.

## Nested folders

Added by [nested tasks](../tasks/nested-tasks.md). Discovery inspects regular
`.md` files at every depth, with bounded read concurrency, never following
symlink entries. A directory's exact `content.md` is that directory's own
task; any other Markdown file is a task in its directory. The root-level
`content.md` keeps its standalone `content` identity. Supporting Markdown with
a valid `status` is now a task, a compatibility change from shallow discovery.
An unreadable directory below the root is a diagnostic naming its path; its
siblings still load.

A task's location, and its fallback ID, is its NFC root-relative path with `/`
separators, without the final `.md` or `/content.md`; its source path is kept
separately. Explicit IDs keep URLs and dependencies across moves between
folders. `a/fix.md` and `a/fix/content.md` share a location and conflict;
`a/fix.md` and `b/fix.md` do not. Detail and image requests accept IDs of
`/`-separated segments without empty, `.` or `..` segments, and resolve them
only through the per-request index.

A directory without a usable task document is a group named after its folder:
no ID, status, or dependency edges, and shown only around visible tasks. A
directory with one is a parent task. A `content.md` without status leaves the
directory a group; an invalid or conflicting one is reported and the directory
is a group. A task file beside a same-named group directory shows as a
separate leaf. Hierarchy never implies dependency, inheritance, or completion.

Attachments and ordinary links resolve from the source document's directory,
so a nested task file's attachment base is its own folder. Links to any task
source in the root become task links through the shared source-to-ID index.

The list has a tree view (the default) and the execution view above, chosen by
`view=tree` or `view=execution`; a missing value is the tree. Every list, task,
dependency and breadcrumb link keeps the root, view, and filter. The tree uses
nested lists and `<details>` disclosures, initially open, separate from task
links. Siblings are ordered by the smallest execution rank in their visible
subtree, unranked nodes last, then by location, placing a group before a leaf
at the same location. Groups show no status or rank. Because the tree mixes
statuses, its done rows carry a done badge; rows otherwise match the execution
view, including the dimmed `after` summary of blocked tasks. With the completed
filter off, a done parent stays as a contextual row above visible unfinished
tasks. The execution view adds each task's folder breadcrumb. Both views use
one dependency graph built over all tasks before filtering. Detail pages show
folder breadcrumbs: a parent task links to its page, and a group to the list,
at its row when that list is the tree. Back/Forward keeps disclosure state with WebKit's page history; `g`
reopens it.

## Task operations

Added by [task browser operations](../tasks/task-browser-operations.md). List
rows and detail pages have **Complete** (todo) or **Reopen** (done) and **Edit in
Emacs** buttons, shown only to the Portal view registered for the page's root.
A row's buttons follow its link, outside it, so activating one never follows
the link. Status stays exactly `todo` or `done`.

**Page script and policy.** Task pages carry one inline script, the page script
in `host/tasks-client.ts`, allowed by its SHA-256 in the page's CSP along with
`connect-src 'self'`. Task content still runs nothing: raw HTML stays text, and
no other script source is allowed. Task pages use `Referrer-Policy: same-origin`
so their POSTs carry a verifiable Origin.

**Commands.** A button posts JSON `{root, context, task, action, status}` to
`/tasks/action`. The app host admits it as it does the Implement form: same
origin, bounded body, and a context registered for that root. It resolves the
ID through the per-request index, so both storage forms and moved tasks work,
then asks Emacs through the [hosted action](hosted-actions.md) pipe to run
`task.status` or `task.edit`. Actions run one at a time, and the request names
the target status, so a repeated or duplicated request finds the task already
there and changes nothing. The reply is `{}` once Emacs has saved the file, or
`{error}` to show.

**Patch planning.** The app host plans a status edit from the file's bytes,
with the reader's own front matter parser. The file must be valid UTF-8 (a BOM
is kept). Its front matter must hold exactly one entry of the form
`status: todo`, in block or flow style, with the key and value plain,
single- or double-quoted, followed by a comment, a comma, `}` or the line end.
Only the value changes, keeping its quotes. The edited text must read back as
the same body and the same front matter with only `status` changed; anything
else, such as a tag, an anchor, an explicit key, a duplicated key, or a
lookalike inside another value, is refused with an explanation, and the
document is left for Emacs. Discovery still reads every valid form. The bytes
planned from must still classify as the requested task, so a file that another
task replaced since discovery is refused.

**Applying.** Emacs receives the byte range, its replacement, and the SHA-256
of the bytes the plan was made from. It refuses a file with unsaved changes in
a visiting buffer, one another Emacs has locked, a read-only one, or one whose
bytes changed since the plan. Otherwise it replaces those bytes and writes the
result, with no conversion, backup or save hooks, to a new file beside the task
that is flushed to disk, given the task's modes and extended attributes, and
renamed over it, as `file-precious-flag` saves do. Just before the rename,
Emacs checks the task's hash again and refuses if it changed during the write.
No rename can be conditional on the target, so a save by another program that
lands between that check and the rename is still lost: the same window every
editor's save has. A failed write is reported and leaves the task as it was.
An unmodified visiting buffer is then reverted.
Only a file inside the view's root is written; nothing is committed or moved,
and each checkout's copy stays independent.

**Edit in Emacs** visits the resolved source with the local-file handoff:
another pane, an existing buffer reused as it is, Emacs given the keyboard, and
`portal-preview-return` coming back. It visits source even if Markdown later
opens elsewhere by default.

**Refresh.** After any save in Emacs of a file inside a task root, and after a
status edit, Emacs sends `{"type": "refresh"}` over the bridge to that root's
loaded view. The page fetches its own URL and replaces its `<main>`, keeping
its URL and history, `<details>` states by row ID, scroll position, and focus
by button, link or disclosure, and only moving focus while the page has it.
A hidden page defers the refresh until it is visible, and a page that Back or
Forward restores from the page cache refreshes the same way. After an action,
a row the filter now hides passes focus to the row that took its place. An
error page (missing, invalid or conflicting task) keeps its diagnostics and
its link to the list. `g` stays the full reload, including for changes made
outside Emacs.

## Project and root selection

Add `M-x portal-tasks` and a `portal-tasks-directory` option defaulting to
`tasks/`. Resolve a relative option against the current Emacs project's root;
an absolute option is used directly. Resolve the option in the original editing
context before creating the task buffer, honoring that project's directory-local
configuration even when invoked from an auxiliary buffer.

Use the editing-project context approach already used by
[quick terminals](../portal-terminal-quick.el), including the last file/Dired
context when invoked from an auxiliary buffer. Outside a project, prompt for
a local task root. A prefix argument explicitly chooses a different task root.
Reject remote Emacs paths. Normalize the root to an absolute path, resolving
existing symlink components, and retain it for the lifetime of that task view.

Each view shows one root. Reinvoking the command for that root reuses its buffer
and current page; another project can have its own view. The resolved root is
passed explicitly to the shared app host. Its process working directory is not
the user's current project.

A missing root shows an explanatory empty page without creating a directory.
A root that is unreadable or is a file shows an error. An existing empty root
shows “No tasks”; a root containing only completed tasks offers “Show completed”.

## List, detail, and navigation

Add the task browser under `/tasks` on the existing token-protected app host.
Use ordinary page navigation and the existing `navigation` toolbar. Example
logical routes below omit the app host's token prefix; query values are URL
encoded, including paths, spaces, non-ASCII characters, and task IDs.

```text
/tasks?root=ROOT                       # unfinished tasks
/tasks?root=ROOT&show=all              # all tasks
/tasks?root=ROOT&task=ID               # detail
/tasks?root=ROOT&task=ID&show=all       # detail reached from all tasks
/tasks?root=ROOT&view=execution         # execution view (nested folders)
```

- Show each task's resolved title and status, ordered by task ID using a
  deterministic, case-sensitive comparison. There is no persisted sort order.
  (Dependencies replace this with the execution order described above.)
- The “Show completed” toggle switches between `todo` only and both statuses.
  A done task remains accessible through its detail URL with either filter.
- Clicking a row opens its complete Markdown body in the same view. A “Tasks”
  link returns to the list with the same root and filter.
- Toolbar Back/Forward use WebKit history and restore reading positions and
  filter state. Following a new link after Back behaves like normal browsing.
- Keep the current hosted route synchronized with Emacs after navigation,
  including Back/Forward, so `g` reloads the displayed page. A restarted app host
  can load the current route with its new token; old history entries need not
  survive restart.
- A missing, newly invalid, or conflicting task shows a recoverable detail error
  with a link to its task list. Do not redirect silently to another task.

Read saved files on each request and apply the existing no-store response
policy. A reload reflects changes to content, status, discovery, and attachments.
Back/Forward may restore an already loaded page; reload is the explicit freshness
boundary. No watcher, polling loop, or rendering of unsaved buffers is required.
(Task operations add an in-place refresh when Emacs saves, and revalidate pages
that history shows again.)

## Attachments and links

Resolve local links and inline images from the source document's directory.
The attachment base for a standalone task is the task root; for a folder task
it is that task's folder. No attachment list or naming convention is required.

- Inline local images render through a token-protected file route on the app
  host. A broken image leaves the rest of the task readable.
- A link to another discovered task's source document opens its task detail in
  the same view, preserving the root, filter, and heading fragment. This lookup
  may cross task folders within the configured root, including for done tasks.
- Other local file links open the saved file in Emacs through the local-file
  handoff described in the [Markdown navigation specification](../tasks/08-markdown-preview-links.md).
  Supporting Markdown is an ordinary file, not another discovered task. Opening
  an attachment preserves the task page and its navigation history. Mock-up HTML
  and code open as source; they are not executed by the task browser.
- Same-document anchors retain normal behavior. External HTTP(S) links use the
  existing default-browser behavior.

Local attachment reads and handoffs must remain within the applicable attachment
base after path decoding and realpath resolution, including symlinks. The
cross-task-link rule applies only to recognized task source files inside the
task root. Escaping paths and unsupported local targets produce an explanatory
error without replacing the task with unrelated content. Keep Markdown raw HTML
non-executable, escape metadata in HTML, and retain the app host's token and Host
checks for every new route.

## Implementation boundaries

Emacs owns project selection, buffer identity, configuration, file editing, and
local-file handoff. The app host owns discovery, metadata validation, filtering,
document rendering, and bounded asset reads. Native WebKit owns browsing history
and the existing toolbar. This is a hosted app, not a new Portal view kind.

Reuse [the app host](../host/server.ts), [Markdown rendering and styles](../host/markdown.ts),
and the shared web-view lifecycle. Current-page tracking and local-file handoff
overlap with the Markdown navigation specification; implement or reuse that
shared behavior rather than introducing a second protocol. This does not require
the unrelated toolbar additions in that specification.

List requests extract metadata and a title without rendering every task body or
reading attachments. Detail requests render only the selected document. Start
with direct reads; no database, persisted index, metadata sidecar, or cache is
required. Bun 1.3.14 was checked to provide `Bun.YAML.parse`.

## Acceptance criteria

- [ ] Loading `portal.el` makes `portal-tasks` available both through M-x and as
  a callable Elisp function.
- [ ] Invoking it in a project with the app host stopped opens a Portal web view,
  starts the shared app host automatically, and loads that project's task list
  when the host is ready, using the configured task root and navigation toolbar.
- [ ] A mixed root discovers valid standalone and folder tasks, ignores ordinary
  documents without status, and never recursively discovers supporting Markdown.
- [ ] Both statuses and all three title sources work; invalid front matter,
  unreadable candidates, and duplicate IDs are reported without hiding valid tasks.
- [ ] Moving `name.md` to `name/content.md` preserves its ID and detail URL;
  simultaneous definitions conflict even when one is done.
- [ ] Done tasks disappear from the default list after reload, remain on disk,
  appear under “Show completed”, and remain directly accessible.
- [ ] Project-relative and absolute configuration, directory-local overrides,
  explicit root selection, auxiliary-buffer context, and two concurrent roots work.
- [ ] List/detail links and Back/Forward preserve root, filter, and reading
  positions; `g` and recovery after an app host restart load the current route.
- [ ] Inline images work for both layouts; task references navigate correctly;
  other attachments open in Emacs without executing mock-up code or losing history.
- [ ] Encoded paths, fragments, missing files, invalid roots, traversal attempts,
  symlink escapes, raw HTML, and unauthorized asset requests are handled explicitly.
- [ ] Reload reflects saved content/status changes and task additions/removals;
  merely browsing never writes or moves task files.
- [ ] App host tests cover real filesystem discovery, parsing, filtering, and
  assets. Batch Emacs tests cover project/root selection and view reuse. Graphical
  tests verify actual history, scroll restoration, and attachment handoff.
- [ ] README documents the command, configuration, two storage forms, status/title
  rules, attachment bases, and save-then-reload workflow.

## Scope

V1 has one list, a completion filter, and task details. Web editing, web status
buttons, automatic refresh, comments, executable mock-up previews, cross-project
aggregation, cross-branch reconciliation, and migration of existing documents
are outside this implementation; [task operations](#task-operations) later
added status buttons and refresh. The repository tasks were subsequently migrated
to the default `tasks/` root with status front matter; browse them with `M-x portal-tasks`.

## Research basis

Backlog.md was inspected at commit
[`c310b7087c3d8d618520bfe4b9918e1c8bc468c4`](https://github.com/MrLesk/Backlog.md/tree/c310b7087c3d8d618520bfe4b9918e1c8bc468c4).
It keeps task fields in [YAML front matter](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/markdown/parser.ts#L146-L215)
and [reads task files when listing](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/file-system/operations.ts#L858-L998),
with bounded concurrency and reuse of parsed results for unchanged text.
This supports considering a file-based approach, but does not establish Portal's
performance. Separate metadata files avoid body bytes on a cold list while still
requiring discovery and one metadata read per task. Measure a real bottleneck
before changing the format for speed. [Bun's YAML API](https://bun.com/docs/runtime/yaml)
provides the parser; the hybrid discovery and identity rules above are Portal's
own conventions.
