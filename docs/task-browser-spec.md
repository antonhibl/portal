# Plain-text task browser: v1 specification

Design date: 26 September 2026. This specifies proposed, not existing, behavior.

Portal hosts list and detail pages for the current project's saved Markdown tasks.
Single-file and folder tasks (document plus attachments) share metadata and UI
behavior. Emacs remains the editor: v1 never writes task content or status.
Later [task operations](#task-operations) let Emacs save status changes.

## Entry point and launch flow

The proposed interactive Elisp entry point was `portal-tasks` in `portal-tasks.el`,
loaded by `portal.el`; it is now `portal-tasks-browser`, since `portal-tasks`
lists `project.org` tasks with org-ql. After loading Portal, run
`M-x portal-tasks-browser` or `(portal-tasks-browser)`. Like
[`portal-excalidraw`](../portal-excalidraw.el), it opens an embedded Portal web
view served by the bundled Bun app host.

```text
M-x portal-tasks-browser / (portal-tasks-browser)
  resolve the current Emacs project and its configured task root
  open or reuse that root's task buffer and Portal web view
  start the shared app host if needed; load /tasks when it is ready
  app host reads the task root and serves the list
  click a task to read its detail in the same web view
```

First opening uses `portal-web-open-hosted` with the task-list route and
`navigation` toolbar. Its lifecycle immediately opens the view, starts the shared
host if needed, and loads the page when the host announces readiness. Only the Elisp command is needed.
Reopening retains the task buffer's current page, as specified below.

Elisp selects the project and passes its resolved task-root path to Bun for
discovery and rendering under the conventions below. By default, the command reads
the project's `tasks/` directory.

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

Inspect only these candidates:

- Regular `.md` files directly under the task root.
- The regular file named exactly `content.md` in each immediate child directory.

Discovery is shallow and case-sensitive, without following symlink entries.
Other files and deeper directories are supporting material. (Nested folders replace
this with recursion; see below.) A child directory without `content.md` is neither
a task nor an error. Root-level `content.md` follows standalone-file rules.

Only opening YAML front matter with valid `status` makes a candidate a task;
body text never determines status. Omit ordinary documentation without front matter or with
valid front matter lacking `status`. Malformed front matter, invalid status, and
unreadable candidates produce source-path diagnostics without stopping other tasks.
Never infer default status or hide diagnostics behind the completed-task filter.

Front matter is a YAML mapping between opening and closing `---` lines at file start.
Accept LF, CRLF, and an optional UTF-8 BOM. Unclosed blocks are malformed. Use
Bun's YAML parser and validate values. Unknown keys neither affect behavior nor
prevent discovery.

## Minimal task document

```markdown
---
status: todo
---

# Fix search

Searching with spaces returns no results.

![Search example](assets/search.png)
```

Only `status` is required: a string with exactly one of these values:

| Value | Meaning | Default list |
| --- | --- | --- |
| `todo` | Work remains | Included |
| `done` | Work is complete | Hidden |

Status is case-sensitive; present but empty, null, or unsupported values are
invalid. Complete or reopen by editing and saving this value, without moving or
deleting files.

Choose the display title in order:

1. A nonempty string in optional front matter `title`.
2. The first level-one Markdown heading, interpreted as text for the list.
3. The task ID.

Report a present `title` that is not a nonempty string as invalid metadata; do not
fall back. Ignore code-fenced headings. Remove front matter before rendering.
Details show the resolved title, reusing the first heading when it supplies the
title rather than duplicating it. Preserve the remaining body.

IDs, timestamps, labels, priorities, ordering fields, and attachment manifests
are not required. Later optional `id` and `depends_on` fields are described below.

## Identity and conversion

The task ID is the standalone filename minus final `.md`, or the task folder's
name: nonempty, case-sensitive, and unique within a root. Roots may share IDs.

```text
fix-search.md  ->  fix-search/content.md
task ID: fix-search in either form
```

Conversion preserves ID and detail URL. Resolve IDs to current source files on each
request; never encode storage form in task URLs. Moving documents changes their
base directory and may require relative attachment-link updates.

If both forms share an ID, report both source paths; neither wins. Omit the ID
from ordinary rows and show a detail-page conflict until resolved. Detect duplicates
before completed filtering. Title or status changes preserve identity; renaming
file stems or folders changes it and may break references. No redirect registry is added.

### Explicit IDs

Added by [task dependencies](../tasks/task-dependencies.md). Optional front matter
`id`, a string matching `^[a-z0-9]+(?:-[a-z0-9]+)*$`, replaces the file stem/folder
name as effective ID; the name remains its location. Renaming or conversion
preserves ID, detail URL, image requests, and dependencies. Explicit and name-derived IDs
share a namespace. Duplicate effective IDs, or two documents at one location even
with different IDs, conflict: name every source and report on every involved detail
URL. Detail and image requests resolve effective IDs through the per-request index;
source links use that index too. Invalid `id` produces a diagnostic like invalid
status.

## Dependencies and execution order

`depends_on` is an optional YAML list of nonempty effective IDs, compared
case-sensitively after NFC normalization and deduplicated. Anything else marks a
dependency problem without hiding the task or body. Body links and `Blocked by` prose
create no dependency.

Status remains `todo` or `done`. Todo tasks are ready only with valid metadata and
every prerequisite uniquely resolved to a done task; otherwise blocked, with
reasons. Missing, invalid, or conflicting prerequisites are unresolved, never
satisfied.

The execution graph contains unfinished tasks, with prerequisite-to-dependent
edges. Done prerequisites satisfy dependents and leave the graph along with their
own dependencies. A stable topological sort ranks the rest, choosing the smallest
ID by code unit among eligible tasks. Invalid metadata, unresolved prerequisites,
or unfinished-task cycles (including self-dependency) leave tasks and their
unfinished dependents unranked, listed by ID under **Blocked by dependency
problems**. **Problems** reports every dependency problem with source paths and IDs,
including historical problems on done tasks, regardless of filter.

The execution list shows position and title; section implies status. Ready rows
have no label. Blocked rows are dimmed and end with a short summary, not blocker
titles: `after`, unfinished prerequisite ranks nearest first, then unranked IDs,
at most three followed by `+N`; then the task's own dependency problems (such as
missing IDs or cycles), marked as problems. Done titles are dimmed and struck
through. Ranked tasks' prerequisites always rank above them, so ranks point up.
Recompute ranks per request; they apply only to their page.

