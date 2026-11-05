# BMAD Viewer

A lightweight native macOS viewer for [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) projects: story status, the build-order queue, and story documents, with files opening in their usual apps.

SwiftUI shell, AppKit text view (TextKit 1) for documents, no web view.

## Run

```sh
swift run BmadViewer ~/dev/Qubric        # debug, unbundled
scripts/make-app.sh                      # build/debug/ and build/release/BmadViewer.app
scripts/make-app.sh --install            # …and copy the release to ~/Applications
open build/release/BmadViewer.app --args ~/dev/Qubric
```

With no argument it reopens the most recent project; **File › Open Project…** (⌘O) picks another.

## Releasing

```sh
scripts/release.sh patch --dry-run   # show the tag and the notes, change nothing
scripts/release.sh 0.1               # tag, build, DMG, publish
```

Cuts a GitHub release from the committed state: notes generated from the commit
subjects since the newest tag — or kept as written if you put your own
`build/release-notes.md` there first — reviewed in your editor before anything
is published, then an annotated tag, a release build wrapped in a DMG with an
Applications shortcut, and a published GitHub release carrying the DMG, which
is what the About window reads
([About and release notes](#about-and-release-notes)). The tag is made before
the build, so the DMG carries the version it is released as. The first release
is `0.1`; then `patch`, `minor`, `major` or an explicit version. The build is
signed ad-hoc, so a downloaded app needs right-click → Open once. The DMG is
signed for Sparkle and an `appcast.xml` is published beside it, so installed
apps take updates from the stable feed
`releases/latest/download/appcast.xml`. The Sparkle signing key lives outside
the repo (`~/.sparkle/BmadViewer-ed25519.key`, public half committed) — losing
it means no installed app ever accepts an update again.

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

Used when `modules.bmm.active_initiative` is set (e.g. `_bmad/custom/config.user.toml`), or when there is no `sprint-status.yaml` but an `initiative-*` folder exists. The rules follow the project's own `_bmad/method/scripts/tickets.py`. Each container keeps its own file at the top and its `tickets.toml`, epic folders, leaf files and plans under a `tickets/` subfolder; trees written in the earlier layout — the tickets beside the container's file, as in the script's first release — still read.

| Source | Used for |
| --- | --- |
| `<initiative>/tickets/tickets.toml` `[[epic]]` | epic order, ids (story numbers are `<epic id>.<entry id>`) and titles |
| `<initiative>/tickets/epic-<slug>/tickets/tickets.toml` `[[entry]]` | tickets in build order: type, title, description, verify, `after`, risk, estimate, refine |
| `story-*.md` / `spike-*.md` / `bug-*.md` | a pulled ticket; joins its entry by `id` (`"6"` and `6` are one id), its `title` and `after` win |
| `*-plan.md` with `ticket:` | the ticket's `status` (draft … built, done, blocked, dropped) and its build record; a plan whose `ticket` names nothing is skipped with a warning, an unknown status reads as blocked |
| `spike-*-findings.md` with `spike:` | a spike's findings, as its fourth tab |
| `<initiative>/deferred-work.md` | the deferred-work ledger (older trees: the implementation artifacts folder) |
| `<store root>/backlog/` | tickets in no epic |

An `id` is a whole number or letters and digits. `after` names a sibling by bare id or file name, another epic's entry as `"<epic id>.<entry id>"`, a whole epic as `"epic-<slug>"`, or a tracker id. A parent initiative — a `tickets.toml` of `[[initiative]]` tables — says which children to open.

The store root is `[tickets] root` in `_bmad/custom/ticketing-store-config.toml` (default: the output folder). **Next** groups tickets the way `tickets.py next` does: in progress, built (awaiting done), ready to start, ready to refine (an unrefined bug always refines), blocked — which includes a ticket whose `unknown` still has an answer owed. A built ticket meets an `after`; an epic gate waits for the epic to be done.

A ticket shows up to four views: **Ticket** (its `tickets.toml` entry as text), **Story file**, **Plan**, and **Findings**.

`BmadViewer --dump <project>` prints what was read and exits, for comparing with `tickets.py next`.

## Reviewing a story

A story with a recorded baseline (`baseline_commit` in a v6 spec, `baseline_revision` in a v7 plan) or a `## Suggested Review Order` gets a fixed **Review** tab:

- **Range bar:** the git range being reviewed, from the baseline to, by default, **the story's last commit**: the last commit to touch the story document (its own commit), or the working tree when that document has uncommitted changes. HEAD and the working tree are the alternatives. It shows the file count and lines added and removed.
- **Left:** the review order's concerns and their stops, then **Other changed files**: what the range changed that no stop names (or every changed file, for a story with no review order). Stops whose file the range did not touch are marked unchanged.
- **Right:** the selected item as a **Diff** of the range, with old and new line numbers, added and removed lines banded across the width, syntax colours, and the stop's lines highlighted and scrolled to (the diff widens to the whole file when the lines fall outside the changed hunks). Since the range ends at the story's own commit, the review's line numbers match. **File** shows the file as it is today. ⌥⌘↑ and ⌥⌘↓ step through.
- A link to a file that has since moved (`RustCore/crates/…` → `crates/…`) is diffed at the path it had in the story's range, and shown from where it lives now in File view; a file that is gone says so.
- **Verify** (below the stops): the story's own checklist — a ticket's `verify` text split into items, or, when the entry says nothing, the review order's stops — as local checkboxes. Ticks are the app's, saved per project with the story, never written into the tree; the text is the key, so a rewritten `verify` asks again rather than inherit stale ticks.
- **Below** (sprint-status projects): for a story in `review`, **Mark Review Complete…** lists the exact lines it will change — the story's `development_status` line in `sprint-status.yaml` (`review` → `done`, comments kept) and the story file's front-matter `status:` — and asks before writing them. Checklist items still unticked are named in the same prompt. Nothing is committed. A story still in `build-order.md`'s queue is left alone: going done there also drops its row and lowers the check's floor in one commit (rule R2), so that stays a hand edit.

`BMADV_DIFF=17.5 BmadViewer --dump <project>` prints a story's range and whether each stop's lines appear in its diff.

## Handing a story to Build

The viewer does not build anything; it hands off. A story or ticket Build could take — not finished, not blocked, nothing still `waitsOn` — offers **Copy Run Command** in its header, and **Copy Build Command** / **Copy Build Auto Command** in its row's right-click menu, for the queue too. The line is what upstream's dispatcher takes, so it works in a fresh agent chat at the project root:

| Project | Attended | Unattended |
| --- | --- | --- |
| ticket tree | `/bmad-build ticket 12.1` | `/bmad-build-auto ticket 12.1` |
| ticket tree, backlog (no ref) | `/bmad-build ticket _bmad-output/backlog/spike-drill-stall.md` | `/bmad-build-auto ticket …` |
| sprint-status | `/bmad-build docs/bmad/implementation-artifacts/spec-9-15-….md` | `/bmad-build-auto …` |

A tree ticket is named by its `<epic id>.<entry id>` ref, which is the viewer's story number; a backlog ticket has no ref, so its file is named by root-relative path. A sprint-status story is named by its spec file, because Build resumes from the status in that file's front matter — a story with no spec file yet has nothing Build can open, so no command is offered. `bmad-build` keeps you at the checkpoints; `bmad-build-auto` never asks.

## Windows, tabs and history

- **One window per project.** **Open Project…** (⌘O) and **Open Recent** open a project in its own window, or bring its window to the front if it is already open; an empty window takes the project in place. **New Window** (⌘N) opens an empty one. Each window keeps its own selection, tabs and history, and macOS reopens every project's window on the next launch.
- **The welcome window.** Close the last project window and the app falls back to a welcome window listing the folders you have opened lately — click one to open it, right-click to show it in Finder or drop it from the list. Opening a project hides it again; closing it, by button or ⌘W, quits the app.
- **Tabs:** ⌘W closes the selected file tab (with no file tabs open it closes the window; ⌘⇧W always closes the window). ⌘1–⌘8 pick a tab and ⌘9 the last, ⌘⇧] and ⌘⇧[ step to the next and previous tab.
- **Back and forward:** ⌘[ and ⌘] (or the toolbar arrows) step through the stories, epics, items, lists and searches you have visited in the window. Quick changes, like arrowing down a list, are folded into one step. Review stops now step with ⌥⌘↑ and ⌥⌘↓.
- **Epic rings:** the ring on each sidebar epic is drawn one arc per status its stories are in — done green, built indigo, review purple, in progress blue, blocked red, ready teal, backlog grey — the same order and colours as the dashboard's donut and the badges, so an epic half done and half built reads that way at a glance. Hover for the counts.

## Dashboard

The first sidebar item, shown when a project opens: the overview holds the left of the window, a column of cards the right.

- **Cards** (right side), each linking to its stories: **Up next** (the build-order queue's head, or a ticket tree's in-progress and ready tickets, plus anything active the queue does not list), **Awaiting review** (review and built), **Recently completed** and **Recently created**, with how long ago.
- **Tiles:** percent complete, built awaiting done, active, in review, open deferred work (and how much is critical or high), open retro actions, human runs owed, and the longest remaining chain. Once tickets carry `estimate`s a tile sums them — **effort remaining** over the open tickets (bare numbers weigh; a written `M` counts toward coverage, not the sum) — and the **heaviest remaining chain** shows when it is a different path than the longest one. Each opens its list.
- **Charts:** completeness by status (a donut, in the badges' colours), throughput per week over the last 12 weeks with its average, the last 60 days of burn-up, and every epic's progress as a stacked bar (click a bar to open the epic).
- **Health:** open deferred work by priority, stories gated by open entries, retro follow-through verdicts, owed human runs, story files that disagree with `sprint-status.yaml`, and loader warnings.

Completion and creation dates come from the same git replay as the burn-up: each commit records which stories appeared and which changed status.

## Views

- **Dependencies:** stories laid out in layers by what they come after, prerequisites on the left, scoped to all epics or one (prerequisites from other epics shown dashed), with finished stories optionally hidden. The **longest remaining chain** is drawn in the accent colour and listed; click a story to light up its links, double-click to open it; zoom in the toolbar. Chain headers sum the estimates on them, and a ticket's `estimate` shows on its node and row; the **heaviest remaining chain** — the path whose bare-number estimates weigh the most, written estimates weighing nothing — is listed under it when it is a different path. Ticket trees use their resolved `after`; sprint-status projects infer links from build-order's *Waits on* column and "Depends on / Queued after N.M" sentences in epics.md. (pangolin's chain matches `tickets.py status` exactly.)
- **Burn-up:** scope against done (and done + built, for ticket trees) over time, per epic or overall, replayed from git: every change to `sprint-status.yaml`'s statuses, or to the ticket tree's `tickets.toml` entries and plan statuses (merges included via first parent). Hover for a day's numbers; **Table** for the figures. The replay ends exactly at today's counts for Qubric and pangolin, in about a second.
- **Retro follow-through:** a retro action shows what the next retrospective's *Previous-retro follow-through* table found — landed, partly, not landed — with its evidence and a link to the row. Rows match by action id (even cut short with …), by an id named in the row, or by item number against the retrospective before it (the same epic's first). An action also links the stories it became: those whose text cites its retro item number ("epic-10 retro items 152, 156"), and stories its own text names.
- **Human runs** (under Review): smoke tests from `smoke-tests.md` (status, blocking, gates, owner, and the spec file), checkpoints from `checkpoints.json`, and unfinished ticket-tree entries marked `hitl = true`. Sorted and filtered like the other review lists; one owed smoke test or checkpoint can be marked passed from its detail view.

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

Three writes come back from these lists, each through the same gate as **Mark Review Complete**: the lines it will change are shown, then applied on confirm, and a line edited by someone since it was read stops the write. **Record Progress…** on a retro action tracked in `sprint-status.yaml` replaces or adds that block's `progress:` and `resolution:` lines. **Mark Passed…** on an owed smoke test rewrites its row's status cell to `` ✅ `pass`<br>today ``, and on a checkpoint its entry's `"status"`; the rest of the row or entry is untouched. **Add Entry…** on Deferred work composes a canonical `### DW-<n>:` entry — the next free number, `status: open`, created today — and appends it to `deferred-work.md`. Nothing is committed.

## Documents and tabs

Every story, ticket, epic and work item opens in the detail view with a browser-style tab bar under its header:

- **Fixed tabs** are the item's own views — Ticket, Plan, Story file, Epic definition; for an epic, its document, `tickets.toml` and retrospective (click the links above an epic's story list). They cannot be closed.
- **File tabs** open when you click a link or a file path in inline code (`scripts/x.py`). Close them with ×, or right-click a tab for Close Other Tabs / Close Tabs to the Right. Each item remembers its open tabs, across launches too.
- `file.rs:42`, `file.rs:42-50` and `file.md#L42-L50` open the file with those lines highlighted and scrolled into view.

Viewers: markdown rendered (with a Source toggle), `tickets.toml` as a ticket list with live status (and Source), code and text with syntax colours and line numbers, images with zoom in/out, fit and actual size (drag to pan, double-click to toggle), PDFs, folders, and an open/reveal panel for anything else. Each file tab's toolbar shows its path and opens it in the default app, Open With, or Finder.

Right-click any link for Open in Tab, Open in <default app>, **Open With ›** (every app that claims the type, default first, plus Other…), Reveal in Finder and Copy Path. "Story 9.16" in text links to that story. ⌘F finds in the document. The project's files are watched and the view reloads on change.

## About and release notes

- **About BMAD Viewer** (app menu) opens its own window: the icon, the version and git build, the developer, and buttons to the repository, its releases and its issue tracker. The version comes from the newest git tag, applied by `scripts/make-app.sh`.
- **Check for Updates…** (app menu) keeps a release build current through [Sparkle](https://sparkle-project.org/): once asked to check automatically — the first prompt — the app checks its release feed at launch and daily, and on demand here; an update downloads, is verified, and the app replaces itself and relaunches. Because the bundle is signed only ad-hoc, the trust anchor is the EdDSA signature on the DMG — `scripts/release.sh` makes it with the private key whose public half ships in `scripts/sparkle-public-key.txt`. The debug bundle has no feed and no menu item.
- **Release notes** fill the window below the header, synced from the repository's **GitHub Releases** — the one place notes are written, when a tag is published. The list opens instantly from a cached copy and refreshes from the network; the refresh button re-checks GitHub, and a cached copy says so when GitHub cannot be reached. Each release gets its heading, date, and a marker against the running build (*this version*, *newer than this build*), and the notes render like story files — real links, lists and ⌘F.

## Not yet

- Tracker-backed ticket stores (`store` other than `repo`): `tracker_status` is read from leaf files, but nothing is synced.
