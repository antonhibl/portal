---
status: todo
---

# Add stable task IDs, dependencies, and execution order

## Problem and outcome

`portal-tasks` currently identifies a task by its file stem or folder name and
sorts by that name. A dependency written in the body is useful to a reader but
cannot drive readiness or execution order. Renaming or regrouping tasks would
also break dependencies if their identity were their location.

Add optional stable identity and dependency metadata, show what blocks each
task, and present unfinished work in a deterministic execution order. This is
the first of two changes; [nested tasks](nested-tasks.md) builds on its identity
and ordering rules. This document specifies future behavior, not an already
supported format.

## Metadata and identity decision

Use human-chosen, stable IDs in YAML for machine-readable references. Use
relative Markdown links for prose and attachments. A path is a location and
changes when a task moves; a title is editable and need not be unique. Opaque
UUIDs would add authoring friction without providing a needed capability here.

```markdown
---
id: implement-c-adapter
status: todo
depends_on:
  - extract-c-interface
---

# Implement the C adapter
```

- `id` is optional for compatibility. When present, it must be a string
  matching `^[a-z0-9]+(?:-[a-z0-9]+)*$`, unique across the configured task root.
  Authors choose it once and retain it through title changes, renames, moves,
  and conversions between standalone and folder documents. IDs are scoped to
  one root; cross-root dependencies are outside scope.
- Separate effective ID, logical location, source path, and display title.
  Without `id`, keep the existing file-stem/folder-name identity. The nested-task
  follow-up extends that fallback to a root-relative logical path. Existing
  tasks require no migration. Add an explicit ID before moving a referenced
  task; choosing its current fallback ID preserves references when that value
  fits the explicit-ID grammar. Otherwise update references when assigning it.
- Explicit IDs and fallback IDs share one namespace. Duplicate effective IDs
  are conflicts, including an explicit ID colliding with another task's
  fallback. Also retain the existing conflict for two task documents occupying
  the same logical location (`name.md` and `name/content.md`), even if they now
  declare different IDs. Report every source; never pick a winner. Check before
  completion filtering, and make all involved detail URLs report the conflict.
- Resolve `task=ID` and image requests through the discovered ID-to-source map,
  not by building a filename from an ID. Existing URLs work for tasks that keep
  their effective ID. Changing an effective ID deliberately changes its URL;
  do not add aliases, redirects, sidecars, a registry, or generated IDs on read.
- `depends_on` is optional and defaults to `[]`. When present it must be a YAML
  sequence of nonempty strings; reject null, a scalar, and non-string entries.
  Values identify effective IDs, including legacy fallback IDs. Compare using
  the existing NFC normalization and case-sensitive rules, and deduplicate
  repeated references. Treat strings as literal IDs, never paths or URLs to
  decode, resolve, or fetch. Recommend explicit stable IDs for new references.
- Only `depends_on` defines edges. Markdown links and `Blocked by` prose do not
  implicitly create dependencies. Keep ordinary relative links working via
  source-to-ID lookup, including tasks with explicit IDs. Such prose links
  still need updating when their source targets move; dependency IDs do not.

## Dependency behavior and execution order

`A depends_on: [B]` means B must have `status: done` before A is ready.
Keep persisted status exactly `todo` or `done`; readiness is derived:

- **Ready:** a todo task with valid dependency metadata whose direct
  prerequisites all resolve uniquely to valid done tasks, or which has none.
- **Blocked:** a todo task with an unfinished or unresolved prerequisite, a
  dependency cycle, or invalid dependency metadata. Show the reasons.
- **Done:** the saved status. Do not change it based on dependency state, infer
  completion from descendants, or mark tasks complete in the UI.

Discover and validate all tasks, including completed tasks, before evaluating
dependencies. An absent, invalid, or conflicting target is an unresolved
prerequisite, not a satisfied one. Invalid `depends_on` must leave an otherwise
valid task and its body visible, marked with a dependency problem. Existing
invalid status/title/ID behavior still prevents an ordinary task row. Report
dependency problems with source paths and IDs even when completion is hidden.

Build the execution graph from unfinished tasks with edges from prerequisite
to dependent. Done prerequisites satisfy their incoming references and are
removed from this graph: their historical prerequisites do not reopen them
or block their dependents. Diagnose bad historical references on done tasks,
but only cycles among unfinished tasks prevent execution. Detect self-edges
and multi-task cycles and name their members.

