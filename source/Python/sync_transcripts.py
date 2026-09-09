#!/usr/bin/env python3
"""Sync camera clips to field recorder by phrase matching of transcripts.

Matches clip transcript text against field recorder transcript using FTS5
phrase queries. SRTX cues are merged into ~15s blocks so that phrases
spanning cue boundaries are captured. Falls back to word-overlap matching
for short clips where no unique phrase can be extracted.

Input (stdin): {"field_recorder": "/path/to/FR_transcript_or_srtx",
                 "clips": ["/path/to/CAM_A_transcript.txt", ...]}
Output (stdout): JSON with results array + per-clip confidence.
"""
import sys, json, re, os, sqlite3
from collections import defaultdict

# Frame rate for parsing frame-based [hh:mm:ss:ff] timecodes. Mirrors the other
# sync scripts: the app passes AE_FPS (default 25).
try:
    FPS = float(os.environ.get("AE_FPS", "25"))
except (TypeError, ValueError):
    FPS = 25.0

STOP_WORDS = {"the","a","an","is","it","in","on","at","to","of","and","or",
              "that","this","with","for","but","not","are","was","were","be",
              "have","has","had","do","does","did","will","would","could",
              "should","may","might","shall","can","i","you","he","she",
              "we","they","me","him","her","us","them","my","your","his",
              "its","our","their","no","yes","so","if","as","by","from",
              "up","down","out","off","over","then","than","also","very",
              "just","like","get","got","go","went","going","come","came",
              "say","said","tell","told","know","think","see","look","make",
              "well","now","oh","ah","um","uh","okay","yeah","right","gonna",
              "wanna","gotcha","kinda","sorta","lot","bit","really","actually",
              "basically","literally","pretty","quite","maybe","perhaps"}

# ——— Transcript parsing ———

def tc_to_seconds(tc):
    tc = tc.strip().replace(",", ".")
    parts = tc.split(":")
    if len(parts) == 3:
        return int(parts[0])*3600 + int(parts[1])*60 + float(parts[2])
    return 0.0

def parse_transcript(path):
    """Parse transcript or SRTX file into (text, start_s, end_s) segments."""
    with open(path, encoding="utf-8") as f:
        raw = f.read()

    # Try frame-based [hh:mm:ss:ff] format first
    segments = []
    frame_pat = re.compile(
        r'\[(\d{2}:\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}:\d{2}:\d{2}:\d{2})\]\s*(.*?)(?=\n\[|\Z)',
        re.DOTALL
    )
    for m in frame_pat.finditer(raw):
        h1, m1, s1, f1 = m.group(1).split(":")
        h2, m2, s2, f2 = m.group(2).split(":")
        segments.append({
            "text": m.group(3).strip().replace("\n", " "),
            "start_s": int(h1)*3600 + int(m1)*60 + int(s1) + int(f1)/FPS,
            "end_s":   int(h2)*3600 + int(m2)*60 + int(s2) + int(f2)/FPS,
        })

    # Fall back to standard SRT format
    if not segments:
        srt_pat = re.compile(
            r'\d+\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})\n(.*?)(?=\n\n|\Z)',
            re.DOTALL
        )
        for m in srt_pat.finditer(raw):
            segments.append({
                "text": m.group(3).strip().replace("\n", " "),
                "start_s": tc_to_seconds(m.group(1)),
                "end_s": tc_to_seconds(m.group(2)),
            })

    if not segments:
        segments.append({"text": raw.strip(), "start_s": 0.0, "end_s": 0.0})

    # Merge consecutive segments into ~15s blocks for phrase-indexing
    merged = []
    block_texts = []
    block_start = segments[0]["start_s"]
    for seg in segments:
        if not block_texts:
            block_texts = [seg["text"]]
            block_start = seg["start_s"]
        elif seg["start_s"] - block_start < 15:
            block_texts.append(seg["text"])
        else:
            merged.append({
                "text": " ".join(block_texts),
                "start_s": block_start,
                "end_s": segments[segments.index(seg)-1]["end_s"],
            })
            block_texts = [seg["text"]]
            block_start = seg["start_s"]
    if block_texts:
        merged.append({
            "text": " ".join(block_texts),
            "start_s": block_start,
            "end_s": segments[-1]["end_s"],
        })
    return segments, merged

# ——— Phrase extraction ———

def extract_content_words(text):
    words = re.findall(r"\b[A-Za-z'àáâãäæçèéêëìíîïðñòóôõöùúûü]{3,}\b", text.lower())
    return [w for w in words if w not in STOP_WORDS]

