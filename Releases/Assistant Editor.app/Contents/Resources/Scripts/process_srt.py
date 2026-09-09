#!/usr/bin/env python3
"""Read an SRT file and generate _chapters.yaml + _synopsis.txt.

Uses Ollama (local LLM) when available, falls back to keyword heuristics.

Usage:
  process_srt.py <srt_path>
  process_srt.py --check-ollama   # returns JSON with ollama status

Output: writes {date}_{name}_chapters.yaml and {date}_{name}_synopsis.txt
in the same directory as the SRT file.
"""
import sys, os, re, json, yaml, time, urllib.request, urllib.error, tempfile
from collections import Counter

# oMLX server (OpenAI-compatible). Env is injected by PythonBridge from the
# app's UserDefaults — base URL + API key stay in sync with the Swift UI.
OMLX_BASE = os.environ.get("OMLX_BASE_URL", "http://localhost:8000").rstrip("/")
OMLX_API_KEY = os.environ.get("OMLX_API_KEY", "")
# Legacy names kept as aliases so the rest of the file need not change.
OLLAMA_BASE = OMLX_BASE
OLLAMA_TIMEOUT = 5  # quick check
GENERATE_TIMEOUT = 600  # long timeout for generation

THEME_KEYWORDS = {
    "Project / Logistics": [
        "project", "logistics", "plan", "schedule", "team", "budget", "permit",
        "construction", "building", "workshop", "tasting", "event",
        "collaboration", "partnership", "timeline", "deadline", "milestone",
    ],
    "Food / Gastronomy": [
        "food", "gastronomy", "recipe", "cooking", "restaurant", "kitchen",
        "meal", "dish", "ingredient", "flavor", "taste", "eat", "dinner",
        "lunch", "breakfast", "cuisine", "chef", "menu", "traditional",
        "preserva", "conserva", "charcuterie", "cheese", "bread", "olive",
    ],
    "Landscape / Terroir": [
        "landscape", "terroir", "soil", "climate", "geography", "valley",
        "mountain", "river", "ocean", "atlantic", "altitude", "elevation",
        "geology", "limestone", "clay", "sandstone", "slope", "hill",
        "microclimate", "exposure",
    ],
    "Winemaking / Cellar": [
        "winemaking", "cellar", "fermentation", "barrel", "aging", "oak",
        "cask", "bottle", "wine", "red wine", "white wine", "sparkling",
        "dosage", "malolactic", "press", "racking", "blending", "cuvee",
        "reserve", "vintage", "tank", "stainless", "concrete", "amphora",
    ],
    "Viticulture": [
        "viticulture", "vineyard", "grape", "pruning", "harvest", "vine",
        "vine age", "planting", "rootstock", "clone", "variety", "bical",
        "baga", "pinot", "chardonnay", "merlot", "cabernet", "syrah",
        "yields", "canopy", "cover crop",
    ],
    "Market / Industry": [
        "market", "industry", "sales", "distribution", "export", "import",
        "price", "cost", "revenue", "customer", "brand", "label",
        "competition", "retail", "wholesale", "margin", "volume", "demand",
    ],
    "Climate Change": [
        "climate", "change", "global warming", "sustainability", "organic",
        "biodynamic", "natural wine", "solar", "temperature", "rain", "drought",
        "harvest date", "adaptation", "resilience", "carbon", "footprint",
    ],
}

THEME_COLORS = {
    "Project / Logistics": "Tan",
    "Food / Gastronomy": "Orange",
    "Landscape / Terroir": "Cyan",
    "Winemaking / Cellar": "Mint",
    "Viticulture": "Green",
    "Market / Industry": "Rose",
    "Climate Change": "Lemon",
}

VALID_THEMES = set(THEME_COLORS.keys())

# Dynamic themes loaded from stdin (overrides hardcoded)
DYNAMIC_THEMES = []

# ─── Ollama API ──────────────────────────────────────────────────────────────

# ─── Globals ───────────────────────────────────────────────────────────────────
PRIMING_PROMPT = ""


DEGRADED_REASON = None


def _omlx_headers():
    h = {"Content-Type": "application/json"}
    if OMLX_API_KEY:
        h["Authorization"] = f"Bearer {OMLX_API_KEY}"
    return h


def ollama_request(path, data=None, timeout=OLLAMA_TIMEOUT):
    """Make a request to the oMLX (OpenAI-compatible) server.

    Kept under the old name so call sites need not change; `path` is expected
    to be an oMLX path such as /v1/models or /v1/chat/completions.
    """
    url = f"{OMLX_BASE}{path}"
    body = None
    if data is not None:
        body = json.dumps(data).encode()
    global DEGRADED_REASON
    try:
        req = urllib.request.Request(url, data=body, headers=_omlx_headers())
        # GET when body is None, POST otherwise
        if body is not None:
            req.method = "POST"
        resp = urllib.request.urlopen(req, timeout=timeout)
        return json.loads(resp.read().decode())
    except Exception as e:
        msg = str(e) or e.__class__.__name__
        if DEGRADED_REASON is None or timeout == GENERATE_TIMEOUT:
            DEGRADED_REASON = f"oMLX request failed ({msg})"
        return None


def check_ollama():
    """Check if oMLX is running and return available models."""
    data = ollama_request("/v1/models", timeout=OLLAMA_TIMEOUT)
    if not data or "data" not in data:
        return {"running": False, "models": [], "selected": None}
    models = [m["id"] for m in data["data"] if "id" in m]
    if not models:
        return {"running": False, "models": [], "selected": None}
    # Prefer the model the app has selected (passed via --model or env), else first
    preferred = ["qwen3", "qwq", "gemma", "llama", "mistral", "phi3"]
    selected = None
    for p in preferred:
        for m in models:
            if m.lower().startswith(p):
                selected = m
                break
        if selected:
            break
    if not selected and models:
        selected = models[0]
    return {"running": True, "models": models, "selected": selected}


def ollama_generate(model, prompt, system=None, timeout=GENERATE_TIMEOUT, max_tokens=512):
    """Generate text via oMLX OpenAI-compatible chat completions."""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    data = {
        "model": model,
        "messages": messages,
        "temperature": 0.3,
        "max_tokens": max_tokens,
        "stream": False,
    }
    result = ollama_request("/v1/chat/completions", data, timeout=timeout)
    if result and "choices" in result and result["choices"]:
        try:
            return result["choices"][0]["message"]["content"].strip()
        except Exception:
            pass
    return None

# ─── SRT Parsing ─────────────────────────────────────────────────────────────

