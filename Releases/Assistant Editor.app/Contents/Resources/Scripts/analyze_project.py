#!/usr/bin/env python3
"""Analyze a folder of interviews: extract themes, keywords, stats.

Walks the folder tree, reads subtitle/transcript/chapter files, optionally
asks the LLM to extract project-specific themes and keywords.

Usage:
  analyze_project.py <root_folder> [--model <ollama_model>] [--priming-prompt-file <path>]

Reads from stdin (optional JSON): {"folders": ["/path/to/folder1", ...]}
If no stdin, uses the single <root_folder> arg.

Output: JSON written to stdout, also writes <folderName>_project.yaml in root_folder.
"""
import sys, os, re, json, yaml, time, glob, urllib.request, urllib.error
from collections import Counter

OMLX_BASE = os.environ.get("OMLX_BASE_URL", "http://localhost:8000").rstrip("/")
OMLX_API_KEY = os.environ.get("OMLX_API_KEY", "")
OLLAMA_BASE = OMLX_BASE
OLLAMA_TIMEOUT = 5
GENERATE_TIMEOUT = 300
PRIMING_PROMPT = ""


def _omlx_headers():
    h = {"Content-Type": "application/json"}
    if OMLX_API_KEY:
        h["Authorization"] = f"Bearer {OMLX_API_KEY}"
    return h


def ollama_request(path, data=None, timeout=OLLAMA_TIMEOUT):
    url = f"{OMLX_BASE}{path}"
    body = None
    if data is not None:
        body = json.dumps(data).encode()
    try:
        req = urllib.request.Request(url, data=body, headers=_omlx_headers())
        if body is not None:
            req.method = "POST"
        resp = urllib.request.urlopen(req, timeout=timeout)
        return json.loads(resp.read().decode())
    except Exception:
        return None