**Show completed** adds a separate ID-ordered completed section without changing
ranks. Details show effective ID, **Depends on** with linked titles, IDs, statuses
and inline unresolved-reference explanations, and reverse **Blocks**. Done tasks
show dependencies, not readiness. Each request builds one index and graph for
resolution, links, and rendering.

## Nested folders

Added by [nested tasks](../tasks/nested-tasks.md). Discovery inspects regular `.md`
files at every depth with bounded read concurrency, never following symlink
entries. Exact `content.md` is its directory's own task; other Markdown files
are tasks in that directory. Root-level `content.md` retains standalone `content`
identity. Supporting Markdown with valid `status` now becomes a task, a
compatibility change from shallow discovery. Unreadable subdirectories produce path diagnostics;
siblings still load.

Location and fallback ID are the NFC root-relative path with `/` separators,
minus final `.md` or `/content.md`; retain the source path separately. Explicit
IDs preserve URLs and dependencies across folder moves. `a/fix.md` and
`a/fix/content.md` share a location and conflict; `a/fix.md` and `b/fix.md` do not.
Detail and image requests accept `/`-separated IDs without empty, `.` or `..` segments,
resolved only through the per-request index.

A directory without a usable task document is a folder-named group: no ID, status,
or dependency edges, visible only around visible tasks. With one, it is a parent
task. Status-less `content.md` leaves a group; invalid or conflicting documents are
reported and also leave a group. A task file beside a same-named group is a
separate leaf. Hierarchy implies no dependency, inheritance, or completion.

