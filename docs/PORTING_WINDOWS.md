# Porting Assistant Editor to Windows

Reference: macOS SwiftUI app (v1.23). This is the complete Windows porting plan. Recommended stack: **Rust + Tauri** (same as the Linux guide, so both platforms can share one Rust core), or **C# + WPF/WinUI** if you prefer the Windows-native route. The Python pipeline is reused unchanged on both. Note: the macOS app no longer ships the Sync-by-Transcript tab (parked in v1.23); its source and scripts remain for later restoration.

---

## 0. What survives, what must change

**Reused unchanged:**
- All 17 Python scripts (with two Resolve-path patches, §7).
- All file formats (SRT, SRTX, TXT, `_chapters.yaml`, `_synopsis.txt`, `_project.yaml`, `_priming_preset.yaml`).
- SQLite FTS5 DB file format.
- The LLM server contract (oMLX-compatible OpenAI `/v1`; on Windows use Ollama or llama.cpp server).
- Resolve's Python scripting API (Windows ships the same module — path differs).

**Replaced/reimplemented on Windows:**

| macOS counterpart | Windows replacement |
|---|---|
| SwiftUI UI | Tauri (web) + `tauri-plugin-dialog`, or WinUI 3 / WPF |
| Swift store logic | Rust (shared with Linux port) or C# |
| `NLEmbedding` semantic embeddings | `fastembed`+ONNX, or an embedding endpoint (see Linux guide §5 — identical) |
| `Foundation.Process` | `std::process` (Rust) / `System.Diagnostics.Process` (C#) |
| `NSOpenPanel`/`NSSavePanel` | `rfd` (Rust) / `Microsoft.Win32.OpenFileDialog` (C#) |
| AppleScript/System-Events Resolve bridge | not applicable — external scripting API only (§7) |
| `~/Library/Caches` | `%LOCALAPPDATA%\AssistantEditor\cache` (or `$XDG_CACHE_HOME`-style path) |
| `/tmp` scratch | platform temp dir — all scripts now use `tempfile.gettempdir()` (`%TEMP%` on Windows) instead of hardcoded `/tmp` (v1.21 porting fix) |
| UserDefaults | `%APPDATA%\AssistantEditor\config.json` (§4) |
| `/usr/bin/python3`, Homebrew paths | Python launcher (`py -3`), discovered at install/setup (§3) |

---

## 1. Runtime prerequisites (Windows)

| Requirement | Purpose | Install |
|---|---|---|
| Python 3.10+ on PATH (`py -3`) | pipeline | [python.org](https://python.org) installer (check "Add to PATH") |
| PyYAML | YAML parse/write | `pip install pyyaml` |
| SQLite with FTS5 | search DBs | Python bundles `sqlite3`; **verify FTS5**: `python -c "import sqlite3; print(sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE t USING fts5(x)'))"` — the official python.org builds include FTS5 |
| ffmpeg + ffprobe | probe + gap clips | [gyan.dev build](https://www.gyan.dev/ffmpeg/builds/) or `winget install ffmpeg` |
| LLM server | AI steps | Ollama (Windows native) or llama.cpp server |
| DaVinci Resolve | timeline/markers | Blackmagic (Studio or Free) |
| Embedding provider | semantics | `fastembed` + `onnxruntime` |

---

## 2. Recommended stack: Rust + Tauri

Follow the **Linux guide §2 (Strategy A) skeleton** — the Rust core (`python_bridge.rs`, `search.rs`, `embeddings.rs`, `resolve.rs`, `persist.rs`, the store modules) is 100% portable to Windows with no logic changes. Only the following differ:

- **Paths**: `persist.rs` picks `%APPDATA%` vs `$XDG_CONFIG_HOME`; caches `%LOCALAPPDATA%` vs `$XDG_CACHE_HOME`.
- **Python invocation**: `py -3 script.py` with a fallback to `python`. Detect Python once at setup and store its path in config (see §3).
- **Process spawning**: same Rust API on both platforms (`std::process::Command`), just different `.env()` values.
- **Webview shell**: Tauri uses the WebView2 runtime on Windows (edge-based). Packaging: use NSIS or WiX MSI installer bundling WebView2 bootstrapper.
- **File dialogs**: Tauri's dialog plugin covers both platforms.

**Alternative: C# + WinUI 3.** Port mapping mirrored from the Linux table; C# equivalents:
- sqlite: `Microsoft.Data.Sqlite`
- subprocess: `System.Diagnostics.Process` with `RedirectStandardInput/Output/Error` + async reads (parallel, or you deadlock on a full pipe)
- dialogs: `Microsoft.Win32.OpenFolderDialog`, `SaveFileDialog`
- config: `System.Text.Json` file in `%APPDATA%`
- embeddings: `fastembed` is Python-based — call a small Python helper once per file, or use `ONNX Runtime for .NET` + a MiniLM ONNX file

---

## 3. Python discovery on Windows

The macOS reference hardcodes `/usr/bin/python3`. On Windows:
1. Prefer `py -3` (Python launcher, always available from python.org installs).
2. Fallback to `python` on PATH (search `%PATH%` for `python.exe`).
3. Store the resolved interpreter path in config after first successful probe; allow user override in Settings.
4. **Environment for scripts**: pass `OMLX_BASE_URL`, `OMLX_API_KEY`, `AE_FPS` explicitly via `.env()` (Windows does not inherit a shell profile).

---

## 4. Persistence (replace UserDefaults)

| macOS (`@AppStorage`) | Windows |
|---|---|
| `UserDefaults.standard` | `%APPDATA%\AssistantEditor\config.json` (mirror every key in `STORAGE.md`) |
| Caches of SQLite/JSON DBs | `%LOCALAPPDATA%\AssistantEditor\cache\` — filenames `assistanteditor_<tabtag>_<folder>.db` / `assistanteditor_knowledge_<folder>.json` kept identical |
| `scratch` JSON/EDL/log files | `%TEMP%` via `tempfile.gettempdir()` — `assistanteditor_*` names kept identical |
| API key / model / base URL | config.json (plaintext is acceptable for a local tool; optionally DPAPI-protect the API key) |

Pattern note: read the analogous "Persistence" guides in `STORAGE.md` and the Linux guide §4.

---

## 5. Search DB on Windows

Use system/runtime `sqlite3` with FTS5 (see §1 verification) and **replicate `Database.swift` exactly**:
- same table/schema names (`subtitle_entries`/`subtitle_fts`, `transcript_entries`/`transcript_fts`),
- embedding BLOB column,
- the FTS5 exact-query builder (`ftsQueryString`: per-term quoted `"term"*`, doubled quotes) — keep byte-identical behavior,
- per-tab, per-folder DB filenames to preserve the isolation model,
- stale `-wal`/`-shm` cleanup before open (Windows file locking is stricter than macOS; always `Close()`/dispose the connection before deleting the `-wal`/`-shm` siblings — see Known Issues pattern in AGENTS.md).

---

## 6. LLM server on Windows

Use **Ollama for Windows** (native) — exposed OpenAI-compatible at `http://127.0.0.1:11434` — or llama.cpp/vLLM via an OpenAI-compat shim. The Python scripts follow `OMLX_BASE_URL`/`OLLAMA_BASE` env (see `LLM_BACKEND.md`), so any server URL works. Default model in config should be set to a Windows-side default (e.g. `llama3.1:8b`); reasoning models are slower and trigger the `stripThinkBlocks` path.

---

## 7. DaVinci Resolve on Windows

Patch the Resolve module/lib resolution — this is the ONLY Python-side change required:

- API modules (on Windows): `%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules`
- Fusion lib: the `DaVinciResolveScript` module finds `fusionscript.dll` by itself via the Windows registry when installed normally; the scripts' `find_api()`/`find_lib()` should first try `import DaVinciResolveScript`, then `RESOLVE_SCRIPT_API`/`RESOLVE_SCRIPT_LIB` env overrides, then the `%PROGRAMDATA%` path.
- Enable external scripting: Preferences → System → General → **External scripting (Local)**.

The **external-scripting path is primary on Windows** — the macOS AppleScript menu fallback does not exist here. If the server returns `None`, prompt the user to start Resolve + enable external scripting. (The macOS probe/pgrep/bridge pattern being replaced is documented in `MACOS_REFERENCE.md` §4.)

---

## 8. Two notes specific to Windows

- **Path separators / case**: file formats and script args use forward-slash-safe `os.path.join`; ensure the UI layer never hardcodes `\` into JSON payloads — pass raw paths and let Python normalize.
- **Antivirus / UAC**: Tauri/app dirs inside `%LOCALAPPDATA%` are standard and low-risk; do not write the SQLite DBs into `Program Files`. Resolve automation via its public scripting API is script/server-based (no SendKeys/UI automation), so no admin elevation or macro permissions are needed.

---

## 9. Verification checklist (Windows)

- [ ] `analyze_project.py` on a test folder produces `<folder>_project.yaml` (JSON match vs macOS modulo LLM nondeterminism).
- [ ] `process_srt.py` produces `_chapters.yaml` + `_synopsis.txt`.
- [ ] FTS5 search on a copied `.db` returns the same hit sets as macOS.
- [ ] Frame-rate detection works (ffprobe + timecode fallback).
- [ ] Timeline creation + marker write against Windows Resolve.
- [ ] Chat RAG grounded (timecodes), ESC cancels.
- [ ] Clean-clone build with `winget`-installed deps (no Homebrew, no `/usr/bin/python3`, no `/tmp` assumptions).