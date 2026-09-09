# Storage & Persistence

How the app persists state, and where. A port must mirror these locations and key names so users can migrate (or so a future release can offer migration).

---

## 1. UserDefaults keys (`@AppStorage`)

The macOS reference persists every setting in `UserDefaults.standard`. A port should mirror these into a JSON config file (`%APPDATA%/AssistantEditor/config.json` on Windows, `$XDG_CONFIG_HOME/assistant-editor/config.json` on Linux). The key list is the contract:

### Tabs / layout
| Key | Meaning |
|---|---|
| `selectedTab` | active tab index |
| `tabOrder` | JSON array of tab ids (Project Setup, AI Edit, Timeline Assist, Transcript Intelligence, Sync) |
| `tabOrderInitialized` | whether tab order was ever persisted |
| `tlPanelLeftWidth`, `syncLeftWidth`, `primingSidebarWidth` | split widths |
| `smStatsRowHeight`, `smStatsRightWidth` (**legacy**) | removed split widths |
| `speakerListHeight`, `speakerListCollapsed` | speaker list geometry |
| `srtListHeight` (**legacy**) | removed |

### App-wide
| Key | Meaning |
|---|---|
| `appTextScale` | Double text scale (0.75–1.75, default 1.0) |
| `ollamaSetupDismissed` | whether the one-time setup alert was dismissed |
| `selectedModel` | current LLM model id |
| `omlxBaseURL` | LLM base URL (default http://localhost:8000) |
| `omlxAPIKey` | optional LLM API key |
| `ytTextSize` → `youtubeTextSize` | YouTube markers sheet text size (9–24 pt) |

### Folder lists (per tab, independent — do not couple across tabs)
| Key | Meaning |
|---|---|
| `sourceMaterialFolders` | Project Setup folder list (JSON array) |
| `timelineAssistFolders` | Timeline Assist work folders |
| `transcriptIntelligenceFolders` | Transcript Intelligence folders |
| `aiEditFolders` | AI Edit folders |
| `lastSourceFolder`, `lastSrtFolder`, `lastTranscriptFolder`, `lastYamlFolder`, `lastSyncFolder`, `lastSyncTimelineFolder`, `lastAnalysisYamlFolder` | last-picked per-tab locations |
| `primingPresetFolder` | preset-source override folder |

### Timeline Assist
| Key | Meaning |
|---|---|
| `timelineSearchSource` | subtitles vs transcripts search source |
| `timelineAddSubtitles` | write `.srtx` subtitles with timeline |
| `timelineFPS` | timeline frame rate (23.976/24/25/29.97/30/50/59.94/60) |
| `subGroupGap`, `subContextSlots` | gap & context settings |
| `tlRefineCollapsed` | refined-search panel state |

### AI Edit
| Key | Meaning |
|---|---|
| `aiEditSessionJSON` | full session (beats, clips, toggles, flow notes) — Combine-debounced autosave |
| `aiEditScript` | current script text |
| `aiEditCandidateCap` | candidate pool cap (8–48, default 24) |
| `aiEditMaxClips` | LLM max clip picks (1–8, default 5) |
| `aiEditUseSynopsis` | include per-interview synopsis excerpts in selection prompt |
| `aiEditMarkerMode` | beat-structure vs clip-description markers |
| `aiEditNameTimestamp` | append `_HHMMSS` to created timeline name |
| `aiEditSplitRatio`, `aiEditRetrievalExpanded`, `aiEditAddSubtitles`, `aiEditContextSlots`, `aiEditGapSeconds` | misc |

### Project Setup
| Key | Meaning |
|---|---|
| `projectThemesJSON` | shared themes (`[ {name, keywords, weight, color} ]`) — consumed by all tabs; `process_srt.py` via `--themes-file` |

### Transcript Intelligence
| Key | Meaning |
|---|---|
| `summaryCacheJSON` | per-doc cached YouTube summaries by length (SummaryCache) |
| `summaryLength` | Short/Medium/Long |

### Priming
| Key | Meaning |
|---|---|
| `activePrimingPreset` | active preset name |
| `priming_*` (9 keys) | the raw prompt texts: `priming_projectAnalysis`, `priming_chaptersSynopsis`, `priming_searchInterpretation`, `priming_transcriptChat`, `priming_promptSort`, `priming_scriptParsing`, `priming_clipSelection`, `priming_flowReview`, `priming_youtubeSummary` |

---

## 2. Cache files (Caches dir)

- macOS: `~/Library/Caches/`. Linux: `$XDG_CACHE_HOME` (default `~/.cache`). Windows: `%LOCALAPPDATA%`.
- Naming: `assistanteditor_<kind><namespacetag>_<folderName>.db` where tag ∈ {`tl`, `ti`, `ai`, `app`} — the per-tab namespace (stops cross-tab SQLite contention). Kind ∈ {subtitle, transcript}.
- Knowledge base: `assistanteditor_knowledge_<folderName>.json`.
- Sidecar: `.project_original.json` next to `_project.yaml` (pristine post-analyze weights).
- The SQLite file holds `subtitle_entries`/`subtitle_fts`, `transcript_entries`/`transcript_fts`, an embeddings BLOB column, and a metadata table (fingerprint + entry count). Stale `-wal`/`-shm` are cleared before open.

---

## 3. `/tmp` scratch

- `assistanteditor_<name>.json` / `.log` — Resolve bridge payloads, priming/progress files, timeline debug log (`$(tempfile.gettempdir())/assistanteditor_timeline_log.json` (platform temp dir)).
- Ports: keep `/tmp` on Linux; use `%TEMP%` on Windows (set `TMPDIR`/`TEMP` for the scripts or patch the few `/tmp` constants).

---

## 4. Per-folder project files (the user's data)

These live **next to the user's footage/transcripts**, not in app caches:
- `<folderName>_project.yaml` — project analysis (or acknowledged rename / legacy `_project.yaml`).
- `_chapters.yaml`, `_synopsis.txt` — per-interview outputs.
- `_transcript.txt` / `_transcripts.txt` — paired transcripts.
- `<folderName>_priming_preset.yaml` (or legacy `_priming_presets.yaml`).

Details and formats: `FILE_FORMATS.md`.

---

## 5. Persistence rules a port must keep

1. **Never auto-load stores on launch; load on folder pick.** Tab folders restore from the last-picked keys, but data is rebuilt only when the user picks a folder.
2. **Per-tab store isolation** — one folder selection never clobbers another tab's loaded data.
3. **Cache fingerprint gate** — a rebuild only happens when the folder's file set changed (`folderFingerprint` → metadata table); stale fingerprinted caches must not brick the store (stale → shared remove+open+retry path).
4. **Atomic writes everywhere** for `*.yaml` / `*.txt` outputs and preset files (temp file + `os.replace` + `os.fsync`).
5. **Session autosave** (AI Edit) via debounced write on every store change.