def extract_phrases(text, max_words=4):
    """Extract unique multi-word phrases from text.
    
    Returns list of (phrase_text, word_count) sorted by word_count descending.
    Only includes phrases where every word is a content word (no stop words).
    """
    words = re.findall(r"\b[A-Za-z'àáâãäæçèéêëìíîïðñòóôõöùúûü]{3,}\b", text.lower())
    content = [w for w in words if w not in STOP_WORDS]
    phrases = []
    seen = set()
    for n in range(min(max_words, len(content)), 1, -1):
        for i in range(len(content) - n + 1):
            phrase = " ".join(content[i:i+n])
            if phrase not in seen:
                seen.add(phrase)
                phrases.append((phrase, n))
    return phrases

# ——— FTS5 matching ———

def build_fts(blocks):
    """Build FTS5 index from merged blocks (not raw segments)."""
    db = sqlite3.connect(":memory:")
    db.execute("CREATE VIRTUAL TABLE fr_fts USING fts5(text_content, start_s UNINDEXED, end_s UNINDEXED)")
    for blk in blocks:
        db.execute("INSERT INTO fr_fts(text_content, start_s, end_s) VALUES (?, ?, ?)",
                   (blk["text"], blk["start_s"], blk["end_s"]))
    db.commit()
    return db

def search_phrases(db, phrases):
    """Search FR blocks for each phrase via FTS5 phrase query.
    
    Returns list of (midpoint_s, phrase_text, word_count) for each hit.
    """
    results = []
    for phrase, n_words in phrases:
        # FTS5 phrase query requires quoted exact match
        query = f'"{phrase}"'
        try:
            rows = db.execute(
                "SELECT start_s, end_s FROM fr_fts WHERE text_content MATCH ? LIMIT 10",
                (query,)
            ).fetchall()
        except sqlite3.OperationalError:
            continue
        for start_s, end_s in rows:
            midpoint = (start_s + end_s) / 2
            results.append((midpoint, phrase, n_words))
    return results

def search_words(db, words, max_results=300):
    """Fallback word-overlap search for short clips with no unique phrases."""
    unique = sorted(set(w for w in words if len(w) > 2))
    if not unique:
        return []
    query = " OR ".join(unique[:150])
    try:
        rows = db.execute(
            "SELECT start_s, end_s, text_content FROM fr_fts WHERE text_content MATCH ? LIMIT ?",
            (query, max_results)
        ).fetchall()
    except sqlite3.OperationalError:
        return []
    word_set = set(unique)
    results = []
    for start_s, end_s, text in rows:
        fr_words = set(re.findall(r"\b[a-z']{3,}\b", text.lower()))
        overlap = len(word_set & fr_words)
        if overlap >= 2:
            results.append(((start_s + end_s) / 2, overlap))
    return results

# ——— Clustering ———

def cluster_hits(hits, window_s=20):
    """Cluster phrase/word hits by time proximity.
    
    Returns list of clusters sorted by score descending.
    Each cluster: {"midpoint": float, "score": float, "phrases": [...], "count": int}
    """
    if not hits:
        return []
    sorted_h = sorted(hits, key=lambda x: x[0])
    clusters = []
    cur = [sorted_h[0]]
    for h in sorted_h[1:]:
        if abs(h[0] - cur[-1][0]) <= window_s:
            cur.append(h)
        else:
            clusters.append(cur)
            cur = [h]
    clusters.append(cur)

    scored = []
    for cl in clusters:
        times = [h[0] for h in cl]
        midpoint = sum(times) / len(times)
        spread = max(times) - min(times)
        if isinstance(cl[0][1], str):
            # Phrase hits: (time, phrase, n_words)
            unique_phrases = len(set(h[1] for h in cl))
            total_words = sum(h[2] for h in cl)
            score = unique_phrases * 100 + total_words * 10
        else:
            # Word-overlap hits: (time, overlap)
            total_overlap = sum(h[1] for h in cl)
            score = total_overlap * 10
        density = len(cl) / (spread + 1)
        score += density * 50
        scored.append({"midpoint": midpoint, "score": score,
                       "count": len(cl), "spread": spread})
    scored.sort(key=lambda x: -x["score"])
    return scored

# ——— Main ———