Attachments and ordinary links resolve from the source directory: a nested task
file's attachment base is its own folder. Source links to any task in the root
become task links through the shared source-to-ID index.

Choose tree (default) or execution view with `view=tree` or `view=execution`;
missing values select tree. All list, task, dependency, and breadcrumb links
retain root, view, and filter. Tree uses nested lists and initially open
`<details>` disclosures separate from task links. Order siblings by smallest
visible-subtree execution rank, unranked last, then location; groups precede
leaves at the same location. Groups show no status or rank. Tree mixes statuses, so
done rows have a done badge; other rows match execution view, including dimmed
`after` summaries. With completed filtering off, done parents remain contextual
rows above visible unfinished tasks. Execution view adds folder breadcrumbs.
Both views use one all-task graph built before filtering. Detail breadcrumbs
link parent tasks to their pages and groups to the list, at their row in tree
view. WebKit history retains disclosure state on Back/Forward; `g` reopens it.

## Task operations

Added by [task browser operations](../tasks/task-browser-operations.md). List rows
and details offer **Complete** (todo) or **Reopen** (done) and **Edit in Emacs**,
only in the Portal view registered for the page's root. Row buttons follow links
but sit outside them, so activation never follows the link. Status remains exactly
`todo` or `done`.

**Page script and policy.** Pages carry one inline script from
`host/tasks-client.ts`, allowed by SHA-256 in CSP alongside `connect-src 'self'`.
Task content runs nothing: raw HTML remains text; no other script source is
allowed. `Referrer-Policy: same-origin` gives POSTs a verifiable Origin.

**Commands.** Buttons post JSON `{root, context, task, action, status}` to
`/tasks/action`. Admission matches the Implement form: same origin, bounded body,
and context registered for that root. The host resolves IDs through the per-request
index (supporting both storage forms and moves), then asks Emacs via the
[hosted action](hosted-actions.md) pipe to run `task.status` or `task.edit`.
Actions run serially and name the target status; repeated or duplicate requests
find it already set and change nothing. Reply `{}` after Emacs saves, or `{error}` to display.

**Patch planning.** The host plans from file bytes using the reader's front matter
parser. Require valid UTF-8; keep any BOM. Front matter must contain exactly one
entry of the form `status: todo`, block or flow style, with plain, single- or
double-quoted keys and values, followed by a comment, comma, `}` or line end. Change
only the value, retaining quotes. Read-back must preserve the body and all front
matter except `status`. Refuse anything else (tags, anchors, explicit keys,
duplicate keys, or lookalikes inside other values) with an explanation, leaving
the document for Emacs. YAML retains only the last duplicate key, so detect
duplicates by renaming the entry's key and checking that no `status` remains,
regardless of other-key syntax. Discovery still reads every valid form. Planned
bytes must still classify as the requested task; refuse files replaced by another
task since discovery.

**Applying.** Emacs receives the byte range, replacement, and planned bytes'
SHA-256. Refuse files with unsaved visiting buffers or locks held by another Emacs.
Also refuse read-only files or bytes changed since planning. Otherwise replace the
bytes without conversion, backup, or save hooks. Write to a new adjacent file, flush to disk, give it the task's modes and
extended attributes, then rename over the task as `file-precious-flag` saves do.
Recheck the task hash just before rename; refuse changes during the write. Rename
cannot be conditional on its target: another program's save between check and
rename is still lost, as in every editor's save window. Report failed writes,
leaving the task unchanged. Then revert any unmodified visiting buffer.
Write only inside the view's root; commit or move nothing. Checkout copies remain
independent.

**Edit in Emacs** uses local-file handoff to visit resolved source: another pane,
reuse existing buffers unchanged, give Emacs the keyboard, return with
`portal-preview-return`. Visit source even if Markdown later opens elsewhere by
default.

