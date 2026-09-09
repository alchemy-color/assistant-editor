# LLM Backend

Every AI step in Assistant Editor runs **locally**. There is no cloud endpoint. The design req: the UI layer, the Python scripts, and whatever server is chosen all speak **OpenAI-compatible** JSON.

---

## 1. The LLM backend

### oMLX (the only macOS backend)
- Base URL `http://localhost:8000`, OpenAI-compatible API (`/v1/models`, `/v1/chat/completions`).
- Default model: `Llama-3.1-8B-Instruct-4bit`.
- Config surfaced in the app: `omlxBaseURL`, `omlxAPIKey`, `selectedModel` (UserDefaults), plus the bottom-bar **Server Setup…** sheet (URL + API key + Test Connection).
- oMLX caches models in memory between requests, so the old Ollama dials (`keep_alive`, `num_ctx`) are absent — and `think`/`num_ctx` have no oMLX equivalent and are deliberately dropped from the client.

> A port to Linux/Windows can point the same OpenAI `/v1` contract at Ollama or a llama.cpp/vLLM server by changing the base URL in config. The OpenAI `/v1` shape is invariant; see the porting guides.

---

## 2. How scripts reach the server

`PythonBridge` (Swift) injects into **every** subprocess invocation:
- `OMLX_BASE_URL` (from app config; default `http://localhost:8000`)
- `OMLX_API_KEY`
- `OLLAMA_BASE` (legacy alias, set to the same value as `OMLX_BASE_URL`)

`process_srt.py`/`analyze_project.py` read these env vars and call `{OMLX_BASE_URL}/v1/chat/completions` (and `/v1/models` for health checks). **This is why the port guides stress passing these env vars explicitly** — Windows/Linux subprocesses don't inherit a macOS shell profile.

A port should keep the same env-var contract so the scripts never need a code change.

---

## 3. Call profile (Swift side OMLXClient)

- Endpoint: `POST {base}/v1/chat/completions`.
- Messages: `system` + `user` (RAG context block + instructions).
- Common fields:
  - `model`: current `selectedModel`.
  - `temperature`: 0.2–0.4 for structured steps (Find Clips 0.2, Review/Parse lower), 0.4 for summaries, 0.3 for chat.
  - `max_tokens`: 2048–4096 by step.
  - `stream: false`.
  - Reasoning-capable models: client-side `stripThinkBlocks` (cuts at last ` response`, removes leftover `thinking` pairs — tolerates partial blocks). No `think: false` flag is sent.
- **Grammar-constrained outputs:** Parse Script, Find Clips, Review Flow send `response_format: json_schema` (schema for beats, clip selections, flow notes). Malformed JSON is then nearly impossible; a `repairJSON()` fallback + validated first-{…}-last-} slice still guard the older paths.
- Error handling: empty 200-responses = model still loading mid-call (distinct message); timeouts per-step (600s parse, etc.).

---

## 4. The nine prompts (stages)

The app exposes each as an independently editable "priming" prompt in the Priming window. Exactly what the window shows is what the model receives. A port must keep 9 prompts and the same "Fires when" mapping:

| Key | Fires when | Notes |
|---|---|---|
| `priming_projectAnalysis` | Project Setup → Analyze/Regenerate (→ analyze_project.py via `--priming-prompt-file`) | themes/keywords/weights extraction |
| `priming_chaptersSynopsis` | processing interviews (→ process_srt.py via `--priming-prompt-file`) | chapter names/notes + synopsis prose |
| `priming_searchInterpretation` | Timeline Assist prompt-bar Send (oMLX system) | query → search terms |
| `priming_transcriptChat` | Transcript Intelligence chat (prepended to context block) | RAG answer style, grounding, timecodes |
| `priming_promptSort` | Prompt Sort option (oMLX system) | narrative reorder of results |
| `priming_scriptParsing` | AI Edit Auto-fill from text (prompt head) | script → beats (searchQueries/targetDuration/mood); camera/imagined visuals forbidden; queries are topic phrases likely in speech |
| `priming_clipSelection` | AI Edit Find Clips | candidates listed verbatim (interview·timecode·speaker·200 chars) + per-interview synopsis excerpts; picks ≤N with reasons (schema-constrained) |
| `priming_flowReview` | AI Edit Review Flow | script prefix + included clips grouped by beat; severity warning/info; language judgment only, no timecode math |
| `priming_youtubeSummary` | Generate Summary (YouTube sheet) | `{LENGTH}` placeholder → Short/Medium/Long instruction |

Preset management: named presets in `<folderName>_priming_preset.yaml` (see FILE_FORMATS), `_priming_presets.yaml` legacy, `Factory` = remove all 9 keys.

---

## 5. Schema-constrained output shapes (must keep JSON stable)

### Parse Script → beats
```json
[ {"title": "...", "description": "...", "searchQueries": ["..."],
   "targetDuration": 45, "mood": "..."} ]
```

### Find Clips → selections
```json
{ "selections": [ {"index": 0, "reason": "..."} ] }
```
Indexes reference the verbatim candidate list order.

### Review Flow → notes
```json
[ {"beatIndex": 0, "severity": "warning|info", "message": "..."} ]
```
`beatIndex` nullable.

### YouTube summary → prose text (no schema).

---

## 6. RAG context composition (chat)

Transcript Intelligence chat context = **KnowledgeStore summaries** (pre-computed per-interview: synopsis, topic breakdown, centroid quotes) **+ FTS5 hits** (up to 20 subtitle/transcript hits with timecode, speaker, interview name). Grounding is verificable: answers cite timecodes. A port must reproduce this context shape (`system` prompt summary block + `user` pinned hits) or the chat answers will hallucinate.

---

## 7. Failure/degradation contract

- If the LLM is unavailable, `process_srt.py` degrades to **keyword-frequency chapter detection** + notes fallback and sets `out["warning"] = "LLM unavailable — keyword fallback"` (+ `DEGRADED_REASON`); the UI turns the status orange. **Do not** make chapter generation hard-fail on LLM absence.
- `analyze_project.py` likewise falls back to keyword-frequency themes (producing exact fractions like `7/28` — a signature of fallback mode).
- The app shows an orange "model not loaded" banner and a red "oMLX server not reachable" banner, both pointing at **Server Setup…** in the bottom bar. There is no server auto-start: if the oMLX server is down, the keyword fallback kicks in until the user launches oMLX.