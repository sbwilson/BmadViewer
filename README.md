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

A story with a recorded baseline (`baseline_commit` in a v6 spec, `baseline_revision` in a v7 plan) or a `## Suggested Review Order` gets a fixed **Review** tab:

- **Range bar:** the git range being reviewed, from the baseline to, by default, **the story's last commit**: the last commit to touch the story document (its own commit), or the working tree when that document has uncommitted changes. HEAD and the working tree are the alternatives. It shows the file count and lines added and removed.
- **Left:** the review order's concerns and their stops, then **Other changed files**: what the range changed that no stop names (or every changed file, for a story with no review order). Stops whose file the range did not touch are marked unchanged.
- **Right:** the selected item as a **Diff** of the range, with old and new line numbers, added and removed lines banded across the width, syntax colours, and the stop's lines highlighted and scrolled to (the diff widens to the whole file when the lines fall outside the changed hunks). Since the range ends at the story's own commit, the review's line numbers match. **File** shows the file as it is today. ⌘[ and ⌘] step through.
- A link to a file that has since moved (`RustCore/crates/…` → `crates/…`) is diffed at the path it had in the story's range, and shown from where it lives now in File view; a file that is gone says so.
- **Below** (sprint-status projects): for a story in `review`, **Mark Review Complete…** lists the exact lines it will change — the story's `development_status` line in `sprint-status.yaml` (`review` → `done`, comments kept) and the story file's front-matter `status:` — and asks before writing them. Nothing is committed. A story still in `build-order.md`'s queue is left alone: going done there also drops its row and lowers the check's floor in one commit (rule R2), so that stays a hand edit.

`BMADV_DIFF=17.5 BmadViewer --dump <project>` prints a story's range and whether each stop's lines appear in its diff.

## Quick open

**⌘K** (or ⌘⇧O, under **Go**) jumps to anything by fuzzy match: stories and tickets (by number or title words), epics, retro actions, deferred entries (`DW-1041`), project documents, and every file git tracks (or would track) in the project. An exact key — `9.16`, `DW-12` — comes first. `core.rs:940` opens the file at that line. ↩ opens: a story or item in its list, a file in the tabs of the story or item on screen (or on its own in the middle column); ⌘↩ opens it in its default app. With nothing typed it lists recent picks and active stories. Indexing Qubric (about 8,000 items, 6,800 files) takes under 100 ms and a search about 25 ms.

`BMADV_QUICKOPEN="9.16|core.rs:940" BmadViewer --dump <project>` prints the top results for each query.

## Find in project

**⌘⇧F** (or **Find in Project** in the sidebar) searches file contents: the **BMAD artifacts** folders by default, or the **whole project**, with match case, whole word and regular-expression toggles. Results group by file — a story's own document is labelled with its number — with every match on the line highlighted; a line in `deferred-work.md` shows which DW entry it belongs to. Selecting a match opens its file at that line, with links to the story or entry. It runs `git grep` (ignored and binary files skipped, untracked files included), stopping at 2,000 matches; outside git it walks the files. Qubric's artifacts search in about 0.1 s, the whole repository in about 0.3 s.

**Find References** on a story or DW entry searches the artifacts for everything that mentions it; a story's search also matches its key spelling (`9.16` and `9-16-…`).

`BMADV_SEARCH="DW-1041" BmadViewer --dump <project>` prints match counts and timings for both scopes.

## Retro actions and deferred work

The sidebar's **Review** section lists what is owed that is not a story, with open counts.

| Source | Read as |
| --- | --- |
| `sprint-status.yaml` → `action_items` (v6) | retro actions: `id`, `epic`, `action`, `owner`, `status`, `ref`, plus `progress`/`resolution` |
| each retrospective's `## Action items` (v7, or v6 with no `action_items`) | numbered/bulleted items or a table with an `Action` column, grouped by `###`; status `proposed` |
| `deferred-work.md` in the implementation artifacts | canonical `### DW-<n>:` entries (one `key: value` per line, `gate:`, `status: done <date>`), and legacy `- source_spec:` / `- source_plan:` bullets, closed by a `disposition:` starting `fixed`, `closed`, `done`… |

**Sort** by key (the default: `DW-12` after `DW-9`, newest first, retro actions kept with their epic), state (open work first, done last, one section per state) or priority (critical → unspecified, one section per level), newest or oldest first. **Filter** by state, priority and, for retro actions, epic; the menu shows how many items each choice covers. Priority is the deferred-work format's `severity:` (or a `priority:` field); retro actions carry neither, so they all read as unspecified. Sort and filters are saved per project. Search matches every field, and **Hide finished** applies. Each item links to the line it is written on; paths in `location:` link to the files.

## Documents and tabs

Every story, ticket, epic and work item opens in the detail view with a browser-style tab bar under its header:

- **Fixed tabs** are the item's own views — Ticket, Plan, Story file, Epic definition; for an epic, its document, `tickets.toml` and retrospective (click the links above an epic's story list). They cannot be closed.
- **File tabs** open when you click a link or a file path in inline code (`scripts/x.py`). Close them with ×, or right-click a tab for Close Other Tabs / Close Tabs to the Right. Each item remembers its open tabs, across launches too.
- `file.rs:42`, `file.rs:42-50` and `file.md#L42-L50` open the file with those lines highlighted and scrolled into view.

Viewers: markdown rendered (with a Source toggle), `tickets.toml` as a ticket list with live status (and Source), code and text with syntax colours and line numbers, images with zoom in/out, fit and actual size (drag to pan, double-click to toggle), PDFs, folders, and an open/reveal panel for anything else. Each file tab's toolbar shows its path and opens it in the default app, Open With, or Finder.

Right-click any link for Open in Tab, Open in <default app>, **Open With ›** (every app that claims the type, default first, plus Other…), Reveal in Finder and Copy Path. "Story 9.16" in text links to that story. ⌘F finds in the document. The project's files are watched and the view reloads on change.

## Not yet

- Tracker-backed ticket stores (`store` other than `repo`): `tracker_status` is read from leaf files, but nothing is synced.
