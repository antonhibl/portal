# Showing task dependencies in minimal list views

Research date: 2026-09-27

## Summary

In the tools surveyed, the list row almost never names the blocking task. The row shows one small signal, and the names live in a detail pane, a popover, or a separate report. The signals seen are:

- **Dim or hide.** OmniFocus and Org mode treat "blocked" as not actionable yet. They gray out the row, or hide it until it becomes actionable. Neither puts a label on the row.
- **Icon, sometimes with a count.** GitLab shows a red "blocked" icon with a count, and a hover popover lists at most three blockers. GitHub shows a "Blocked" icon. Taskwarrior has `D` and `[n]` column styles.
- **Short references.** Taskwarrior's default `next` report lists the blockers' numeric IDs in a `Deps` column, for example `3 7`. Those IDs are renumbered as tasks finish, just like Portal's ranks.
- **Names in a separate field or pane.** Linear, Asana, Notion, and Shortcut keep blocker titles in the sidebar or detail pane, or in optional list columns. Where Linear's list row shows anything, it is a flag badge, not a title.
- **No dependencies at all.** Things and Todoist have no dependency feature. They handle sequence through manual order, headings or sub-tasks, and date-based hiding.

Portal's list is already a topological order, which removes most of the work. Every blocker of a ranked task is itself an unfinished, ranked task, and it always appears higher in the list. So "blocked" can be a quiet state (dimmed), and the row only needs to say *which* earlier rows to finish first. Rank numbers do that in a few characters, the way Taskwarrior's `Deps` column does.

## Per-product findings

### Linear

