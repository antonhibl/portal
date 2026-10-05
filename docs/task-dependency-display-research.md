# Showing task dependencies in minimal list views

Research date: 2026-09-27

## Summary

Surveyed list rows rarely name blockers. They show a small signal, leaving names
in details, popovers, or separate reports:

- **Dim or hide.** OmniFocus and Org gray out or hide blocked, not-yet-actionable rows without labels.
- **Icon, sometimes with a count.** GitLab shows a red blocked icon and count and at most three blockers on hover. GitHub shows a "Blocked" icon. Taskwarrior offers `D` and `[n]` columns.
- **Short references.** Taskwarrior's default `next` report lists numeric blocker IDs in `Deps`, e.g. `3 7`, renumbered as tasks finish like Portal ranks.
- **Names in a separate field or pane.** Linear, Asana, Notion, and Shortcut put titles in sidebars, details, or optional columns. When shown, Linear's list signal is a flag badge, not a title.
- **No dependencies at all.** Things and Todoist use manual order, headings or sub-tasks, and date-based hiding instead.

Portal's topological order already puts every ranked task's unfinished, ranked
blockers above it. Dimmed rows can quietly signal "blocked"; short rank references,
like Taskwarrior's `Deps`, identify which earlier rows to finish.

## Per-product findings

### Linear

