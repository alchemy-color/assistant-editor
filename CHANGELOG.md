# Changelog

All notable changes to this project's **macOS reference app** are documented here. The repo's primary audience is porters; see `docs/` for architecture and porting guides.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project does **not** follow semantic versioning (internal build numbering).

## [v1.24] — 2026-09-09

### Changed
- **Unified project bar on every tab** — `Source Folder(s) | Materials`, a three-row grid separated by a thin fixed divider: row 1 the two section labels, row 2 the add/re-read/clear actions with the tab's status caption inline next to the materials totals, row 3 the folder chips beside a `subfolders ▾` toggle that opens the material tree on demand. The bar stays ~71pt collapsed regardless of loaded material. (The plain `Divider()` originally inflated the bar several-fold taller — now a fixed-height hairline.)
- **AI Edit panels renamed Script Beats / Timeline Beats** — left authors beats with a big Add Beat CTA + Auto-fill from Text in its empty state; right shows each beat as a timeline cell with a passive hint when empty. The footer + Add Beat / Remove all (bigger buttons) appears only once beats exist.
- **Undo/redo buttons removed** from the beat footer (snapshot-based undo remains internally; Auto-fill is a single undo point).
- **Save / Load an edit** — the Script Beats header's `square.and.arrow.down` writes the whole session (name, timestamp flag, estimated seconds, intent, treatment, beats, clip results) to `<timeline name>_timeline.yaml` in the first work folder; `square.and.arrow.up` lists saved edits (or **Open…**) and replaces the session after confirmation. Saved edits surface as a **`N tl`** badge in the project bar.
- **Timeline metadata block** above the Treatment drawer — timeline name, editable estimated seconds, "Append timestamp (_HHMMSS)" checkbox, multiline **Intent** field.
- **Project Setup decluttered** — Analyze / Regenerate Themes lives in the Weighing header (spinner + thin progress strip); the empty state has its own Analyze button.
- **Single title on every tab** — per-tab repeated heading rows removed; each tab starts directly with its project bar.
- **Chapter density & split verbosity** — Timeline Assist gains a Chapter density slider plus separate Chapters / Synopsis verbosity sliders under a "Usage" caption.

### Added
- `docs/MANUAL.md` — the full v1.24 user manual (every tool, ticker and slider), live in the repo.
- `Releases/Assistant Editor.app` — prebuilt macOS app bundle + `Releases/README.md` with run/zip/distribute instructions.

### Fixed
- Crash when deleting a beat (stale array-index binding during SwiftUI row removal) — getter returns an inert placeholder when the index is out of range.
- Project bar stretching to ~320pt: vertical `Divider` is flexible-height and inflated with the tab's tall proposal; replaced with a fixed 1×40 separator.

## [v1.23] — 2026-09-09

### Changed
- **Structured-first AI-Edit editor**: the left panel is now a beat-card list (title, description, mood, target duration, search queries) with a collapsible Treatment drawer; **Create Edit** replaces the old Parse-Script-then-find flow.
- **Sync by Transcript removed (parked)** — the tab is gone from this release, but `SyncByTranscriptTab.swift`, the sync model structs, and the sync Python scripts remain in the repo for later restoration. Use custom `tabOrder` migration; stale names are filtered defensively.

## [v1.21] — 2026

### Changed
- Project analysis is written as `<folder>_project.yaml` (manual renames acknowledged); preset files are `<folder>_priming_preset.yaml`.
- Whole-project **material tree** on every tab with green/red project-file health indicators.

## [v1.20] — 2026

### Fixed
- FTS5 metacharacter escaping (queries like `OR`, quotes, parentheses now treated literally).
- Embedding-map / chat-context data races.
- Atomic writes for `_chapters.yaml`, `_synopsis.txt`, `_project.yaml` (temp file + rename, no truncated output).

### Changed
- `--model` passthrough for chapter/synopsis generation.

## [v1.15 — v1.19] — folder unification, tab rename, robustness

- Canonical folder-ingest row on every tab, multi-select folder pickers, Clear-All confirmations.
- Timeline-Assist asset queue removed — processing always covers all discovered files.
- Tab renamed user-facing **Project Setup** (internal names unchanged; persisted keys migrated).
- Plural `_transcripts.txt` accepted everywhere; blank-line-after-timecode SRT/SRTX parser tolerance; subtitle-only chapter creation.
- Transcript-DB race fixes (single-queued connection handle).

## [v1.12 — v1.14]

- Per-tab media store isolation (one SubtitleStore/DocumentStore per tab).
- Priming window (9 fully independent LLM prompts) with named presets.
- Marker-directed retrieval (beats naming chapters resolve deterministically); beat-span timeline markers.
- Hardening: model pull/upgrade deadlock fix, cache fingerprinting, YAML escaping, beat-gap math, ES-ESC cancellation, crash fixes.

## [v1.0 — v1.11]

- Initial app: four-tab assistant-editor for interview post-production — Project Setup analysis, AI Edit, Timeline Assist (chapters/synopsis + Resolve timeline creation), Transcript Intelligence (RAG chat against local transcripts).
- Programmatic app icon (Didot Æ monogram on a graphite squircle).