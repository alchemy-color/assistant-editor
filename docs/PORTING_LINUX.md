# Porting Assistant Editor to Linux

The reference app is macOS SwiftUI. This guide gives a complete, opinionated port plan for **Linux**, mapping every file, every macOS-only dependency, and every runtime requirement to a Linux equivalent. Two strategies are presented; **Strategy A (recommended)** keeps the Python pipeline untouched and reimplements the UI/glue; **Strategy B** is a heavier rewrite.

---

## 0. Decision: what must stay, what must go

**Stays unchanged (platform-neutral, highest value):**
- All 17 Python scripts in `source/Python/` (with two small changes noted below).
- All file formats: SRT, SRTX, TXT, `_chapters.yaml`, `_synopsis.txt`, `_project.yaml`, `_priming_preset.yaml`.
- The SQLite FTS5 database file format (a plain SQLite file — Linux `sqlite3` reads/writes it identically).
- The LLM server contract (oMLX/Ollama, OpenAI `/v1`).
- The Resolve scripting API contract (Resolve's Python API is identical on Linux — only the module **path** differs).

**Must be reimplemented/replaced on Linux:**

| macOS counterpart | Files in `source/Swift/` | Linux replacement |
|---|---|---|
| SwiftUI UI layer | all `*Tab.swift`, `ContentView`, `AssistantEditorApp` | Tauri (Rust+web) or GTK/Qt (see §2) |
| App logic / models | `AIEditStore`, `SubtitleStore`, `AssistantStore`, `KnowledgeStore`, `DocumentStore`, `ProjectAnalysis`, `Models`, `MaterialTree` | Reimplement in the port language (the logic is straightforward CRUD + calls to Python) |
| `NLEmbedding` embeddings | `EmbeddingService.swift`, `SubtitleStore.swift` (embed path), `KnowledgeStore.swift` | `fastembed` + `onnxruntime`, or an embedding HTTP route on the LLM server (see §5) |
| `Foundation.Process` | `PythonBridge.swift`, `ResolveConnector.swift`, `ProcessTimelineTab.swift` (ffprobe) | stdlib `subprocess`/`child_process` (Rust: `std::process`) |
| `NSOpenPanel`/`NSSavePanel` | many files | GTK/Qt/`rfd` dialogs (Tauri has built-in dialogs) |
| `NSAppleScript` GUI automation | `ResolveConnector.swift` | Not needed on Linux — see §7 |
| Caches dir | `Database.swift`, `KnowledgeStore.swift` | `$XDG_CACHE_HOME` (default `~/.cache`) |
| `/tmp` scratch files | `ProcessTimelineTab`, `ResolveConnector`, python | same `/tmp` works on Linux |
| UserDefaults | many | Config file (JSON/TOML) or platform keyring (§4) |

**Recommended port language:** **Rust + Tauri** (web UI) or **Rust + egui** (native). Rationale:
- Rust has a first-class `sqlite3` binding, simple subprocess, strong typing to port the Swift store logic 1:1.
- The UI is forms/tables/list-heavy, so even a web-tech shell (Tauri) is low-friction.
- A pure Python GUI (PySide6) is also viable and would let you keep stores as Python classes — but you lose the Swift reference's structure.

---

## 1. Runtime prerequisites (Linux)

| Requirement | Purpose | Install (Debian/Ubuntu example; adjust per distro) |
|---|---|---|
| Python 3.10+ | runs the pipeline | `apt install python3` |
| PyYAML | parse/write `_chapters.yaml` etc. | `pip install pyyaml` or `apt install python3-yaml` |
| SQLite 3.35+ (with FTS5) | search DBs | bundled with Python `sqlite3` on most distros (check FTS5 is compiled in) |
| ffmpeg + ffprobe | frame-rate detection, gap video | `apt install ffmpeg` |
| An LLM server | all AI steps | [oMLX](https://github.com/jundot/omlx) or [Ollama](https://ollama.com) — Linux supported natively by both |
| DaVinci Resolve for Linux | timeline/marker ops | [Blackmagic Design download](https://www.blackmagicdesign.com/products/davinciresolve) |
| An embedding provider | semantics (see §5) | `fastembed` + `onnxruntime` or an embedding route |

---

## 2. Strategy A — RUST + TAURI (recommended, plan reusing Python unchanged)

### 2.1 Repo/project skeleton
```
assistant-editor-linux/
├── src-tauri/                 # Rust shell
│   ├── src/
│   │   ├── main.rs
│   │   ├── stores/            # ports of Swift stores
│   │   │   ├── subtitle.rs    # SubtitleStore logic
│   │   │   ├── document.rs    # DocumentStore
│   │   │   ├── assistant.rs   # AssistantStore (LLM chat)
│   │   │   ├── knowledge.rs   # KnowledgeStore
│   │   │   └── project.rs     # ProjectAnalysis
│   │   ├── python_bridge.rs   # port of PythonBridge (subprocess + JSON)
│   │   ├── search.rs          # SQLite FTS5 wrapper
│   │   ├── embeddings.rs      # fastembed wrapper
│   │   ├── resolve.rs         # Resolve API path + subprocess wrapper
│   │   └── persist.rs         # config storage (UserDefaults equivalent)
│   ├── Cargo.toml
│   └── tauri.conf.json
├── ui/                        # web frontend (HTML/TS, Tauri)
│   ├── index.html
│   ├── src/ (React/Vue/Svelte) …
│   └── package.json
├── python/                    # copy of source/Python (frozen)
├── formats/                   # copy of file-format docs (reference)
└── README.md
```

### 2.2 `python_bridge.rs` — port of `PythonBridge.swift`
Match the Swift contract exactly so scripts behave identically:
```
result = run_script(name, args, stdin: Option<String>, timeout: Duration)
  ├── locate script: bundled resource (copy python/ next to the binary) 
  │                   or path from config
  ├── spawn: python3 script args
  ├── env: OMLX_BASE_URL, OMLX_API_KEY, AE_FPS inherited/from config
  ├── feed stdin, close
  ├── read stdout+stderr concurrently (don't deadlock on a full pipe)
  ├── if timeout → kill child, report "Timeout: ..."
  └── if exit != 0 → parse last stdout JSON {"error": ...}, else stderr tail
```
Progress variant: same, but scan stdout lines for `{"progress": "..."}` and emit to the UI.

### 2.3 SQLite FTS5 (`search.rs`)
The Swift code (`Database.swift`) is a thin safe wrapper around the SQLite C API + FTS5. In Rust use `rusqlite` with the `bundled` feature (ships its own SQLite **without** FTS5 unless you compile the feature), or link system `sqlite3` ensuring FTS5. **Prefer system SQLite + `rusqlite` without `bundled`** so FTS5 availability matches. Replicate:
- `subtitle_entries`/`subtitle_fts` and `transcript_entries`/`transcript_fts` schemas (see `STORAGE.md`).
- the exact-match query builder (`ftsQueryString`: per-term `"term"*` quoting, `"` doubled) — do not "improve" it or search behavior changes.
- embedding BLOB column + cosine re-rank step.

### 2.4 UI mapping (SwiftUI → Tauri web or egui)

| SwiftUI construct | Tauri/web | egui |
|---|---|---|
| `TabView`, right-click reorder | tab bar + context menu in JS | `TopBottomPanel`/manual |
| `NSOpenPanel`/`NSSavePanel` | `tauri-plugin-dialog` | `rfd` crate |
| `@AppStorage` | `localStorage` | config file |
| Sliders / toggles | HTML widgets bound to state | egui `Slider`/`Checkbox` |
| Sheets / alerts | web modals | egui `Window`/`Modal` |
| Text scale (⌘±) | CSS `font-size` scaling | render scale |
| Progress bar (bottom) | web component | egui progress |

Preserve the **5-tab layout, left/right split panels, resizable dividers, and the per-tab store isolation** rule.

### 2.5 The stores, one paragraph each (port from `source/Swift/`)
- **SubtitleStore**: parse SRT/SRTX/TXT (rule: 3-line transcript vs 4+ line subtitle blocks; blank-line-after-timecode tolerance — group by timecode line, flush previous cue on new index/timecode line), load into FTS5, search (exact ∪ semantic), speaker filter, frame-rate parsing, reload/clear semantics, paired `_transcript`/`_transcripts` detection.
- **DocumentStore**: filesystem scan for `_chapters.yaml` → typed docs (via `scan_summaries.py`).
- **AssistantStore**: chat messages; build RAG context (KnowledgeStore summaries + FTS5 hits) **on the main/UI thread**, move only the blocking LLM HTTP call off-thread.
- **KnowledgeStore**: build per-interview knowledge JSON: synopsis, topic breakdown (theme→markers), centroid key quotes from embeddings; cache in `$XDG_CACHE_HOME`; `{folder, stamp}` staleness check.
- **ProjectAnalysis**: YAML read/write of `<folderName>_project.yaml`; must mirror Swift's `yamlEscaped`/`unescapeYAML` and the canonical-name/legacy/rename-acknowledged file resolution.

---

## 3. Audio/video scanning specifics

- `PythonBridge.detectFrameRate` runs `ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate:stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 <video>` and parses `num/den`. Reuse the exact ffprobe invocation and the `nearestKnownRate` table (`23.976, 24, 25, 29.97, 30, 50, 59.94, 60`).
- Timecode fallback regex `\d{2}:\d{2}:\d{2}:(\d{2})` → max frame digit → heuristics (≥59→60, ≥49→50, ≥29→30, ≥24→25, ≥23→24, else 23.976). Keep identical.
- ffmpeg is used to synthesize black gap clips for grouped timeline clips and to probe sources. Gap generation lives inside `create_timeline.py` (`recordFrame`-based). Ensure `ffmpeg` on PATH.

---

## 4. Persistence (replace UserDefaults)

On Linux use:
- **Config**: a single JSON at `$XDG_CONFIG_HOME/assistant-editor/config.json` mirroring the UserDefaults keys in `STORAGE.md` (folder lists, selected model/base URL/API key, weights, session JSON, tab order, split ratios, etc.).
- **Caches**: `$XDG_CACHE_HOME/assistant-editor/` for `assistanteditor_<tab>_<folder>.db` and `assistanteditor_knowledge_<folder>.json`.
- **Scratch**: `/tmp` is fine (keep the same filenames if you want the debug logs to interoperate with the tests).
- Sensitive values (API key): store in the system keyring (libsecret) or in the config with chmod 600; **never commit**.

---

## 5. Replacing NLEmbedding (semantic search)

`NLEmbedding` is macOS-only. Choose one:
1. **`fastembed` (recommended)** — ONNX-backed, cross-platform Python. Pair with the status quo: keep embeddings inside the Python pipeline (compute once, store the vector BLOB in SQLite; the Rust side only does cosine).
   - Model suggestion matching NLEmbedding behavior: `sentence-transformers/all-MiniLM-L6-v2` (384-dim) or `BAAI/bge-small-en-v1.5` (384-dim). Dimensionality only matters for your own DB compat — the reference DBs are not shared with the port by design.
2. **An embedding endpoint on the LLM server** — oMLX may expose embeddings; if not, run a tiny separate embedding server. Simplest: `fastembed` invoked once per file by a small Python step and stored in the DB — the Rust side then stays dependency-free.

**Critical detail:** embeddings in the reference are stored as a **BLOB column** alongside each entry. Preserve that storage shape even if the model changes, so your search/write path mirrors `Database.swift`.

---

## 6. LLM server on Linux

oMLX is macOS-centric (MLX = Apple silicon). **On Linux use Ollama** (or llama.cpp server / vLLM / LM Studio) and keep the OpenAI `/v1/chat/completions` shape. Config points at e.g. `http://127.0.0.1:11434` (Ollama) — the app default `localhost:8000` is just a default; persist the base URL in config. The Python scripts already read `OMLX_BASE_URL`/`OLLAMA_BASE` so they'll follow any URL. See `LLM_BACKEND.md` for the model/prompt contract and the `response_format: json_schema` requirement for Parse Script / Find Clips / Review Flow.

Suggested default model for Linux: a strong instruct model available in Ollama (e.g. `llama3.1:8b` / `qwen2.5:7b`). **Reasoning-capable models** (Qwen3, etc.) are slower; the app already strips `thinking` blocks defensively (`stripThinkBlocks`).

---

## 7. DaVinci Resolve on Linux

- Resolve's Python API on Linux needs the same `DaVinciResolveScript` module. Paths (this is the part to change in the scripts):
  - API modules typically: `/opt/resolve/Developer/Scripting/Modules`
  - Fusion lib: `/opt/resolve/libs/Fusion/fusionscript.so`
  The scripts' `find_api()`/`find_lib()` currently search macOS paths + `RESOLVE_SCRIPT_API`/`RESOLVE_SCRIPT_LIB` env overrides. **Patch `find_api()`/`find_lib()` in `create_timeline.py`, `write_resolve.py`, `build_sync_timeline.py` to also search `/opt/resolve/...` (and honor `RESOLVE_INSTALL_DIR`/the env override).** Then the scripts run unchanged.
- External scripting must be enabled: Resolve → Preferences → System → General → **External scripting (Local)**.
- The macOS AppleScript **menu-automation fallback** has no Linux equivalent — the external script server is the primary path on Linux. If the server returns `None`, the error message already tells the user to restart Resolve. (The macOS behavior you are replacing — probes, `pgrep`, the in-console AppleScript bridge — is documented in `MACOS_REFERENCE.md` §4.)

> If you prefer not to patch the shipped scripts in-place, set `RESOLVE_SCRIPT_API`/`RESOLVE_SCRIPT_LIB` in the environment before spawning. The scripts already honor those env vars first (see `create_timeline.py:find_api/find_lib`).

---

## 8. Strategy B — heavier rewrite (full stack in one language)

If you want a single-language app (no Python subprocess), port the Python logic into the target language. This is substantially more work and risks subtle differences in:
- the SRTX/SRT/TXT parser quirks (blank-line tolerance, 3-vs-4-line layouts),
- the chapter/synopsis LLM prompts and output schemas,
- the sync frame math and EDL conversion.

Only pursue if the Python runtime is unacceptable operationally. The file-format docs and script interface docs give you the spec to re-test against.

---

## 9. Verification checklist (Linux)

- [ ] `analyze_project.py` on a test folder produces `<folder>_project.yaml` with themes + stats (compare JSON to macOS run).
- [ ] `process_srt.py --synopsis-only` and `--chapters-only` produce `_synopsis.txt` / `_chapters.yaml` byte-comparable (modulo LLM nondeterminism).
- [ ] FTS5 search returns the same hit sets as macOS for the same DB (port a DB to test).
- [ ] Frame-rate detection matches ffprobe output and timecode heuristics.
- [ ] Resolve timeline creation works against a Linux Resolve install with external scripting on.
- [ ] Chat/RAG answers are grounded (citations carry timecodes), ESC cancels.
- [ ] App builds headless and runs on a clean XDG environment (no Homebrew paths, no `/Applications`).

---

## 10. Open questions for the author before shipping a Linux port

1. Embedding model: confirm `fastembed`/ONNX is acceptable vs. expecting an embedding route on the LLM server.
2. Default LLM model naming/config on Linux (a non-oMLX default). 
3. Timeline gap video: confirm pure `recordFrame` positioning is acceptable on your Resolve version (see Known Issues) before you ship.