**Refresh.** After any Emacs save inside a task root or status edit, Emacs sends
`{"type": "refresh"}` over the bridge to that root's loaded view. The page fetches
its own URL and replaces `<main>`, retaining URL and history, `<details>` states
by row ID, scroll position, and focus by button, link or disclosure. Move focus only while
the page has it. Hidden pages defer until visible; Back/Forward page-cache restores
refresh likewise. After actions, a filtered-out row passes focus to its replacement
row. Missing, invalid, or conflicting task error pages retain diagnostics and list
links. `g` remains full reload, including for changes outside Emacs.

## Project and root selection

Add `M-x portal-tasks` and `portal-tasks-directory`, default `tasks/`. Resolve
relative options against the current Emacs project root; use absolute options
directly. Resolve in the original editing context before creating the task buffer,
honoring project directory-locals even from auxiliary buffers.

Reuse [quick terminals'](../portal-terminal-quick.el) editing-project context,
including last file/Dired context from auxiliary buffers. Outside projects, prompt
for a local task root; a prefix argument explicitly selects another. Reject remote
Emacs paths. Normalize roots to absolute paths, resolving existing symlink
components, and retain them for the view's lifetime.

Each view shows one root. Reinvoking reuses its buffer and current page; other
projects can have separate views. Pass the resolved root explicitly to the shared
host; its process working directory is not the user's project.

Missing roots show explanatory empty pages without creating directories. Unreadable
roots or files used as roots show errors. Empty roots show “No tasks”; completed-only
roots offer “Show completed”.

## List, detail, and navigation

Add `/tasks` on the existing token-protected host, with ordinary navigation and
the existing `navigation` toolbar. These logical routes omit the token prefix;
URL-encode query values including paths, spaces, non-ASCII characters, and task IDs.

```text
/tasks?root=ROOT                       # unfinished tasks
/tasks?root=ROOT&show=all              # all tasks
/tasks?root=ROOT&task=ID               # detail
/tasks?root=ROOT&task=ID&show=all       # detail reached from all tasks
/tasks?root=ROOT&view=execution         # execution view (nested folders)
```

- Show resolved title and status in deterministic, case-sensitive ID order, without
  persisted sorting. (Dependencies replace this with execution order above.)
- “Show completed” switches between `todo` only and both statuses. Done details
  remain accessible with either filter.
- Rows open complete Markdown bodies in the same view. “Tasks” returns to the
  list retaining root and filter.
- Toolbar Back/Forward restore reading positions and filter through WebKit history.
  New links after Back behave like normal browsing.
- Synchronize the hosted route with Emacs after navigation, including Back/Forward,
  so `g` reloads the displayed page. Restarted hosts load the current route with
  their new token; old history need not survive.
- Missing, newly invalid, or conflicting tasks show recoverable detail errors
  linking to the task list, never silent redirects to other tasks.

Read saved files per request under the existing no-store policy. Reload reflects
content, status, discovery, and attachment changes. Back/Forward may restore loaded
pages; reload is the explicit freshness boundary. No watcher, polling, or rendering
of unsaved buffers is required. (Task operations add in-place refresh after Emacs
saves and revalidate history-restored pages.)

## Attachments and links

Resolve local links and inline images from the source directory: task root for
standalone tasks, task folder for folder tasks. No attachment list or naming
convention is required.

- Render local inline images via a token-protected host file route. Broken images
  leave the task readable.
- Links to discovered task sources open details in the same view, preserving root,
  filter, and heading fragment. Lookup may cross folders within the root, including
  done tasks.
- Other local links open saved files in Emacs via the
  [Markdown navigation specification's](../tasks/08-markdown-preview-links.md)
  local-file handoff. Supporting Markdown is ordinary, not a discovered task.
  Attachments preserve the task page and history. Mock-up HTML and code open as source,
  never execute in the browser.
- Same-document anchors behave normally; external HTTP(S) links use the existing
  default-browser behavior.

Keep local reads and handoffs within the applicable attachment base after path decoding
and realpath resolution, including symlinks. Cross-task links apply only to
recognized task sources inside the root. Escaping paths and unsupported local
targets produce explanatory errors, never replacing tasks with unrelated content.
Keep raw Markdown HTML non-executable, escape metadata in HTML, and retain token
and Host checks on every new route.

## Implementation boundaries

Emacs owns project selection, buffer identity, configuration, editing, and
local-file handoff; the host owns discovery, metadata validation, filtering,
rendering, and bounded asset reads. Native WebKit owns history and the existing
toolbar. This hosted app is not a new Portal view kind.

Reuse [the app host](../host/server.ts), [Markdown rendering and styles](../host/markdown.ts),
and shared web-view lifecycle. Implement or reuse current-page tracking and local-file
handoff shared with the Markdown navigation specification, not a second protocol.
Its unrelated toolbar additions are unnecessary.

Lists extract metadata and titles without rendering every body or reading attachments.
Details render only the selected document. Start with direct reads: no database,
persisted index, metadata sidecar, or cache required. Bun 1.3.14 was checked to
provide `Bun.YAML.parse`.

## Acceptance criteria

- [ ] Loading `portal.el` exposes `portal-tasks` through M-x and callable Elisp.
- [ ] Invoking in a project with the host stopped opens a Portal web view, starts
  the shared host automatically, and loads that project's list when ready, with
  configured root and navigation toolbar.
- [ ] Mixed roots discover valid standalone and folder tasks, ignore status-less
  documents, and never recursively discover supporting Markdown.
- [ ] Both statuses and all three title sources work; invalid front matter, unreadable
  candidates, and duplicate IDs are reported without hiding valid tasks.
- [ ] Moving `name.md` to `name/content.md` preserves ID and detail URL; simultaneous
  definitions conflict even if one is done.
- [ ] Done tasks vanish from default lists after reload, remain on disk and directly
  accessible, and appear under “Show completed”.
- [ ] Project-relative and absolute configuration, directory-local overrides,
  explicit root selection, auxiliary-buffer context, and two concurrent roots work.
- [ ] List/detail links and Back/Forward preserve root, filter, and reading
  positions; `g` and host-restart recovery load the current route.
- [ ] Inline images work in both layouts; task references navigate; other attachments
  open in Emacs without executing mock-ups or losing history.
- [ ] Encoded paths, fragments, missing files, invalid roots, traversal, symlink
  escapes, raw HTML, and unauthorized asset requests are explicitly handled.
- [ ] Reload reflects saved content/status and task additions/removals; browsing
  never writes or moves task files.
- [ ] Host tests cover real filesystem discovery, parsing, filtering, and assets.
  Batch Emacs tests cover project/root selection and view reuse; graphical tests
  verify actual history, scroll restoration, and attachment handoff.
- [ ] README documents command, configuration, two storage forms, status/title
  rules, attachment bases, and save-then-reload workflow.

## Scope

V1 includes one list, completion filtering, and details. Web editing, web status
buttons, automatic refresh, comments, executable mock-ups, cross-project aggregation,
cross-branch reconciliation, and document migration are out of scope;
[task operations](#task-operations) later added status buttons and refresh. Repository
tasks were subsequently migrated to default `tasks/` with status front matter;
browse with `M-x portal-tasks-browser`.

## Research basis

Backlog.md was inspected at commit
[`c310b7087c3d8d618520bfe4b9918e1c8bc468c4`](https://github.com/MrLesk/Backlog.md/tree/c310b7087c3d8d618520bfe4b9918e1c8bc468c4).
It stores fields in [YAML front matter](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/markdown/parser.ts#L146-L215)
and [reads task files when listing](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/file-system/operations.ts#L858-L998),
with bounded concurrency and parsed-result reuse for unchanged text. This supports
a file-based approach, not Portal performance claims. Separate metadata files avoid
cold-list body bytes but still needs discovery and one metadata read per task. Measure a
bottleneck before changing formats for speed. [Bun's YAML API](https://bun.com/docs/runtime/yaml)
supplies the parser; hybrid discovery and identity rules are Portal's conventions.
