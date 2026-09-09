# Assistant Editor — Architecture

This document describes the reference **macOS** implementation in enough detail that a third-party developer can reimplement the UI layer for Linux/Windows while reusing the Python pipeline and the file formats unchanged.

---

## 1. High-level picture

```
┌──────────────────────────────────────────────────────────────┐
│                        UI layer (SwiftUI)                    │
│  4 tabs:  Project Setup · AI Edit · Timeline Assist ·        │
│           Transcript Intelligence                            │
│          (Sync by Transcript parked in v1.23 — source kept)  │
│                                                              │
│  ┌────────────┐ ┌─────────────┐ ┌────────────┐ ┌───────────┐ │
│  │ Subtitle   │ │ Document    │ │ Assistant  │ │ Knowledge │ │
│  │ Store      │ │ Store       │ │ Store      │ │ Store     │ │
│  └────────────┘ └─────────────┘ └────────────┘ └───────────┘ │
└───────────┬───────────────────────────────────────────────────┘
            │ PythonBridge (subprocess, JSON on stdin/stdout)
            ▼
┌──────────────────────────────────────────────────────────────┐
│                  Python pipeline (17 scripts)                 │
│  process_srt · analyze_project · scan_summaries              │
│  create_timeline · write_resolve · sync_* · parse/convert    │
└──────┬──────────────────────────────┬───────────────────────┘
       │ HTTP (OpenAI /v1)             │ DaVinci Resolve scripting API
       ▼                              ▼
   oMLX / Ollama              DaVinci Resolve (Fusion)
   (local LLM server)         + FTS5 SQLite + ffmpeg
```

Key insight for porters: **the UI layer and the Python pipeline only talk over a well-defined JSON contract** (implemented by `PythonBridge` on the Swift side). That boundary is where the port lives.

---

## 2. Store hierarchy (macOS Swift reference)

All stores are created at app level in `AssistantEditorApp.swift` and injected with `@EnvironmentObject`. **No store auto-loads on launch** — each tab loads on demand when the user picks a folder.

| Store (file) | Role | Persistence |
|---|---|---|
| `SubtitleStore` (`SubtitleStore.swift`) | Parses SRT/SRTX/TXT; owns the search SQLite DBs; embeddings for semantic search; speaker filtering; frame-rate state | file-backed SQLite + FTS5 in `~/Library/Caches/assistanteditor_<tabtag>_<folder>.db` |
| `DocumentStore` (`DocumentStore.swift`) | Scans folders for `_chapters.yaml` (via `scan_summaries.py`), typed `[SummaryDocument]`, no DB | pure filesystem |
| `AssistantStore` (`AssistantStore.swift`) | Chat messages for Transcript Intelligence tab; calls the LLM server with RAG context | in-memory + optional HTML save |
| `KnowledgeStore` (`KnowledgeStore.swift`) | Pre-computed per-interview knowledge base: synopsis, topic breakdown (theme→markers), centroid key quotes | JSON in Caches |
| `ProjectAnalysis` (`ProjectAnalysis.swift`) | `_project.yaml` model: themes, keywords, weights, stats, interviews | per-folder YAML + `@AppStorage` theme JSON |
| `AppProgress` | Bottom-bar progress: `isActive`, `progress`, `message` | — |

### Per-tab media stores (important isolation rule, since v1.12)
Timeline Assist, Transcript Intelligence, and AI Edit each own their **own** `SubtitleStore`/`DocumentStore` instances (`tlSub`/`tiSub`/`aiSub` etc.). A tab's load/clear can never clobber another tab's loaded data. Source Material touches no media stores at all. The per-tab instance is held as `@StateObject` in `ContentView` and passed via init. Cache files are namespaced per tab (`tl`/`ti`/`ai`/`app` tags) to avoid cross-tab SQLite connection contention.

---

## 3. The four tabs

### 3.1 Project Setup (`SourceMaterialTab.swift`)
- Folder picker (multiple, directories only) → `@AppStorage("sourceMaterialFolders")`.
- **Analyze/Regenerate** button calls `analyze_project.py` (via `runRawProgress`) with the folder list on stdin. Returns themes/keywords/weights + per-interview stats.
- Results decoded as `ProjectAnalysis`, persisted as `<folderName>_project.yaml` in the root folder (canonical name), acknowledged for manual renames (`*_project.yaml`).
- Weighing sliders (co-dependent: always sum to 100%; snapshot-based so dragging restores originals; reset restores `_project.yaml` values).
- Material tree (green/red project-file indicators) built from filesystem scan.
- Themes shared across tabs via `@AppStorage("projectThemesJSON")`.