def parse_srt(path, fps=25.0):
    """Parse SRT/SRTX into list of (speaker, text, start_s, end_s).

    Supports standard SRT (00:00:00,000 --> 00:00:03,120), frame-based SRTX
    ([hh:mm:ss:ff - hh:mm:ss:ff]), and the DaVinci export style that puts a
    blank line between the timecode and its text. Cues are grouped by their
    timecode line instead of by blank-line separation, so missing/inconsistent
    blank lines never split (or merge) individual cues.
    """
    with open(path, encoding="utf-8") as f:
        content = f.read()

    is_srtx = path.endswith(".srtx") or path.endswith(".txt")
    cues = []

    # Standard SRT with arrow
    std_re = re.compile(
        r"(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)"
    )
    # Frame-based format: [hh:mm:ss:ff - hh:mm:ss:ff]
    frame_re = re.compile(
        r"\[(\d+):(\d+):(\d+):(\d+)\s*-\s*(\d+):(\d+):(\d+):(\d+)\]"
    )

    FPS = max(1.0, float(fps))

    def flush(cur_tc, cur_lines):
        start, end = cur_tc
        lines = [l.strip() for l in cur_lines if l.strip()]
        if not lines:
            return None
        if is_srtx and len(lines) >= 2:
            speaker = lines[0]
            text = " ".join(lines[1:]).strip()
        elif len(lines) >= 1:
            speaker = ""
            text = " ".join(lines).strip()
            text = re.sub(r"</?b>", "", text)
        else:
            return None
        if text:
            return (speaker, text, start, end)
        return None

    cur_tc = None
    cur_lines = []
    for raw in content.splitlines():
        line = raw.strip()

        m = std_re.search(line)
        if m:
            if cur_tc is not None:
                c = flush(cur_tc, cur_lines)
                if c is not None:
                    cues.append(c)
            h1 = int(m[1]); m1 = int(m[2]); s1 = int(m[3]); ms1 = int(m[4])
            h2 = int(m[5]); m2 = int(m[6]); s2 = int(m[7]); ms2 = int(m[8])
            cur_tc = (h1 * 3600 + m1 * 60 + s1 + ms1 / 1000,
                      h2 * 3600 + m2 * 60 + s2 + ms2 / 1000)
            cur_lines = []
            continue

        f = frame_re.search(line)
        if f:
            if cur_tc is not None:
                c = flush(cur_tc, cur_lines)
                if c is not None:
                    cues.append(c)
            h1 = int(f[1]); m1 = int(f[2]); s1 = int(f[3]); frm1 = int(f[4])
            h2 = int(f[5]); m2 = int(f[6]); s2 = int(f[7]); frm2 = int(f[8])
            cur_tc = (h1 * 3600 + m1 * 60 + s1 + frm1 / FPS,
                      h2 * 3600 + m2 * 60 + s2 + frm2 / FPS)
            cur_lines = []
            continue

        if re.fullmatch(r"\d+", line):
            # Standalone cue index. If we already have content, this is the
            # next cue's index -> flush. Otherwise it's the current cue's index.
            if cur_lines:
                c = flush(cur_tc, cur_lines)
                if c is not None:
                    cues.append(c)
                cur_tc = None
                cur_lines = []
            continue

        if line == "":
            continue

        # Content line. Ignore text that appears before any timecode (header).
        if cur_tc is None:
            continue
        cur_lines.append(line)

    if cur_tc is not None:
        c = flush(cur_tc, cur_lines)
        if c is not None:
            cues.append(c)

    return cues


def merge_cues(cues, gap=2.0):
    """Merge consecutive cues from same speaker within gap seconds."""
    if not cues:
        return []
    merged = []
    cur_speaker, cur_text, cur_start, cur_end = cues[0]

    for speaker, text, start, end in cues[1:]:
        same_speaker = speaker and speaker == cur_speaker
        gap_ok = 0 <= start - cur_end <= gap
        if same_speaker and gap_ok:
            cur_text += " " + text
            cur_end = end
        else:
            merged.append((cur_speaker, cur_text, cur_start, cur_end))
            cur_speaker, cur_text, cur_start, cur_end = speaker, text, start, end

    merged.append((cur_speaker, cur_text, cur_start, cur_end))
    return [(s, t, st, e) for s, t, st, e in merged if t.strip()]


def infer_info(srt_path):
    """Infer date, name, and location from SRT path."""
    filename = os.path.basename(srt_path)
    name = re.sub(r"\.(srtx?|txt)$", "", filename)
    name = re.sub(r"_subtitles$", "", name)
    name = re.sub(r"_(?:transcript|transcripts)$", "", name)
    name = re.sub(r"_rough$", "", name)

    m = re.match(r"(\d{2}-\d{2})_(.+)", name)
    if m:
        date = m.group(1)
        person = m.group(2).replace("_", " ")
    else:
        date = ""
        person = name.replace("_", " ")

    parent = os.path.basename(os.path.dirname(srt_path))
    location = {"bairrada": "Bairrada", "belgium": "Belgium"}.get(parent.lower(), parent)

    return date, person, location


def extract_speakers(cues):
    """Extract unique speaker names from cues."""
    speakers = set()
    for speaker, _, _, _ in cues:
        if speaker:
            speakers.add(speaker)
    return sorted(speakers)

# ─── Keyword-based fallback ──────────────────────────────────────────────────

def get_theme_keywords(text):
    text_lower = text.lower()
    matched = []
    # Use dynamic themes if available
    if DYNAMIC_THEMES:
        for theme in DYNAMIC_THEMES:
            for kw in theme.get("keywords", []):
                if kw.lower() in text_lower:
                    matched.append(theme["name"])
                    break
    else:
        for theme, keywords in THEME_KEYWORDS.items():
            for kw in keywords:
                if kw in text_lower:
                    matched.append(theme)
                    break
    return matched


def detect_chapters_keyword(merged, density=0.5):
    """Split into chapters using keyword shifts and time gaps.

    density controls chapter granularity:
      0.0 → very few chapters (min_dur=300s, forced_break=600s)
      0.5 → balanced (min_dur=120s, forced_break=300s) [default]
      1.0 → many chapters (min_dur=60s, forced_break=120s)
    """
    if not merged:
        return []
    min_dur = 300 - density * 240    # 300 at 0.0, 60 at 1.0
    forced_break = 600 - density * 480  # 600 at 0.0, 120 at 1.0
    chapters = []
    cur = [merged[0]]
    for i in range(1, len(merged)):
        prev_t = merged[i - 1][1].lower()
        curr_t = merged[i][1].lower()
        gap = merged[i][2] - merged[i - 1][3]
        prev_kw = set(get_theme_keywords(prev_t))
        curr_kw = set(get_theme_keywords(curr_t))
        kw_shift = len(prev_kw.symmetric_difference(curr_kw)) >= 2
        ch_dur = cur[-1][3] - cur[0][2]
        if (kw_shift and ch_dur >= min_dur) or (gap > 5.0 and ch_dur >= min_dur) or ch_dur >= forced_break:
            chapters.append(cur)
            cur = [merged[i]]
        else:
            cur.append(merged[i])
    chapters.append(cur)
    return chapters


