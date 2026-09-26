# Plain-text task storage options

Research date: 26 September 2026. This note informs a design discussion; it does
not describe implemented Portal behavior. Backlog.md was inspected at commit
[`c310b7087c3d8d618520bfe4b9918e1c8bc468c4`](https://github.com/MrLesk/Backlog.md/tree/c310b7087c3d8d618520bfe4b9918e1c8bc468c4).

## What Backlog.md actually does

- Tasks are individual Markdown files in a project-local backlog directory. The
  directory can be configured with `backlog_directory` in `backlog.config.yml`.
  [README](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/README.md)
- The task parser takes identity, title, and status from YAML front matter. It
  also parses body sections and considerably more metadata than this proposal
  needs. Front matter parsing is wrapped around `gray-matter`.
  [Task parser](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/markdown/parser.ts#L146-L215),
  [front matter wrapper](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/markdown/frontmatter.ts#L1-L20)
- The default statuses are `To Do`, `In Progress`, and `Done`. Its terminal
  status is the last configured status, rather than always the literal `Done`.
  [Defaults](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/constants/index.ts#L44-L52),
  [terminal-status rule](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/utils/terminal-status.ts#L1-L16)
- Filesystem listing discovers matching task files, reads them, then applies
  status inclusion/exclusion filters. Reads have bounded concurrency. Each file
  is reread for freshness; parsed objects are cached when the exact text has not
  changed. This path does not use a separate persisted metadata index or read
  only front matter.
  [Listing and parse cache](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/file-system/operations.ts#L858-L998)
- Filtering by status is separate from moving files out of the active directory.
  Cleanup selects terminal-status tasks by age and moves them to `completed/`;
  archive has its own destination, `archive/tasks/`.
  [Cleanup endpoint](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/server/index.ts#L1898-L1987),
  [file moves](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/file-system/operations.ts#L1071-L1115)
- The server exposes a shared `backlog/assets/` directory at `/assets/*`.
  The inspected handler is not a folder-per-task attachment convention.
  [Asset handler](https://github.com/MrLesk/Backlog.md/blob/c310b7087c3d8d618520bfe4b9918e1c8bc468c4/src/server/index.ts#L660-L708)

## Tradeoffs for a folder-per-task design

These are design judgments for Portal, not claims about Backlog.md.

| Storage | Strength | Cost |
| --- | --- | --- |
| `content.md` with front matter | One file holds title, status, and prose; editing or copying a task is straightforward. | A naive listing reads prose along with metadata. |
| `task.json` plus `content.md` | Listing can read a small metadata file and leave the body until detail is opened; JSON parsing is straightforward. | Every task requires two coordinated files; viewing the Markdown alone omits title/status if those live only in JSON. |
| `task.yaml` plus `content.md` | Same separation, with concise hand-edited metadata. | Same two-file cost, plus YAML syntax and parsing rules. |
| Status directories such as `todo/<id>/` and `done/<id>/` | Status is visible in the filesystem without parsing content. | Completion moves the task and changes its path, complicating stable references. |

For the stated minimum, title and status are sufficient metadata. The task
folder supplies identity within its configured root, so repeating an ID inside
the file creates an unnecessary consistency rule. A title can live in front
matter or in a required Markdown heading; choose one authoritative location.

Folder-local images and mock-up files can be ordinary sibling files referenced
with relative Markdown links. They do not require an attachment manifest. Their
URLs should resolve relative to the task folder, and asset serving should remain
within that folder. Source code attachments do not by themselves imply execution
or a live mock-up preview.

Keeping completed folders in place and filtering `status: done` gives the
requested default list and “show completed” toggle without a second lifecycle
mechanism. Folder paths can remain stable when a title or status changes.

There is no measured evidence here that sidecar metadata would materially speed
up Portal. It reduces body bytes read for a cold list, but directory enumeration
and one metadata-file read per task remain. Reading front matter need not render
Markdown, and linked images are separate files that listing need not load.
Benchmark the actual task count and body sizes before adding a cache, index, or
metadata split purely for speed. Backlog.md's implementation demonstrates one
working strategy, not a performance result for this different workload.

## Recommended starting point

Use one immediate child folder per task and one required `content.md`. The
folder name is the task identifier within that root; treat it as stable after
creation. Renaming the title does not rename the folder. Renaming the folder
changes the identifier and can break existing references.

```text
tasks/                         # configurable, relative to the project
  markdown-navigation/
    content.md
    mockup.png                 # optional; no prescribed asset layout
    prototype/
      index.html
```

Example `content.md`:

```markdown
---
title: "Improve Markdown navigation"
status: todo
---

Allow navigation between local Markdown documents.

![Proposed layout](mockup.png)

[Mock-up source](prototype/index.html)
```

Require only `title` (a nonempty string) and `status` (`todo` or `done`). The
detail page renders the title as its heading, so the body need not repeat it.
Two statuses meet the stated filtering requirement; `in-progress` would only
be justified if distinguishing started work is useful now. Require explicit
status rather than silently treating malformed or missing metadata as todo.
Report invalid task folders on the list so they do not disappear unnoticed.
There is no separate ID, timestamp, ordering field, or attachment manifest.

Start with a read-only hosted app: create tasks, edit details, and change status
in ordinary Emacs files, then reload the view. This is a proposed scope choice,
not an assumption that the user has rejected web editing. A “Mark done / Reopen”
control is the smallest alternative if writing status from the page is wanted;
it would need to coordinate with unsaved Emacs edits. Neither choice requires
additional stored metadata.

## Fit with Portal

These are proposed additions, based on the current code:

1. A `portal-tasks` command resolves the current Emacs project, using the same
   project-root approach as [quick terminals](../portal-terminal-quick.el).
   A `portal-tasks-directory` option defaults to `tasks/`, resolved against
   that project; per-project configuration can override it, including with an
   absolute path. Outside a project, prompt for a root. Pass the resolved root
   to each hosted view; the shared app host's working directory cannot identify
   the current project. Initially each view shows one project's task root.
2. Add list and detail routes under `/tasks` to the existing token-protected
   [app host](../host/server.ts). Enumerate immediate task folders, load their
   metadata, and order deterministically by folder name. The default list
   excludes `done`; “Show completed” includes both statuses. Completed folders
   remain readable directly. Missing roots get an explanatory empty page.
3. Use ordinary links for list → detail → list and the existing navigation
   toolbar for Back/Forward. Keep root, selected task, and filter in the URL so
   returning preserves the filter. Keep the current hosted route synchronized
   with Emacs so reload/restart returns to the displayed page; this overlaps
   with the [existing navigation plan](tasks/08-markdown-preview-links.md).
4. Reuse the [Markdown renderer and styles](../host/markdown.ts). List requests
   parse metadata without rendering bodies or reading attachments; render only
   the selected task. The installed Bun 1.3.14 was checked to support
   `Bun.YAML.parse`, so front matter needs no new parser dependency.
   [Bun YAML API](https://bun.com/docs/runtime/yaml)
5. Add task-relative image and attachment handling: the current Markdown
   preview does not implement it. Resolve files within the selected task folder,
   including containment checks after symlink resolution. Images display inline;
   other attachments are linked as files, with mock-up code treated as source.
   This extends document browsing without introducing a prototype runner.

Read saved files on navigation/reload for v1. Existing flat files in
`docs/tasks/` are not automatically reinterpreted or migrated by this proposal.
Aggregation across projects or branches is also a separate scope choice: each
configured root currently represents one filesystem checkout.