### 3.2 AI Edit (`AIEditTab.swift` + `AIEditStore.swift`)
Pipeline: author beats in the structured left panel (or paste a treatment + **Auto-fill from text**) → **Create Edit** (Find Clips across all beats) → Review Flow (optional LLM continuity pass) → Create Timeline in Resolve.
- Retrieval is **material-driven**: the script gives structure, transcripts give content. Stage A builds a candidate pool (beat queries + content words + project theme keywords), Stage B lets the LLM pick ≤N with reasons, Stage C snaps to subtitle cues.
- Schemas are LLM-constrained (`format:` JSON schema on the oMLX call, `response_format` json_schema) to prevent malformed JSON.
- Session autosaved to `@AppStorage("aiEditSessionJSON")`.

### 3.3 Timeline Assist (`ProcessTimelineTab.swift`)
- Search subtitles/transcripts via FTS5 exact + semantic merge.
- Generate per-interview chapters + synopsis via `process_srt.py`.
- Assemble a Resolve timeline from search hits: colored clip groups, gap video (ffmpeg black), marker flags, optional `.srtx` subtitle export.
- Multi-folder mode (work folders > 1): chapters are per-timeline so unavailable → button becomes "Create Synopsis" and processing passes `--synopsis-only`.

### 3.4 Transcript Intelligence (`TranscriptIntelligenceTab.swift`)
- RAG chat. Context = KnowledgeStore summaries + FTS5 subtitle/transcript search hits (timecoded, speaker-attributed).
- Chat calls the LLM server via `AssistantStore`.
- ESC cancels in-flight generation (`AssistantStore.cancelAll()` + `PythonBridge.cancelRunning()`).

### 3.5 Sync by Transcript (parked in v1.23)
Transcript-to-timeline sync; EDL import/export; marker restore/undo. Removed from the active app in v1.23 (`SyncByTranscriptTab.swift` stays in the project/repo for later restoration).

---

## 4. Python pipeline (the reusable core)

All scripts read args and/or JSON on **stdin** and print JSON on **stdout**. Progress is streamed as JSON lines `{"progress": "message"}`. Errors are a final JSON line `{"error": "..."}` (surfaced first-class by the bridge, not garbled stderr).

| Script | Input | Output | Cross-platform? |
|---|---|---|---|
| `process_srt.py` | SRT/SRTX path + flags (+ `--transcript`) | `_chapters.yaml` + `_synopsis.txt`, JSON status | ✅ pure Python + LLM HTTP |
| `analyze_project.py` | folder list on stdin | `<folder>_project.yaml`, JSON analysis | ✅ |
| `scan_summaries.py` | folder root | JSON `[SummaryDocument]` | ✅ |
| `create_timeline.py` | timeline JSON on stdin (markers, name, gap, fps…) | operates Resolve, writes `.srtx`, JSON status | ⚠️ Resolve API path resolution is macOS-specific today |
| `write_resolve.py` | marker JSON on stdin | adds/clears markers in Resolve | ⚠️ same |
| `sync_transcripts.py` / `sync_from_timeline.py` / `build_sync_timeline.py` / `export_sync_edl.py` / `convert_edl_to_summary.py` | misc | EDL/JSON translation, Resolve ops | ⚠️ mixed |
| `parse_srt.py` / `parse_summary.py` / `search_index.py` / `rebuild_index.py` / `convert_summaries.py` / `resolve_workbench.py` / `test_build_timeline.py` | misc helpers | JSON | mostly ✅ |

Full stdin/stdout contracts in **`SCRIPT_INTERFACES.md`**.

---

## 5. PythonBridge (the boundary to replace per-platform)

`PythonBridge.swift` is the macOS implementation of "run a Python script with JSON I/O". A port must provide an equivalent that matches this contract exactly:

- **`runRaw(script, args, stdin, envOverrides, timeoutSeconds)`** → stdout String, throws on non-zero exit or timeout.
- **`runRawProgress(...)`** → streams stdout; every line that parses as JSON with a `"progress"` key is forwarded to the UI (drives the bottom progress bar).
- **`runJSON(script, args, as: T)`** → decode stdout as `T`.
- **`cancelRunning()`** → terminate the in-flight child process.
- **`bestError(stdout, stderr)`** → prefer the final JSON `{"error": ...}` line over raw stderr.