def assign_theme_keyword(cues_in_chapter):
    counts = Counter()
    for _, text, _, _ in cues_in_chapter:
        for t in get_theme_keywords(text):
            counts[t] += 1
    if counts:
        return counts.most_common(1)[0][0]
    if DYNAMIC_THEMES:
        return DYNAMIC_THEMES[0]["name"]
    return "Project / Logistics"


def build_notes_fallback(cues_in_chapter):
    """Extract informative phrases from chapter text as fallback notes."""
    all_text = " ".join(t for _, t, _, _ in cues_in_chapter)

    # Find capitalized named entities (people, places, specific terms)
    proper = re.findall(r'\b([A-Z][a-z]+(?:\s[A-Z][a-z]+){0,2})', all_text)
    stop_proper = {"What", "When", "Where", "Which", "There", "Here", "This",
                   "That", "They", "Them", "She", "He", "Have", "With", "From"}
    proper = [p for p in proper if p not in stop_proper and len(p) > 4]

    # Find "X of Y" constructions
    of_phrases = re.findall(r'\b([a-z]{4,})\s+of\s+the\s+([a-z]{4,})', all_text.lower())
    of_parts = []
    for a, b in of_phrases:
        of_parts.extend([a, b])

    # Find adjective-noun and noun-noun bigrams where at least one word
    # is in a theme keyword list (these are likely topical)
    words = re.findall(r'\b([a-zA-Z]{4,})\b', all_text)
    stop_words = {"yeah", "like", "just", "well", "really", "actually", "okay",
                  "gonna", "wanna", "thing", "stuff", "little", "because",
                  "about", "which", "there", "going", "into", "could", "would",
                  "should", "think", "maybe", "also", "even", "much", "many",
                  "some", "then", "that", "this", "with", "from", "they",
                  "them", "what", "when", "where", "very", "been", "every",
                  "make", "made", "know", "said", "say", "way", "kind", "lot",
                  "sort", "thing", "stuff", "need", "take", "look", "come"}

    # Collect informative phrases: proper nouns first, then key bigrams
    parts = []
    seen = set()
    for p in proper:
        if p.lower() not in seen:
            parts.append(p)
            seen.add(p.lower())

    # Add meaningful non-overlapping bigrams
    key_bigrams = []
    i = 0
    while i < len(words) - 1:
        w1, w2 = words[i].lower(), words[i+1].lower()
        if w1 not in stop_words and w2 not in stop_words:
            key_bigrams.append(f"{words[i]} {words[i+1]}")
            i += 2
        else:
            i += 1

    for bg in key_bigrams:
        if bg.lower() not in seen and len(parts) < 5:
            parts.append(bg)
            seen.add(bg.lower())

    # Fill remaining from "of" phrases
    for p in of_parts:
        if p not in seen and len(parts) < 5:
            parts.append(p)
            seen.add(p)

    if parts:
        return "; ".join(parts[:5])

    # Ultra fallback: first sentence
    sents = re.split(r'(?<=[.!?])\s+', all_text)
    if sents:
        return sents[0].strip()[:120]
    return ""


def build_name_keyword(theme, cues_in_chapter):
    all_text = " ".join(t for _, t, _, _ in cues_in_chapter).lower()

    # Use dynamic theme suffixes if available
    if DYNAMIC_THEMES:
        for t in DYNAMIC_THEMES:
            if t["name"] == theme:
                kws = t.get("keywords", [])
                for s in kws[:3]:
                    if s.lower() in all_text:
                        return f"{theme}: {s}"
                return f"{theme}: {kws[0]}" if kws else f"{theme}: Discussion"
    else:
        suffixes = {
            "Project / Logistics": ["Opening", "Planning", "Organization"],
            "Food / Gastronomy": ["Food Traditions", "Cuisine", "Recipes"],
            "Landscape / Terroir": ["Terroir", "Landscape", "Geography"],
            "Winemaking / Cellar": ["Winemaking", "Cellar Work", "Production"],
            "Viticulture": ["Vineyard", "Vines", "Growing"],
            "Market / Industry": ["Market", "Industry", "Business"],
            "Climate Change": ["Climate", "Weather", "Sustainability"],
        }.get(theme, ["Discussion"])
        for s in suffixes:
            if s.lower() in all_text:
                return f"{theme}: {s}"
        return f"{theme}: {suffixes[0]}"
    return f"{theme}: Discussion"


def process_keyword(merged, date, person, location, title, density=0.5):
    """Full keyword-based processing."""
    raw_ch = detect_chapters_keyword(merged, density=density)
    chapters = []
    for i, ch in enumerate(raw_ch):
        theme = assign_theme_keyword(ch)
        color = "Tan"
        if DYNAMIC_THEMES:
            for t in DYNAMIC_THEMES:
                if t["name"] == theme:
                    color = t.get("color", "Tan")
                    break
        else:
            color = THEME_COLORS.get(theme, "Tan")
        chapters.append({
            "id": i + 1,
            "start_s": round(ch[0][2], 2),
            "end_s": round(ch[-1][3], 2),
            "name": build_name_keyword(theme, ch),
            "theme": theme,
            "color": color,
            "notes": build_notes_fallback(ch),
        })
    return chapters

# ─── LLM-based synopsis ──────────────────────────────────────────────────────

def build_compact_transcript(merged, max_chars=30000):
    """Build a compact transcript summary, truncating to fit context."""
    lines = []
    total = 0
    for i, (speaker, text, start_s, end_s) in enumerate(merged):
        tag = f"[{speaker}]" if speaker else ""
        start_tc = f"{int(start_s//3600):02d}:{int((start_s%3600)//60):02d}:{int(start_s%60):02d}"
        line = f"{i+1}. {tag} {text[:120]} ({start_tc})"
        total += len(line) + 1
        if total > max_chars:
            break
        lines.append(line)
    return "\n".join(lines)



