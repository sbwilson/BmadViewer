# Roadmap

Features to consider, in rough priority order. Grounded in the BMAD Method
releases through v6.12.4 (v7 in preview) and where this codebase stands.

## 1. Keep pace with upstream BMAD

The reader must keep matching what the tools write.

- **Deferred findings in spec front matter.** v6.11's Build Auto contract dropped
  `deferred-work.md` from the flow: deferred findings now live in each spec's
  `deferred:` front-matter list (Build keeps its ledger). Read both sources and
  merge them into the Deferred Work view with a source label, or the tile silently
  reads zero on new projects. (`WorkItems.deferredWork` in `Sources/BmadKit/WorkItems.swift`,
  `ProjectLoader.loadDeferredWork`.)
- **Story range convention changed.** With `final_revision` gone, upstream computes a
  story's range as `baseline_revision..<next story's baseline_revision>` (`..HEAD` at
  exit). Add "next story's baseline" as an endpoint in the Review tab's range bar,
  beside the story's own commit, HEAD and the working tree.
- **Cross-check with `sprint_plan.py`.** v6.11 sprint-planning owns epic parsing,
  status merging and validation with JSON-only output. Add a Dashboard health row
  that cross-runs it against our own parse — the same trick as comparing `--dump`
  with `tickets.py next` — and a `--json` output for `--dump` so CI can diff both.
- **New artifact shapes to discover.** Show these in Documents and link them:
  `SPEC.md` spec folders (five-field kernel), `ARCHITECTURE-SPINE.md`,
  `DESIGN.md` / `EXPERIENCE.md` (the UX two-spine), and headless retrospectives,
  which v6.11 writes as `RETROSPECTIVE.md` *inside a spec folder* — the current
  `epic-<n>-retro-*` discovery in `ProjectLoader` misses those. `AGENTS.md`
  project-context blocks and memlog session files are also worth listing.
- **Naming churn.** `bmad-checkpoint-preview` became `bmad-walkthrough`; verify
  whether `checkpoints.json` (`HumanRuns.checkpoints` in `Insights.swift`) still
  ships that shape, and where the review-triage logs (verdict + evidence per
  finding) land, show them in the Review tab.
- **Installed-version awareness.** Read the `_bmad` install's version and modules;
  show them in the Dashboard subtitle and warn when the tree is newer than what
  the loader understands.

## 2. Make the viewer actionable without becoming an editor

BMAD's skills own writes; the viewer's job is handoff, not editing. The three
here landed on 2026-11-02 (see [Done](#done)): copy the run command, the
previewed-edit pattern on the other write paths, and the review checklist. What
is left is the next write path, whatever it turns out to be, held to the same
rule — plan the lines against the files as they read, show them, apply on
confirm, and refuse when a line has changed underneath.

## 3. Awareness beyond the window

- **Menu bar extra + notifications.** "N awaiting review, M critical deferred work,
  K human runs owed" — `FileWatcher` already watches the files; this is mostly
  presentation.
- **Portfolio view.** The app tracks recent projects per window; a rollup window
  showing progress and awaiting-review across all of them is a small step.

## 4. Export and share

- **Standup/status export.** Copy-as-Markdown for the dashboard summary, the Next
  queue or any filtered list — pasteable into a retro or chat; or an HTML export
  of the dashboard.

## 5. Tracker-backed stores (the README's "Not yet")

- `tracker_status` and `tracker_id` are already parsed (`TicketTree`). Next is
  read-only tracker sync: fetch the tracker's state and surface local-vs-tracker
  divergence as Dashboard health rows, before any write-back.

## 6. Smaller things

- **Surface dependency cycles.** `DependencyGraph` cuts cycles silently where they
  close; emit a warning row naming the cycle instead of hiding it.
- **Archive browsing.** `archive/` is deliberately skipped during search; a toggle
  to browse archived epics and stories would stop losing them entirely.
- **Section-scoped TOML keys.** `ConfigResolver.tomlAssignments` ignores section
  headers, so a same-named key under any `[section]` leaks into
  `active_initiative` and path resolution.
- **Non-BMAD folder onboarding.** When a chosen folder has no status file and no
  ticket tree, point at the BMAD installer rather than only erroring.

## Done

- **Every status in the sidebar ring.** 2026-11-03: `Epic.statusBreakdown` counts
  an epic's stories per status kind in `Status.Kind.chartOrder` (the order the
  dashboard charts in, now shared rather than duplicated), and the sidebar's
  epic ring draws one arc per status in the badge colours instead of a single
  done-of-total turn — so `built`, `review` and a blocked ticket each show.
  Hovering an epic lists the counts.
- **Handoff, run commands.** 2026-11-02: `RunCommand.command(for:in:auto:)` builds
  the `bmad-build` / `bmad-build-auto` line — `ticket <epic>.<entry>` for a tree
  ticket, `ticket <path>` for a backlog ticket with no ref, the root-relative spec
  file for a sprint-status story — offered only where Build can take the story: not
  terminal, not blocked, nothing `waitsOn`. **Copy Run Command** in a ticket's
  header, **Copy Build Command** / **Copy Build Auto Command** on story and queue
  rows.
- **The other write paths, previewed first.** 2026-11-02: `WorkItemEdits` plans
  `smokeTestPass` (a `smoke-tests.md` row's status cell), `checkpointPass` (a
  `checkpoints.json` entry's `"status"`), `retroActionRecord` (`progress:` /
  `resolution:` on a `sprint-status.yaml` action item) and `ledgerAppend`
  (`### DW-<n>:` on the deferred-work ledger), each applied through
  `ReviewCompletion.apply`, so the lines are shown before writing and a line
  changed since it was read stops the write. **Mark Passed…**, **Record
  Progress…** and **Add Entry…** in the work-item views.
- **Review checklist.** 2026-11-02: `ReviewChecklist.items(for:)` — a ticket's
  `verify` text split into items, else its review order's stops — as checkboxes in
  the review list, ticks saved per project keyed on the item text, and the unticked
  ones named in the Mark Review Complete prompt.
- **Aggregate effort.** 2026-10-30: `Story.estimate` from `tickets.toml` entries
  and front matter, the `Effort` summary, the dashboard's effort-remaining and
  heaviest-remaining-chain tiles, estimate-weighted chain listing in the
  Dependencies view, and the `--dump` effort line.
