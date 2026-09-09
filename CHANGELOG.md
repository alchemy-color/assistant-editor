# Changelog

All notable changes to this project's **macOS reference app** are documented here. The repo's primary audience is porters; see `docs/` for architecture and porting guides.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project does **not** follow semantic versioning (internal build numbering).

## [Unreleased]

### Added (v1.24 — AI-Edit UI polish, in progress)
- Timeline metadata block at the top of the AI-Edit left panel: timeline name, editable estimated length, "include timestamp", and a multiline **Intent** field (persisted in sessions).
- Beat cards expand by default with larger text (headline title / subheadline description) and a visible trash icon.
- Drag-and-drop reordering of beats (Move Up/Down menu retained as fallback).
- Full **Undo/Redo** for beat changes — adds, deletes, reorders, drag-drops, typed edits; "Auto-fill from text" is a single undo point.
- Right-panel BeatRows simplified to title + clips only.
- Fixed a crash when deleting a beat (stale array-index binding during SwiftUI row removal).

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