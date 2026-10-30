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

BMAD's skills own writes; the viewer's job is handoff, not editing.

- **Copy the run command.** On any ready ticket or story, copy the `bmad-build` /
  `bmad-build-auto` invocation with the right spec/ticket arguments. Pairs with
  the Next queue.
- **Extend the previewed-edit pattern** (the `ReviewCompletion` lines-then-confirm
  mechanism) to the other write paths it fits: marking a human run (smoke test,
  checkpoint) passed, recording progress/resolution on a retro action, appending
  a new `DW-` entry to the ledger.
- **Review checklist.** Persist the `verify` items from a ticket's `tickets.toml`
  entry or review order as local checkboxes; show unchecked items in the
  Mark Review Complete prompt.

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

- **Aggregate effort.** 2026-10-30: `Story.estimate` from `tickets.toml` entries
  and front matter, the `Effort` summary, the dashboard's effort-remaining and
  heaviest-remaining-chain tiles, estimate-weighted chain listing in the
  Dependencies view, and the `--dump` effort line.