- **Relations.** Linear has *blocked by*, *blocks*, *related*, and *duplicate* relations. "The issue and type of relationship will show up in the issue properties sidebar." ([docs](https://linear.app/docs/issue-relations))
- **Detail sidebar.** Blockers are listed "with an orange flag under *Blocked by*". Blocked issues are listed "with a red flag under *Blocks*". "Once the blocking issue has been resolved, the relationship moves under *Related*", so a finished blocker stops counting as one. ([docs](https://linear.app/docs/issue-relations))
- **List rows and boards.** The 2020 changelog says: "Issue boards now include issue relationships (blocked etc.) flags. Badges can now be clicked to change their value similar to list views." ([changelog 2020-03-11](https://linear.app/changelog/2020-03-11-issue-relations)) A 2023 entry says the relations got "a new icon that better indicates whether they are blocked or blocking". ([changelog 2023-12-14](https://linear.app/changelog/2023-12-14-github-issues-sync))
- **Display options.** Relations are not in the documented list of toggleable display properties. ([display options](https://linear.app/docs/display-options)) Relations are available as top-level filters. ([filters](https://linear.app/docs/filters))
- **Unverified.** How the current list row renders the blocked badge: whether it shows a count, an issue ID, or only an icon, and what hover shows.
- **Row shows:** a small flag or icon badge. **Full relationship:** sidebar. **Hidden or dimmed:** no; filter only.

### Things 3

- **No dependencies.** Cultured Code's documentation describes no dependency feature. Sequence is expressed through manual order and headings, which break a project into "categories or milestones". ([Using Headings](https://culturedcode.com/things/support/articles/2803577/))
- **Actionable vs. not yet.** Things separates these by date rather than by relation. Anytime holds only active to-dos: "nothing's blocking you from working on any task in this list right now". Its contents and those of Upcoming and Someday "are mutually exclusive". ([Today, Upcoming, Anytime, Someday](https://culturedcode.com/things/support/articles/4001304/))
- **Row shows:** nothing. Items that are not actionable are *moved to another list* rather than marked.

### OmniFocus

- **Sequential projects.** Sequencing is structural, set per project or action group. In a sequential project, "only the topmost Active action is considered Available, and all actions below that one are considered Blocked". ([OmniFocus 4 manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/))
- **Availability is a computed state.** The states are Available, Blocked, Blocked with Container, Unavailable (deferred), and Unavailable with Container. The inspector's Status field reads "Blocked with container" for inherited cases. ([manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/), [glossary](https://support.omnigroup.com/documentation/omnifocus/mac/4/en/glossary/))
- **View options choose what is visible.** The options are First Available, Available, Remaining, and Everything. *Available* excludes Blocked items. *Remaining* is the default in Projects, Tags, and Review. ([manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/))
- **Row treatment.** The OmniFocus 2.7 manual says: "Actions beyond the first available action in a sequential project are blocked, and therefore hidden" when Available is shown. "In other View settings the distinction is there, but more subtle: future actions in a sequential project have their titles in gray text instead of black." ([OmniFocus 2.7 Projects](https://support.omnigroup.com/documentation/omnifocus/mac/2.7/en/projects/))
  - The OmniFocus 4 manual does not restate the gray-text rule. That it still applies in version 4 is unverified.
- **Other signals.** The status circle's color encodes due, overdue, and flagged, not blocked. A project-type icon marks a project as sequential in the sidebar. ([manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/))
- **Row shows:** gray title, or the row is hidden. No label, no names. **Blocking:** not marked; order implies it.

### Todoist

- **No native dependencies.** Todoist's integrations directory lists Ganttify as the way to "Create dependencies between Todoist tasks", which implies the feature is not native. ([Ganttify integration](https://www.todoist.com/integrations/apps/ganttify))
- **Sequence.** Sequence is expressed with indented sub-tasks, up to four levels, and manual order. ([sub-tasks](https://www.todoist.com/help/articles/introduction-to-sub-tasks-kMamDo))
- **Row shows:** nothing dependency-related.

### Asana

- **Detail pane.** A dependent task shows a banner. "The indication banner will only appear in the dependent task's details pane." The prerequisite task "will now show the tasks it is blocking". ([help](https://help.asana.com/s/article/task-dependencies?language=en_US))
  - A vendor post describes this as "a yellow banner at the top of the task indicating that it is waiting on the selected task", which disappears when the blocker completes. ([Inside Asana](https://asana.com/inside-asana/dependencies))
- **List view.** "The dependencies field has been split into two distinct fields: Blocked by and Blocking". These are optional columns added with **+ Add field**. ([help](https://help.asana.com/s/article/task-dependencies?language=en_US))
- **Notifications.** The assignee is notified when blockers complete, "only … one notification when all precedent tasks have been completed". ([help](https://help.asana.com/s/article/task-dependencies?language=en_US))
- **Unverified.** Whether the default list row shows an icon for dependent tasks when those columns are not added.
- **Row shows:** by default, not documented; optionally, task names in dedicated columns. **Full relationship:** banner in the detail pane.

### GitHub Issues

- **Relationships sidebar.** Blocked-by and blocking are managed in the sidebar's Relationships section, with up to 50 issues per type. ([changelog 2025-08-21](https://github.blog/changelog/2025-08-21-dependencies-on-issues/))
- **List signal.** "Blocked issues are marked with a 'Blocked' icon on your project boards or repository's Issues page." ([docs](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies))
- **Filters.** `is:blocked`, `is:blocking`, `blocked-by:<n>`, `blocking:<n>`. ([changelog](https://github.blog/changelog/2025-08-21-dependencies-on-issues/))
- **CLI.** `gh issue view` prints "Blocked by" and "Blocking" rows. ([docs](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies))
- **Unverified.** Whether the list icon carries a count, and what hover shows. Also whether blocking issues get a list icon at all; only the Blocked icon is documented.
- **Row shows:** a "Blocked" icon. **Full relationship:** sidebar.

### GitLab (added: the most fully specified icon + count + hover design found)

- **Docs.** "Issues blocked by other issues have an icon (entity-blocked) next to their title, shown in the issue lists and boards." The icon "disappears when the blocking issue is closed". ([docs](https://docs.gitlab.com/user/project/issues/related_issues/)) On boards, hovering the icon shows "a detailed information popover". ([issue boards](https://docs.gitlab.com/user/project/issue_board/))
- **Source: `work_item_relationship_icons.vue`.** The row renders `entity-blocked` in the *danger* variant followed by `blockedByCount`. It renders `entity-blocking` in the *warning* variant followed by `blockingCount`. The aria-labels read "… is blocked by N items" and "… blocks N items". ([source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/work_items/components/shared/work_item_relationship_icons.vue))
- **Source: `work_item_relationship_popover.vue`.** The popover sets `defaultDisplayLimit = 3` and shows "+N more items" beyond that. ([source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/work_items/components/shared/work_item_relationship_popover.vue))
  - The design issue states the rule: "If there are more than 3 Blocked/Blocking items, only show the first 3 with a link to view the rest". Closed items are excluded from both the list and the count. ([gitlab#474945](https://gitlab.com/gitlab-org/gitlab/-/issues/474945))
- **Closing.** Closing a blocked issue shows a confirmation warning. ([docs](https://docs.gitlab.com/user/project/issues/related_issues/))
- **Row shows:** a red icon and count for blocked, an amber icon and count for blocking. **Names:** hover popover, capped at 3. **Hover-dependent:** yes, for names.

### Height

- **Discontinued.** Height had "Blocked by" / "Blocking" task attributes, but the product has been discontinued.
- **Unverified.** height.app and help.height.app did not respond on 2026-09-27. The shutdown (reported for September 2025) is known only from third-party reports, so there is no primary source. Height is excluded.

### Taskwarrior

- **Virtual tags.** `BLOCKED`: "Is the task dependent on another incomplete task?" `BLOCKING`: "Does another task depend on this incomplete task?" `READY`: "Is the task pending, not blocked, and either not scheduled, or scheduled before now." ([tags](https://taskwarrior.org/docs/tags/))
- **Default reports in [`src/Context.cpp`](https://github.com/GothenburgBitFactory/taskwarrior/blob/develop/src/Context.cpp):**
  - `next` ("Most urgent tasks") has filter `+PENDING -WAITING`, sort `urgency-`, and a **`depends`** column labeled `Deps`. So blocked tasks stay in the list, with blocker IDs shown.
  - `ready` ("Most urgent actionable tasks") has filter `+READY` and hides blocked tasks. It uses `depends.indicator`, labeled `D`.
  - `list` also uses `depends.indicator`.
  - `blocked` and `blocking` are dedicated reports filtered on `+BLOCKED` and `+BLOCKING`.
- **Column styles in [`ColDepends.cpp`](https://github.com/GothenburgBitFactory/taskwarrior/blob/develop/src/columns/ColDepends.cpp).**
  - `list` (default) prints the blockers' IDs joined by spaces, e.g. `1 2 10`.
  - `count` prints `[3]`.
  - `indicator` prints `dependency.indicator`, which defaults to `D`.
  - There are no titles in any style.
- **IDs shift.** "ID numbers change occasionally, although in a predictable way". They are rebuilt when tasks leave the working set, while UUIDs are permanent. ([IDs](https://taskwarrior.org/docs/ids/)) The reference list is therefore built on renumbered IDs, as Portal's ranks would be.
- **Color.** The default theme sets `color.blocked=white on color8`, a gray background, and `color.blocking=black on color15`, a bright background. ([default.theme](https://github.com/GothenburgBitFactory/taskwarrior/blob/develop/doc/rc/default.theme))
- **Urgency.** Blocking tasks are pushed up and blocked tasks down: `urgency.blocking.coefficient 8.0`, `urgency.blocked.coefficient -5.0`. ([urgency](https://taskwarrior.org/docs/urgency/))
- **Row shows:** blocker IDs, `D`, or `[n]`, plus a dim or bright row color. **Full relationship:** `task <id> info`, or the `blocked` and `blocking` reports.

### Org mode (plus org-edna)

- **Enforcement.** `org-enforce-todo-dependencies` blocks a parent from DONE while it has undone TODO children. "If a parent has an :ORDERED: property, switching an entry to DONE will be blocked if any prior sibling is not yet done." ([manual](https://orgmode.org/manual/TODO-dependencies.html), [org.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org.el))
- **Agenda display: `org-agenda-dim-blocked-tasks`** ([org-agenda.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org-agenda.el)):
  - It defaults to `t` in current source, which means "Dim to a gray face".
  - The value `invisible` means "blocked tasks will be invisible and only become visible when they become unblocked". The exception is tasks blocked by checkboxes: those are only dimmed, since hiding them would "remove any trace … that there is something to do".
  - The face is `org-agenda-dimmed-todo-face`, `grey50` on both light and dark backgrounds, and it applies to the whole line. ([org-faces.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org-faces.el))
- **ORDERED is not visible by default.** `org-track-ordered-property-with-tag` exists because "a property is not very visible". It mirrors ORDERED as a tag, which "is not relevant for the behavior, but it makes things more visible". ([org.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org.el))
- **org-edna.** It adds arbitrary blockers via a `BLOCKER` property, e.g. `ids(ID1 ID2)` or `previous-sibling`. ([Org Edna manual](https://www.nongnu.org/org-edna-el/))
  - `org-edna-mode` adds `org-edna-blocker-function` to `org-blocker-hook`. ([org-edna.el](https://github.com/emacsmirror/org-edna/blob/master/org-edna.el))
  - The agenda's blocked check (`org-entry-blocked-p`) runs that same hook, so Edna blockers get the standard dim/invisible treatment. ([org.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org.el))
- **Row shows:** a grey line or nothing. No names, no count, no icon. **Blocking:** not marked.

### Shortcut

- **Relations.** "Blocks" means Story A must finish before Story B, and B is marked "Is blocked by" A. "When Story A is completed, these properties will be removed from both Story Cards in the Column View - however, they will still be visible in the Story Dialogs."
  - Source: the help article "Contents of a Story" (`help.shortcut.com/hc/en-us/articles/360044391911`), quoted from the search index. The URL now redirects to [shortcut.com/help](https://www.shortcut.com/help), so this is unverified against a live page.
- **Epic and Iteration pages.** These draw blocked and blocking stories as a diagram. ([Shortcut blog](https://www.shortcut.com/blog/visualize-dependencies-between-related-stories))
- **Search filters.** `is:blocked` and `is:blocker`. ([Shortcut blog](https://www.shortcut.com/blog/how-a-product-manager-uses-filtered-spaces-to-zoom-in-on-key-work/))
- **Unverified.** The exact card marker: icon, color, or label.

### Notion, Plane

- **Notion.** Dependencies are relation properties that are enabled per database. They are drawn as connectors in timeline view and shift dates automatically. ([help](https://www.notion.com/help/tasks-and-dependencies)) In table or list views they would appear as ordinary relation cells holding page titles. The exact property names and row rendering are not stated on that page (unverified).
- **Plane.** It separates *relations* ("blocked by", "blocking"), which "don't enforce scheduling constraints", from *dependencies*, which appear "as visual connectors in the Timeline layout". ([docs](https://docs.plane.so/core-concepts/issues/overview)) List-row rendering is not documented.

### Not covered

Basecamp, Apple Reminders, Tana, Amie, and Superlist were not researched: no primary-source dependency documentation was found in the time available. Reminders and Basecamp to-dos are not known to have dependencies (unverified).

## Patterns

1. **Blocked is a quiet state: dim or hide it.** OmniFocus shows gray titles, or hides blocked items under Available. Org mode dims the line to grey50 by default, or hides it with `invisible`. Taskwarrior gives blocked rows a gray background and has a `ready` report that omits them. Things moves items that are not actionable out of the working list. None of these adds a word to the row. Blocked is the absence of emphasis.
2. **Readiness is the default, and the only state that earns contrast.** Taskwarrior's `READY`, OmniFocus's "First Available", and Things' Anytime all define the *actionable* set, and the UI emphasizes that set. Nobody labels ready rows "Ready".
3. **Icon only, or icon plus count.** GitHub shows a "Blocked" icon. GitLab shows a red icon + N and an amber icon + N for blocking. Taskwarrior has `D` and `[n]`. Linear shows flag badges. The count answers "how much is in the way" without names.
4. **References by short ID, never by title, in the row.** Taskwarrior's default `next` report shows `Deps` as a space-separated list of numeric IDs, and those IDs are renumbered as the working set changes. GitLab's popover and GitHub's filters also address issues by number. Titles appear only in dedicated fields: Asana's optional columns, Linear's sidebar, GitHub's Relationships panel.
5. **Names on demand, capped.** GitLab's hover popover shows at most 3 items plus "+N more items". Everyone else keeps names in the detail pane or sidebar, which Portal already has.
6. **Sequence from structure instead of relations.** OmniFocus sequential projects, Org `ORDERED`, and Things and Todoist order with headings or sub-tasks: position in the list *is* the dependency. Portal's topological order gives the same guarantee for free, because blockers are always above.
7. **"Blocking" is rarely marked in the row.** Only GitLab (amber icon + count) and Taskwarrior (row color, plus an urgency boost) mark it. OmniFocus, Org, Linear's list, and GitHub's list do not.
8. **Resolved blockers disappear from the signal.** Linear moves them to Related. GitLab and Shortcut remove the icon or property on close. Asana's banner disappears. Only open blockers count, which Portal already does.

## Implications for Portal

Two facts constrain the design:

- **Blockers are always above.** A ranked blocked task's blockers are all unfinished and ranked above it, because a task that depends on an unranked task goes to "Blocked by dependency problems". Rank references therefore always resolve, and they always point up the list.
- **Ranks are stable only within one page load.** Taskwarrior uses shifting IDs in exactly this role, as a reference that is valid for the list in front of you.

Row mocks below use `·` for dimmed text. Each assumes the `todo` badge is dropped from ranked rows, since everything ranked is todo.

### 1. Dim + rank references (recommended; no hover)

```
1  Define native view protocol
2  Own native view lifetime in the C core
3  ·Route terminal input through the bridge·           ·after 2·
4  Draft toolbar icons
5  ·Ship quick terminal·                              ·after 3, 4·
```

- **Sources.** Dimming follows Org and OmniFocus. The trailing IDs follow Taskwarrior's `depends` column.
- **Ready rows.** Full contrast and no label.
- **Blocked rows.** The whole row is muted, with `after N, M` at the right in the same muted color and nearest blocker first. Past three references, show `after 7, 6, 5 +2`, the GitLab cap.
- **Why it works.** It keeps the link-by-reference feel the user liked. The title never gets squeezed, because the reference is at most about 12 characters. No hover is needed. Removes the "Ready"/"Blocked by" words entirely.

### 2. Dim + count, names on hover

```
3  ·Route terminal input through the bridge·           ⧗ 1
5  ·Ship quick terminal·                              ⧗ 2
```

- **Sources.** GitLab's icon + count and Taskwarrior's `[n]`.
- **Relies on hover** to learn *which* rows: highlight the blocker rows, or show a title that lists them.
- It is the narrowest option, but it answers "which" only through hover or the detail page. It is weaker than design 1 in a keyboard-driven Emacs web view.

### 3. Icon-only dim, no references

```
3  ·Route terminal input through the bridge·
5  ·Ship quick terminal·
```

- **Sources.** Org's default and OmniFocus's gray text. Order plus dimming carries everything; "which" lives only on the detail page, which already lists **Depends on** / **Blocks**.
- It is the most minimal of the three. It loses at-a-glance "what do I finish first to unlock this", which the user valued in option B.

### 4. Optional: hide blocked behind a toggle

- **Sources.** Org `invisible`, OmniFocus "Available", Taskwarrior `ready`.
- It reuses the page's existing filter concept, next to "Show completed", rather than adding a new one. It is only worth doing if the list grows long. Do not build it speculatively.

**Recommendation: design 1.**

- It needs one visual rule (dim when blocked) and one short text field (`after` + ranks).
- It matches the pattern the surveyed tools converge on: quiet state, short IDs in the row, names in the detail pane.
- It removes both the "Ready" label and the long blocker titles that currently crush the title column.
- Hover-highlighting the referenced rows can be added later as a pure enhancement. Nothing depends on it.
- Don't mark "blocking" in the row: a ready row with dimmed rows below that reference it already shows that it blocks them.
