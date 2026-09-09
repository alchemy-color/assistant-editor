# File Formats

Format stability is a hard requirement — **never change these** unless you bump the project version and migrate. Both the macOS app and every downstream tool (YouTube marker export, EDL export, sync, Resolve build) depend on them.

---

## 1. Subtitle formats (input)

### Standard SRT
```
1
00:00:00,000 --> 00:00:03,120
Hello world.
```
- Index line, timecode line (`HH:MM:SS,mmm --> HH:MM:SS,mmm`), text line(s), blank line.
- **Blank-line-after-timecode tolerance (v1.18):** some Resolve exports put a blank line between the timecode and its text. Every parser (Swift `parseSRT`/`parseFrameSRT`, Python `parse_srt`/`parse_srt_text`) groups cues **line-by-line** off the timecode/index line instead of `re.split(r"\n\n+")` — a stray blank line must not orphan the timecode from its text (that previously returned 0 cues).

### SRTX (frame-based, input)
```
[00:00:00:00 - 00:00:03:10]
Speaker Name
Text of the subtitle
```
- `[hh:mm:ss:ff - hh:mm:ss:ff]` bracketed frame timecodes (ff = frames @ the file's fps).
- **3-line layout** (timecode, speaker, text) = transcript format.
- **4+-line layout** (timecode, blank, speaker, text) = subtitle format; speaker on line 3.

### TXT (frame-based, input)
- Same `[hh:mm:ss:ff]` timecode style as SRTX, accepted as subtitles.
- Paired transcript: `_transcript.txt` **or** `_transcripts.txt` (plural accepted everywhere) — paragraph-level Resolve transcript export.
- When a transcript has **no** paired `_subtitles` sibling, the transcript itself is used as source content; subtitles remain the baseline fallback.

### Output SRTX (timeline creation)
Standard SRT millisecond timecodes (`HH:MM:SS,mmm`), speaker on its own line, text with leading space — matches Resolve's export format, human-readable, frame-independent.

---

## 2. `_chapters.yaml` (per-interview, written by `process_srt.py`)
Written with `yaml.safe_dump(..., default_flow_style=False, allow_unicode=True, sort_keys=False)`:
```yaml
title: Interview Title
location: Location / person
date: '2026-08-26'
duration_seconds: 1234.5
speakers:
- Speaker A
- Speaker B
markers:
- id: 1
  start_s: 12.3
  end_s: 57.5
  name: Chapter Title
  theme: Wine            # dynamic theme name, if any
  color: Tan             # theme color
  notes: Notes / context for the editor
- ...
```
- Chapter keys: `id` (1-based), `start_s`, `end_s`, `name`, `theme`, `color`, `notes`.
- Marker structs (`SummaryMarker`) mirror `{id, name, notes, start_s, end_s, theme, color}`.
- Written **atomically** (temp + `os.replace` + `os.fsync`).

---

## 3. `_synopsis.txt` (per-interview, written by `process_srt.py`)
```
INTERVIEW: <title> (<total duration>)
DATE: <date>

## Intro
20–30 sentences / 500–800 words per subject at max verbosity.

## Paragraphs
...

## Bullets
- ...

## Timecode
[00:12:34:01] Key moment
```
Section toggles: Intro, Paragraphs, Bullets, Timecode. Written atomically.

---

## 4. `<folderName>_project.yaml` (project analysis, written by `analyze_project.py`)
Canonical name = `<folderName>_project.yaml` (e.g. `Bairrada_project.yaml` for a root, `07-03_Carlos Campolargo_project.yaml` for a single-material folder). Written by hand-formatted YAML (all strings via `yaml_quote`):
```yaml
version: 1

folders:
  - path: "/path/to/root"
    interviews:
      - title: "Interview Title"
        excluded: false
        hasSubtitles: true
        hasTranscript: true

themes:
  - name: "Wine"
    keywords: ["terroir", "harvest", "vineyard"]
    weight: 0.44
    color: "Blue"

stats:
  totalInterviews: 12
  totalDurationS: 72045.3
  totalCues: 18320
  speakers:
    - name: "Speaker A"
      cueCount: 4210
  frequentWords:
    - ["wine", 128]
```
Resolution rules (all sides — Swift `findProjectYaml`, Python globs):
1. Canonical `<folderName>_project.yaml`.
2. **Any single** `*_project.yaml` match in the folder (acknowledges manual renames).
3. Legacy `_project.yaml` fallback.

`nearestProjectYamlFolder(for:)` walks ≤4 ancestors doing the same suffix match.
`weight` values live between 0–1 and sum to 1.0; LLM-fallback mode produces exact fractions (e.g. `0.25`) and may be `0.44`-style floats.

The Swift `ProjectAnalysis` model is the richer decoded form (adds `durationS`, `cueCount`, `speakers`, `hasChapters`/`hasSynopsis` per interview).**Lossy fields** (`hasChapters`/`hasSynopsis`/counts) are restored by `refreshMaterialFlags()`, a FileManager-only companion-file check (`<base>_chapters.yaml`, `<base>_synopsis.txt`, `_transcript.txt`) run after load.

### Weighing sidecar
`.project_original.json` sits next to `_project.yaml` and holds the pristine post-analyze balance (`{themename: weight}`). Written only on analysis; **Reset Weighing** prefers it over session values.

---

## 5. `<folderName>_priming_preset.yaml` (named LLM prompt presets)
```yaml
presets:
- name: MyProject
  basedOn: Factory
  stages:
        priming_projectAnalysis: |...
        priming_clipSelection: |...
```
- 8-space block scalars; stage keys = the `priming_*` UserDefaults keys.
- Canonical name `<folderName>_priming_preset.yaml`; legacy `_priming_presets.yaml` and any single `*_priming_preset.yaml` read as fallbacks.

---

## 6. YAML escaping rules (must match exactly)

`ProjectAnalysis` escapes `\`, `"`, `\n`, `\r`, `\t` plus control chars in every string interpolation (`yamlEscaped`/`unescapeYAML`); the parser normalizes CRLF/CR → `\n`. Titles, paths, and keywords are always quoted/escaped on write. **A port must reproduce this escaping or `_project.yaml` round-trips will corrupt.**

---

## 7. Database files (SQLite FTS5)

- `assistanteditor_<tabtag>_<folder>.db` (tabtags `tl`, `ti`, `ai`, `app`) in the Caches dir.
- Tables: `subtitle_entries` + `subtitle_fts`; `transcript_entries` + `transcript_fts`; each entry carries an embedding BLOB column; metadata table stores cache fingerprint + entry count.
- Fingerprints gate rebuilds: a stale `-wal`/`-shm` set is cleared before every open.
- Pure SQLite file — identical cross-platform.

---

## 8. Knowledge base JSON
`assistanteditor_knowledge_<folder>.json` — envelope `{folder, stamp}` where `stamp` is derived from `(docCount|markers|cues)`; must match or rebuild. Contents: per-interview synopsis, topic breakdown (theme → markers), centroid key quotes (embedding-derived).