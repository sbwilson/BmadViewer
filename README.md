# BMAD Viewer

A lightweight native macOS viewer for [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) projects: story status, the build-order queue, and story documents, with files opening in their usual apps.

SwiftUI shell, AppKit text view (TextKit 1) for documents, no web view.

## Run

```sh
swift run BmadViewer ~/dev/Qubric        # debug, unbundled
scripts/make-app.sh                      # build/BmadViewer.app
scripts/make-app.sh --install            # …and copy to ~/Applications
open build/BmadViewer.app --args ~/dev/Qubric
```

With no argument it reopens the most recent project; **File › Open Project…** (⌘O) picks another.

## What it reads (BMAD v6 layout)

| Source | Used for |
| --- | --- |
| `_bmad/config.toml`, `_bmad/custom/*.toml`, `_bmad/bmm/config.yaml` | where the artifacts live (`{project-root}` expanded) |
| `sprint-status.yaml` → `development_status` | epics, stories, retrospectives and their statuses, in file order |
| `epics.md` | epic and story titles (`## Epic S5-9: …`, `### Story 9.16: …`), and each story's section as a fallback document |
| story files `spec-N-M-*.md` / `story-N-M-*.md` / `N-M-*.md` | the story document; matched on the `N-M` number because tracking keys are truncated |
| `build-order.md` (optional) | queue tables: any table with a `Story` column, grouped by `##` section |

Archived copies (`archive/`, worktrees, build output) are skipped when searching for the status file.

## What it reads (BMAD v7 ticket tree)

Used when `modules.bmm.active_initiative` is set (e.g. `_bmad/custom/config.user.toml`), or when there is no `sprint-status.yaml` but an `initiative-*` folder exists. The rules follow the project's own `_bmad/method/scripts/tickets.py`.

| Source | Used for |
| --- | --- |
| `<store root>/<initiative>/tickets.toml` `[[epic]]` | epic order, ids (story numbers are `<epic id>.<entry id>`) and titles |
| `<initiative>/epic-<slug>/tickets.toml` `[[entry]]` | tickets in build order: type, title, description, verify, `after`, risk, refine |
| `story-*.md` / `spike-*.md` / `bug-*.md` | a pulled ticket; joins its entry by `id`, its `title` and `after` win |
| `*-plan.md` with `ticket:` | the ticket's `status` (draft … built, done, blocked, dropped) and its build record |
| `<store root>/backlog/` | tickets in no epic |

The store root is `[tickets] root` in `_bmad/custom/ticketing-store-config.toml` (default: the output folder). **Next** groups tickets the way `tickets.py next` does: in progress, built (awaiting done), ready to start, ready to refine, blocked. A built ticket meets an `after`; an epic gate waits for the epic to be done.

A ticket shows three views: **Ticket** (its `tickets.toml` entry as text), **Story file**, and **Plan**.

`BmadViewer --dump <project>` prints what was read and exits, for comparing with `tickets.py next`.

## Reviewing a story

A story whose document has a `## Suggested Review Order` (bmad-build writes one at the end of a build) gets a fixed **Review** tab:

- **Left:** the review's concerns (its bold lines or `###` headings) and their stops — one line of framing and the `file:line` link.
- **Right:** the selected stop's file, scrolled to and highlighting its line or range, under a bar with the stop's framing. ⌘[ and ⌘] step through the stops.
- A link to a file that has since moved (`RustCore/crates/…` → `crates/…`) is followed to where a file of that name lives now, and marked moved; a file that is gone says so.
- **Below:** for a story in `review`, **Mark Review Complete…** lists the exact lines it will change — the story's `development_status` line in `sprint-status.yaml` (`review` → `done`, comments kept) and the story file's front-matter `status:` — and asks before writing them. Nothing is committed. A story still in `build-order.md`'s queue is left alone: going done there also drops its row and lowers the check's floor in one commit (rule R2), so that stays a hand edit. Done stories keep the pane for reading.

Ticket-tree (v7) plans carry no Suggested Review Order, so they get no Review tab.

## Retro actions and deferred work

The sidebar's **Review** section lists what is owed that is not a story, with open counts.

| Source | Read as |
| --- | --- |
| `sprint-status.yaml` → `action_items` (v6) | retro actions: `id`, `epic`, `action`, `owner`, `status`, `ref`, plus `progress`/`resolution` |
| each retrospective's `## Action items` (v7, or v6 with no `action_items`) | numbered/bulleted items or a table with an `Action` column, grouped by `###`; status `proposed` |
| `deferred-work.md` in the implementation artifacts | canonical `### DW-<n>:` entries (one `key: value` per line, `gate:`, `status: done <date>`), and legacy `- source_spec:` / `- source_plan:` bullets, closed by a `disposition:` starting `fixed`, `closed`, `done`… |

Retro actions group by epic, newest retrospective first; deferred work by status, newest first. Search matches every field, and **Hide finished** applies. Each item links to the line it is written on; paths in `location:` link to the files.

## Documents and tabs

Every story, ticket, epic and work item opens in the detail view with a browser-style tab bar under its header:

- **Fixed tabs** are the item's own views — Ticket, Plan, Story file, Epic definition; for an epic, its document, `tickets.toml` and retrospective (click the links above an epic's story list). They cannot be closed.
- **File tabs** open when you click a link or a file path in inline code (`scripts/x.py`). Close them with ×, or right-click a tab for Close Other Tabs / Close Tabs to the Right. Each item remembers its open tabs, across launches too.
- `file.rs:42`, `file.rs:42-50` and `file.md#L42-L50` open the file with those lines highlighted and scrolled into view.

Viewers: markdown rendered (with a Source toggle), `tickets.toml` as a ticket list with live status (and Source), code and text with syntax colours and line numbers, images with zoom in/out, fit and actual size (drag to pan, double-click to toggle), PDFs, folders, and an open/reveal panel for anything else. Each file tab's toolbar shows its path and opens it in the default app, Open With, or Finder.

Right-click any link for Open in Tab, Open in <default app>, **Open With ›** (every app that claims the type, default first, plus Other…), Reveal in Finder and Copy Path. "Story 9.16" in text links to that story. ⌘F finds in the document. The project's files are watched and the view reloads on change.

## Not yet

- Tracker-backed ticket stores (`store` other than `repo`): `tracker_status` is read from leaf files, but nothing is synced.
