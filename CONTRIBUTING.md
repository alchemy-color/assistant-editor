# Contributing (porting to Linux / Windows)

This repository exists so that third-party developers can build **Linux** and **Windows** versions of Assistant Editor. This file lays out how to work here.

## Branch strategy
- `main` — the macOS reference source (v1.23, structured AI-Edit editor; Sync-by-Transcript parked) + shared docs. Treat as stable.
- `port-linux` — follow the PORTING_LINUX guide; commit strategy by milestone.
- `port-windows` — follow the PORTING_WINDOWS guide.
- Land shared, not-yet-platform-specific improvements back to `main`.

## What a good port PR contains
1. Platform decision + rationale (see guides: Rust+Tauri preferred; all-Python viable).
2. A `python_bridge` reimplementation matching `SCRIPT_INTERFACES.md` exactly.
3. An embeddings strategy (fastembed/ONNX or LLM-server embedding route).
4. Resolve module/lib path resolution (env overrides first, then platform defaults).
5. Storage migration for UserDefaults→config and Caches→platform cache dir (mirror `STORAGE.md`).
6. A verification checklist run (each guide has one) — documented in the PR body.

## Non-negotiables (do not "improve" these)
- Python scripts stay as subprocess JSON pipes — no in-language rewrites unless approved (see ARCHITECTURE.md §4 and SCRIPT_INTERFACES.md §9).
- File formats in `docs/FILE_FORMATS.md` must not change (tools depend on them).
- FTS5 exact+semantic merge search (question of quality; don't regress to substring).
- Per-tab store isolation.
- Local-only AI; no cloud endpoints.
- AI-output JSON schemas stay grammar-constrained and stable (LLM_BACKEND.md §5).

## Conventions
- Docs are the source of truth for porters. If a port reveals a plate-specific
  detail (a new macOS path, a Resolve quirk), add it to the relevant `docs/*.md`
  or the appropriate porting guide.
- Commit messages: imperative, short, reference the milestone (e.g.
  `port-linux: python bridge + config storage`).
- No operating-system-specific code in the shared `source/Python/` — use env-var
  overrides (RESOLVE_SCRIPT_API/RESOLVE_SCRIPT_LIB, TMPDIR) instead.

## Communication
Open issues for: platform blockers, Resolve API version quirks, and any place
where the reference and the port disagree on expected output. Links to the
chosen UI stack and LLM server (with versions) in the issue body.

---

Approval gate: because this is a proprietary project, every PR is reviewed by
the copyright holder before merge. Ports shipping without an explicit
authorization will not be merged.