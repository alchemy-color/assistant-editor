# macOS Reference — Build, Run, Deploy, Resolve Integration

This document covers everything **specific to the macOS reference app**: prerequisite toolchain, local dev build, headless build, deploy/packaging, permissions/entitlements the app relies on, and the two Resolve-integration paths macOS uses (external scripting API **and** the AppleScript in-console bridge). Porters should read `ARCHITECTURE.md` first; this is the macOS deep-dive that the porting guides reference for "macOS does it this way".

---

## 1. Toolchain and build

### Requirements
- macOS 14.0+ (deployment target `LSMinimumSystemVersion 14.0`)
- Xcode 15+ (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` works when multiple Xcodes exist)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen` (installed at `/opt/homebrew/bin/xcodegen`)
- Homebrew runtime tools: `ffmpeg`/`ffprobe` (in `/opt/homebrew/bin` or `/usr/local/bin` — the app **prepends both** to `PATH` for every subprocess)

The Xcode project is **generated, not committed**: `source/AssistantEditor` is the source dir, `Scripts/` the Python pipeline, `project.yml` the XcodeGen spec. Run `xcodegen generate` **from the project directory** (a bare run elsewhere fails with "No project spec found").

### One-time setup
```bash
cd "Assistant Editor-Xcode"
sh setup.sh          # installs xcodegen if missing, then xcodegen generate
```

### Dev build (inside Xcode)
- `open Assistant Editor.xcodeproj`
- Target "Assistant Editor" → Signing & Capabilities → set your Team
- Cmd+B — a **pre-build script** rsyncs `Scripts/` → `Resources/Scripts/` inside the built app (so the shipped app is self-contained)

### Headless build (used in CI / scripts)
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Assistant Editor-Xcode/Assistant Editor.xcodeproj" \
           -scheme "Assistant Editor" -destination 'platform=macOS' build
```
Produces `~/Library/Developer/Xcode/DerivedData/Assistant_Editor-*/Build/Products/Debug/Assistant Editor.app`.

### Deployment to the distribution folder (the project's convention)
```bash
pkill -f "Assistant Editor" 2>/dev/null || true
rm -rf "dist/Assistant Editor.app"
cp -R "<DerivedData>/Assistant Editor.app" "dist/Assistant Editor.app"
codesign --force --sign - "dist/Assistant Editor.app"   # ad-hoc -> runs locally
open "dist/Assistant Editor.app"
```
- Versioned snapshots live in `dist/v1/`, `dist/v1.1/`, …, `dist/v1.21/` — each holds the project source, the built `.app`, standalone Python scripts, and `docs/` (README, CHANGELOG, MANUAL). **Never overwrite a versioned folder**; only `dist/Assistant Editor.app` and `dist/MANUAL.md` are updated in place (current release: v1.23).

---

## 2. Runtime detection and paths (macOS-specific constants)

The macOS reference hardcodes a set of paths. These live in `PythonBridge.swift` and `ResolveConnector.swift`:

| What | Value |
|---|---|
| Python interpreter | `/usr/bin/env python3` (PATH prepended with `/Library/Frameworks/Python.framework/Versions/Current/bin` in some paths) |
| Script source (dev) | `<transcriptsRoot>/../software/Assistant Editor-Xcode/Scripts/<name>.py` |
| Script source (shipped app) | `Resources/Scripts/` inside the `.app` bundle |
| `PATH` for subprocesses | `/opt/homebrew/bin:/usr/local/bin:` + inherited |
| `ffprobe` probe command | `ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate:stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 <video>` |
| Default transcripts root | `PythonBridge.transcriptsRoot` (in the reference build: `~/Transcripts`; *scrubbed in this repo — the original pointed at a developer's local drive. Apps ask the user for folders instead*) |
| Caches | `~/Library/Caches/assistanteditor_<kind><tabtag>_<folderName>.db` + `assistanteditor_knowledge_<folderName>.json` |
| Scratch | platform temp dir (`tempfile.gettempdir()`): `assistanteditor_*.json`, `assistanteditor_timeline_log.json`, `assistanteditor_resolve_payload.json` / `_result.txt` |
| Process check | `/usr/bin/pgrep -x Resolve` |
| Prose pasteback (status) | `osascript`/AppleScript bridge (see §4) |

**Detection logic that must NOT change on a port:** `detectFrameRate` (ffprobe first, then timecode heuristic `\d{2}:\d{2}:\d{2}:(\d{2})` → nearest known rate 23.976/24/25/29.97/30/50/59.94/60) and the `merged exact+semantic` search merge.

---

## 3. App identity & UI conventions (macOS)

- Bundle ID `com.assistanteditor.transcripts`, display name **Assistant Editor**, ad-hoc codesign, LSUIElement false (regular app with Dock icon).
- App icon: programmatic Didot-serif "Æ" monogram — graphite squircle + amber rule, generated at 1024px into `AppIcon.appiconset` (`make_icon.swift` pattern, not in this repo).
- **Text scaling** (macOS has no OS-level Dynamic Type for desktop): custom `appTextScale` @AppStorage key (0.75–1.75) applied via `.scaledFont(...)` View modifiers; **⌘+ / ⌘− / ⌘0** step/reset it (hardcoded in `.commands`).
- **Menu keyboard shortcuts** (`.commands`): ⌘, → Priming window; ⌘? → Help; **⌘1…⌘4** → tabs (dynamic, following the persisted tab order).
- Tabs: Project Setup / AI Edit / Timeline Assist / Transcript Intelligence (Sync by Transcript was parked in v1.23 — source remains in `SyncByTranscriptTab.swift` for later restore). Tab order persisted in `tabOrder`; reorder via **right-click context menu** (SwiftUI `.onDrag/.onDrop` is unreliable on macOS — context menu is the only working approach).
- Bottom bar: status dot, model picker (oMLX `:8000`), LLM "N tok/s" meter, Load/Unload toggle, bordered buttons (Model Manager…, Preferences…, Methodology, Setup…), ProgressView during pipeline runs.
- Warning banners: orange "model not loaded", red "Ollama/unavailable", one-time launch alert (via `ollama list` auto-start check).

---

## 4. DaVinci Resolve integration (the macOS-specific part)

macOS has **two** ways to reach Resolve:

### 4a. External scripting API (primary)
- Probe: `"/usr/bin/python3" -c "import sys; sys.path.insert(0,'/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules'); import DaVinciResolveScript as d; print(d.scriptapp('Resolve') is not None)"`
- Requires Resolve running with a project open, external scripting **Local** enabled, and the script server healthy. When the server is down the app disambiguates via `/usr/bin/pgrep -x Resolve` (`isScriptServerDown()`): Resolve running + probe False ⇒ tell the user to **fully quit Resolve (⌘Q) and relaunch**.
- Python scripts resolve the API/library with `find_api()`/`find_lib()`:
  - API: env `RESOLVE_SCRIPT_API`, else `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting[Modules]`.
  - Lib: env `RESOLVE_SCRIPT_LIB`, else `/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so`, else glob `DaVinci Resolve*/**/fusionscript.so`.

### 4b. In-console bridge fallback (macOS-only, System Events / AppleScript)
When external scripting fails, `ResolveConnector` installs a helper at
`/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp/AssistantEditor_ResolveBridge.py`
then triggers it by **GUI scripting**:
```
tell application "DaVinci Resolve" to activate
delay 0.5
tell application "System Events"
  tell process "Resolve"
    click menu item "AssistantEditor_ResolveBridge" of menu 1 of menu item "Comp"
         of menu 1 of menu "Scripts" of menu 1 of menu "Workspace" of menu bar 1
  end tell
end tell
```
- The bridge script reads the expected payload from the platform temp dir (`tempfile.gettempdir()`), runs the same COLOR_MAP + AddMarker/AppendToTimeline logic **in-process** (where the `resolve` global is healthy), and writes a result file to the same location. The app polls for 6s to verify.
- On first use macOS prompts for **Automation permission** (System Events / DaVinci Resolve) under System Settings → Privacy & Security → Automation; `NSAppleScript` requires it. The app shows a one-time wizard (bottom-bar "Setup…"/Resolve wizard) explaining: open Resolve → Workspace → Scripts → Comp → AssistantEditor_ResolveBridge.

### Color bug workaround (both paths)
Resolve's `AddMarker` fails for Gold/Peach/Chocolate/Lime. `COLOR_MAP` remaps: Tan→Yellow, Orange→Rose, Cyan→Sky, Peach→Rose, Gold→Yellow, Chocolate→Cream, Lime→Mint. Markers are added **grouped by color** (AddMarker glitches on color changes between successive calls).

---

## 5. macOS backends / frameworks a porting dev must know

| macOS facility | Where used | What a port needs |
|---|---|---|
| `NLEmbedding.sentenceEmbedding(for: .english)` | `EmbeddingService.swift`, `SubtitleStore.swift`, `KnowledgeStore.swift` | pure-macOS. Replace (see porting guides: fastembed/ONNX or an embedding route). Not thread-safe → serialized private queue |
| `NSOpenPanel`/`NSSavePanel` | all tabs (folder/file pickers), EDL/SRTX/YouTube export | replace with platform dialogs |
| `FileManager.urls(for: .cachesDirectory, in: .userDomainMask)` | `Database.swift:140`, `KnowledgeStore.swift:314`, `TranscriptIntelligenceTab.swift:393` | → `$XDG_CACHE_HOME`/`%LOCALAPPDATA%` |
| `Foundation.Process` + `Pipe` | `PythonBridge`, `ResolveConnector` (probe/pgrep) | → `std::process`/`System.Diagnostics.Process` |
| `UserDefaults` (`@AppStorage`) | everywhere | → config file (see `STORAGE.md`) |
| `NSAppleScript` + System Events | `ResolveConnector.triggerViaMenu()` | macOS-only; external API is the portable equivalent |
| `/usr/bin/env`, `/usr/bin/python3`, `/usr/bin/pgrep`, `/usr/bin/open` | subprocess launchers | macOS-resolved; ports must search for the tools |
| `NSWorkspace.shared` / `open` | reveal-in-Finder, open URLs (Model Manager download, Resolve docs) | replace with platform equivalents |

---

## 6. Key macOS runtime behaviors to preserve

1. **Ask-user-first folder model** — no store loads at app launch. Each tab restores its last-picked folders from `@AppStorage` but loads data only on folder pick (or the one-time AI Edit auto-restore, fingerprint-guarded).
2. **Per-tab store isolation** — Domains never share `SubtitleStore`/`DocumentStore` instances; cache filenames are tab-namespaced (`tl`/`ti`/`ai`/`app`) so SQLite connections never contend cross-tab.
3. **ESC cancel** — local `NSEvent` monitor cancels chat (AssistantStore) and Python pipelines (`PythonBridge.cancelRunning()`).
4. **Local-only AI** — every LLM call goes to the local oMLX/Ollama server; nothing leaves the machine.
5. **Think stripping** — reasoning models produce `thinking` blocks; all responses run through `stripThinkBlocks` before JSON parsing.