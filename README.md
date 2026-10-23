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

## Documents

- Click a link or a file path in inline code (`scripts/x.py`) → opens in the default app.
- Right-click a link → Open, **Open With ›** (every app that claims the type, default first, plus Other…), Show in BMAD Viewer (markdown), Reveal in Finder, Copy Path.
- "Story 9.16" in text links to that story.
- ⌘F finds in the document. The project's files are watched and the view reloads on change.

## Not yet

- **BMAD v7 ticket tree** (`tickets/tickets.toml`, status in `story-*-plan.md` front matter): detected, not read yet. `ProjectLoader` is the seam.
- Retrospective action items from `sprint-status.yaml`.