def ollama_generate(model, prompt, system="", timeout=GENERATE_TIMEOUT, max_tokens=4096):
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    data = {
        "model": model,
        "messages": messages,
        "temperature": 0.4,
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


def check_ollama():
    data = ollama_request("/v1/models", timeout=OLLAMA_TIMEOUT)
    if data and "data" in data:
        models = [m["id"] for m in data["data"] if "id" in m]
        if models:
            selected = models[0]
            return {"running": True, "models": models, "selected": selected}
    return {"running": False, "models": [], "selected": None}


def parse_srt_text(text, fps=25.0):
    """Parse SRT/SRTX text into list of (speaker, text, start_s, end_s).

    Cues are grouped by their timecode line (not by blank-line separation), so
    the DaVinci export style that puts a blank line between the timecode and
    its text is parsed correctly.
    """
    cues = []
    std_re = re.compile(r'\d+:\d+:\d+[,.]\d+\s*-->\s*\d+:\d+:\d+[,.]\d+')
    frame_re = re.compile(r'^\[\d{1,2}:\d{2}:\d{2}')

    def flush(cur_tc, cur_lines):
        if cur_tc is None:
            return None
        text_lines = [l.strip() for l in cur_lines if l.strip()]
        if not text_lines:
            return None
        speaker = ""
        content_lines = text_lines
        if len(text_lines) >= 2:
            first = text_lines[0]
            if first and first[0].isupper() and len(first) < 40 and not first[0].isdigit():
                speaker = first
                content_lines = text_lines[1:]
        full_text = ' '.join(content_lines).strip()
        if not full_text:
            return None
        start_s, end_s = _parse_tc(cur_tc, fps)
        if start_s is None or end_s is None:
            return None
        return (speaker, full_text, start_s, end_s)

    cur_tc = None
    cur_lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if std_re.search(line) or '-->' in line or re.match(r'^\[\d{1,2}:\d{2}:\d{2}', line):
            if cur_tc is not None:
                c = flush(cur_tc, cur_lines)
                if c is not None:
                    cues.append(c)
            cur_tc = line
            cur_lines = []
            continue
        if re.match(r'^\d+$', line):
            if cur_lines:
                c = flush(cur_tc, cur_lines)
                if c is not None:
                    cues.append(c)
                cur_tc = None
                cur_lines = []
            continue
        if line == '':
            continue
        if cur_tc is None:
            continue
        cur_lines.append(line)

    if cur_tc is not None:
        c = flush(cur_tc, cur_lines)
        if c is not None:
            cues.append(c)

    return cues


def _parse_tc(line, fps=25.0):
    """Parse timecodes from a line, return (start_s, end_s)."""
    if '-->' in line:
        parts = line.split('-->')
        if len(parts) == 2:
            return _tc_to_sec(parts[0].strip()), _tc_to_sec(parts[1].strip())
    # Single bracket pair spanning a range: [hh:mm:ss[:ff] - hh:mm:ss[:ff]]
    m = re.search(
        r'\[(\d{1,2}):(\d{2}):(\d{2})(?::(\d{2}))?\s*-\s*'
        r'(\d{1,2}):(\d{2}):(\d{2})(?::(\d{2}))?\]', line)
    if not m:
        # Legacy two-bracket form: [hh:mm:ss] - [hh:mm:ss]
        m = re.search(
            r'\[(\d{1,2}):(\d{2}):(\d{2})\]\s*-\s*\[(\d{1,2}):(\d{2}):(\d{2})\]', line)

    if m:
        f = float(fps) if fps else 25.0

        def _part(h, mi, s, fr):
            t = int(h) * 3600 + int(mi) * 60 + int(s)
            if fr is not None and f > 0:
                t += int(fr) / f
            return float(t)

        g = m.groups()
        if len(g) == 6:                      # two-bracket form has no frame fields
            g = (g[0], g[1], g[2], None, g[3], g[4], g[5], None)

        s = _part(g[0], g[1], g[2], g[3])
        e = _part(g[4], g[5], g[6], g[7])
        return (s, max(s, e))
    return (None, None)


def _tc_to_sec(tc):
    tc = tc.strip().replace(',', '.')
    m = re.match(r'(\d{1,2}):(\d{2}):(\d{2})(?:[,.:](\d{1,3}))?', tc)
    if not m:
        return None
    h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
    ms = int(m.group(4)) if m.group(4) else 0
    if len(m.group(4) or '') <= 2:
        ms *= 10
    return h * 3600 + mi * 60 + s + ms / 1000.0


def merge_cues(cues, gap=0.3):
    """Merge consecutive cues from same speaker with small gaps."""
    if not cues:
        return []
    merged = [list(cues[0])]
    for speaker, text, start_s, end_s in cues[1:]:
        prev = merged[-1]
        if speaker == prev[0] and start_s - prev[3] < gap:
            prev[1] += " " + text
            prev[3] = end_s
        else:
            merged.append([speaker, text, start_s, end_s])
    return [tuple(c) for c in merged]


def extract_frequent_words(texts, top_n=30):
    """Extract most frequent meaningful words from a list of texts."""
    stop = {"yeah", "like", "just", "well", "really", "actually", "okay",
            "gonna", "wanna", "thing", "stuff", "little", "because",
            "about", "which", "there", "going", "into", "could", "would",
            "should", "think", "maybe", "also", "even", "much", "many",
            "some", "then", "that", "this", "with", "from", "they",
            "them", "what", "when", "where", "very", "been", "every",
            "make", "made", "know", "said", "say", "way", "kind", "lot",
            "sort", "thing", "stuff", "need", "take", "look", "come",
            "have", "been", "were", "being", "will", "shall", "might",
            "still", "back", "over", "only", "such", "than", "them",
            "these", "those", "its", "his", "her", "our", "your", "their",
            "can", "may", "must", "not", "but", "for", "yet"}
    counter = Counter()
    for text in texts:
        words = re.findall(r'\b[a-zA-Z]{4,}\b', text.lower())
        for w in words:
            if w not in stop:
                counter[w] += 1
    return counter.most_common(top_n)


def scan_folder(root):
    """Scan a folder for subtitle/transcript/chapter/synopsis files."""
    subtitle_exts = {'.srt', '.srtx', '.txt'}
    interviews = []
    speakers_all = Counter()
    all_texts = []

    for dirpath, dirnames, fnames in os.walk(root):
        for f in sorted(fnames):
            base, ext = os.path.splitext(f)
            if ext.lower() not in subtitle_exts:
                continue

            # Pairing: prefer _subtitles files when both exist.
            # Skip a transcript (named _transcript.txt or _transcripts.txt) only if a
            # paired _subtitles exists; otherwise use the transcript as source.
            if f.endswith('_transcript.txt') or f.endswith('_transcripts.txt'):
                has_paired = False
                subs_base = base  # base = splitext(f)[0], already .txt-stripped
                for sfx in ('_transcripts', '_transcript'):
                    if subs_base.endswith(sfx):
                        subs_base = subs_base[:-len(sfx)]
                        break
                for srt_ext in ['.srtx', '.srt']:
                    srtx = os.path.join(dirpath, subs_base + '_subtitles' + srt_ext)
                    if os.path.isfile(srtx):
                        has_paired = True
                        break
                if has_paired:
                    continue  # skip transcript — subtitles will be processed

            path = os.path.join(dirpath, f)
            try:
                with open(path, encoding='utf-8') as fh:
                    text = fh.read()
            except Exception:
                continue

            cues = parse_srt_text(text)
            if not cues:
                continue

            merged = merge_cues(cues)
            duration = merged[-1][3] - merged[0][2] if merged else 0

            for speaker, _, _, _ in merged:
                if speaker:
                    speakers_all[speaker] += 1

            all_texts.append(' '.join(t for _, t, _, _ in merged))

            # check for companion files
            dir_files = set(os.listdir(dirpath))
            base_name = f.split('.')[0]
            # strip _subtitles or _transcript(s) from base for matching
            clean_base = base_name.replace('_subtitles', '').replace('_transcripts', '').replace('_transcript', '')

            chapters_path = None
            for f2 in dir_files:
                if f2.endswith('_chapters.yaml'):
                    # match: "Title_chapters.yaml" or "Title_transcript_chapters.yaml"
                    ch_base = f2.replace('_chapters.yaml', '').replace('_transcripts', '').replace('_transcript', '')
                    if ch_base == clean_base:
                        chapters_path = os.path.join(dirpath, f2)
                        break

            synopsis_path = None
            for f2 in dir_files:
                if f2.endswith('_synopsis.txt'):
                    # match: "Title_synopsis.txt" or "Title_transcript_synopsis.txt"
                    syn_base = f2.replace('_synopsis.txt', '').replace('_transcripts', '').replace('_transcript', '')
                    if syn_base == clean_base:
                        synopsis_path = os.path.join(dirpath, f2)
                        break

            transcript_path = None
            if ext.lower() == '.srtx' or ext.lower() == '.srt':
                # look for paired transcript (_transcript.txt or _transcripts.txt)
                for suf in ('_transcript.txt', '_transcripts.txt'):
                    candidate = os.path.join(dirpath, clean_base + suf)
                    if os.path.isfile(candidate):
                        transcript_path = candidate
                        break

            # Parse chapters
            chapter_count = 0
            if chapters_path:
                try:
                    import yaml
                    with open(chapters_path, encoding='utf-8') as chf:
                        ch_data = yaml.safe_load(chf)
                    if ch_data and 'markers' in ch_data:
                        chapter_count = len(ch_data['markers'])
                except Exception:
                    pass

            # Parse synopsis
            synopsis_subject_count = 0
            synopsis_word_count = 0
            if synopsis_path:
                try:
                    with open(synopsis_path, encoding='utf-8') as sf:
                        syn_text = sf.read()
                    synopsis_word_count = len(syn_text.split())
                    # Count "Subject N:" lines
                    import re
                    synopsis_subject_count = len(re.findall(r'^Subject \d+:', syn_text, re.MULTILINE))
                except Exception:
                    pass

            # Parse transcript word count
            transcript_word_count = 0
            if transcript_path:
                try:
                    with open(transcript_path, encoding='utf-8') as tf:
                        transcript_word_count = len(tf.read().split())
                except Exception:
                    pass

            # File sizes
            def fsize(p):
                try:
                    return os.path.getsize(p) if p else 0
                except Exception:
                    return 0

            title = clean_base.replace('_', ' ')
            speakers = list(set(s for s, _, _, _ in merged if s))

            interviews.append({
                'title': title,
                'folderPath': dirpath,
                'excluded': False,
                'hasSubtitles': ext.lower() in {'.srt', '.srtx'},
                'hasTranscript': transcript_path is not None,
                'hasChapters': chapters_path is not None,
                'hasSynopsis': synopsis_path is not None,
                'durationS': round(duration, 1),
                'cueCount': len(merged),
                'speakers': speakers,
                'chapterCount': chapter_count,
                'synopsisSubjectCount': synopsis_subject_count,
                'transcriptWordCount': transcript_word_count,
                'fileSizeSrtx': fsize(path),
                'fileSizeTranscript': fsize(transcript_path),
                'fileSizeChapters': fsize(chapters_path),
                'fileSizeSynopsis': fsize(synopsis_path),
                'textPreview': ' '.join(t[:200] for _, t, _, _ in merged[:20]),
            })

    # Group by folder
    folders_map = {}
    for iv in interviews:
        fp = iv['folderPath']
        if fp not in folders_map:
            folders_map[fp] = []
        folders_map[fp].append(iv)

    folders = [{'path': fp, 'interviews': ivs} for fp, ivs in folders_map.items()]
    total_duration = sum(iv['durationS'] for iv in interviews)
    total_cues = sum(iv['cueCount'] for iv in interviews)
    speakers = [{'name': sp, 'durationS': 0, 'cueCount': count}
                for sp, count in speakers_all.most_common(20)]
    freq_words = extract_frequent_words(all_texts)

    return folders, {
        'totalInterviews': len(interviews),
        'totalDurationS': round(total_duration, 1),
        'totalCues': total_cues,
        'speakers': speakers,
        'frequentWords': freq_words,
    }, all_texts


def extract_themes_with_llm(model, all_texts, priming=""):
    """Use LLM to extract project-specific themes and keywords."""
    # Build a compact preview of all interview content
    previews = []
    total_chars = 0
    for i, text in enumerate(all_texts):
        preview = text[:1500]
        previews.append(f"INTERVIEW {i+1}:\n{preview}")
        total_chars += len(preview)
        if total_chars > 25000:
            break

    previews_text = "\n\n".join(previews)

    priming_section = f"\n\nAdditional context:\n{priming}" if priming else ""

    system_prompt = f"""You are a documentary editor analyzing interview transcripts to extract the main themes and keywords.

Analyze the interviews below and extract 5-8 major themes that describe the project.

For each theme provide:
- A short descriptive name (e.g. "Family Legacy", "Urban Architecture", "Sustainability")
- 8-15 keywords that would identify this theme in text (nouns, verbs, domain-specific terms)
- A weight from 0.0 to 1.0 indicating how dominant this theme is across all interviews

Output EXACTLY one JSON object (no markdown fences):
{{"themes": [{{"name": "...", "keywords": ["...", "..."], "weight": 0.8, "color": "Blue"}}]}}

Available colors: Blue, Orange, Cyan, Mint, Green, Rose, Lemon, Tan, Sky, Purple
Assign colors to distinguish themes visually. Each theme gets a unique color.{priming_section}"""

    prompt = f"""Analyze these interview transcripts and extract the project's main themes:

{previews_text}

Return a JSON object with themes, keywords, and weights."""

    response = ollama_generate(model, prompt, system=system_prompt, timeout=GENERATE_TIMEOUT, max_tokens=2048)
    if not response:
        return None

    # Try to parse JSON from response
    try:
        # Strip think blocks if present
        cleaned = response
        if '<think>' in cleaned:
            last_end = cleaned.rfind('</think>')
            if last_end >= 0:
                cleaned = cleaned[last_end + len('</think>'):]
            else:
                cleaned = re.sub(r'<think>.*?</think>', '', cleaned, flags=re.DOTALL)
            cleaned = cleaned.strip()

        # Find JSON in response — try progressively larger substrings
        # First try direct parse
        try:
            data = json.loads(cleaned)
            if isinstance(data, dict) and 'themes' in data and isinstance(data['themes'], list):
                return data['themes']
        except Exception:
            pass

        # Try to find JSON object by brace matching
        idx = cleaned.find('"themes"')
        if idx >= 0:
            # Walk backward to find opening brace
            start = cleaned.rfind('{', 0, idx)
            if start >= 0:
                depth = 0
                end = start
                for i in range(start, len(cleaned)):
                    if cleaned[i] == '{':
                        depth += 1
                    elif cleaned[i] == '}':
                        depth -= 1
                        if depth == 0:
                            end = i + 1
                            break
                try:
                    data = json.loads(cleaned[start:end])
                    if isinstance(data, dict) and 'themes' in data and isinstance(data['themes'], list):
                        return data['themes']
                except Exception:
                    pass
    except Exception:
        pass
    return None


def build_default_themes(freq_words):
    """Build default themes from frequent words when LLM is unavailable."""
    # Group words into broad categories
    theme_defs = [
        ("Story / Narrative", ["story", "narrative", "tell", "memory", "remember", "history", "tradition", "legacy", "family", "generation"], "Blue"),
        ("People / Community", ["people", "community", "together", "relationship", "friend", "neighbor", "group", "team", "together"], "Orange"),
        ("Place / Environment", ["place", "home", "house", "building", "city", "street", "garden", "nature", "space", "environment"], "Cyan"),
        ("Work / Process", ["work", "process", "create", "build", "make", "design", "plan", "develop", "method", "craft"], "Green"),
        ("Change / Time", ["change", "time", "year", "new", "old", "modern", "future", "past", "history", "transform"], "Rose"),
        ("Values / Beliefs", ["value", "believe", "important", "meaning", "purpose", "mission", "vision", "quality", "integrity"], "Mint"),
        ("Growth / Learning", ["learn", "grow", "discover", "explore", "understand", "education", "research", "develop"], "Lemon"),
        ("Challenges / Solutions", ["challenge", "problem", "solution", "difficult", "overcome", "adapt", "resolve", "issue"], "Tan"),
    ]

    themes = []
    words_lower = {w.lower() for w, _ in freq_words}
    for name, keywords, color in theme_defs:
        matched = [k for k in keywords if k in words_lower]
        if len(matched) >= 2:
            weight = min(1.0, len(matched) / len(keywords))
            themes.append({
                'name': name,
                'keywords': keywords,
                'weight': round(weight, 2),
                'color': color,
            })

    if not themes:
        themes.append({
            'name': 'General Discussion',
            'keywords': [w for w, _ in freq_words[:15]],
            'weight': 1.0,
            'color': 'Blue',
        })

    # Normalize weights
    total = sum(t['weight'] for t in themes)
    if total > 0:
        for t in themes:
            t['weight'] = round(t['weight'] / total, 2)

    return themes



def yaml_quote(v):
    """Escape a string for double-quoted YAML scalar."""
    return str(v).replace('\\', '\\\\').replace('"', '\\"')

def main():
    global PRIMING_PROMPT

    # Parse args
    model = None
    root = None
    priming_file = None

    i = 1
    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg == '--model' and i + 1 < len(sys.argv):
            model = sys.argv[i + 1]
            i += 2
        elif arg == '--priming-prompt-file' and i + 1 < len(sys.argv):
            priming_file = sys.argv[i + 1]
            i += 2
        elif not arg.startswith('--'):
            root = arg
            i += 1
        else:
            i += 1

    if priming_file:
        try:
            with open(priming_file, 'r') as f:
                PRIMING_PROMPT = f.read().strip()
        except Exception:
            pass

    if not root:
        print(json.dumps({"error": "Usage: analyze_project.py <root_folder> [--model <model>]"}))
        sys.exit(1)

    # Optionally read folders from stdin
    folders_input = None
    if not sys.stdin.isatty():
        try:
            raw = sys.stdin.read().strip()
            if raw:
                folders_input = json.loads(raw)
        except Exception:
            pass

    folders_to_scan = [root]
    if folders_input and isinstance(folders_input, dict) and 'folders' in folders_input:
        folders_to_scan = folders_input['folders']

    print(json.dumps({"progress": f"Scanning {len(folders_to_scan)} folder(s)…"}), flush=True)

    all_folders = []
    all_interviews = []
    all_texts = []
    all_speakers = Counter()
    total_duration = 0
    total_cues = 0

    for folder in folders_to_scan:
        folders, stats, texts = scan_folder(folder)
        all_folders.extend(folders)
        all_texts.extend(texts)
        total_duration += stats['totalDurationS']
        total_cues += stats['totalCues']
        for sp in stats['speakers']:
            all_speakers[sp['name']] += sp['cueCount']

    # Check Ollama
    ollama_status = check_ollama()
    if not model:
        model = ollama_status['selected'] if ollama_status['running'] else None

    # Extract themes
    themes = None
    if model and all_texts:
        print(json.dumps({"progress": "Extracting themes via LLM…"}), flush=True)
        themes = extract_themes_with_llm(model, all_texts, priming=PRIMING_PROMPT)

    if not themes:
        print(json.dumps({"progress": "Using keyword-based theme detection…"}), flush=True)
        freq_words = Counter()
        for text in all_texts:
            words = re.findall(r'\b[a-zA-Z]{4,}\b', text.lower())
            stop = {"yeah", "like", "just", "well", "really", "actually", "okay", "gonna", "wanna",
                    "thing", "stuff", "little", "because", "about", "which", "there", "going", "into",
                    "could", "would", "should", "think", "maybe", "also", "even", "much", "many",
                    "some", "then", "that", "this", "with", "from", "they", "them", "what", "when",
                    "where", "very", "been", "every", "make", "made", "know", "said", "say", "way",
                    "kind", "lot", "sort", "need", "take", "look", "come", "have", "been", "were",
                    "being", "will", "shall", "might", "still", "back", "over", "only", "such",
                    "than", "them", "these", "those", "its", "his", "her", "our", "your", "their",
                    "can", "may", "must", "not", "but", "for", "yet"}
            for w in words:
                if w not in stop:
                    freq_words[w] += 1
        themes = build_default_themes(freq_words.most_common())

    speakers_list = [{'name': sp, 'durationS': 0, 'cueCount': count}
                     for sp, count in all_speakers.most_common(20)]
    freq_words_final = [{'word': w, 'count': c} for w, c in extract_frequent_words(all_texts)]

    result = {
        'version': 1,
        'folders': all_folders,
        'themes': themes,
        'stats': {
            'totalInterviews': len(all_interviews) if all_interviews else sum(len(f['interviews']) for f in all_folders),
            'totalDurationS': round(total_duration, 1),
            'totalCues': total_cues,
            'speakers': speakers_list,
            'frequentWords': freq_words_final,
        },
        'createdAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    }

    # Write <folderName>_project.yaml to the analyzed root folder (atomically)
    import io as _io
    def _atomic_write_text(path, text):
        import tempfile as _tf
        d = os.path.dirname(os.path.abspath(path))
        fd, tmp = _tf.mkstemp(dir=d, prefix=".tmp_", suffix=".partial")
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

    root_name = os.path.basename(os.path.normpath(root))
    canonical_yaml = os.path.join(root, f'{root_name}_project.yaml')
    # Acknowledge manually-renamed / legacy files: if exactly one *_project.yaml
    # already exists (user has renamed it), update that very file; otherwise
    # write the canonical <folderName>_project.yaml.
    existing = [p for p in glob.glob(os.path.join(root, '*_project.yaml')) if os.path.isfile(p)]
    yaml_path = canonical_yaml if len(existing) != 1 else existing[0]
    try:
        fh = _io.StringIO()
        # Write a readable YAML (not the full JSON dump) into the in-memory buffer
        q = yaml_quote
        fh.write("version: 1\n\n")
        fh.write("folders:\n")
        for folder in all_folders:
            fh.write(f'  - path: "{q(folder["path"])}"\n')
            fh.write('    interviews:\n')
            for iv in folder['interviews']:
                fh.write(f'      - title: "{q(iv["title"])}"\n')
                fh.write(f'        excluded: {str(iv["excluded"]).lower()}\n')
                fh.write(f'        hasSubtitles: {str(iv["hasSubtitles"]).lower()}\n')
                fh.write(f'        hasTranscript: {str(iv["hasTranscript"]).lower()}\n')
        fh.write("\nthemes:\n")
        for theme in themes:
            fh.write(f'  - name: "{q(theme["name"])}"\n')
            fh.write(f'    keywords: [{", ".join(q(k) for k in theme["keywords"])}]\n'.replace("'", '"'))
            fh.write(f'    weight: {theme["weight"]}\n')
            fh.write(f'    color: "{q(theme["color"])}"\n')
        fh.write("\nstats:\n")
        fh.write(f'  totalInterviews: {result["stats"]["totalInterviews"]}\n')
        fh.write(f'  totalDurationS: {result["stats"]["totalDurationS"]}\n')
        fh.write(f'  totalCues: {result["stats"]["totalCues"]}\n')
        if speakers_list:
            fh.write("  speakers:\n")
            for sp in speakers_list[:15]:
                fh.write(f'    - name: "{q(sp["name"])}"\n')
                fh.write(f'      cueCount: {sp["cueCount"]}\n')
        if freq_words_final:
            fh.write("  frequentWords:\n")
            for entry in freq_words_final[:30]:
                w = q(entry.get("word", ""))
                c = entry.get("count", 0)
                fh.write(f'    - ["{w}", {c}]\n')
        _atomic_write_text(yaml_path, fh.getvalue())
        print(json.dumps({"progress": f"Wrote {yaml_path}"}), flush=True)
    except Exception as e:
        print(json.dumps({"error": f"Failed to write YAML: {e}"}), flush=True)
        sys.exit(1)

    print(json.dumps({"progress": "Complete"}), flush=True)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        try:
            print(json.dumps({"error": str(e), "traceback": tb}))
        except BrokenPipeError:
            pass
        sys.exit(1)
