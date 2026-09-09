# Dependencies

What the app needs at runtime, per environment, and what each one is for. Keep this in sync with the porting guides.

---

## 1. Required everywhere

| Dependency | Version | Purpose | Notes for ports |
|---|---|---|---|
| **Python 3** | 3.10+ | entire pipeline (17 scripts) | macOS hardcodes `/usr/bin/python3`; Windows: `py -3` or `python` on PATH; Linux: system `python3` |
| **PyYAML** | latest | parse/write `_chapters.yaml`, `_synopsis.txt`, `_project.yaml`, presets | only third-party Python dep; `import yaml` |
| **SQLite with FTS5** | 3.35+ | subtitle/transcript search DBs | macOS links system `libsqlite3.tbd`; Python's `sqlite3` must have FTS5 compiled in; Linux: system sqlite3; Windows: official python.org builds include it |
| **Local LLM server** | — | all AI: analysis, chapters, synopsis, script parsing, clip selection, flow review, chat, prompt sort, YouTube summary | OpenAI-compatible `/v1` required; see `LLM_BACKEND.md` |
| **ffmpeg + ffprobe** | any recent | frame-rate detection, black gap-clip synthesis for timeline gaps | must be on PATH (macOS prepends `/opt/homebrew/bin`); Windows gyan.dev build or winget; Linux apt |

### LLM server options
- **oMLX** — default on macOS (Apple-silicon), OpenAI-compatible, `http://localhost:8000`.
- **Ollama** — macOS/Linux/Windows native, `http://localhost:11434`, also exposes OpenAI-compatible API. The app's bottom-bar model picker talks to Ollama (`ollama list`) when present.
- **Any OpenAI-compatible server** — vLLM, llama.cpp server, LM Studio, etc. — works as long as it speaks `/v1/chat/completions`.

---

## 2. DaVinci Resolve (optional — timeline/marker features)

Not needed for analysis/search/chat. Required for: Timeline Assist timeline creation, AI Edit timeline creation, Sync assembly, Write-to-Resolve marker ops.

- **windowCompatible**: macOS, Windows, Linux.
- The **Resolve scripting API** ships inside the Resolve install (a `DaVinciResolveScript` Python module + a library `fusionscript.so`/`.dll`). The scripts locate it:
  1. `import DaVinciResolveScript` attempt first (when Resolve added it to `sys.path` / via env).
  2. `RESOLVE_SCRIPT_API` / `RESOLVE_SCRIPT_LIB` env overrides (guaranteed route for ports).
  3. Compiled-in search lists, which are **macOS-specific today**:
     - `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting[Modules]`
     - `/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so`
     - glob of `DaVinci Resolve*/**/fusionscript.so` under `/Applications`
  4. Linux: `/opt/resolve/Developer/Scripting/Modules`, `/opt/resolve/libs/Fusion/fusionscript.so`. Windows: `%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules`.
- External scripting must be **enabled** in Resolve: Preferences → System → General → External scripting (Local).
- **Known Resolve API quirks** (dodge or you lose markers):
  - `AddMarker` color bug: Gold, Peach, Chocolate, Lime always fail. Script remaps Teal→Sky, Tan→Yellow, Orange→Rose, Gold→Yellow, Peach→Rose, Chocolate→Cream, Lime→Mint.
  - `AppendToTimeline` requires a **list of dicts**, never a single dict (hangs the API).
  - Group-gap picture relies on `recordFrame` positioning (no ffmpeg black clip in the current Resolve path); if Resolve ignores `recordFrame` the script detects it and falls back back-to-back.

---

## 3. Platform build toolchains

### macOS (reference)
- Xcode 15+, XcodeGen (`/opt/homebrew/bin/xcodegen`), Swift 5.9, deployment target macOS 14.0.
- Frameworks: SwiftUI, AppKit, Combine, NaturalLanguage (embeddings), UniformTypeIdentifiers; lib `sqlite3.tbd`.
- Build: `xcodegen generate` from the project dir, then `xcodebuild -scheme "Assistant Editor" build`. A preBuild script rsyncs `Scripts/` into `Resources/Scripts/`.

### Linux port
- Rust 1.75+ (if Tauri/egui) + WebKitGTK (Tauri deps) — see `PORTING_LINUX.md`.
- Or Python + PySide6 (all-Python port).
- Cargo deps: `rusqlite` (system sqlite, FTS5), `serde`/`serde_json`, `tokio` (for async subprocess), `tauri` (or `egui`), `rfd` (dialogs), `fastembed` via its Python helper.

### Windows port
- Rust + Tauri + WebView2 runtime, or C# .NET 8 + WinUI 3.
- Python launcher (`py`) for script execution; `winget install ffmpeg`; Ollama Windows.
- `%LOCALAPPDATA%` for caches; `%APPDATA%` for config.

---

## 4. Environment variables the app/scripts use

| Var | Consumers | Meaning |
|---|---|---|
| `OMLX_BASE_URL` | process_srt, analyze_project (Python); ports should mirror | LLM base URL (default `http://localhost:8000`) |
| `OMLX_API_KEY` | same | optional LLM API key |
| `OLLAMA_BASE` | process_srt (secondary) | alternate LLM base URL |
| `AE_FPS` | sync_transcripts / export_sync_edl / build_sync_timeline | timeline frame rate (default 25) |
| `RESOLVE_SCRIPT_API` | create_timeline / write_resolve / build_sync_timeline | Resolve scripting modules dir |
| `RESOLVE_SCRIPT_LIB` | same | Resolve fusion lib path |
| `DEVELOPER_DIR` | macOS build | Xcode location (used in the build script) |

---

## 5. Optional / quality-of-life

| Tool | Purpose |
|---|---|
| **ollama CLI** | used by Model Manager (`ollama list`, `ollama pull`, `ollama rm`) and by the app to auto-start the server |
| **detectFrameRate** | tries ffprobe first, timecode heuristic fallback; needs no extra deps |
| **DocumentStore** | pure filesystem; no DB |