def generate_llm_notes(model, merged, chapters, verbosity=0.5):
    """Generate chapter notes using LLM."""
    speakers_str = ", ".join(extract_speakers(merged)) or "Unknown"

    chapter_excerpts = []
    for ch in chapters:
        cues = [c for c in merged if c[2] >= ch["start_s"] - 0.1 and c[3] <= ch["end_s"] + 0.1]
        text = " ".join(t for _, t, _, _ in cues)
        sents = re.split(r'(?<=[.!?])\s+', text.strip())
        excerpt = sents[0][:300] if sents else text[:300]
        chapter_excerpts.append(f"CHAPTER {ch['id']}: {ch['name']} — {excerpt}")

    excerpts_text = "\n\n".join(chapter_excerpts)

    if verbosity < 0.2:
        detail = "2-3 words"
        prompt_extra = "very concise, just key terms"
    elif verbosity < 0.4:
        detail = "5-8 words"
        prompt_extra = "brief description of the topic"
    elif verbosity < 0.6:
        detail = "6-10 words"
        prompt_extra = "specific topics, not generic"
    elif verbosity < 0.8:
        detail = "1-2 sentences"
        prompt_extra = "detailed description of the content covered"
    else:
        detail = "2-4 sentences"
        prompt_extra = "comprehensive description with specific details, anecdotes, and factual information"

    priming = f"\n\n{PRIMING_PROMPT}" if PRIMING_PROMPT else ""
    system_prompt = f"""For each chapter, output EXACTLY one line with:
CH<num>: <{detail} describing the main subjects mentioned>

Example:
CH1: Vincent Van Duysen building; Guggenheim effect
CH2: Cool climate positioning; gastronomy trends
CH3: Marketing differentiation; unique story

No intros, no explanations. Only the CH lines.{priming}"""

    prompt = f"""Speakers: {speakers_str}

{excerpts_text}

Write one CH line per chapter — {detail}, {prompt_extra}."""

    response = ollama_generate(model, prompt, system=system_prompt, timeout=GENERATE_TIMEOUT, max_tokens=2048)
    if not response:
        return None

    notes_map = {}
    for line in response.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        m = re.match(r"(?:CH|Chapter)\s*(\d+)\s*[:\-.)]\s*(.+)", stripped, re.IGNORECASE)
        if not m:
            m = re.match(r"(\d+)\s*[:\-.)]\s+(.+)", stripped)
        if m:
            idx = int(m.group(1))
            note = m.group(2).strip().rstrip(".")
            if note and len(note) > 3 and idx <= len(chapters) + 2:
                notes_map[idx] = note

    return notes_map if notes_map else None


def has_non_latin_chars(text):
    """Check if text contains non-Latin characters (e.g. Chinese, Japanese, Korean)."""
    if not text:
        return False
    non_latin = sum(1 for c in text if ord(c) > 0x024F)
    return non_latin > len(text) * 0.1  # more than 10% non-Latin