Also handles:
- **Frame-rate detection**: ffprobe on source video(s), else timecode heuristics (`\d{2}:\d{2}:\d{2}:(\d{2})` → nearest known rate).
- **Path prepending** for the Python interpreter and ffprobe (Homebrew /usr/local). A port must change these to the platform's Python/ffprobe locations.
- **Env injection**: `OMLX_BASE_URL`, `OMLX_API_KEY`, `AE_FPS` (sync scripts read fps from `AE_FPS`, default 25).

> Porting note: the hardcoded `/usr/bin/env`, `/Library/Frameworks/...`, `/opt/homebrew/bin` paths, `/tmp` payload files, and the Resolve module path are **macOS-specific**. The Linux/Windows guides enumerate every one.

---

## 6. Search & embeddings

### Subtitle/transcript search
`SearchDatabase` (`Database.swift`) builds file-backed SQLite with FTS5:
- `subtitle_entries` + `subtitle_fts` (subtitle cues)
- `transcript_entries` + `transcript_fts` (long paragraphs)
- Embeddings stored as a BLOB column in each table (from `NLEmbedding`).

Search = FTS5 exact (`ftsQueryString` quotes each term + trailing `*`, escaping metacharacters) **merged with** semantic cosine results. Results are deduped, re-ranked, sliced.

### Semantic embeddings (macOS-only, must be replaced on a port)
`EmbeddingEngine` (`EmbeddingService.swift`) wraps **`NLEmbedding.sentenceEmbedding(for: .english)`** — a macOS 11+ framework. It is **not thread-safe**, so all calls serialize on a private `DispatchQueue`. A port needs an equivalent embedding provider producing comparable `[Double]` vectors (see porting guides — `fastembed`/ONNX, or an embedding model served by the LLM server).

---

## 7. LLM integration (see `LLM_BACKEND.md`)

Two equivalent local backends, both OpenAI-compatible `/v1`:
- **oMLX** (default) — `http://localhost:8000`. Default model `Llama-3.1-8B-Instruct-4bit`. Base URL + API key in UserDefaults (`omlxBaseURL`, `omlxAPIKey`).
- **Ollama** — `http://localhost:11434` (legacy path; a `keep_alive`, `format` schema field, and `num_ctx` may be used in some call sites).

The condition is strict: **the Python scripts and the Swift code both target the OpenAI `/v1/chat/completions` contract**, injecting `OMLX_BASE_URL`/`OMLX_API_KEY` into every subprocess so scripts hit the same server the UI uses. Any OpenAI-compatible local server (vLLM, llama.cpp server, LM Studio, etc.) also works.

---

## 8. DaVinci Resolve integration (see `PORTING_*` for per-OS paths)

Resolve exposes its scripting API through `DaVinciResolveScript` (a Python module shipped with Resolve under `Developer/Scripting/Modules`) plus a `fusionscript.so`/`.dll` library. The scripts resolve the API/library path with a platform-specific search list (currently macOS `/Library/...` and `/Applications/DaVinci Resolve...`).

On macOS there is also an **in-console bridge** (`ResolveConnector.swift`): it installs a helper into Resolve's `Fusion/Scripts/Comp`, drives it via AppleScript menu automation as a fallback when the external script server misbehaves. This AppleScript/System-Events automation is macOS-only; a port uses the platform's equivalent (or just the external scripting API). **Full macOS build/deploy/paths/bridge details: `MACOS_REFERENCE.md`.**

---

## 9. Persistence surface (see `STORAGE.md`)

- UserDefaults keys (`@AppStorage`) for all UI settings, folder lists, theme JSON, session JSON.
- SQLite FTS5 caches in Caches dir, namespaced per tab + folder.
- Per-folder YAML: `_chapters.yaml`, `_synopsis.txt`, `<folderName>_project.yaml`, `<folderName>_priming_preset.yaml`.
- `/tmp` scratch: payload/result files for Resolve bridge, priming prompt, themes file, debug logs.

---

## 10. Key architectural decisions new ports must preserve

1. **Python does the heavy lifting; UI is thin.** Match the JSON contracts, not the Swift internals.
2. **Per-tab store isolation.** Never share a media store across tabs.
3. **FTS5 exact + semantic merge.** Don't drop to plain substring search.
4. **Grammar-constrained LLM JSON.** Use `response_format: json_schema` so beats/clip-selections are always valid.
5. **All AI local.** No cloud endpoints.
6. **File-format stability.** Do not change `_chapters.yaml`, `_synopsis.txt`, `_project.yaml`, SRTX shape — tools (YouTube marker export, EDL export, sync) depend on them.