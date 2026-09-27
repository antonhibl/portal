---
status: todo
depends_on:
  - task-dependencies
---

# Discover nested tasks and browse their folder tree

## Problem and outcome

`portal-tasks` only discovers root-level Markdown files and immediate child
folders' `content.md`. A larger change cannot be organized into nested task
folders without hiding its work from the dashboard.

Discover tasks recursively, derive their hierarchy from folders, and show a
tree alongside the execution view introduced by the prerequisite. Preserve
stable identity independently of location. This document specifies future
behavior; keep this task at the current shallow root until it is implemented.

## Storage and discovery decision

```text
tasks/
  big refactor/                         # grouping folder; no metadata required
    extract something in c.md           # task with status front matter
    implement something/
      content.md                        # task with status front matter
      notes.md                          # ordinary support document; no status
      mockup.png
```

With headings matching the task names, the tree is:

```text
big refactor
  extract something in c
  implement something
```

- Recursively inspect regular `.md` files at every depth under the configured
  root. Preserve the case-sensitive extension, front matter parsing, and
  explicit valid-status opt-in. A directory's exact `content.md` represents
  that directory's own task; another Markdown file represents a leaf there.
  Root-level `content.md` retains its existing standalone `content` identity.
- Directories without task metadata are grouping nodes, named from the folder
  basename. They have no task ID, saved status, or dependency edges. Display
  groups only when they contain a visible task descendant; ordinary attachment
  folders and documents do not produce empty tree rows.
- A directory may contain both its own task (`content.md`) and child tasks.
  Render one parent row using that task's resolved title, with its children
  underneath. Continue discovery inside task folders. Treat a `content.md`
  without status as ordinary documentation, so the directory is still a group.
  If the parent document is invalid or conflicting, show its diagnostic and
  retain the folder as a group so valid children remain reachable.
- Supporting Markdown without status stays ordinary documentation. With
  recursive discovery, supporting Markdown that already has task-status front
  matter will now become a task; explicitly document this compatibility change.
  There is no inferred status, inherited front matter, folder manifest, or
  special `assets/` or dot-directory exclusion. Never follow symlink entries.
- Report unreadable directories and malformed candidate documents with source
  paths while continuing through readable siblings. Keep diagnostics visible
  regardless of filtering. Reuse root containment, decoding, realpath, and
  escaping protections; recursion must not read through a symlink out of root.

## Identity, links, and parent semantics

Retain the prerequisite's explicit root-wide IDs. A task's fallback identity is
its NFC-normalized, root-relative logical path using `/` separators: remove a
standalone file's final `.md`, or remove a folder document's final `/content.md`.
Store the actual source path separately from this normalized key.

```text
big refactor/extract something in c.md
  -> big refactor/extract something in c

big refactor/implement something/content.md
  -> big refactor/implement something
```

Different branches may have the same leaf name. `a/fix.md` and `b/fix.md` have
different fallback IDs. `a/fix.md` and `a/fix/content.md` have the same logical
location and conflict when both are tasks, even if explicit IDs differ. If
`a/fix.md` exists beside a grouping directory `a/fix/` without a task document,
show the leaf and group separately; distinguish them by task/group styling.
Do not infer a parent-child relationship from a shared file stem.

Explicit IDs keep dependencies and detail URLs stable when tasks move between
groups. Legacy fallback IDs retain the existing rename-sensitive behavior;
converting `a/fix.md` to `a/fix/content.md` still preserves the fallback.
Validate logical paths as relative segments without empty, `.` or `..`
segments. URL-encode IDs as query values; never use a requested ID directly
as a filesystem path. Reserve nested `content.md` for its containing directory
and retain the root-level special case above.

Hierarchy expresses organization only. A parent's `status` and `depends_on`
apply to that task alone: children do not inherit dependencies, completion
does not cascade, and depending on a parent means that parent's own saved
status is done. Grouping folders cannot be dependency targets. Authors who
want a parent to wait for its children list those child IDs in `depends_on`.

Resolve attachments and ordinary local links from the actual source document's
directory for both task forms. For a nested standalone task this deliberately
narrows the attachment base to its containing folder, not the entire root.
Cross-task links may still target any recognized task source within the root,
including completed tasks, and must use the shared source-to-ID index rather
than the old shallow `taskAt` path heuristic. Other local links and image reads
retain their attachment-boundary restrictions. Moving a document can require
updating its relative prose/attachment links even when its ID remains stable.

## Tree and execution views

The tree is the default list after this change. Add a **Tree / Execution**
switch, encoded as `view=tree` or `view=execution` in the hosted route; a missing
value means tree. Preserve view, root, and completion filter through task and
dependency links, the return-to-list link, Back/Forward, reload, and restart.