def sec_to_tc(s, offset=0):
    s = max(0, s - offset)
    m = int(s // 60)
    sec = int(s % 60)
    if m >= 60:
        h = m // 60
        m = m % 60
        return f"{h:02d}:{m:02d}:{sec:02d}"
    return f"{m:02d}:{sec:02d}"

TIME_RANGE_RE = re.compile(r'\[(\d{1,2}):(\d{2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2}):(\d{2})\]')
TC_REF_RE = re.compile(r'\[(\d{1,2}):(\d{2}):(\d{2})\]')

def normalize_tc_refs(text, offset):
    if not offset or not text:
        return text
    def _repl(m):
        s = int(m[1])*3600 + int(m[2])*60 + int(m[3])
        return f"[{sec_to_tc(s, offset)}]"
    return TC_REF_RE.sub(_repl, text)

def extract_time_range(text):
    m = TIME_RANGE_RE.search(text)
    if m:
        start_s = int(m[1])*3600 + int(m[2])*60 + int(m[3])
        end_s = int(m[4])*3600 + int(m[5])*60 + int(m[6])
        return start_s, end_s, m.start(), m.end()
    return None, None, None, None

def generate_synopsis(title, location, duration_s, chapters,
                      timecode_offset=0,
                      synopsis_intro=True, synopsis_paragraphs=True, synopsis_bullets=True,
                      synopsis_timecode=True,
                      llm_intro=None, llm_subjects=None, raw_llm_text=None):
    """Generate synopsis in the Antidoot-style format.

    Sections (controlled by flags):
      - Introduction: overall picture paragraph
      - Paragraphs: comprehensive paragraphs per subject area
      - Bullet points: bullet points under each subject paragraph

    Falls back to the old Carlos Campolargo format if no new flags are set
    or if LLM content is missing.
    """
    hours = int(duration_s) // 3600
    minutes = (int(duration_s) % 3600) // 60
    dur_str = f"~{hours}h {minutes:02d}min" if hours > 0 else f"~{minutes}min"

    lines = [
        f"SYNOPSIS - {title}",
        f"{location}",
        f"Duration: {dur_str}",
        "=" * 80,
        "",
    ]

    has_llm = bool(llm_intro) or bool(llm_subjects)

    # --- Introduction ---
    if synopsis_intro and llm_intro:
        lines.append(llm_intro)
        lines.append("")
    elif not has_llm and synopsis_intro:
        themes_covered = [ch["theme"] for ch in chapters]
        theme_list = ", ".join(dict.fromkeys(themes_covered))
        lines.append(f"Interview at {location} covering {theme_list.lower()}.")
        lines.append("")

    # --- Raw LLM fallback (parser couldn't extract sections) ---
    if not has_llm and raw_llm_text:
        lines.append(raw_llm_text)
        lines.append("")
        has_llm = False  # still show TOPICS COVERED below
    # --- Paragraphs + Bullets ---
    if synopsis_paragraphs and llm_subjects:
        # Compute time ranges for each subject from keyword chapter data
        sorted_chapters = sorted(chapters, key=lambda ch: ch["start_s"])
        n_subjects = len(llm_subjects)
        subject_ranges = []
        if sorted_chapters and n_subjects > 0:
            ch_total = len(sorted_chapters)
            # Distribute chapters evenly among subjects
            base_count = ch_total // n_subjects
            remainder = ch_total % n_subjects
            ch_idx = 0
            for s_idx in range(n_subjects):
                count = base_count + (1 if s_idx < remainder else 0)
                if count == 0:
                    subject_ranges.append(None)
                    continue
                first_ch = sorted_chapters[ch_idx]
                last_ch = sorted_chapters[ch_idx + count - 1]
                subject_ranges.append((first_ch["start_s"], last_ch["end_s"]))
                ch_idx += count
        # Assign computed ranges to subjects
        for s_idx, subject in enumerate(llm_subjects):
            name = subject.get("name", "").strip()
            para = subject.get("paragraph", "").strip()
            raw_bullets = subject.get("bullets", [])
            srange = subject_ranges[s_idx] if s_idx < len(subject_ranges) else None
            if srange:
                tc_start_s, tc_end_s = srange
                tc_duration = tc_end_s - tc_start_s
                # Prepend time range to paragraph header
                header = f"{name} ({sec_to_tc(tc_start_s, timecode_offset)}-{sec_to_tc(tc_end_s, timecode_offset)})"
                # Compute per-bullet average timecodes
                n_bullets = len(raw_bullets)
                if n_bullets > 0:
                    bullets = []
                    for b_idx, b in enumerate(raw_bullets):
                        frac = (b_idx + 1) / (n_bullets + 1)
                        avg_s = tc_start_s + tc_duration * frac
                        avg_tc = sec_to_tc(avg_s, timecode_offset)
                        bullets.append(f"[{avg_tc}] {b}")
                else:
                    bullets = []
            else:
                header = name
                bullets = raw_bullets
            if header:
                lines.append(header)
                lines.append("")
            if para and len(para) > len(name):
                lines.append(para)
                lines.append("")
            elif not para and bullets:
                sentences = []
                for b in bullets:
                    b_clean = b.strip(".").split("(")[0].strip()
                    if b_clean and not b_clean[0].isupper():
                        if sentences:
                            sentences[-1] += " and " + b_clean
                        else:
                            sentences.append("The discussion covers " + b_clean)
                    else:
                        sentences.append(b_clean)
                if len(sentences) == 1:
                    lines.append(sentences[0] + ".")
                else:
                    para_text = " ".join(s + "." for s in sentences[:-1])
                    lines.append(para_text + " " + sentences[-1] + ".")
                lines.append("")
            elif not para:
                lines.append(f"Interview subjects discussed include {name.lower()}.")
                lines.append("")
            if synopsis_bullets and bullets:
                for b in bullets:
                    lines.append(f"  - {b}")
                lines.append("")
    elif not has_llm:
        # Fallback to old TOPICS COVERED format
        lines.append("TOPICS COVERED")
        lines.append("")
        seen_themes = {}
        for ch in chapters:
            theme = ch["theme"]
            name = ch.get("name", "")
            prefix = f"{theme}: "
            if name.startswith(prefix):
                name = name[len(prefix):]
            if not name:
                name = ch.get("notes", "")[:60]
            start_tc = sec_to_tc(ch["start_s"], timecode_offset)
            end_tc = sec_to_tc(ch["end_s"], timecode_offset)
            entry = {"name": name, "start": start_tc, "end": end_tc}
            if theme not in seen_themes:
                seen_themes[theme] = []
            seen_themes[theme].append(entry)
        for theme, entries in seen_themes.items():
            lines.append(theme)
            merged = []
            for e in entries:
                if merged and merged[-1]["name"] == e["name"]:
                    merged[-1]["end"] = e["end"]
                else:
                    merged.append(dict(e))
            for m in merged:
                lines.append(f"  - {m['name']} ({m['start']}-{m['end']})")
            lines.append("")

    return "\n".join(lines)


def generate_llm_synopsis_full(model, merged, title, location, duration_s, verbosity,
                                synopsis_intro=True, synopsis_paragraphs=True, synopsis_bullets=True, synopsis_timecode=True):
    """Generate full synopsis (all requested sections) in a single LLM call.

    Returns raw LLM text, to be parsed by parse_llm_synopsis().
    """
    transcript = build_compact_transcript(merged, max_chars=80000)
    speakers_str = ", ".join(extract_speakers(merged)) or "Unknown"

    sections = []
    if synopsis_intro:
        sections.append("1. **Introduction paragraph**: Write 1-2 paragraphs that give the overall picture of what this interview is about. Set the scene — who, where, when, and the general subject matter. Cover the main arc of the conversation.")
    if synopsis_paragraphs:
        sections.append("2. **Subject paragraphs**: For each major subject or topic area discussed, write a comprehensive narrative paragraph describing what is said in detail. Cover the key facts, anecdotes, quotes, and information within each subject area.")
    if synopsis_bullets:
        tc = "Include a timecode reference [hh:mm:ss] at the start of each bullet point indicating where in the interview this topic arises. " if synopsis_timecode else ""
        sections.append(f"3. **Bullet points**: Under each subject paragraph, add bullet points that synthesize the key points covered in that section. {tc}")

    if not sections:
        return None

    sections_text = "\n".join(sections)

    if verbosity < 0.2:
        length = "Be very concise — 1-2 sentences total."
    elif verbosity < 0.4:
        length = "Keep it brief — intro 3-5 sentences, each subject paragraph 4-6 sentences."
    elif verbosity < 0.6:
        length = "Write a moderate length — intro 6-10 sentences, each subject paragraph 8-12 sentences."
    elif verbosity < 0.8:
        length = "Write in detail — intro 10-15 sentences, each subject paragraph 15-25 sentences with specific details from the transcript."
    else:
        length = "Write very comprehensively — intro 20-30 sentences (2-3 paragraphs). Each subject section: 500-800 words with full narrative detail, specific anecdotes, direct quotes from the interviewee, and factual information from the transcript. Cover every distinct topic thoroughly. Write like you're describing the entire interview to someone who hasn't seen it."

    system_prompt = f"""You are a documentary film editor writing a synopsis of an interview transcript.

{length}

Output format — use these exact section headers. Each section MUST include paragraph text on its own lines — do NOT put the subject name on the same line as SUBJECT: header.

INTRODUCTION:
[your paragraph text here, separate line]

SUBJECT: [Name of Subject Area]
[Write the narrative paragraph here on its own line(s), before any bullet points. This paragraph MUST be at least 3-4 sentences describing the content in detail.]
  - [bullet point]
  - [bullet point]

SUBJECT: [Next Subject]
[Paragraph text on separate line(s)]
  - [bullet point]

CRITICAL: Every subject section ABSOLUTELY MUST have 3-4+ sentences of narrative paragraph text on its own lines between the SUBJECT header and any bullet points. The paragraph must be a coherent block of prose, not just a single sentence. If you cannot write real paragraph text about a subject, do not include that subject. Bullet points alone without a preceding paragraph are unacceptable. Separate subject sections with blank lines. Use natural, engaging documentary prose — descriptive, factual, and specific. Avoid generic statements; ground every sentence in what was actually said in the transcript.

{PRIMING_PROMPT}"""

    prompt = f"""Interview: {title}
Location: {location}
Duration: {int(duration_s//60)} min
Speakers: {speakers_str}

Transcript excerpts:
{transcript}

Generate the following sections:
{sections_text}"""

    return ollama_generate(model, prompt, system=system_prompt,
                           timeout=GENERATE_TIMEOUT, max_tokens=8192)


def parse_llm_synopsis(text, synopsis_intro, synopsis_paragraphs, synopsis_bullets, synopsis_timecode):
    """Parse the raw LLM synopsis output into structured intro + subjects.

    Handles both standard format (SUBJECT:/INTRODUCTION:) and
    qwq-style markdown headings (###, ####).

    Returns (intro_text, subjects_list) where each subject is a dict with
    name, paragraph, and bullets keys.
    """
    intro_text = ""
    subjects = []

    if not text:
        return intro_text, subjects

    # Strip common reasoning/thinking preamble
    cleaned = re.sub(r'(?s)<think>.*?</think>', '', text)
    cleaned = re.sub(r'(?s)```.*?```', '', cleaned)

    # Try markdown-heading parsing first (qwq style)
    lines = cleaned.split("\n")
    # Find first structural header: ###, ####, or INTRODUCTION:/SUBJECT: at line start
    first_content_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r'^#{1,6}\s', stripped) or re.match(r'^\*{0,2}(?:INTRODUCTION|INTRO|SUBJECT|TOPIC)[:\s]', stripped, re.IGNORECASE):
            first_content_idx = i
            break
    if first_content_idx and first_content_idx > 2:
        cleaned = "\n".join(lines[first_content_idx:])

    # Detect format: markdown headings vs standard SUBJECT:/INTRODUCTION:
    has_markdown = bool(re.search(r'^#{1,6}\s', cleaned, re.MULTILINE))

    if has_markdown:
        # qwq-style markdown format
        current_subject = None
        current_subject_timecode = None
        current_para = []
        current_bullets = []
        in_subject = False
        in_bullet_block = False
        collecting_intro = False

        for line in cleaned.split("\n"):
            stripped = line.strip()
            if not stripped:
                continue

            # Check for top-level markdown heading (###) — major section
            top_head = re.match(r'^###\s+\**?(\d*\.?\s*)?(.*?)\**?\s*$', stripped)
            if top_head:
                heading_text = top_head.group(2).strip().rstrip(':').strip().rstrip('*').strip()
                # Flush current subject
                if current_subject is not None:
                    subjects.append({
                        "name": current_subject,
                        "paragraph": " ".join(current_para),
                        "bullets": current_bullets,
                        "timecode": current_subject_timecode,
                    })
                elif current_para or current_bullets:
                    intro_text = " ".join(current_para)
                    if not intro_text and current_bullets:
                        intro_text = ". ".join(current_bullets)

                # Flush intro buffer if collecting
                if collecting_intro and current_para:
                    intro_text = " ".join(current_para)
                    current_para = []
                    collecting_intro = False

                # Detect introduction vs bullet-list section
                heading_lower = heading_text.lstrip('*').strip()
                if re.search(r'(?i)^\d*\.?\s*introduction', heading_lower):
                    current_subject = None
                    current_subject_timecode = None
                    current_para = []
                    current_bullets = []
                    in_subject = True
                    in_bullet_block = False
                    collecting_intro = True
                    continue
                elif re.search(r'(?i)^\d*\.?\s*(bullet|subject)', heading_lower):
                    # Section divider (e.g. "2. Subject Paragraphs", "3. Bullet Points") — skip
                    current_subject = None
                    current_subject_timecode = None
                    current_para = []
                    current_bullets = []
                    in_subject = False
                    in_bullet_block = False
                    collecting_intro = False
                    continue
                else:
                    # Treat as subject boundary — clean name
                    clean_name = heading_text.strip('*').strip()
                    tc_start_s, tc_end_s, tc_pos_start, tc_pos_end = extract_time_range(clean_name)
                    if tc_pos_start is not None:
                        clean_name = clean_name[:tc_pos_start].strip() + clean_name[tc_pos_end:].strip()
                    current_subject = clean_name
                    current_subject_timecode = (tc_start_s, tc_end_s)
                    current_para = []
                    current_bullets = []
                    in_subject = True
                    in_bullet_block = False
                    continue

            # Check for sub-heading (####) — subject within a major section
            sub_head = re.match(r'^####\s+\**?(.*?)\**?\s*$', stripped)
            if sub_head:
                # Flush previous subject
                if current_subject is not None:
                    subjects.append({
                        "name": current_subject,
                        "paragraph": " ".join(current_para),
                        "bullets": current_bullets,
                        "timecode": current_subject_timecode,
                    })
                clean_sub_name = sub_head.group(1).strip().rstrip(':').strip().rstrip('*').strip()
                clean_sub_name = clean_sub_name.strip('*').strip()
                tc_start_s, tc_end_s, tc_pos_start, tc_pos_end = extract_time_range(clean_sub_name)
                if tc_pos_start is not None:
                    clean_sub_name = clean_sub_name[:tc_pos_start].strip() + clean_sub_name[tc_pos_end:].strip()
                current_subject = clean_sub_name
                current_subject_timecode = (tc_start_s, tc_end_s)
                current_para = []
                current_bullets = []
                in_subject = True
                in_bullet_block = False
                continue

            # Inside subject: collect paragraph or bullet
            if in_subject:
                if stripped.startswith("-") or stripped.startswith("*"):
                    bt = stripped.lstrip("-* ").strip()
                    # Skip section labels like "Key points:" or "Key points**:"
                    bt_clean = bt.replace("**", "").strip()
                    if bt and not re.match(r'(?i)^(key points?|details?|notes?)[:\s]', bt_clean):
                        current_bullets.append(bt)
                    in_bullet_block = True
                elif in_bullet_block and not stripped.startswith("-"):
                    # Continuation of last bullet
                    if current_bullets:
                        current_bullets[-1] += " " + stripped
                elif not in_bullet_block:
                    # Strip bold markers
                    clean_line = stripped.replace("**", "").strip()
                    if clean_line and not re.match(r'(?i)^(key points?|details?|notes?)[:\s]', clean_line):
                        current_para.append(clean_line)

        # Flush last subject
        if current_subject is not None:
            subjects.append({
                "name": current_subject,
                "paragraph": " ".join(current_para),
                "bullets": current_bullets,
                "timecode": current_subject_timecode,
            })
        elif current_para:
            intro_text = " ".join(current_para)

    else:
        # Standard SUBJECT:/INTRODUCTION: format
        cleaned = re.sub(r'(?s)<think>.*?</think>', '', text)
        cleaned = re.sub(r'(?s)```.*?```', '', cleaned)
        first_header = re.search(r'(?im)^\*{0,2}(?:introduction|intro|subject|topic)[:\s]', cleaned)
        if first_header:
            cleaned = cleaned[first_header.start():]

        header_re = re.compile(r'^\*{0,2}(?:INTRODUCTION|INTRO|SUBJECT|TOPIC)[:\s]\*{0,2}', re.MULTILINE | re.IGNORECASE)
        raw_sections = header_re.split(cleaned)
        raw_headers = header_re.findall(cleaned)

        if raw_sections:
            header_index = 0
            for seg in raw_sections:
                if not seg.strip():
                    continue
                seg = seg.strip()
                header_label = raw_headers[header_index].strip("* \n\t").upper() if header_index < len(raw_headers) else ""
                if header_label.startswith("INTRODUCTION") or header_label.startswith("INTRO"):
                    intro_text = seg
                    header_index += 1
                elif header_label.startswith("SUBJECT") or header_label.startswith("TOPIC"):
                    header_index += 1
                    slines = seg.split("\n")
                    subject_name = slines[0].strip() if slines else ""
                    tc_start_s, tc_end_s, tc_pos_start, tc_pos_end = extract_time_range(subject_name)
                    if tc_pos_start is not None:
                        subject_name = subject_name[:tc_pos_start].strip() + subject_name[tc_pos_end:].strip()
                    subject_timecode = (tc_start_s, tc_end_s) if tc_start_s is not None else None
                    para_lines = []
                    bullets = []
                    in_bullets = False
                    for sline in slines[1:]:
                        sstripped = sline.strip()
                        if not sstripped:
                            if in_bullets:
                                in_bullets = False
                            continue
                        if sstripped.startswith("-") or sstripped.startswith("*"):
                            bt = sstripped.lstrip("-* ").strip()
                            if bt:
                                bullets.append(bt)
                            in_bullets = True
                        elif in_bullets:
                            bullets[-1] += " " + sstripped
                        else:
                            para_lines.append(sstripped)
                            in_bullets = False
                    paragraph = " ".join(para_lines)
                    if subject_name or paragraph:
                        subjects.append({
                            "name": subject_name,
                            "paragraph": paragraph,
                            "bullets": bullets,
                            "timecode": subject_timecode,
                        })
                else:
                    header_index += 1

    # Fallback: if no sections were found but text exists,
    # treat the whole thing as an introduction
    if not intro_text and not subjects and cleaned.strip():
        intro_text = cleaned.strip()

    return intro_text, subjects