- **Relations.** Linear has *blocked by*, *blocks*, *related*, and *duplicate*. "The issue and type of relationship will show up in the issue properties sidebar." ([docs](https://linear.app/docs/issue-relations))
- **Detail sidebar.** Blockers appear "with an orange flag under *Blocked by*"; blocked issues "with a red flag under *Blocks*". "Once the blocking issue has been resolved, the relationship moves under *Related*", so it stops counting. ([docs](https://linear.app/docs/issue-relations))
- **List rows and boards.** In 2020: "Issue boards now include issue relationships (blocked etc.) flags. Badges can now be clicked to change their value similar to list views." ([changelog 2020-03-11](https://linear.app/changelog/2020-03-11-issue-relations)) In 2023: "a new icon that better indicates whether they are blocked or blocking". ([changelog 2023-12-14](https://linear.app/changelog/2023-12-14-github-issues-sync))
- **Display options.** Relations are absent from documented toggleable display properties ([display options](https://linear.app/docs/display-options)), but available as top-level filters. ([filters](https://linear.app/docs/filters))
- **Unverified.** Whether current list badges show a count, issue ID, or only an icon, and what hover shows.
- **Row shows:** small flag or icon badge. **Full relationship:** sidebar. **Hidden or dimmed:** no; filter only.

### Things 3

- **No dependencies.** Cultured Code documents no dependency feature. Manual order and headings express sequence, dividing projects into "categories or milestones". ([Using Headings](https://culturedcode.com/things/support/articles/2803577/))
- **Actionable vs. not yet.** Dates, not relations, separate these. Anytime contains only active to-dos: "nothing's blocking you from working on any task in this list right now". Anytime, Upcoming, and Someday "are mutually exclusive". ([Today, Upcoming, Anytime, Someday](https://culturedcode.com/things/support/articles/4001304/))
- **Row shows:** nothing. Non-actionable items move to another list rather than being marked.

### OmniFocus

- **Sequential projects.** Sequencing is structural, per project or action group. In sequential projects, "only the topmost Active action is considered Available, and all actions below that one are considered Blocked". ([OmniFocus 4 manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/))
- **Availability is a computed state.** States: Available, Blocked, Blocked with Container, Unavailable (deferred), Unavailable with Container. The inspector's Status reads "Blocked with container" for inherited cases. ([manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/), [glossary](https://support.omnigroup.com/documentation/omnifocus/mac/4/en/glossary/))
- **View options choose what is visible.** First Available, Available, Remaining, Everything. *Available* excludes Blocked; *Remaining* defaults in Projects, Tags, and Review. ([manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/))
- **Row treatment.** OmniFocus 2.7: "Actions beyond the first available action in a sequential project are blocked, and therefore hidden" under Available. "In other View settings the distinction is there, but more subtle: future actions in a sequential project have their titles in gray text instead of black." ([OmniFocus 2.7 Projects](https://support.omnigroup.com/documentation/omnifocus/mac/2.7/en/projects/))
  - The OmniFocus 4 manual does not restate gray text; its continued use in version 4 is unverified.
- **Other signals.** Status-circle color encodes due, overdue, and flagged, not blocked. A sidebar project-type icon marks sequential projects. ([manual](https://support.omnigroup.com/documentation/omnifocus/universal/4.8.11/en/print/))
- **Row shows:** gray title or hidden row; no labels or names. **Blocking:** unmarked, implied by order.

### Todoist

- **No native dependencies.** Its integration directory offers Ganttify to "Create dependencies between Todoist tasks", implying no native feature. ([Ganttify integration](https://www.todoist.com/integrations/apps/ganttify))
- **Sequence.** Manual order and indented sub-tasks, up to four levels. ([sub-tasks](https://www.todoist.com/help/articles/introduction-to-sub-tasks-kMamDo))
- **Row shows:** nothing dependency-related.

### Asana

- **Detail pane.** "The indication banner will only appear in the dependent task's details pane." The prerequisite "will now show the tasks it is blocking". ([help](https://help.asana.com/s/article/task-dependencies?language=en_US))
  - A vendor post describes "a yellow banner at the top of the task indicating that it is waiting on the selected task"; it disappears on blocker completion. ([Inside Asana](https://asana.com/inside-asana/dependencies))
- **List view.** "The dependencies field has been split into two distinct fields: Blocked by and Blocking". Add these optional columns with **+ Add field**. ([help](https://help.asana.com/s/article/task-dependencies?language=en_US))
- **Notifications.** Assignees receive "only … one notification when all precedent tasks have been completed". ([help](https://help.asana.com/s/article/task-dependencies?language=en_US))
- **Unverified.** Whether default rows show a dependency icon without those columns.
- **Row shows:** default undocumented; optional task-name columns. **Full relationship:** detail banner.

### GitHub Issues

- **Relationships sidebar.** Manages blocked-by and blocking, up to 50 issues per type. ([changelog 2025-08-21](https://github.blog/changelog/2025-08-21-dependencies-on-issues/))
- **List signal.** "Blocked issues are marked with a 'Blocked' icon on your project boards or repository's Issues page." ([docs](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies))
- **Filters.** `is:blocked`, `is:blocking`, `blocked-by:<n>`, `blocking:<n>`. ([changelog](https://github.blog/changelog/2025-08-21-dependencies-on-issues/))
- **CLI.** `gh issue view` prints "Blocked by" and "Blocking" rows. ([docs](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies))
- **Unverified.** Icon counts, hover contents, and whether blocking issues have list icons; only Blocked is documented.
- **Row shows:** "Blocked" icon. **Full relationship:** sidebar.

### GitLab (added: the most fully specified icon + count + hover design found)

- **Docs.** "Issues blocked by other issues have an icon (entity-blocked) next to their title, shown in the issue lists and boards." It "disappears when the blocking issue is closed". ([docs](https://docs.gitlab.com/user/project/issues/related_issues/)) Board hover shows "a detailed information popover". ([issue boards](https://docs.gitlab.com/user/project/issue_board/))
- **Source: `work_item_relationship_icons.vue`.** Renders `entity-blocked` in *danger* followed by `blockedByCount`, and `entity-blocking` in *warning* followed by `blockingCount`. Aria-labels: "… is blocked by N items" and "… blocks N items". ([source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/work_items/components/shared/work_item_relationship_icons.vue))
- **Source: `work_item_relationship_popover.vue`.** Sets `defaultDisplayLimit = 3`, then shows "+N more items". ([source](https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/work_items/components/shared/work_item_relationship_popover.vue))
  - Design rule: "If there are more than 3 Blocked/Blocking items, only show the first 3 with a link to view the rest". Exclude closed items from list and count. ([gitlab#474945](https://gitlab.com/gitlab-org/gitlab/-/issues/474945))
- **Closing.** Closing a blocked issue shows a confirmation warning. ([docs](https://docs.gitlab.com/user/project/issues/related_issues/))
- **Row shows:** red icon and count for blocked, amber icon and count for blocking. **Names:** hover popover, capped at 3. **Hover-dependent:** yes, for names.

### Height

- **Discontinued.** Height had "Blocked by" / "Blocking" attributes, but is discontinued.
- **Unverified.** height.app and help.height.app did not respond on 2026-09-27. Only third-party reports support the reported September 2025 shutdown; no primary source. Height is excluded.

### Taskwarrior

- **Virtual tags.** `BLOCKED`: "Is the task dependent on another incomplete task?" `BLOCKING`: "Does another task depend on this incomplete task?" `READY`: "Is the task pending, not blocked, and either not scheduled, or scheduled before now." ([tags](https://taskwarrior.org/docs/tags/))
- **Default reports in [`src/Context.cpp`](https://github.com/GothenburgBitFactory/taskwarrior/blob/develop/src/Context.cpp):**
  - `next` ("Most urgent tasks"): filter `+PENDING -WAITING`, sort `urgency-`, **`depends`** column labeled `Deps`. Blocked tasks remain, with blocker IDs.
  - `ready` ("Most urgent actionable tasks"): filter `+READY`, hides blocked tasks; uses `depends.indicator`, labeled `D`.
  - `list` also uses `depends.indicator`.
  - `blocked` and `blocking` reports filter on `+BLOCKED` and `+BLOCKING`.
- **Column styles in [`ColDepends.cpp`](https://github.com/GothenburgBitFactory/taskwarrior/blob/develop/src/columns/ColDepends.cpp).**
  - `list` (default): space-separated blocker IDs, e.g. `1 2 10`.
  - `count`: `[3]`.
  - `indicator`: `dependency.indicator`, default `D`.
  - No style shows titles.
- **IDs shift.** "ID numbers change occasionally, although in a predictable way". They are rebuilt when tasks leave the working set; UUIDs are permanent. ([IDs](https://taskwarrior.org/docs/ids/)) References use renumbered IDs, like Portal's proposed ranks.
- **Color.** Default theme: `color.blocked=white on color8` (gray background), `color.blocking=black on color15` (bright background). ([default.theme](https://github.com/GothenburgBitFactory/taskwarrior/blob/develop/doc/rc/default.theme))
- **Urgency.** Blocking pushes tasks up, blocked pushes down: `urgency.blocking.coefficient 8.0`, `urgency.blocked.coefficient -5.0`. ([urgency](https://taskwarrior.org/docs/urgency/))
- **Row shows:** blocker IDs, `D`, or `[n]`, plus dim or bright row color. **Full relationship:** `task <id> info`, or `blocked` and `blocking` reports.

### Org mode (plus org-edna)

- **Enforcement.** `org-enforce-todo-dependencies` prevents parent DONE with undone TODO children. "If a parent has an :ORDERED: property, switching an entry to DONE will be blocked if any prior sibling is not yet done." ([manual](https://orgmode.org/manual/TODO-dependencies.html), [org.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org.el))
- **Agenda display: `org-agenda-dim-blocked-tasks`** ([org-agenda.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org-agenda.el)):
  - Current source defaults to `t`: "Dim to a gray face".
  - With `invisible`, "blocked tasks will be invisible and only become visible when they become unblocked". Checkbox-blocked tasks are only dimmed: hiding would "remove any trace … that there is something to do".
  - Whole-line face `org-agenda-dimmed-todo-face` uses `grey50` on light and dark backgrounds. ([org-faces.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org-faces.el))
- **ORDERED is not visible by default.** `org-track-ordered-property-with-tag` exists because "a property is not very visible". Mirroring ORDERED as a tag "is not relevant for the behavior, but it makes things more visible". ([org.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org.el))
- **org-edna.** Adds arbitrary blockers through `BLOCKER`, e.g. `ids(ID1 ID2)` or `previous-sibling`. ([Org Edna manual](https://www.nongnu.org/org-edna-el/))
  - `org-edna-mode` adds `org-edna-blocker-function` to `org-blocker-hook`. ([org-edna.el](https://github.com/emacsmirror/org-edna/blob/master/org-edna.el))
  - Agenda's blocked check (`org-entry-blocked-p`) runs the same hook, giving Edna blockers standard dim/invisible treatment. ([org.el](https://git.savannah.gnu.org/cgit/emacs/org-mode.git/plain/lisp/org.el))
- **Row shows:** grey line or nothing; no names, count, or icon. **Blocking:** unmarked.

### Shortcut

- **Relations.** "Blocks" requires Story A to finish before B; B is "Is blocked by" A. "When Story A is completed, these properties will be removed from both Story Cards in the Column View - however, they will still be visible in the Story Dialogs."
  - Source: "Contents of a Story" (`help.shortcut.com/hc/en-us/articles/360044391911`), quoted from the search index. Its URL now redirects to [shortcut.com/help](https://www.shortcut.com/help); unverified against a live page.
- **Epic and Iteration pages.** Show diagrams of blocked and blocking stories. ([Shortcut blog](https://www.shortcut.com/blog/visualize-dependencies-between-related-stories))
- **Search filters.** `is:blocked` and `is:blocker`. ([Shortcut blog](https://www.shortcut.com/blog/how-a-product-manager-uses-filtered-spaces-to-zoom-in-on-key-work/))
- **Unverified.** Exact card marker: icon, color, or label.

### Notion, Plane

- **Notion.** Per-database dependency relation properties appear as timeline connectors and automatically shift dates. ([help](https://www.notion.com/help/tasks-and-dependencies)) Tables or lists would show ordinary relation cells with page titles; that page does not specify property names or row rendering (unverified).
- **Plane.** *Relations* ("blocked by", "blocking") "don't enforce scheduling constraints"; *dependencies* appear "as visual connectors in the Timeline layout". ([docs](https://docs.plane.so/core-concepts/issues/overview)) List-row rendering is undocumented.

### Not covered

Basecamp, Apple Reminders, Tana, Amie, and Superlist were not researched: no
primary-source dependency docs were found in time. Reminders and Basecamp to-dos
are not known to have dependencies (unverified).

## Patterns

1. **Blocked is a quiet state: dim or hide it.** OmniFocus grays titles or hides them under Available; Org dims lines to grey50 or hides with `invisible`. Taskwarrior uses gray backgrounds and omits blocked tasks in `ready`. Things moves non-actionable items out of working lists. None adds a word; blocked lacks emphasis.
2. **Readiness is the default, and the only state that earns contrast.** Taskwarrior's `READY`, OmniFocus's "First Available", and Things' Anytime define the actionable set, emphasized without "Ready" labels.
3. **Icon only, or icon plus count.** GitHub: "Blocked" icon. GitLab: red icon + N, amber icon + N for blocking. Taskwarrior: `D` and `[n]`. Linear: flags. Counts answer "how much is in the way" without names.
4. **References by short ID, never by title, in the row.** Taskwarrior's default `next` shows space-separated numeric `Deps`, renumbered with working-set changes. GitLab popovers and GitHub filters also use numbers. Titles occupy dedicated fields: Asana columns, Linear sidebar, GitHub Relationships.
5. **Names on demand, capped.** GitLab hover shows at most 3 plus "+N more items"; others use details or sidebars, which Portal already has.
6. **Sequence from structure instead of relations.** OmniFocus sequential projects, Org `ORDERED`, and Things and Todoist order with headings or sub-tasks make position the dependency. Portal's topological order similarly guarantees blockers above.
7. **"Blocking" is rarely marked in the row.** Only GitLab (amber icon and count) and Taskwarrior (row color and urgency boost) mark it; OmniFocus, Org, Linear's list, and GitHub's list do not.
8. **Resolved blockers disappear from the signal.** Linear moves them to Related; GitLab and Shortcut remove icons or properties on close; Asana removes banners. Only open blockers count, as in Portal.

## Implications for Portal

Two constraints:

- **Blockers are always above.** Ranked blocked tasks have only unfinished blockers ranked above them; depending on unranked tasks means "Blocked by dependency problems". Rank references always resolve upward.
- **Ranks are stable only within one page load.** Taskwarrior's shifting IDs likewise reference the current list.

Mocks use `·` for dimming and assume ranked rows drop the `todo` badge, since all
ranked tasks are todo.

### 1. Dim + rank references (recommended; no hover)

```
1  Define native view protocol
2  Own native view lifetime in the C core
3  ·Route terminal input through the bridge·           ·after 2·
4  Draft toolbar icons
5  ·Ship quick terminal·                              ·after 3, 4·
```

- **Sources.** Org and OmniFocus dimming; Taskwarrior's trailing `depends` IDs.
- **Ready rows.** Full contrast, no label.
- **Blocked rows.** Mute the whole row; place `after N, M` at right in the same color, nearest blocker first. After three references, use `after 7, 6, 5 +2` (GitLab's cap).
- **Why it works.** Preserves the link-by-reference feel the user liked. References of at most about 12 characters never squeeze titles. No hover or "Ready"/"Blocked by" words.

### 2. Dim + count, names on hover

```
3  ·Route terminal input through the bridge·           ⧗ 1
5  ·Ship quick terminal·                              ⧗ 2
```

- **Sources.** GitLab icon and count; Taskwarrior `[n]`.
- **Relies on hover** to identify rows: highlight blockers or list them in a title.
- The narrowest option answers "which" only through hover or details, making it weaker than design 1 in a keyboard-driven Emacs web view.

### 3. Icon-only dim, no references

```
3  ·Route terminal input through the bridge·
5  ·Ship quick terminal·
```

- **Sources.** Org's default and OmniFocus gray text. Order and dimming convey state; only details identify blockers, already listing **Depends on** / **Blocks**.
- The most minimal option loses the at-a-glance "what do I finish first to unlock this" the user valued in option B.

### 4. Optional: hide blocked behind a toggle

- **Sources.** Org `invisible`, OmniFocus "Available", Taskwarrior `ready`.
- Reuse existing filters beside "Show completed", not a new concept. This is worthwhile only for long lists; do not build it speculatively.

**Recommendation: design 1.**

- One visual rule (dim blocked) and one short field (`after` + ranks).
- Matches surveyed patterns: quiet state, short row IDs, names in details.
- Removes "Ready" labels and long blocker titles currently crushing the title column.
- Optional later hover-highlighting can enhance references; nothing depends on it.
- Do not mark "blocking": dimmed rows referencing a ready row above already show it.
