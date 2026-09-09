# Assistant Editor User Manual — v1.24

## Overview

Assistant Editor is an assistant editor for documentary film post-production. It ingests interview transcripts and subtitles (SRT/SRTX/TXT), analyzes projects to extract themes and keywords, generates structured chapter markers and synopses via local LLM (Ollama), creates timelines in DaVinci Resolve from subtitle search results, and provides a transcript intelligence chat system grounded in your interview data.

All AI processing runs **entirely on your machine** via Ollama — nothing leaves your computer.

---

## Getting Help

Press **⌘?** or choose **Help ▸ Assistant Editor Help** to open this manual inside a native macOS window — searchable table of contents on the left, formatted pages on the right. The content is this file (`MANUAL.md`), read live from the folder next to the app: edit it and the Help window reflects your edits on next open.

---

## Architecture

Assistant Editor is a macOS SwiftUI app with four tabs: **Project Setup** (project analysis and theme management), **AI Edit** (script → beats → clips → timeline), **Timeline Assist** (primary search workflow), and **Transcript Intelligence** (RAG chat). Tab order can be changed by right-clicking a tab label.

### Swift Stores (EnvironmentObject)

| Store | Role |
|-------|------|
| `SubtitleStore` | Parses SRT/SRTX/TXT files, maintains file-backed SQLite+FTS5 databases for subtitle + transcript search, manages AI embeddings (`NLEmbedding`) for semantic search, handles speaker filtering and sort options |
| `DocumentStore` | Scans filesystem via `PythonBridge.scanSummaries()` for `_chapters.yaml` files, loads them as `SummaryDocument` objects. No database used — pure filesystem reads |
| `AssistantStore` | Manages chat messages for the Transcript Intelligence tab. Calls Ollama `localhost:11434/api/generate` with RAG context from `KnowledgeStore` |
| `KnowledgeStore` | Pre-computed per-interview knowledge base: full synopsis text, topic breakdown (theme → markers), centroid-based key quotes from embeddings. File-backed JSON at `~/Library/Caches/assistanteditor_knowledge_{folderName}.json`. Built on demand when user picks a project folder. Uses dynamic themes from `@AppStorage("projectThemesJSON")` for topic color assignment |
| `ProjectAnalysis` | Codable model for `_project.yaml` — project themes, keywords, weights, stats, interview metadata. Persisted per root folder, shared across tabs via `@AppStorage("projectThemesJSON")` |

### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| `SearchDatabase` | `Database.swift` | File-backed SQLite+FTS5 for subtitles (`subtitle_entries` + `subtitle_fts`) and transcripts (`transcript_entries` + `transcript_fts`). Marker tables removed (now filesystem-driven) |
| `EmbeddingEngine` | `EmbeddingService.swift` | Sentence embedding via `NLEmbedding` (macOS 11+), serialized on a private queue for thread safety |
| `PythonBridge` | `PythonBridge.swift` | Runs Python scripts (`process_srt.py`, `scan_summaries.py`, `create_timeline.py`, `write_resolve.py`) with timeout. Provides `runRawProgress()` for streaming progress JSON output with `ProgressView` in the bottom bar |

### Python Scripts

| Script | Function |
|--------|----------|
| `process_srt.py` | LLM-based chapter/synopsis generation. Accepts `--chapters-verbosity`, `--synopsis-verbosity`, `--synopsis-{intro,paragraphs,bullets,timecode}` flags, `--transcript` for paired transcript, `--themes-file` for dynamic project themes (overrides hardcoded wine/viticulture keywords). Outputs JSON with `markers` and `synopsis` sections. Writes `_chapters.yaml` and `_synopsis.txt`. Timeout 600s, max_tokens 8192. Handles qwq:32b reasoning model output (strips `<think>` blocks, parses markdown headings). Synopsis timecodes are computed from keyword chapter boundaries — not LLM-generated (avoids hallucination). Per-bullet average timecodes are evenly distributed within each subject's chapter range |
| `analyze_project.py` | LLM-based project analysis. Scans folders for subtitle/transcript files, merges cues, extracts speakers/frequency words. Optionally uses LLM to extract project-specific themes (5–8 themes with keywords, weights, colors). Falls back to keyword-frequency theme detection when no model is loaded. Writes `_project.yaml` to root folder. Accepts folder list via stdin JSON |
| `scan_summaries.py` | Walks a directory tree recursively, finds all `_chapters.yaml` files, parses them, returns JSON array of `SummaryDocument` objects |
| `create_timeline.py` | Creates a DaVinci Resolve timeline from subtitle search results. Accepts a JSON request with markers array. Adds clip gaps via ffmpeg black ProRes video. Sets clip colors (Blue=match, Orange=context). Adds marker flags. When subtitles toggle is on, writes an SRTX captions file to the work folder and reveals it in Finder |
| `write_resolve.py` | Writes/restores markers in DaVinci Resolve via Fusion API |

---

## Getting Started

