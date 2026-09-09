# Python Script Interfaces

The app's UI layer never does the heavy lifting — it shells out to Python scripts and exchanges **JSON only**. This document is the contract. A port must reproduce the bridge (`PythonBridge.swift` on macOS) to match these exactly; the scripts themselves are cross-platform.

---

## 0. Conventions (apply to every script)

- **Invocation:** Python 3 (`/usr/bin/python3` on macOS; `python3`/`py -3` elsewhere) + script name + args, **working directory = the script's own directory**.
- **stdin:** JSON payload or nothing — see each script.
- **stdout:** a single JSON object (or a stream of JSON `{"progress": "..."}` lines ending in a final JSON result/error). **All output `flush=True`.**
- **Errors:** `{"error": "human readable message"}` printed to stdout with `sys.exit(1)`, or stdout JSON with an `"error"` field. The bridge prefers this over stderr.
- **Env vars honored by scripts:**
  - `OMLX_BASE_URL` — LLM server base URL (default `http://localhost:8000`).
  - `OMLX_API_KEY` — optional API key for the LLM server.
  - `AE_FPS` — timeline frame rate for sync/EDL math (default `25`).
  - `RESOLVE_SCRIPT_API` / `RESOLVE_SCRIPT_LIB` — overrides for the Resolve module/library path.
  - `OLLAMA_BASE` — legacy alias, set to the same value as `OMLX_BASE_URL` (kept for older port configs).
- **File-family relations** (all scripts know these): a subtitle `.srtx`/`.srt` optional pair is its `_subtitles` sibling; a transcript pairs at `<base>_transcript.txt` **or** `<base>_transcripts.txt` (plural accepted everywhere since v1.18).

---

## 1. `process_srt.py` — chapters + synopsis for ONE interview

`USAGE: process_srt.py <srt_path> [--fps 25.0] [--force-keyword] [--verbosity 0.5] [--synopsis-intro] [--synopsis-paragraphs] [--synopsis-bullets] [--synopsis-timecode] [--chapters-verbosity 0.5] [--synopsis-verbosity 0.5] [--chapters-only] [--synopsis-only] [--priming-prompt-file <file>] [--transcript <path>] [--themes-file <file>] [--model <name>] [--chapter-density <float>] [--check-ollama]`

Checks/first-arg special:
- `process_srt.py --check-ollama` → returns JSON report of LLM availability (used by app health checks).

Behavior:
- Reads the SRT/SRTX/TXT file, parses via the robust timecode-line parser, computes per-chapter cues.
- **LLM path:** calls the local oMLX server (`OMLX_BASE_URL`, OpenAI-compatible `/v1/chat/completions`) with the (customizable) chapters priming; produces `markers` array + synopsis prose. Grammar-constrained JSON (`response_format: json_schema`) when available.
- **Keyword-fallback path:** when the LLM is unavailable, falls back to keyword-frequency chapter extraction and flags `DEGRADED_REASON` in the output (`warning` field).
- Writes `_chapters.yaml` (interview metadata + chapter markers) and `_synopsis.txt` (header + optional Intro/Paragraphs/Bullets/Timecode sections) **atomically** (temp file + `os.replace` + `os.fsync`).
- `--transcript` passes the paired transcript for richer LLM context; chapter timecodes snap to subtitle boundaries.
- `--themes-file` supplies dynamic project themes (overrides hardcoded wine/viticulture themes) for chapter detection, color assignment, and name building.

**Output JSON:**
```json
{
  "chapters": N, "synopsis": true/false, "file": "...",
  "cueCount": N, "duration_s": 1234.5, "markers": [ {...} ],
  "warning": "LLM unavailable — keyword fallback"        // optional
}
```

---

## 2. `analyze_project.py` — project analysis / theme extraction

`USAGE: analyze_project.py <root_folder> [--model <name>] [--priming-prompt-file <file>]`

- Called with the root folder (or the folder whose `_project.yaml` should be regenerated); the folder list for multi-folder is passed via stdin on the macOS side but the script's contract key is the root arg.
- Scans folders for SRT/SRTX/TXT; merges cues; extracts speakers + frequency words.
- LLM extracts project-specific themes (name, keywords, weight 0–1, color) using the project-analysis priming; falls back to keyword-frequency theme detection when LLM unavailable (produces exact fractions like `7/28`, `3/28` — a signature of fallback mode).
- Writes `<folderName>_project.yaml` (**canonical name**; acknowledges an existing `*_project.yaml` / legacy `_project.yaml`) atomically. Also writes to the work folder when invoked with a single-material folder.

**Output JSON:**
```json
{
  "version": "1.0", "folders": ["..."],
  "themes": [ {"name":"...", "keywords":["..."], "weight":0.5, "color":"Blue"} ],
  "interviews": [ {"title":"...", "folderPath":"...", "durationS":0, "cueCount":0, "speakers":[...] , "hasSubtitles":true, ...} ],
  "stats": {...}, "createdAt": "..."
}
```

---

## 3. `scan_summaries.py` — document/inventory scan

`USAGE: scan_summaries.py <root> [--flat]`

- Walks the folder tree (recursive by default; `--flat` = only the root level) discovering `_chapters.yaml` files.
- **Output:** JSON array of `SummaryDocument` objects:
```json
[ {"title": "...", "path": "...", "folder": "...", "chapterCount": N,
   "generatedDate": "...", "chapters": [ {"index":0,"name":"...","notes":"...","duration_s":0} ]} ]
```

---

## 4. `create_timeline.py` — build a Resolve timeline from clip markers