Use a stable topological sort; when multiple tasks are eligible, choose the
smallest effective ID by the existing case-sensitive code-unit comparison.
Tasks with broken dependency metadata, unresolved targets, or cycles, and all
unfinished tasks transitively dependent on them, have no valid execution rank.
Show them after the ordered work in a clearly labeled dependency-problems
section, sorted by ID. Ordinary blocked tasks whose prerequisites can be
completed still get ranks after those prerequisites. Unrelated work remains
usable when part of the graph is broken.

Ranks describe an order in which the remaining tasks could be completed, not
permission to start every listed task immediately. For `A -> B -> C`, where
the arrow means "must finish before", show A, B, C, with only A ready. Reloading
after A is marked done makes B ready and removes A from the unfinished order.

## UI and implementation scope

- The current flat list becomes the execution view. Show execution position,
  title, saved status, and readiness/blocker summary. On detail pages, show
  the effective ID and a generated **Depends on** section with linked titles,
  IDs, and completion status; explain unresolved references inline. Also show
  reverse **Blocks** links, derived from the same graph, to expose impact.
- Keep dependency targets navigable even when completed tasks are hidden.
  **Show completed** adds a separate completed section ordered by ID, without
  changing the unfinished graph or ranks. A done task's detail keeps its saved
  status and displays its dependency information without a ready/blocked badge.
- Preserve root, completion filter, heading fragments, and the current view
  through list/detail/dependency navigation, Back/Forward, `g`, and app host
  restart. The follow-up adds a tree view using this same graph and metadata.
- Build one consistent discovery/index/graph snapshot per request and reuse it
  for resolution, links, and rendering. Reread saved files on reload as today;
  no watcher, database, cross-request cache, or writes while browsing. Keep
  list rendering independent of full Markdown-body and attachment rendering.
- Update README task authoring and `docs/task-browser-spec.md`, then update
  `.agents/skills/author-tasks/SKILL.md` to teach `id` and `depends_on` once they
  work. Retain `Blocked by` prose for rationale. Migrating unrelated existing
  backlog dependencies is outside this task.

Start with `host/tasks.ts` (classification, discovery, resolution, `taskAt`,
attachment base, list/detail), `host/tasks.css`, `test/portal-server-tests.el`,
`test/portal-tasks-tests.el`, and `test/portal-tasks-gui-tests.el`.
Keep Emacs project selection and the existing hosted-app lifecycle intact.
No product decisions remain open; choose internal graph helpers and markup
during implementation without changing the contracts above.

## Acceptance criteria and verification

- [ ] Existing tasks without new fields retain their identities, URLs, status,
  title behavior, attachment bounds, and relative-link behavior.
- [ ] Metadata examples parse; malformed IDs/dependency lists and collisions
  produce actionable diagnostics. Duplicate definitions with different status
  values or different explicit IDs never silently select one source.
- [ ] Renaming an explicitly identified task, or converting `x.md` to
  `x/content.md`, preserves dependency resolution, detail URLs, and image
  requests. A source link opens the correct effective-ID detail page.
- [ ] Real-filesystem/HTTP tests cover chains, diamonds, independent tasks,
  deterministic tie-breaking, repeated references, self/multi-task cycles,
  missing/invalid/duplicate targets, and dependents of broken subgraphs.
- [ ] A done prerequisite unblocks its dependents even if its own historical
  dependency is unfinished or broken. Reopening it blocks them on reload.
  Completed-task filtering never changes dependency resolution or ranks.
- [ ] Dependency errors leave unrelated work and otherwise valid task details
  readable; an all-blocked root never misleadingly reports "No tasks".
- [ ] Graphical checks verify readiness labels, dependency/reverse links,
  completed prerequisites, navigation/filter preservation, and save/reload.
- [ ] `bun run --cwd host check`, `bun run --cwd host typecheck`, `./build.sh`,
  and `ctest --test-dir build --output-on-failure` pass. Record affected GUI
  checks, update authoring documentation, and mark this task done only after
  implementation and verification. Follow `AGENTS.md` for its worktree and PR.

## Blocked by

None.