# ─── Write helpers ───────────────────────────────────────────────────────────

def atomic_write_text(path, text):
    """Write text atomically: temp file in the same dir, then os.replace()."""
    import tempfile as _tf
    dirpath = os.path.dirname(os.path.abspath(path))
    fd, tmp = _tf.mkstemp(dir=dirpath, prefix=".tmp_", suffix=".partial")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def write_outputs(yaml_data, synopsis_text, dirpath, base, duration_s, write_yaml=True, write_synopsis=True):
    yaml_path = None
    synopsis_path = None
    if write_yaml:
        yaml_path = os.path.join(dirpath, f"{base}_chapters.yaml")
        import io as _io, yaml as _yaml
        buf = _io.StringIO()
        _yaml.dump(yaml_data, buf, default_flow_style=False, allow_unicode=True, sort_keys=False)
        atomic_write_text(yaml_path, buf.getvalue())
    if write_synopsis:
        synopsis_path = os.path.join(dirpath, f"{base}_synopsis.txt")
        atomic_write_text(synopsis_path, synopsis_text)
    return yaml_path, synopsis_path

# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: process_srt.py <srt_path> [--fps 25.0] [--force-keyword] [--verbosity 0.5] [--synopsis-intro] [--synopsis-paragraphs] [--synopsis-bullets]"}))
        sys.exit(1)

    if sys.argv[1] == "--check-ollama":
        print(json.dumps(check_ollama()))
        return

    srt_path = sys.argv[1]
    force_keyword = "--force-keyword" in sys.argv
    chapters_only = "--chapters-only" in sys.argv
    synopsis_only = "--synopsis-only" in sys.argv
    if not chapters_only and not synopsis_only:
        chapters_only = True
        synopsis_only = True
    synopsis_intro = "--synopsis-intro" in sys.argv
    synopsis_paragraphs = "--synopsis-paragraphs" in sys.argv
    synopsis_bullets = "--synopsis-bullets" in sys.argv
    synopsis_timecode = "--synopsis-timecode" in sys.argv
    if not synopsis_intro and not synopsis_paragraphs and not synopsis_bullets:
        synopsis_intro = True
        synopsis_paragraphs = True
        synopsis_bullets = True
        synopsis_timecode = True
    chapters_verbosity = 0.5
    synopsis_verbosity = 0.5
    fps = 25.0
    priming_prompt_text = ""
    for i, arg in enumerate(sys.argv):
        if arg == "--fps" and i + 1 < len(sys.argv):
            try:
                fps = max(1.0, float(sys.argv[i + 1]))
            except ValueError:
                pass
        if arg == "--chapters-verbosity" and i + 1 < len(sys.argv):
            try:
                chapters_verbosity = max(0.0, min(1.0, float(sys.argv[i + 1])))
            except ValueError:
                pass
        if arg == "--synopsis-verbosity" and i + 1 < len(sys.argv):
            try:
                synopsis_verbosity = max(0.0, min(1.0, float(sys.argv[i + 1])))
            except ValueError:
                pass
        if arg == "--priming-prompt-file" and i + 1 < len(sys.argv):
            try:
                with open(sys.argv[i + 1], "r") as f:
                    priming_prompt_text = f.read().strip()
            except Exception:
                pass
    global PRIMING_PROMPT
    PRIMING_PROMPT = priming_prompt_text

    transcript_path = None
    themes_file = None
    chapter_density = 0.5
    requested_model = None
    for i, arg in enumerate(sys.argv):
        if arg == "--transcript" and i + 1 < len(sys.argv):
            transcript_path = sys.argv[i + 1]
        if arg == "--themes-file" and i + 1 < len(sys.argv):
            themes_file = sys.argv[i + 1]
        if arg == "--model" and i + 1 < len(sys.argv):
            requested_model = sys.argv[i + 1].strip()
        if arg == "--chapter-density" and i + 1 < len(sys.argv):
            try:
                chapter_density = float(sys.argv[i + 1])
            except ValueError:
                pass

    # Load dynamic themes from file if provided
    global DYNAMIC_THEMES
    if themes_file and os.path.isfile(themes_file):
        try:
            with open(themes_file, "r") as f:
                themes_data = json.load(f)
            if isinstance(themes_data, list):
                DYNAMIC_THEMES = themes_data
            elif isinstance(themes_data, dict) and "themes" in themes_data:
                DYNAMIC_THEMES = themes_data["themes"]
            # Rebuild VALID_THEMES from dynamic themes
            global VALID_THEMES
            VALID_THEMES = {t["name"] for t in DYNAMIC_THEMES}
        except Exception:
            pass

    if not os.path.isfile(srt_path):
        print(json.dumps({"error": f"File not found: {srt_path}"}))
        sys.exit(1)

    # Parse
    print(json.dumps({"progress": "Parsing subtitle file…"}), flush=True)
    cues = parse_srt(srt_path, fps=fps)
    if not cues:
        print(json.dumps({"error": "No cues found in SRT file"}))
        sys.exit(1)

    print(json.dumps({"progress": "Merging subtitle segments…"}), flush=True)
    merged = merge_cues(cues)
    if not merged:
        print(json.dumps({"error": "No valid subtitle cues after merging"}))
        sys.exit(1)

    # Parse paired transcript if available (richer context for LLM)
    llm_context = merged  # fallback to merged subtitle cues
    if transcript_path and os.path.isfile(transcript_path):
        try:
            tc = parse_srt(transcript_path, fps=fps)
            if tc:
                llm_context = tc
        except Exception:
            pass

    date, person, location = infer_info(srt_path)
    title = f"{date} {person}" if date else person
    duration_s = merged[-1][3] - merged[0][2]
    timecode_offset = merged[0][2]
    speakers = extract_speakers(merged)
    dirpath = os.path.dirname(srt_path)
    base = re.sub(r"\.(srtx?|txt)$", "", os.path.basename(srt_path))
    base = re.sub(r"_subtitles$", "", base)
    base = re.sub(r"_(?:transcript|transcripts)$", "", base)

    # Check Ollama
    ollama_status = check_ollama()
    model = ollama_status["selected"] if (ollama_status["running"] and ollama_status["selected"] and not force_keyword) else None
    # Prefer the model the app selected (passed via --model), when it is installed.
    if model and requested_model:
        available = ollama_status.get("models") or []
        if available and requested_model in available:
            model = requested_model
        elif ollama_status["running"]:
            model = None  # requested model isn't installed — degrade to keywords rather than silently use another model

    print(json.dumps({"progress": "Analyzing content structure via keyword detection…"}), flush=True)
    # Always use keyword-based chapter detection for reliable timecode boundaries
    chapters = process_keyword(merged, date, person, location, title, density=chapter_density)
    print(json.dumps({"progress": f"Found {len(chapters)} chapters via keywords"}), flush=True)

    # Use Ollama for synopsis sections + chapter notes
    llm_synopsis = None
    llm_intro = None
    llm_subjects = []
    notes_map = None
    if model:
        print(json.dumps({"progress": "Generating synopsis (LLM)…"}), flush=True)
        llm_synopsis = generate_llm_synopsis_full(model, llm_context, title, location, duration_s,
                                                    synopsis_verbosity, synopsis_intro, synopsis_paragraphs, synopsis_bullets, synopsis_timecode)
        if llm_synopsis:
            llm_intro, llm_subjects = parse_llm_synopsis(llm_synopsis, synopsis_intro, synopsis_paragraphs, synopsis_bullets, synopsis_timecode)
        print(json.dumps({"progress": "Generating chapter notes (LLM)…"}), flush=True)
        notes_map = generate_llm_notes(model, llm_context, chapters, chapters_verbosity)

    # Override chapter notes with LLM-generated ones if available
    if notes_map:
        notes_have_non_latin = any(has_non_latin_chars(n) for n in notes_map.values())
        if not notes_have_non_latin:
            for ch in chapters:
                idx = ch["id"]
                if idx in notes_map and notes_map[idx]:
                    ch["notes"] = notes_map[idx]

    if llm_intro and has_non_latin_chars(llm_intro):
        llm_intro = None
    llm_subjects = [s for s in llm_subjects if not has_non_latin_chars(s.get("paragraph", ""))]

    # Build YAML data
    yaml_data = {
        "title": title,
        "location": location,
        "date": date,
        "markers": chapters,
    }
    if speakers:
        yaml_data["speakers"] = speakers
    yaml_data["duration_seconds"] = round(duration_s, 1)

    # Generate synopsis with new format
    synopsis_text = generate_synopsis(title, location, duration_s, chapters,
                                        timecode_offset=timecode_offset,
                                        synopsis_intro=synopsis_intro,
                                        synopsis_paragraphs=synopsis_paragraphs,
                                        synopsis_bullets=synopsis_bullets,
                                        synopsis_timecode=synopsis_timecode,
                                        llm_intro=llm_intro,
                                        llm_subjects=llm_subjects,
                                        raw_llm_text=llm_synopsis if not llm_intro and not llm_subjects else None)

    print(json.dumps({"progress": "Writing output files…"}), flush=True)
    # Write only the requested output files
    yaml_path, synopsis_path = write_outputs(
        yaml_data, synopsis_text, dirpath, base, duration_s,
        write_yaml=chapters_only, write_synopsis=synopsis_only
    )

    print(json.dumps({"progress": "Complete"}), flush=True)
    out = {
        "status": "ok",
        "chapters": len(chapters),
        "markers": chapters,
        "duration_seconds": round(duration_s, 1),
        "ollama": model is not None,
        "model": model,
    }
    if yaml_path:
        out["yaml"] = yaml_path
    if synopsis_path:
        out["synopsis"] = synopsis_path
    if DEGRADED_REASON:
        out["warning"] = "LLM unavailable — " + str(DEGRADED_REASON)
    print(json.dumps(out))


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        with open(os.path.join(tempfile.gettempdir(), "process_srt_error.log"), "w") as f:
            f.write(tb)
        try:
            print(json.dumps({"error": str(e), "traceback": tb}))
        except BrokenPipeError:
            pass
        sys.exit(1)