1. **Install Ollama** from [ollama.com/download](https://ollama.com/download)
2. **Pull a model**: `ollama pull sonct988/gemma4-26b-a4b-it-q4km-256k` (default) or any compatible model
3. Launch Assistant Editor — Ollama does not need to be running; the app auto-starts the server via the CLI on launch
4. The model dropdown in the bottom bar auto-detects installed models
5. Click **Load Model** (red button) to load the model into GPU memory
6. The **Project Setup** tab opens by default — add your interview root folder via the **＋** icon, then click **Analyze** in the Weighing header (or the empty state) to extract themes
7. Switch to **Timeline Assist** and add work folders the same way

### The Project Bar (every tab)

Every tab opens the same way: **project bar → divider → tab content.** There is no per-tab title row repeating the tab's name. The bar is three slim rows arranged as a grid of two columns separated by a thin fixed divider:

- **Row 1 — section labels**: `Source Folder(s)` (left) and `Materials` (right)
- **Row 2 — actions & status**: ＋ (add folders), ↻ (re-read), 🗑 (clear all, with confirmation) beside the tab's status caption inline on the left; on the right, the materials summary (`2 folders · 3 sub · 1 tr · 1 tl`)
- **Row 3 — content**: one horizontally scrolling row of folder chips on the left; a `subfolders ▾` toggle that opens the material tree on demand on the right

**Left — folder selection:**
- **＋ Add** — pick one or more folders in a single dialog (`⌘-click` for multiple). Folders appear as removable chips (× to remove); each tab keeps its own set across launches. The ＋ tooltip shows what material the tab expects
- **↻ Re-read** — forces a full reload: re-scans the folders from disk and rebuilds caches/analysis from scratch (normal launches serve valid caches instead)
- **🗑 Clear All** — removes all folders and clears that tab's loaded data, with a confirmation dialog on every tab
- Folder chips also carry their per-tab health: a green film dot when the folder has a valid project file, red when it's missing one (tooltip explains)
- Chips are middle-truncated (max ~240pt) when a folder name is long

**Right — material identification** (visible once folders exist): compact totals of what's present — **S sub · T tr · N tl** (subtitle files, transcripts, saved edits), a **green/red film dot** per folder (project file detected / missing), and **badges** (sub/tr/ch/syn/tl) per node. Health dots and badges stay visible even when collapsed; the **subfolders** toggle opens the recursive subfolder tree (≤150pt) showing every nested folder that carries subtitle/transcript/chapter/synopsis/timeline files. Default collapsed, so the bar stays ~71pt tall no matter how much material is loaded.

- **Startup is automatic** — every tab scans its stored folders on launch and populates itself; you never need to press anything to re-read previously created materials
- Project Setup additionally restores its analysis even when `_project.yaml` lives in a parent of your stored folder, or in a location you removed earlier

### Prerequisite: Resolve Workflow

Before using Assistant Editor, prepare interviews in DaVinci Resolve:

1. **Sync** audio and video for each interview
2. **Transcribe** the entire timeline (Resolve's built-in speech-to-text)
3. **Assign speakers** to each voice in the transcript
4. **Export transcript** (`_transcript.txt` or `_transcripts.txt`) — paragraph-level with timecodes
5. **Export subtitles** (`_subtitles.srtx` or `.srt`) — granular 2–10s cues

Assistant Editor uses **subtitles** for timeline creation (precise clip selection) and **transcripts** for chapter/synopsis generation (richer paragraph context) and the **2-pass search strategy** (transcripts FTS5 first for multi-word phrases, then subtitle timecode overlap). When both exist in the same folder with the same base name, processing deduplication skips the subtitle file and uses only the transcript for LLM calls.

---

## Project Setup Tab

The project analysis and theme management tab. Opens by default on launch. **Single column** — everything stacks vertically.

### Layout (top to bottom)

1. Project bar (shared design — see Getting Started)
2. **Weighing section** — title row carrying the **Analyze / Regenerate Themes** button (spinner while running, thin progress strip + status message just underneath), totals caption, speaker line, and one slider row per theme

### Weighing Section

**Title row** — `Weighing` · **Analyze / Regenerate Themes** (runs `analyze_project.py` with the folder list on stdin; writes `_project.yaml` to the analysis root) · totals caption (`5 interviews · 3h 24m · 1,204 cues · 6 speakers · 5/5 transcripts`) · **Reset Weighing**

**Empty state** (folders chosen but no analysis yet) — illustration, explanation, and a dedicated **Analyze** button under the Weighing header.

**Speaker line** — one scrollable row of mini bars: `Name ▮▮▮▮ 412` per speaker, bar length ∝ cue share, `+N` overflow after eight.

**Theme rows** — each theme appears exactly once, as a slider row:

- **Color dot · name · proportional color bar · %** — the bar visualizes the weight inline
- **Weight slider** — all sliders always sum to 100%; moving one redistributes the rest proportionally from the values captured when that drag began
- **Balance memory** — if you push a slider to an extreme and other themes get crushed toward 0%, returning *that* slider to its starting position restores every theme's exact pre-drag weight. The baseline survives drag-end and re-grabs, and even app restarts (see below)
- **Keywords** — comma-separated identifiers used by chapter generation and retrieval
- **Context menu** — right-click to remove a theme

**Reset Weighing** restores the pristine post-analyze balance. That baseline is persisted in a `.project_original.json` sidecar next to `_project.yaml`, written only by Regenerate Themes — so even if you clip sliders and quit, Reset brings the original back after restart. Slider saves go to `_project.yaml` (debounced 400ms).

### How It Works

1. `analyze_project.py` scans all subtitle/transcript files in the selected folders
2. Merges cues, extracts speakers, counts duration and cues per interview
3. If an Ollama model is loaded, sends interview samples to the LLM for 5–8 project-specific themes; otherwise falls back to keyword-frequency categories
4. Writes `_project.yaml`; themes are shared across all tabs via `projectThemesJSON`

### Instant Loading & Persistence

- If `_project.yaml` exists (yours or an ancestor folder's), it is read **directly on launch** — no LLM re-run. The button reads **Regenerate Themes** afterwards
- Material flags (subtitles/transcripts/chapters/synopsis per interview) are re-verified against the filesystem on every load
- Adding folders merges their `_project.yaml` themes into the current list automatically (weights summed for matching names, new themes appended)
- Externally edited `_project.yaml` values are picked up on next launch or via **↻**

---

## AI Edit Tab

Turn a script or treatment into a rough assembly. The guiding principle: **the script provides structure, the materials provide content.** Your document defines narrative function (introduction → statement → practice → conclusion); what fills each beat comes from what was actually said.

### The Material-Driven Method

1. **Author beats in the left panel — Script Beats** — the structured editor shows one card per beat with title, description (multiline, `.subheadline`), **target duration**, **mood**, and **search-query chips** — all expanded by default. Add beats with the big **＋ Add Beat** button in the empty state; edit any field inline. Cards expand/collapse with the chevron, move via drag-and-drop or the ⋯ menu (Move Up / Move Down), and delete via the visible trash icon or the menu. Above the cards sit the collapsible **Timeline** metadata block (name, editable estimated length in seconds, "Append timestamp (_HHMMSS)" checkbox, and a multiline **Intent** field describing what the edit is trying to say) and the **Treatment** drawer holding your free-form script or treatment; its **Auto-fill from text** button runs the LLM to populate empty beats from it (one Undo point). Beats express *editorial intent and topic* — never camera angles or imagined visuals (the priming prompt forbids them). The footer **+ Add Beat / Remove all** appears below the card list only once beats exist.
2. **Find Clips** inverts the usual search flow:
   - **Stage A — the materials propose.** Candidate passages are gathered from transcripts via three signals: the beat's topic queries (hints only), the beat's own description words, and **your theme keywords weighted by the Project Setup sliders** — the weighing actively drives discovery.
   - **Stage B — meaning decides.** The LLM sees only real verbatim passages plus each interview's synopsis excerpt, and selects up to 5 that serve the beat's intent. Its reasoning appears on every clip row — grounded in what was said.
   - **Stage C — precision.** Selected passages snap to overlapping subtitle cues for exact cut points; adjacent context paragraphs are offered optionally.
3. If the LLM is unavailable, selection falls back to lexical ranking over the same real-material pool (status shows "lexical fallback") — it never reverts to searching script-invented phrases.

### Tuning It

Two layers of control:

- **Priming windows** (Cmd+,) — the judgment layer:
  - *AI Edit · Parse Script*: how beats are formed from your treatment (the **Auto-fill from text** button)
  - *AI Edit · Clip Selection*: the exact instructions used to judge candidates (specificity, anecdotes vs generics, meaning over word-matching). What you see is exactly what the model receives.
- **Retrieval section** (collapsible, at the bottom of the Script Beats panel's setup cluster) — the mechanics:
  | Control | Range | Default | Effect |
  |---|---|---|---|
  | Candidates | 8–48 | 24 | How many transcript passages are shown to the selector |
  | Clips / beat | 1–8 | 5 | Maximum selections per beat |
  | Ground in synopses | on/off | on | Whether synopsis excerpts accompany candidates |

### Workflow

**ESC cancels an in-flight chat answer** (the streaming message is replaced with "Cancelled."). **Clear All** in the folder bar asks for confirmation and wipes the knowledge base together with the folders.

1. **Add source folders** — the project bar's left column sits above the editor split (＋ picks several folders at once). Subtitles + transcripts load into the search store; the bar's **right column** shows what's present (sub/tr/ch/syn/tl badges + per-folder project-file health).
2. **Author your beats** in the Script Beats panel, or paste a treatment into the **Treatment** drawer and click **Auto-fill from text** to have the LLM split it into beats (title, description, search queries, target duration, mood; schema-constrained, so malformed JSON is structurally impossible). Either way, you edit the beats directly — nothing is locked to the AI's output.
3. **Create Edit** — ranks real transcript passages against each beat's meaning (theme keywords from your Project Setup weighing participate in discovery), then the LLM selects those that serve the beat, with per-clip reasoning. Selected passages snap to overlapping subtitle cues for frame-accurate cut bounds. In the right **Timeline Beats** panel each beat shows an expandable clip list: include/exclude toggle, speaker, timecode, duration, and the selector's reason.
4. **Review Flow** *(optional)* — the LLM reviews your selected sequence against the script for narrative jumps, redundancy, and gaps. Notes appear above the beats. Language judgment only — all timing stays deterministic.
5. **Save / Load** (top of the Script Beats panel) — `square.and.arrow.down` writes the whole session to `<timeline name>_timeline.yaml` in your first work folder (title, timestamp flag, estimated seconds, intent, treatment, beats, clip results); `square.and.arrow.up` lists the saved edits in your folders (or **Open…**) and replaces the session after a confirmation. Saved edits surface as a **N tl** badge in the project bar.
6. **Create Timeline in Resolve** — two-row bar under the panels: a controls row (Export ▾ menu with EDL / SRTX export that works before creation, the created timeline name, an "N clips · total H:MM:SS" readout, and the Gap-seconds field) above a single full-width **Create Timeline in Resolve** button that assembles included clips into a new Resolve timeline.

### Tips

- Edit any beat's title/description/queries in the Script Beats panel; use the magnifying glass to re-search a single beat after editing its queries. Trim cards keep the list compact. The **Timeline Beats** panel shows clean title + clips rows for review.
- Context clips (orange badge) are adjacent paragraphs offered around a strong match — include them manually if useful.
- The same clip can't be claimed by two beats (dedup by source+timecode).
- Thematic treatments work now: beats describe topics, and candidates come from the transcripts themselves — but raising theme weights in Project Setup for topics you need will measurably improve what Find Clips surfaces.
- If a beat returns nothing, check the status line: "selected from N passages" means material was considered but judged off-topic (edit the beat's description); "no matching material found" means even the candidate pool was thin (check that transcripts are loaded).
- **ESC cancels** Parse Script / Find Clips / Review Flow instantly — late LLM responses are discarded instead of overwriting your edits. Beat move/delete and include-toggles lock while a search runs.

---

## Timeline Assist Tab

The primary workflow tab for processing interviews and creating timelines.

### Layout

Left and right panels below a permanent folder row. The old per-file asset queue is gone — processing always covers **every** discovered file.

### Top Row: Folder Loading

- The shared ingest bar (＋ ↻ 🗑, chips) sits full-width under the tab title; the current status shows in its trailing slot
- Folders are scanned **recursively** for `.srt`, `.srtx`, `.txt` files; paired `_transcript.txt` / `_transcripts.txt` files are auto-detected and deduplicated (the transcript wins for LLM context when paired with subtitles)
- Sentence/paragraph counts appear after loading; subtitle caches serve repeat launches instantly and rebuild themselves when the file set changes
- If the transcript index ever fails to open (e.g. after a force-quit), an orange status with a **Force Rebuild Transcript Index** button appears in the process area
- **Timeline FPS** is auto-detected when a folder is loaded: a video file is probed with `ffprobe`; otherwise the most common timecode frame digit is inferred (loose match across `hh:mm:ss:ff` — works for both colon and range formats). An override **FPS dropdown** in the controls strip lets you switch between 23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60. Changing it re-loads the current files at the new rate. EDL export and Resolve timecodes are FPS-aware

### Left Panel: Processing

#### Processing Controls

- **Chapters** checkbox (default on) — generates `_chapters.yaml`
- **Synopsis** checkbox (default on) — generates `_synopsis.txt`
- **Chapter density** slider — 0–100%, how many chapters the LLM segments the interview into (step 0.1)
- **Chapters / Synopsis verbosity sliders** — labeled "Usage — how much detail the notes carry"; each appears only while its checkbox is on:
  - 0.0 → Python verbosity 0.5 (higher floor, concise output)
  - 1.0 → Python verbosity 1.0 (maximum detail: intro 20–30 sentences, 500–800 words per subject)
- **Synopsis section toggles** — individual checkboxes for Intro, Paragraphs, Bullets, Timecode (shown when Synopsis is enabled)
- **Create Chapters and Synopsis** button (label varies: "N missing", "Recreate… (weights changed)", "(settings changed)") — checks for existing output files first, shows Overwrite/Cancel alert if any exist. Runs `process_srt.py` with progress streaming. Deduplicates: when a paired transcript exists, the subtitle `.srt`/`.srtx` is skipped to avoid double-processing

#### Processing Progress

- Determinate `ProgressView` in the bottom bar
- Status message updates live via `runRawProgress` callback
- Progress JSON lines printed by Python: `{"progress": "message"}`
- On completion, markers are read from the JSON output and displayed in the chapter list. Transcripts are automatically reloaded after processing — the Source picker (Subtitles/Transcripts) becomes available immediately without requiring an app restart
- Markers DB cache is deleted before `docStore.reload()` to force full re-index

#### Chapter / Synopsis Generation Details

- **Timeout**: Python side 600s (GENERATE_TIMEOUT), Swift side 1200s — needed for qwq:32b reasoning model which burns tokens on internal reasoning before producing output
- **max_tokens**: 8192 (increased from 4096 for qwq:32b)
- **`parse_llm_synopsis()` handles multiple formats**:
  - Standard `SUBJECT:` / `INTRODUCTION:` format
  - qwq:32b markdown headings (`###`, `####` with `**bold**` subject names)
  - Strips `<think>` reasoning blocks from the LLM output
  - Intro paragraph captured correctly via `collecting_intro` flag
  - Subject names cleaned — `**` markers stripped
  - "Key points**:" labels filtered from bullets
  - Section-divider headings ("2. Subject Paragraphs") skipped
- **LLM prompt strengthened** with "CRITICAL: Every subject section ABSOLUTELY MUST have 3-4+ sentences of narrative paragraph text"
- **Fallback paragraphs**: `generate_synopsis()` synthesises multi-sentence narrative paragraphs from bullet content when the LLM doesn't produce proper prose
- **Chapter notes** are now LLM-generated full sentences instead of keyword fragments
- **Data-driven timecodes**: Synopsis subject time ranges and per-bullet average timecodes are computed from keyword chapter boundaries — the LLM is not asked to generate timecodes (avoids hallucination). Subjects are mapped to consecutive chapter ranges proportionally. Bullet average timecodes are evenly distributed within the subject's assigned chapter range
- **Timecode offset normalization**: When subtitle files start with a time-of-day offset (e.g., `00:40:00:00`), all displayed timecodes in the synopsis are normalized relative to the interview start by subtracting the first cue's start time. The `_chapters.yaml` always stores absolute timecodes for correct Resolve marker placement

#### Post-Processing: Chapter List

After processing, a **document picker** dropdown lets you switch between loaded YAML documents. Selected document's markers are displayed in a numbered chapter list with:

- **Chapter number** (monospaced index), **Timecode**, **Name**, **Theme** (color-coded), **Notes** (2-line limit, secondary color)
- **Total duration** of selected markers
- **Export EDL** button — exports an Edit Decision List
- **Write to Resolve** button — pushes markers to DaVinci Resolve via Fusion API
  - Markers backed up to temp JSON before writing
  - **Undo** button appears (orange) after write — shows confirmation alert before restoring
- **Sync synopsis to markers** — reads existing `_synopsis.txt` and appends synopsis text as marker notes (updates the YAML file)

#### YouTube Publishing

Two buttons generate deliverables for video descriptions:

- **YouTube Markers** — opens a sheet with a timestamped chapter list (`m:ss` / `h:mm:ss` + chapter title), ready to paste into a YouTube description. **Copy** copies to the clipboard, **Save…** writes a `.txt` file. A **text size slider** (9–24 pt, monospaced) adjusts the sheet preview
- **AI Summary** — opens a sheet (nothing generates yet). Pick a length — **Short** / **Medium** / **Long** — then press **Generate Summary** in the window. Ollama writes the summary from the selected document's transcript (falling back to subtitles, then chapter notes), with thinking disabled (`think: false`) and any leaked reasoning (complete or partial `<think>` blocks) stripped so only the clean summary is shown. Each length's result is cached and saved per document, so switching between Short/Medium/Long restores its previous summary without regenerating; cached summaries survive app restarts. A **generation time** (`mm:ss`) appears below the text. **Copy** keeps the window open and shows a brief "Copied ✓" confirmation; **Save As…** and **Regenerate** are also available while the sheet is open

### Right Panel: Subtitle Search & Timeline Creation

#### Search Bar

- Text field with paperplane **Send** button
- Every query is interpreted through Ollama (`keep_alive: 0`):
  - Natural language: "Find all mentions of oak aging and fermentation temperature" → LLM extracts keywords and runs search
  - Keywords: "barrel aging bairrada" → LLM returns them as-is
- **CLI reasoning window** above the prompt bar — dark background, monospaced, max 140pt height. Shows `>` query and LLM interpretation. Text is selectable via `.textSelection(.enabled)`
- **Spinning wheel** during LLM interpretation next to Send button; button disabled while `isInterpreting`
- Search terms cached as `lastSearchTerms`
- **Clear** button clears results, reasoning messages, and resets state

#### Search Source

When transcripts are loaded, a segmented picker above the prompt bar chooses the assembly granularity (`@AppStorage("timelineSearchSource")`):

| Source | Behavior |
|--------|----------|
| **Subtitles** | Atomized assembly — each result is a single subtitle cue (exact FTS5 + semantic merged). Uses the 2-pass strategy below for multi-word queries |
| **Transcripts** | Long paragraphs — each result is a full `_transcript.txt` / `_transcripts.txt` paragraph from `searchTranscripts()` (paragraph FTS5 only, no semantic search). Speaker/source-file lists and context expansion switch to the transcript pool |

#### 2-Pass Search Strategy (Subtitles mode)

When transcripts are loaded and the query has 2+ words, Assistant Editor uses a 2-pass approach to solve the multi-word FTS5 gap (where adjacent subtitle cues like "barrel" + "aging" never form a contiguous FTS5 phrase match):

1. **Pass 1 (Transcripts FTS5)**: Search the continuous paragraph `transcriptDb` via FTS5 — multi-word phrases match naturally across whole paragraphs
2. **Pass 2 (Overlap)**: Find subtitle cues whose timecode ranges overlap with the matching transcript paragraphs
3. **Fallback**: Single-word queries or no-transcript mode go directly to subtitle FTS5 search

Search strategy is configurable via the **Priming** window (Cmd+,) under *Search Interpretation* — the exact system prompt sent with every query interpretation call.

#### Filters

| Control | Behavior |
|---------|----------|
| **Semantic Threshold slider** (Looser/Tighter) | 0.05–0.95, re-runs `executeSearch(terms: lastSearchTerms)` immediately on every change — no re-interpretation. Hidden in Transcripts search-source mode (semantic search is subtitle-only) |
| **Speaker filter** | List below sliders (`@AppStorage("speakerListHeight")`), "All Speakers" toggle, filters via `filterSpeakers: Set<String>` |

#### Sort Options

| Option | Behavior |
|--------|----------|
| Relevance | By semantic similarity score |
| Chronological | By subtitle start time |
| Speaker | Alphabetical by speaker name |
| Location | By interview location folder |
| Prompt Sort | Sends current results + search query to LLM for narrative re-ordering. Cached in `smartOrder` |

#### Search Results

- Each result shows: speaker, interview, timecode, text content excerpt
- Results are grouped by search hit with surrounding context (configured via **Before/After** context slots slider)
- **Context entries** are shown indented below the matching hit, with blue (match) or orange (context) color coding
- Checkboxes for selection
- **Selected duration** display at the top

#### Context Slots & Group Gap

- **Before/After** stepper — number of surrounding subtitle cues to include as context per match (default 3)
- **Group Gap** — seconds of gap between groups when creating the timeline (default 5s, translated to frames)
- **Add Subtitles (.srtx)** — when on, writes an SRTX captions file to the work folder with standard SRT millisecond timecodes (`HH:MM:SS,mmm`), speaker on its own line, and text with leading space. The format matches Resolve's SRTX export — human-readable, not frame-based. After timeline creation, the file is revealed in Finder. Written into the first marker's folder (else `/tmp`)

#### Create Timeline

- Sends selected entries to DaVinci Resolve via `create_timeline.py`
- Timeline entries include `sourceFile` — the script derives a clean media name via `source_base()` (strips `_subtitles`/`_transcript`/`_rough` suffixes) for better Resolve media pool matching
- **Cancel** button (orange) appears while creating — calls `PythonBridge.cancelRunning()`
- **Clip colors**: Blue = direct match, Orange = surrounding context
- **Group gaps**: A black ProRes video is generated via ffmpeg, imported with `mp.ImportMedia()`, and appended between groups as a clip gap. Falls back to no gaps if ffmpeg is missing
- **Marker flag colors**: Blue → Blue, Orange → Rose (remapped from Orange since Resolve's Orange returns False)
- Debug log: `/tmp/assistanteditor_timeline_log.json`

---

## Transcript Intelligence Tab

RAG chat interface grounded in your interview data.

### Workflow

1. **Choose Project Folder** — select the root directory containing transcripts, chapters, and synopses. This tab has its own independent folder picker (`@AppStorage("transcriptIntelligenceFolders")`) with folder chips and × remove buttons
2. The tab loads both `DocumentStore` (YAML chapters) and `SubtitleStore` (subtitles + transcripts) from the chosen folders
3. `KnowledgeStore` builds automatically once both stores are loaded — this pre-computes per-interview summaries, topic breakdowns, and centroid key quotes
4. Start chatting — type a question about the interviews

### Chat Interface

- Messages anchored to bottom via `GeometryReader` + `Spacer`
- User messages right-aligned (accent color background), assistant messages left-aligned
- **Clear** button resets conversation and LLM reasoning state
- Input field with **Send** button and spinning wheel during processing
- Powered by the selected Ollama model

### Knowledge Base & Search Context

The chat combines two sources of context for each query:

1. **Knowledge Store** — pre-computed per-interview summaries, topic breakdowns, and centroid key quotes (from `KnowledgeStore`). Used for high-level orientation about what's in the material
2. **FTS5 subtitle/transcript search** — up to 20 actual transcript excerpts matching the query, with timecodes, speaker names, and interview titles. This gives the LLM the real text to work with

The priming prompt (editable in the Priming window, *Transcript Chat*) guides the LLM's editorial behavior. A generic fallback context is used when no matches are found.

---

## Sync by Transcript Tab (parked in v1.23)

The transcript-based sync workflow is **not shipped in v1.23** — it has been removed from the UI while the feature is re-evaluated and possibly reworked later. The source and Python scripts remain in the repository for future restoration.

When it returns, the workflow is: single work folder with auto-detected files (`.edl`, timeline SRT, field SRTX) → **Sync** matches each clip to its moment in the field recording → **Build Timeline** assembles the sequence in Resolve → **Export EDL** writes a CMX3600 EDL (frame rate follows the app's Timeline FPS setting).

---

## Bottom Bar

### Model Status & Controls

| Element | Description |
|---------|-------------|
| **Status dot** | Green = model loaded and ready; Gray = model not loaded or Ollama unavailable |
| **Model dropdown** | Picker of available models from `ollama list` (auto-detected on launch). Selection stored in `@AppStorage("selectedModel")` |
| **Load / Unload** | Green bordered button (loaded) / Red bordered button (unloaded). Load sends warm-up API request with `keep_alive: -1` to keep model in GPU memory. Unload runs `ollama stop <model>` to free ~20GB of VRAM. On app termination, model is automatically unloaded via the selected model stored in UserDefaults |
| **Model Manager…** | Opens the Model Manager popover — installed/available model lists with per-model hardware-fit badges, install/delete/update, Ollama update, and hardware summary |
| **Preferences…** | Opens the Preferences window (⌘,) — priming prompts, presets, pipeline tuning |
| **Methodology** | Button that re-opens the onboarding splash screen explaining the Resolve workflow |
| **Setup…** | Appears when Ollama is unavailable. Opens the setup sheet with options to Install Ollama, Pull Model, or Use Keywords Instead |
| **ProgressView** | Determinate progress bar with status caption text during processing |

The bar is decluttered with dividers between logical groups (Model controls | Model Manager | Priming/Methodology).

### Model Manager

Opened via the **Model Manager…** button in the bottom bar. A popover with:

- **Hardware header** — detected chip (e.g. "Apple M2 Max"), core count, unified memory, Ollama version, and install method (Homebrew / Ollama.app)
- **Installed Models** — list of locally pulled models with parameter size, quantization, file size, and a hardware-fit badge. Trash icon deletes a model (`ollama rm`), an **Update** button appears when the installed model is not the latest on the Hub
- **Available Models** — searchable list of all 192 models on [Ollama Hub](https://ollama.com/library). Sizes load lazily from the registry when scrolled into view. Each row shows a fit badge and an **Install** button
- **Check for Updates** — compares the local digest of the default model (`sonct988/gemma4-26b-a4b-it-q4km-256k`) against the Hub manifest (SHA-256); flags when a newer version exists
- **Update Ollama** — if installed via Homebrew, runs `brew upgrade ollama` with live output; otherwise opens the Ollama download page
- **Done** — closes the popover

Hardware-fit badges estimate the RAM needed to run a model (model file size × 1.2 + 4GB overhead for context/OS) against your machine's unified memory:
- **Runs well** (green) — comfortably within memory
- **Tight** (orange) — runnable but close to the memory ceiling
- **Too large** (red) — exceeds available memory
- **Unknown** — size not yet known

### Model Auto-Detection

- On launch, `ollama list` is queried to populate the model dropdown
- `selectedModel` is auto-set to the first detected model
- If only one model is available, it's auto-selected
- Model loaded/unloaded state is tracked across load/unload/check cycles
- `pullModel()` sets `modelLoaded = true` after successful download

### Warning Banners

- **Orange banner**: Model not loaded — "Click Load Model in the bottom bar to enable AI features"
- **Red banner**: Ollama unavailable — "Click Setup… in the bottom bar to configure"
- Appear below the tab picker

---

## Priming Window

Opened via **Cmd+,**, the **Preferences…** button in the bottom bar, or the Help menu. One editable prompt per LLM step — what you see in each window is *exactly* what the model receives, nothing added behind your back.

The sidebar lists all steps; a colored dot marks prompts you've customized. Each editor shows when the prompt fires ("Fires when…"), saves automatically on every keystroke, and offers **Reset to Default** with confirmation.

| Step | Fires when |
|------|-----------|
| Project Analysis | Analyze / Regenerate Themes (Project Setup) |
| Chapters & Synopsis | Processing interviews (Timeline Assist) |
| Search Interpretation | Every prompt-bar Send — query → keywords |
| Transcript Chat | Transcript Intelligence messages |
| Prompt Sort | Sort option "Prompt" in Timeline Assist |
| AI Edit · Parse Script | Auto-fill from text button |
| AI Edit · Clip Selection | Find Clips — judges real transcript passages against each beat |
| AI Edit · Flow Review | Review Flow button |
| YouTube Summary | Generate Summary — `{LENGTH}` is replaced with Short/Medium/Long at runtime |

Python-backed steps receive their prompt via `--priming-prompt-file`; Swift-backed steps inject it directly into the Ollama call.

---

## Onboarding

### Methodology Splash

Appears on every launch. Explains the Resolve workflow:

1. Sync audio/video
2. Transcribe timeline
3. Assign speakers
4. Export transcript
5. Export subtitles

Dismiss with Continue, Return/Enter, or Escape. Re-open via **Methodology** button in the bottom bar.

### Text Size

- **⌘+** / **⌘-** increases/decreases the app-wide text size (0.75×–1.75×, step 0.125), **⌘0** resets to 1.0
- The scale persists across launches (`appTextScale`) and applies to every view, including the YouTube Markers / AI Summary sheets (which stack on top of their own sheet-level preview size)

### Ollama Setup Sheet

Auto-presents on first launch when Ollama is not found. Provides:
- **Install Ollama…** — opens the Ollama download page
- **Pull sonct988/gemma4-26b-a4b-it-q4km-256k** — runs `ollama pull` in the background with progress output
- **Use Keywords Instead** — dismisses the sheet and runs without AI

On launch, Assistant Editor also checks the Hub for the default model (`sonct988/gemma4-26b-a4b-it-q4km-256k`): if it isn't installed, or a newer version exists, an alert offers to open the Model Manager.

---

## File Formats

### SRTX (frame-based subtitles)

Input format (what the app reads):

```
[00:01:23:15 - 00:01:25:10]
Speaker Name
Text of the subtitle
```

Output format (what the app writes when Subtitles toggle is on):

```
1
00:01:23,400 --> 00:01:25,200

Speaker Name
 Text of the subtitle
```

The output uses standard SRT millisecond timecodes (not frame-based), speaker on its own line, text with leading space. This matches Resolve's SRTX export format — human-readable and directly compatible with Resolve's subtitle import.

### SRT (standard subtitles)

```
1
00:01:23:15 --> 00:01:25:10
Speaker Name
Text of the subtitle
```

### TXT (frame-based)

`.txt` files with `[hh:mm:ss:ff]` format accepted as subtitles alongside `.srt`/`.srtx`.

### TXT (paired transcript)

`_transcript.txt` (or `_transcripts.txt`) — paragraph-level export from Resolve's transcript feature. When placed alongside a subtitle file with the same base name, it's auto-detected and used for richer chapter/synopsis generation while subtitles provide timecode snapping. Processing deduplication skips the subtitle file when a paired transcript exists.

### Output: `_chapters.yaml`

YAML file with interview metadata and chapter markers:

```yaml
title: Interview Name
location: Location
date: ""
speakers:
  - Speaker 1
  - Speaker 2
markers:
  - start_s: 123.5
    end_s: 456.7
    name: Chapter Name
    theme: Theme
    color: Blue
    notes: Detailed notes about this chapter (LLM-generated full sentences)
```

### Output: `_synopsis.txt`

Plain text file with:
- Synopsis header (title, location, duration)
- Introduction (optional, LLM-generated narrative paragraph)
- Subject paragraphs (LLM-generated, 3-4+ sentences each, with or without bullet points)
- Subject-level time range from keyword chapter boundaries (e.g., `Policy (00:05-12:30)`)
- Per-bullet average timecodes evenly distributed within the subject's chapter range (e.g., `[05:47] First key point`)
- Timecodes are normalized relative to interview start when subtitle files use time-of-day offsets

### Output: `_project.yaml`

Project analysis file generated by `analyze_project.py`:

```yaml
version: 1
folders:
  - path: "/path/to/folder"
    interviews:
      - title: "Interview Name"
        excluded: false
        hasSubtitles: true
        hasTranscript: false
themes:
  - name: "Theme Name"
    keywords: ["keyword1", "keyword2", ...]
    weight: 0.15
    color: "Blue"
stats:
  totalInterviews: 14
  totalDurationS: 65924.2
  totalCues: 8261
  speakers:
    - name: "Speaker Name"
      cueCount: 1449
  frequentWords:
    - ["wine", 576]
    - ["people", 353]
```

---

## DaVinci Resolve Integration

### Timeline Creation

- Selected subtitle entries are sent to Resolve as timeline clips
- **Clips**: Blue border = direct match, Orange border = surrounding context
- **Group gaps**: Separate hit groups with a black ProRes video clip (requires ffmpeg; no gaps without it)
- **Markers**: Added at each clip with flag colors (Blue → Blue, Orange → Rose)
- **Media pool matching**: Source file names are cleaned via `source_base()` (strips `_subtitles`/`_transcript`/`_rough` suffixes) for better Resolve media pool matching
- **Subtitles**: When the Subtitles toggle is on, an SRTX file is written to the work folder (standard SRT millisecond timecodes, speaker on its own line). The file is revealed in Finder for manual import into Resolve
- **Known limitations**:
  - Gold, Peach, Chocolate, Lime colors always return `False` from `AddMarker`; script remaps Tan→Yellow, Orange→Rose
  - `AppendToTimeline` requires a list of dicts (single dict hangs the API)

### Marker Writing

- Chapters can be written as Resolve markers via `write_resolve.py`
- **Color mapping**: Blue → Blue, Orange → Rose
- **Undo**: Markers are backed up to a temp JSON file. An **Undo** button (orange) appears after writing — shows confirmation alert before restoring previous markers via the API

---

## Cache & Troubleshooting

### Cache Locations

| Data | Path |
|------|------|
| Subtitle database | `~/Library/Caches/assistanteditor_subtitles_{folderName}.db` |
| Knowledge store | `~/Library/Caches/assistanteditor_knowledge_{folderName}.json` |

### Debug Files

| File | Contents |
|------|----------|
| `/tmp/process_srt_error.log` | Python stderr from `process_srt.py` |
| `/tmp/assistanteditor_timeline_log.json` | Per-marker debug: raw_color, mapped_color, marker_frame, add_marker_ok. Also: srt_entries_count, srt_path (when subtitles toggle is on) |
| `/tmp/assistanteditor_gap_debug.log` | Gap positioning logic debug from `create_timeline.py` |

### Cache Busting

- Subtitle caches are fingerprinted (file set + sizes + mtimes) and validated by an expected row count — a mismatch or a partially written cache rebuilds itself automatically; failed loads are never marked valid
- Transcript searches never touch the index while it is being rebuilt (previously a source of "Transcript DB error")
- **↻ on any tab forces a full cache rebuild**, bypassing fingerprints
- SubtitleStore deletes both subtitle and transcript SQLite cache DBs before re-parsing on every `reload()` or `loadSingleSRT()` call
- DocumentStore always re-reads `_chapters.yaml` from filesystem (no database cache)
- KnowledgeStore rebuilds automatically on store reload

### Known Issues

- Resolve API: Gold, Peach, Chocolate, Lime colors always return False from `AddMarker`
- `AppendToTimeline` requires a list of dicts, not a single dict (hangs API)
- `EmbeddingEngine` serializes via `queue.sync` to avoid CoreNLP crashes under concurrency
- `findExistingOutputs()` doesn't check old `_summary.yaml` format
- `QwQ:32b` is a reasoning model and inherently slower than non-reasoning models — it burns tokens on internal reasoning before producing output, requiring higher timeouts (600s Python, 1200s Swift) and max_tokens 8192. For large transcripts (>500KB), the first Ollama call may consume the entire timeout

---

## v1.6 Changes

- **SRTX subtitle export** — the Subtitles toggle in Create Timeline writes an SRTX captions file to the work folder (standard SRT millisecond timecodes, speaker on its own line, text with leading space). Format matches Resolve's SRTX export. File is revealed in Finder after timeline creation
- **App-wide text size** — **⌘+** / **⌘-** scale the entire UI (0.75×–1.75×), **⌘0** resets. Implemented via a `scaledFont`/`scaledFontSize` modifier pair backed by the `appTextScale` environment value (persisted with `@AppStorage`). Note: macOS does not expose a user-changeable `DynamicTypeSize`, so this is a custom scale applied to all semantic text styles
- **Timeline FPS auto-detect + override** — folder loads probe the video with `ffprobe` and fall back to a timecode-frame heuristic (loose `hh:mm:ss:ff` match, so both colon and range formats are covered). A dropdown lets you force 23.976–60 fps; changing it re-parses loaded files at the new rate, and EDL/Resolve timecodes follow
- **YouTube Markers sheet** — copy/save a timestamped chapter list for video descriptions
- **AI Summary from transcript** — Ollama summary generated from the selected document's transcript, with `think: false` and robust reasoning stripping (handles partial `<think>` blocks). Summary window opens empty; generation starts from a **Generate Summary** button in the window. **Short/Medium/Long** length buttons replace the old size slider; each length is cached and persisted per document, so switching lengths restores previously generated summaries. **Copy** no longer closes the window and shows a "Copied ✓" flash. A per-generation time in `mm:ss` appears below the text
- **Methodology splash** updated — documents the new FPS, YouTube, and text-size options

## v1.5 Changes

- **Data-driven synopsis timecodes** — time ranges and per-bullet average timecodes are now computed from keyword chapter boundaries instead of LLM generation (which hallucinated wrong times). Subjects are mapped to consecutive chapter ranges proportionally; bullet average timecodes are evenly distributed within each subject's assigned chapter range
- **Timecode offset normalization** — when subtitle files start with a time-of-day offset (e.g., `00:40:00:00`), all displayed synopsis timecodes are normalized relative to interview start by subtracting the first cue's start time. The `_chapters.yaml` always stores absolute timecodes for correct Resolve marker placement
- **LLM prompt simplified** — the system prompt no longer asks the LLM to generate timecodes (they were unreliable). The LLM writes only subject paragraphs and bullet text
- **`GENERATE_TIMEOUT` increased** 300s→600s — QwQ:32b needs longer for large transcripts (>500KB, 80K compact context)
- **Swift PythonBridge timeout increased** 600s→1200s — end-to-end window accommodates two LLM calls (synopsis + chapter notes) for large interviews
- **`BrokenPipeError` graceful handling** — Python script exits cleanly with `sys.exit(0)` when Swift closes the pipe on timeout, instead of dumping a misleading traceback to `/tmp/process_srt_error.log`

### Migration Notes

- Existing `_synopsis.txt` files can be regenerated by re-processing the SRT — the timecode display will now show correct data-driven positions rather than LLM-hallucinated values
- No changes to `_chapters.yaml` format — absolute timecodes unchanged

## v1.8 Changes

- **Priming presets** — named prompt sets stored in `_priming_presets.yaml` next to `_project.yaml`. The Preferences window (⌘,) picks them up from a folder you choose (folder button under the Preset picker) or from Source Material roots; switching applies all 9 stage texts instantly, with a confirmation only if you've hand-edited stages. **Factory** restores the generic documentary-editor prompts. First shipped preset: **Convivium**, generated from this project's transcripts (Belgian fermentation farms + Bairrada wine). **Save/Delete (v1.20)**: the sidebar header row gains a save button (down-arrow icon) that opens a sheet prefilled with the current 9 stage texts and writes a named preset, and a trash button that deletes the selected preset with a confirmation. Saving immediately applies and activates the preset.
- **Parse Script renamed to Create Beats** — full-width button with ⌘↩ shortcut
- **Transcript Intelligence layout** — chat and input now sit in a centered 720pt reading column
- **tok/s meter** — bottom bar always shows tokens-per-second of the last local LLM call (Swift-side calls); hover for details
- **Tab shortcuts follow order** — ⌘1–5 select positions after you reorder tabs via right-click, not fixed tabs
- **Timeline Assist hardening** — duplicate overwrite warnings fixed; transcript cache errors auto-retry (stale WAL cleanup) with a visible Force Rebuild button
- **Per-tab cache namespaces** — subtitle/transcript caches are namespaced per tab (tl/ti/ai), eliminating cross-tab database contention

- **Clear All** button in Source Material tab — trash icon in the left panel header clears all folders, themes, and analysis across all tabs with a confirmation alert. Resets SubtitleStore and DocumentStore state
- **Co-dependent weighing sliders** — all theme weight sliders always sum to 100%. Moving one redistributes the remaining % proportionally across the others. Snapshot-based: captures all weights at drag start, redistributes from snapshot during drag, so dragging a slider back to its original position restores others proportionally. Reset button restores original weights from last analysis load
- **Transcript pairing fix in SubtitleStore** — `loadFolders()` now checks 4 candidates (`_subtitles.srtx`, `_subtitles.srt`, `.srtx`, `.srt`) instead of only `_subtitles.*`, ensuring `_transcript.txt` is properly skipped when a paired subtitle exists
- **Transcript Intelligence tab harmonized** — title uses `.title2`, project bar and input bar use 12px size to match Source Material tab spacing

## v1.7 Changes

- **Source Material tab** — new first tab (default on launch). Folder management, LLM project analysis, dynamic theme extraction, interview table with exclude toggles, weight sliders. Analyzes all interviews in selected folders to extract project-specific themes and keywords
- **Dynamic themes** — themes are no longer hardcoded to wine/viticulture. `analyze_project.py` uses the LLM to extract 5–8 project-specific themes with keywords and weights, falling back to generic keyword-frequency categories when no model is loaded. Themes flow through the entire app: chapter detection, color assignment, KnowledgeStore topic colors, and chat context **File Coverage bars removed** from Source Material stats panel per v1.13 UI harmonization
- **`_project.yaml`** — new output format storing project analysis: themes, keywords, weights, stats, interview metadata. Generated by `analyze_project.py`, read by `process_srt.py` (via `--themes-file`) and `KnowledgeStore` (via shared `@AppStorage`)
- **`analyze_project.py`** — new Python script. Scans folders, merges cues, extracts speakers and frequency words. Optionally uses LLM for theme extraction. Falls back to keyword-frequency analysis
- **`process_srt.py` now accepts `--themes-file`** — reads dynamic themes from a JSON file, overriding the previous hardcoded wine/viticulture keyword lists for chapter detection, theme assignment, and chapter name building
- **Removed hardcoded themes from `Models.swift`** — `THEME_COLOR_MAP`, `suggestTheme()`, and `themeKeywords()` removed (~50 lines). Theme detection is now fully dynamic
- **KnowledgeStore uses dynamic themes** — topic colors assigned from project themes instead of hardcoded `THEME_COLOR_MAP`
- **Interview table** — sortable by title, duration, cues, speakers, status. Exclude toggles to flag interviews
- **Theme weight sliders** — adjust theme importance (0–100%), persisted to `_project.yaml` and shared via `@AppStorage`

## v1.13 Changes

- **New app icon** — Didot serif Æ monogram on a graphite squircle with an amber editor's-rule accent
- **Transcript Intelligence freshness** — the knowledge base cache is now validated against the loaded folder and its contents; switching projects can never serve another project's knowledge. A **rescan button** (⟳ in the project bar) wipes the cache, re-reads every file, and rebuilds from scratch
- **Rescan buttons everywhere stale data can hide** — Timeline Assist header (new/renamed/processed files + YAML status), Source Material interviews header (re-check chapters/synopses on disk), AI Edit material chips (recount what's present)
- **Every divider is draggable** — vertical panel splits (Source Material, AI Edit, Timeline Assist, Sync, Priming sidebar) and now horizontal boundaries too: the Timeline Assist top section height and the Source Material interview-list size are drag-adjustable; all positions persist
- **Dead space eliminated** — the interviews list hugs its content, and Timeline Assist shows a "No chapters yet" hint instead of an empty void before processing

## v1.12 Changes (Hardening)

- **Per-tab data isolation** — Timeline Assist, Transcript Intelligence, and AI Edit each own their subtitle/transcript stores. A tab's folder choice can no longer clear or silently replace another tab's loaded material
- **AI Edit sessions survive restart** — parsed beats, clip selections, include toggles, and flow notes save automatically ~0.6s after any change
- **Correct EDL timecodes** — fixed frame rollover in exported EDLs (10.999s at 25fps no longer becomes 00:00:10:25)
- **Visible errors** — script failures surface the real message instead of an empty "Python error:"; processing reports which files degraded to keyword fallback when the LLM is unreachable
- **Faster relaunches** — the subtitle cache (including AI embeddings) is reused when files are unchanged; the knowledge base is cached between sessions
- **Safer timeline assembly** — build timeout scales with clip count; media matching prefers exact name matches; pre-create cleanup can no longer delete a video clip that shares the timeline's name; short-clip chapter expansion reads the correct `_chapters.yaml`
- **Model pulls fixed** — progress drains continuously (no deadlock), UI stays responsive during download/upgrade
- **Retrieval upgrades** — semantic subtitle matches join the candidate pool even when transcripts are loaded; passages inside matching chapters are prioritized
- **fps-correct Sync pipeline** — sync scripts follow the app frame rate on 23.976/30/50/60 fps projects
- Misc: Cmd+2 opens AI Edit and Cmd+5 Sync (Tabs menu); weight-slider writes debounced; dead code removed

## v1.10 Changes

- **AI Edit tab (new)** — script/treatment → LLM beats → clip search → timeline. Schema-constrained Parse Script (grammar-level JSON guarantee), **material-driven retrieval** (candidates from transcripts + theme weights; LLM selects among verbatim passages with reasons; synopsis-grounded), cross-beat clip dedup, per-beat re-search, expandable clip lists with include toggles, Review Flow continuity pass, single Create Timeline button with Export ▾ menu
- **Priming window replaces Preferences** — one independent, editable prompt per LLM step (8 steps). Sidebar navigation, autosave, Reset to Default, "fires when" captions. Old global priming/search-strategy prompts retired; every step's prompt is now visible and tunable
- **Instant project analysis** — existing `_project.yaml` loads directly via a purpose-built YAML parser (no LLM re-run on launch); material flags re-verified against the filesystem each load. Analyze button becomes Regenerate Themes once analysis exists
- **Material chips in AI Edit** — Synopsis / Chapters / Transcripts / Subtitles counts for the selected folder (green = present, orange = missing)
- **Parse reliability** — Ollama `format` schema makes malformed JSON impossible; empty-response detection distinguishes model-loading from parse failure; error messages show the raw response head for diagnosis
- **AI Edit simplification** — Write to Resolve removed (Timeline Assist only); EDL/SRTX export available pre-creation via Export menu
- **Failproof test script** — `software/testscripts/failproof_test_script.txt` with queries verbatim from the Valke Vleug transcript, for isolating retrieval bugs

## v1.9 Changes

- **Processing JSON output fix** — `processAllSRTs()` now correctly extracts the last JSON line from `runRawProgress` output. Previously, `JSONSerialization` failed on multi-line JSON output (progress messages + final status), causing every file to be marked as "Failed". This was the root cause of processing failures across all files
- **Independent folder pickers per tab** — Timeline Assist and Transcript Intelligence each have their own `@AppStorage` key and `NSOpenPanel` folder picker. Each tab manages its own folders independently with × remove buttons on folder chips. No cross-tab folder propagation (attempted and reverted due to `@AppStorage` cross-view `.onChange` unreliability)
- **Transcript count display** — Timeline Assist file section shows "sentences + paragraphs" when transcripts are loaded, and a Source picker (Subtitles/Transcripts) for search granularity
- **SubtitleStore extractSpeakerAndText fix** — handles both 3-line SRTX blocks (transcript format: timecode, speaker, text) and 4-line blocks (subtitle format: timecode, blank, speaker, text). Previously only 4-line blocks got speaker extraction, causing transcripts to show empty speakers
- **SubtitleStore transcriptDb race fix** — `loadFolders()` no longer closes `transcriptDb` (not its responsibility), and `loadTranscriptsFolders()` no longer checks `isTranscriptsLoaded` (allows reloading when called from `loadOwnFolders`)
- **Timeline Assist transcript loading** — `loadOwnFolders()` now calls `subStore.loadTranscriptsFolders(folders)` after loading subtitles, so transcripts are available for search
- **Empty folder handling** — both Timeline Assist and Transcript Intelligence clear file lists and reset stores when all folders are removed

### Known Limitations

- **No single-folder propagation** — each tab has its own independent folder picker. Adding a folder in Project Setup does not add it to Timeline Assist or Transcript Intelligence. This is intentional: `@AppStorage` instances in different views don't trigger each other's `.onChange` reliably, and the cross-tab synchronization workaround added unacceptable complexity and race conditions
- **No debounced search** — search re-runs on every keystroke without debouncing. Rapid typing sends multiple FTS5 queries
- **Single project at a time** — no concept of switching between multiple saved projects
- **Theme colors are fixed** — assigned from a fixed palette by `analyze_project.py`. Users can remove themes but not customize colors or add new ones manually
- **No theme reordering** — themes display in LLM-extracted order. No drag-and-drop reordering
- **No project analysis import/export** — `_project.yaml` is per-root-folder with no transfer UI
- **No step-by-step slider undo** — **Reset Weighing** restores the persisted post-analyze balance, but individual intermediate states aren't recorded
- **No video preview** — subtitle/transcript files are not associated with video files. Timeline creation relies on Resolve's media pool for video matching


---

## v1.20 Changes (Robustness Round)

- **Robustness fixes** — FTS5 queries now escape metacharacters (`OR`/`AND`/`NOT`/`NEAR`, quotes, parentheses) so literal searches never silently return 0 hits; `clearAll()` resets the embedding map under its lock; Transcript Intelligence `send()` builds chat context on the main thread and only the blocking Ollama call runs off-main (no more `@Published` data race on background queues)
- **`--model` for processing** — the Create Chapters command passes your selected bottom-bar model to `process_srt.py`; when the installed-model check disagrees, your chosen model is used. Degraded (LLM-unavailable) runs now surface a `warning` note per file
- **Atomic file writes** — `_chapters.yaml`, `_synopsis.txt`, and `_project.yaml` are written to a temp file and swapped in atomically, so an interrupted/power-loss write can't leave a truncated file
- **YAML escaping hardened** — `ProjectAnalysis.save` now escapes backslashes, quotes, newlines, tabs and control chars; the parser round-trips them and normalizes CRLF/CR line endings
- **Sync frame rate** — `sync_transcripts.py` reads `AE_FPS` (default 25) instead of a hardcoded rate
- **`create_timeline.py` fixes** — timeline markers read from `_chapters.yaml` via the correct variable (`chapters_path`); a stray duplicate subtitle block that referenced stale loop variables was removed

## v1.21 Changes (Project Naming & Material Tree)

- **Project file naming** — analysis is now written as `<folderName>_project.yaml` (e.g. `Bairrada_project.yaml` for a root, `07-03_Carlos Campolargo_project.yaml` for a single-material folder). Manually-renamed files are acknowledged: the app scans for any `*_project.yaml` in the folder, preferring the canonical name, falling back to legacy `_project.yaml`, then any single `*_project.yaml` match. Writing uses the same acknowledgment logic
- **Preset file naming** — priming preset files are now named `<folderName>_priming_preset.yaml` (e.g. `Convivium_priming_preset.yaml`). Legacy `_priming_presets.yaml` and manual renames (`*_priming_preset.yaml`) are read as fallbacks
- **Subfolder material tree** — a folder tree walks subdirectories (depth-limited), detecting material files (subtitles, transcripts, chapters, synopses) and showing badges per folder (sub/tr/ch/syn). Refreshes on folder add/remove/rescan/clear
- **Folder tree on every tab (green/red project indicator)** — the **Materials** tree lives in the right column of the shared project bar on all four folder tabs: Project Setup, Timeline Assist, Transcript Intelligence, and AI Edit. Every row shows a **film icon colored green** when that folder carries a valid project file (`<name>_project.yaml`), **red** when missing, plus a red "no project" badge. Roots stay visible; the **subfolders** toggle expands deeper nesting. Each tab builds its own tree from its own folders
- **Timeline Assist "Create Synopsis" (multi-folder)** — with multiple work folders open, per-timeline chapters are unavailable, so the Process button reads **Create Synopsis…** and only synopses are generated (chapters skipped). Single-folder projects keep the full "Create Chapters and Synopsis" behavior

## v1.23 Changes (Structured AI Edit Editor)

- **Structured-first editor** — AI Edit's left panel is now a beat-card list instead of one large text window. Each card authors title, description, mood, target duration, and search-query chips in place, with per-beat find, move/delete, and an expandable editor. The free-text window became a collapsible **Treatment** drawer above the cards.
- **Auto-fill from text** — the Treatment drawer's **Auto-fill from text** button runs the old Parse Script LLM step to populate empty beats when you'd rather paste prose and let the AI structure it. Beats remain fully editable afterward — nothing is locked to the model's output.
- **Create Edit** — the primary button (renamed from Create Beats) now runs Find Clips across all authored beats directly; you no longer need to parse text first.
- **Backward compatible** — existing sessions (`script` + beats in `aiEditSessionJSON`) load unchanged; the treatment text is preserved as the auto-fill source.
- **Sync by Transcript removed** — the sync tab is dropped from this release (feature parked while re-evaluated; source + Python scripts remain in the repo for later restoration). If a saved tab order or selection still references it, `migrateTabNames()` and the tab bar filter it out on launch. Four tabs remain: Project Setup, AI Edit, Timeline Assist, Transcript Intelligence.

## v1.19 Changes

- **Subtitle-only chapter creation** — Create Chapters and Synopsis works from subtitles alone (no transcript needed). A paired transcript is optional enrichment, never a requirement
- **Blank-line-after-timecode tolerance** — DaVinci/Resolve SRT exports that put a blank line between the timecode and its text now parse correctly (cues grouped by timecode line, not blank-line blocks). Verified: a `.srtx` with no speaker line → 1929 cues, 34 keyword chapters
- **Startup robustness** — Source Material scans at launch (restored in the single-column rewrite); analysis restores even when `_project.yaml` lives in a parent of the stored folder or in a now-removed location
- **Versioned snapshot** — `dist/v1.19/` holds the pre-robustness-fix backup

## v1.18 Changes

- **Tab renamed: Source Material → Project Setup** — user-facing name changed everywhere (internal `SourceMaterialTab` struct and the persisted tab key stay; `migrateTabNames()` handles the change on launch). Purists: the AGENTS.md still references the old name internally in a few spots
- **Plural transcript files** — `_transcripts.txt` (plural) is accepted everywhere `_transcript.txt` is, on both the Swift and Python sides: subtitle pairing, processing (process_srt.py / create_timeline.py), sync scripts, and project analysis flag detection

## v1.17 Changes

- **Timeline Assist harmonization & folder-unification round** — canonical title → folder bar → content row on every tab; multi-select folder pickers; Clear All confirmation everywhere; TL asset queue removed (process all discovered files); Create Chapters and Synopsis button
- **Transcript DB race fixed** — `SearchDatabase.open()` mutates its handle inside its own queue; searches return `[]` while the transcript index rebuilds; transcript loaders unconditionally clear `-wal`/`-shm` before opening

## v1.16 Changes

- **Nine critical fixes from a full app audit** (~85 findings logged): self-healing subtitle caches (stale fingerprints no longer brick a tab), AI Edit cancellation integrity, timeline SRTX captions per clip, Source Material now reads frame-based SRTX timecodes, Sync Export EDL actually saves (crash fixed + save dialog), beat-span markers aligned with gaps, Model Manager update-check works for namespaced models, Sync build status shows real results
- **ESC cancels AI work** app-wide — chat answers, Parse Script / Find Clips / Review Flow, and Python pipelines — without swallowing dialogs

## v1.24 Changes

- **Unified project bar on every tab** (`Source Folder(s) | Materials` three-row grid) — the folder loader and the Materials tree merged into one compact bar: row 1 section labels, row 2 the add/rescan/clear actions with the tab's status caption inline next to the materials totals, row 3 the folder chips beside a `subfolders ▾` toggle that opens the material tree on demand. A thin fixed divider separates the columns and one divider sits below the bar. The bar stays ~71pt collapsed no matter how much material is loaded (in v1.24.7 the divider used to stretch the whole bar several-fold taller — now a fixed-height hairline)
- **Materials tree owns material identification** — per-folder green/red project-file film dots and sub/tr/ch/syn/tl badges stay visible even when the subfolder tree is collapsed; the **`N tl`** badge acknowledges saved edits next to chapters/synopses
- **AI Edit panels renamed Script Beats / Timeline Beats** — the left panel (Script Beats) authors beats, with a big **Add Beat** CTA and **Auto-fill from Text** in its empty state; the right panel (Timeline Beats) shows each beat as a timeline cell with a passive "each beat you author on the left appears here" hint when empty. The footer **+ Add Beat / Remove all** (bigger buttons) appears only once beats exist
- **Undo/redo buttons removed** from the beat footer (the snapshot-based undo stacks remain internally for Auto-fill as a single Undo point)
- **Save / Load an edit** — `square.and.arrow.down` writes the whole session (name, timestamp flag, estimated seconds, intent, treatment, beats, clip results) to `<timeline name>_timeline.yaml` in the first work folder; `square.and.arrow.up` lists saved edits (or **Open…**) and replaces the session after confirmation
- **Timeline metadata block** above the Treatment drawer — timeline name, editable estimated seconds, "Append timestamp (_HHMMSS)" checkbox, and a multiline **Intent** field
- **Project Setup decluttered** — the full-width Analyze band is gone: **Analyze / Regenerate Themes** lives in the Weighing header (spinner + thin progress strip underneath), and the pre-analysis empty state has its own **Analyze** button
- **Single title on every tab** — the per-tab headings that repeated the tab name under the description are gone; each tab starts directly with its project bar
- **AI Edit header simplified** — material counts removed (the project bar owns them); the header keeps Save / Load / rescan / clear-session only
- **Empty-beats start buttons** — when no script beats exist, the Script Beats panel shows a large, centered **Add Beat** button right under the description, plus **Auto-fill from Text**
- **Chapter density meter & split verbosity** — Timeline Assist gains a Chapter density slider, plus separate Chapters / Synopsis verbosity sliders (shown per enabled output) under a "Usage" caption
- **Add beat always at hand** — the footer add / remove-all row stays reachable without opening the Treatment drawer

## v1.15 Changes

- **Unified folder ingest** — identical title → folder bar → content structure on all five tabs; multi-select pickers; Clear All confirmation everywhere; icon-led bar (＋ ↻ 🗑)
- **Source Material redesigned** — single column; interviews table removed; stats as one caption + speaker mini-bars under the Weighing title; themes shown once with inline weight bars in their slider rows; **Reset Weighing** with persisted baseline (`.project_original.json`)
- **Slider balance memory** — pushing a slider to an extreme no longer permanently crushes the others: return it to its origin and the exact pre-drag balance is restored, even after restart
- **Automatic startup scan** — every tab reads its stored folders and materials on launch; **↻** forces a full re-read
- **Timeline Assist** — asset queue removed (all discovered files process); button renamed **Create Chapters and Synopsis**