def main():
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({"error": "No input data"}))
        sys.exit(1)
    try:
        req = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON: {e}"}))
        sys.exit(1)

    fr_path = req.get("field_recorder", "")
    clip_paths = req.get("clips", [])
    if not fr_path or not os.path.isfile(fr_path):
        print(json.dumps({"error": f"Field recorder transcript not found: {fr_path}"}))
        sys.exit(1)

    print(json.dumps({"progress": "Parsing field recorder transcript…"}), flush=True)
    fr_segments, fr_blocks = parse_transcript(fr_path)
    if not fr_blocks:
        print(json.dumps({"error": "Could not parse field recorder transcript"}))
        sys.exit(1)
    fr_duration = max(s["end_s"] for s in fr_segments)

    print(json.dumps({"progress": "Building search index…"}), flush=True)
    db = build_fts(fr_blocks)

    sorted_clips = sorted(clip_paths)
    results = []
    total = len(sorted_clips)

    for idx, clip_path in enumerate(sorted_clips):
        clip_name = os.path.basename(clip_path)
        clip_name = re.sub(r'_(?:transcript|transcripts)$', '', os.path.splitext(clip_name)[0])
        clip_name = re.sub(r'_subtitles$', '', clip_name)

        print(json.dumps({"progress": f"Syncing {clip_name} ({idx+1}/{total})…"}), flush=True)

        if not os.path.isfile(clip_path):
            results.append({"clip_name": clip_name, "clip_path": clip_path,
                            "error": "File not found", "confidence": 0.0,
                            "sync_time_s": 0.0, "matched_phrases": [],
                            "clip_duration_s": 0.0,
                            "field_recorder_duration_s": round(fr_duration, 3)})
            continue

        segs, _ = parse_transcript(clip_path)
        if not segs:
            results.append({"clip_name": clip_name, "clip_path": clip_path,
                            "error": "Could not parse", "confidence": 0.0,
                            "sync_time_s": 0.0, "matched_phrases": [],
                            "clip_duration_s": 0.0,
                            "field_recorder_duration_s": round(fr_duration, 3)})
            continue

        clip_start = min(s["start_s"] for s in segs)
        clip_duration = max(s["end_s"] for s in segs) - clip_start
        clip_text = " ".join(s["text"] for s in segs)

        # Strategy 1: phrase matching
        phrases = extract_phrases(clip_text)
        if phrases:
            phrase_hits = search_phrases(db, phrases)
            if phrase_hits:
                clusters = cluster_hits(phrase_hits, window_s=20)
                if clusters:
                    best = clusters[0]
                    best_time = best["midpoint"]
                    # Confidence from phrase match: how many unique phrases found
                    matched_phrase_set = set()
                    for h in phrase_hits:
                        if abs(h[0] - best_time) <= 20:
                            matched_phrase_set.add(h[1])
                    confidence = min(1.0, len(matched_phrase_set) * 0.25 + 0.1)
                    matched = list(matched_phrase_set)[:5]
                    results.append({
                        "clip_name": clip_name, "clip_path": clip_path,
                        "sync_time_s": round(best_time, 3),
                        "confidence": round(confidence, 4),
                        "matched_phrases": matched,
                        "total_phrases_checked": len(phrases),
                        "clip_duration_s": round(clip_duration, 3),
                        "field_recorder_duration_s": round(fr_duration, 3),
                    })
                    continue

        # Strategy 2: word-overlap fallback
        clip_words = extract_content_words(clip_text)
        unique_words = list(set(clip_words))
        word_hits = search_words(db, unique_words)
        if word_hits:
            clusters = cluster_hits(word_hits, window_s=15)
            if clusters:
                best = clusters[0]
                best_time = best["midpoint"]
                total_overlap = sum(h[1] for h in word_hits
                                    if abs(h[0] - best_time) <= 15)
                confidence = min(1.0, total_overlap / max(1, len(unique_words)) * 1.5)
                results.append({
                    "clip_name": clip_name, "clip_path": clip_path,
                    "sync_time_s": round(best_time, 3),
                    "confidence": round(confidence, 4),
                    "matched_phrases": [],
                    "total_phrases_checked": len(unique_words),
                    "clip_duration_s": round(clip_duration, 3),
                    "field_recorder_duration_s": round(fr_duration, 3),
                })
                continue

        # No match found
        results.append({
            "clip_name": clip_name, "clip_path": clip_path,
            "sync_time_s": 0.0, "confidence": 0.0,
            "matched_phrases": [],
            "total_phrases_checked": 0,
            "clip_duration_s": round(clip_duration, 3),
            "field_recorder_duration_s": round(fr_duration, 3),
        })

    print(json.dumps({"results": results}, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