**stdin JSON:**
```json
{
  "name": "Timeline Name",
  "markers": [
    {"folder": "/path/to/interview", "file": "clip name", "start_s": 0.0, "duration_s": 5.0,
     "query": "matched phrase", "subtitleText": "full cue/paragraph text", "speaker": "...",
     "match": "exact|semantic|context", "color": "Blue|Orange|...",
     "group_id": "beat-1", "notes": "...", "start_frame": 0},
    ...
  ],
  "groupGapFrames": 24,
  "addClipMarkers": true,
  "addSubtitles": false,
  "srtFolder": "/path/for/subtitle_file"
}
```

Behavior:
- Locates API (`find_api()`) + fusion lib (`find_lib()`) — **the macOS-specific paths live here; see porting guides**.
- Creates a timeline, imports media (clips matched from the Resolve media pool by `folder`+file), places clips back-to-back inside a beat (`group_id`), inserts a gap (group-gap frames or `recordFrame` positioning; black gap clip via ffmpeg in classic mode) **between** beats.
- Adds markers: per-clip (blue match / orange context) or beat-span markers (cycling palette); color mapping normalizes Resolve's broken AddMarker colors (Teal→Sky, Orange→Rose, Tan→Yellow, etc.).
- Optionally writes `<timelineName>.srtx` (standard SRT millisecond timecodes, speaker line, leading-space text) into the first marker's folder.
- Emits progress JSON lines while assembling; debug log at `{tempfile.gettempdir()}/assistanteditor_timeline_log.json` (platform temp dir).

**Output JSON:** `{"timelineName":"...", "placed": N, "total": N, "errors": [...] }`

---

## 5. `write_resolve.py` — write/restore markers on the CURRENT timeline

**stdin JSON:** array of marker objects, or a wrapper `{"markers": [...], "clear": bool}`:
```json
[ {"start_s": 0.0, "duration_s": 5.0, "text": "...", "summary": "...", "keywords": "...", "color": "Blue"} ]
```
- Legacy frame-based `frame_id`/`duration` fields still accepted.
- Groups markers by color to dodge Resolve's per-color AddMarker bug.
- `Undo` mode: app backs up current markers to temp JSON before writing; a subsequent call with those backups clears/re-restores.

**Output JSON:** `{"added": N, "cleared": N, "ok": true}`

---

## 6. Sync family (frame-accurate transcript↔timeline)

### `sync_transcripts.py`
`USAGE: reads JSON from stdin`.
```json
{"field_recorder": "/path/to/recorder_transcript.txt", "clips": ["/clip1", "/clip2", ...]}
```
Builds an FTS index of the field-recorder transcript, then for each clip searches for matched segments. Reads `AE_FPS` (default 25). Outputs `{"results": [ {clip, segments, total_s, ...} ], "progress": "…"}` lines.

### `build_sync_timeline.py`
`USAGE: reads JSON from stdin`.
```json
{"field_recorder": "...", "results": [ {clip, segments, ...} ]}
```
Builds the Resolve timeline from sync results (uses the project's real frame rate). Outputs `{"timeline_name": "...", "edl_events": N, "markers_only": bool, "placed": N, "total": N, "unmatched": [...]}` — note the **snake_case** keys (Swift uses a `convertFromSnakeCase` decoder).

### `export_sync_edl.py`
`USAGE: cat sync_results.json | python3 export_sync_edl.py > sync_timeline.edl`
Reads the same results JSON from stdin; writes EDL to stdout. Frame-accurate, fps-aware.

### `sync_from_timeline.py`
Reads JSON from stdin (timeline→transcript markers). Converts a Resolve timeline's markers back into transcript edits. Output: `{"clip_segments": {...}, "built_sync_markers": [...]}`.

---

## 7. `convert_edl_to_summary.py`

`USAGE: python3 convert_edl_to_summary.py <folder_path> [more_folders...]`
Reads EDL files in the given folders and converts each into `<base>_chapters.yaml`-shaped summary data (reconstructs a summary/`_chapters.yaml` from an archived EDL). Output JSON per folder.

---

## 8. Small parse/debug helpers

| Script | Usage | Output |
|---|---|---|
| `parse_srt.py` | `python3 parse_srt.py <file.srt>` | JSON `{cues:[{start_s,end_s,text,speaker}]}` via the shared robust parser |
| `parse_summary.py` | `python3 parse_summary.py <summary.yaml>` | JSON representation of `_chapters.yaml` |
| `convert_summaries.py` | `<transcripts_root>` | JSON aggregate of all summaries under a root |
| `search_index.py` | `<db_path> <query>` | FTS5 search against an existing DB file |
| `rebuild_index.py` | `<transcripts_root> <db_path>` | rebuilds the FTS index for a root |
| `resolve_workbench.py` | (various CLI flags) | diagnostic: reports platform, Resolve API paths, connection probe (socket to 127.0.0.1) |
| `test_build_timeline.py` | `<sync_results.json> [field_recorder]` | loopback test of timeline math from sync results |

---

## 9. Porting rule of thumb

Do **not** convert these scripts to another language. Keep them as subprocess JSON pipes on every platform. The scripts are already guarded: no GUI, no AppleScript, only stdlib + PyYAML + (for timeline scripts) the Resolve Python module that ships with Resolve itself. The only macOS-isms to neutralize are the `find_api()`/`find_lib()` path lists and any `/tmp` constant — both fixed in the porting guides and by honoring the `RESOLVE_SCRIPT_API`/`RESOLVE_SCRIPT_LIB`/`TMPDIR` env vars, so **no script behavior needs to change to port**.