A strict folder tree cannot always be a global execution order. For example,
`a/first -> b/middle -> a/last` requires returning to folder a; keeping every
folder contiguous cannot express that sequence. Both views are necessary:

- **Tree:** each task appears once in its physical hierarchy. Use semantic
  nested lists and keyboard-operable disclosure controls, initially expanded,
  with task links separate from expand/collapse controls. Show saved status,
  readiness/blocker summary, and the shared execution rank for ranked tasks.
  A parent task has its own rank; its structural position above children does
  not assert that it executes first. Groups show no task status or rank.
- Order tree siblings by the smallest execution rank of a task anywhere in
  that node's visible subtree, including the node's own task where visible.
  Nodes without ranks follow ranked nodes. Break remaining ties by normalized
  root-relative logical path, then node kind for a leaf/group path tie, using
  case-sensitive comparison and placing the group before the leaf. Label tree
  ordering as folder browsing; only the execution view promises global order.
- **Execution:** keep the prerequisite's flat topological order across every
  folder, its separate dependency-problems section, and its completed section
  under **Show completed**. Add each task's folder breadcrumb for context.
  Use identical ranks, dependency diagnostics, and readiness in both views.
- Compute the graph over all discovered tasks before applying visibility.
  Hide done task rows by default, but preserve ancestor folders needed to show
  unfinished descendants. For a done parent with unfinished children, retain
  the parent as a contextual row with its title, done status, and detail link;
  this is the sole completed-row exception needed to preserve the hierarchy.
  **Show completed** reveals the full tree without changing unfinished ranks.
- A group whose descendants are all hidden disappears; offer **Show completed**
  when the whole root has only completed work. Empty groups are never errors.
  Keep **Problems** visible even when a corresponding branch has no rows.
  Task detail pages include folder breadcrumbs back into the selected list
  view. Back/Forward restores disclosure state with page history; `g` may reset
  it to expanded. No persisted UI preferences are required.

## Implementation scope

Extend discovery/indexing and render the hierarchy in `host/tasks.ts` and
`host/tasks.css`. Audit detail/image resolution, source links, and all ID
validators for their single-segment assumptions. Reuse the prerequisite's
graph once per request, keep saved-file/no-write behavior, and leave Emacs
project/root selection unchanged. Use bounded traversal/read concurrency;
do not start an unbounded promise for every file in a large nested tree.

Update README task examples, `docs/task-browser-spec.md`, and
`.agents/skills/author-tasks/SKILL.md` after implementation to describe recursive
discovery, group versus parent-task behavior, nested attachment bases, stable
IDs, and the two views. Do not reorganize existing repository tasks as part of
this feature. No product decisions remain open; choose traversal and rendering
helpers during implementation while retaining these contracts.

## Acceptance criteria and verification

- [ ] The exact example above appears as one group with two task children,
  with no extra `content` row. Three or more levels, mixed file/folder tasks,
  optional parent documents, empty groups, and supporting documents work.
- [ ] Real-filesystem/HTTP tests cover repeated basenames, spaces, non-ASCII
  names/NFC, encoded IDs, both duplicate rules, unreadable branches, symlink
  entries, and attempted path escapes without losing unrelated tasks.
- [ ] Moving a task with an explicit ID between groups preserves its URL and
  dependencies; converting either storage form preserves its logical location.
  Legacy top-level IDs, including root `content.md`, remain compatible.
- [ ] Parent dependencies/status do not cascade. Done or invalid parents do
  not hide unfinished children; completion filtering prunes empty groups and
  never changes the shared dependency graph or unfinished execution ranks.
- [ ] Cross-folder dependencies and the interleaving example above display a
  faithful tree and a correct global execution list. Cycles, missing targets,
  and downstream blocked tasks behave identically in both views.
- [ ] Nested source links, attachment images, and ordinary-file Emacs handoff
  resolve against the right directory and retain existing containment rules.
- [ ] Graphical tests in `test/portal-tasks-gui-tests.el` verify indentation,
  disclosure keyboard behavior, view/filter preservation, contextual done
  parents, dependency navigation, Back/Forward, and reload after saved moves.
  Extend `test/portal-server-tests.el` and affected batch task tests as needed.
- [ ] `bun run --cwd host check`, `bun run --cwd host typecheck`, `./build.sh`,
  and `ctest --test-dir build --output-on-failure` pass. Record GUI verification,
  update authoring documentation, and mark this task done only after
  implementation. Follow `AGENTS.md` for its worktree and PR.

## Blocked by

- [Add stable task IDs, dependencies, and execution order](task-dependencies.md)
  supplies the ID/source separation, dependency graph, readiness, and execution
  view; `depends_on` records it for the dashboard.
