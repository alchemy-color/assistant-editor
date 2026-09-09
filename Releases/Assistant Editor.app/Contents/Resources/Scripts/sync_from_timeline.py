#!/usr/bin/env python3
"""Sync timeline camera clips to field recorder by parsing EDL + timeline SRT + field SRTX.

Pipeline:
  1. Parse EDL → clip list with record_in/out + source_in/out + clip_name
  2. Parse timeline subtitle.srt → segments with timeline timecodes
  3. Assign SRT entries to clips by timeline timecode (record_in ≤ tc ≤ record_out)
  4. For each clip, collect its text and run phrase matching against field recording
  5. Output results array compatible with build_sync_timeline.py

Input (stdin): {"field_recorder": "/path/to/field_srtx",
                 "timeline_srt": "/path/to/timeline.srt",
                 "edl": "/path/to/export.edl"}
Output (stdout): {"results": [...]} (same format as sync_transcripts.py)
"""
import sys
import os, json, re, os, sqlite3
from collections import defaultdict

def _sync_fps():
    try:
        return float(os.environ.get("AE_FPS", "25"))
    except Exception:
        return 25.0



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


def tc_to_seconds(tc):
    tc = tc.strip().replace(",", ".")
    parts = tc.split(":")
    if len(parts) == 3:
        return int(parts[0])*3600 + int(parts[1])*60 + float(parts[2])
    if len(parts) == 4:
        return int(parts[0])*3600 + int(parts[1])*60 + int(parts[2]) + int(parts[3])/_sync_fps()
    return 0.0


def edl_tc_to_seconds(tc):
    """EDL timecode (hh:mm:ss:ff) → seconds."""
    parts = tc.strip().split(":")
    if len(parts) == 4:
        return int(parts[0])*3600 + int(parts[1])*60 + int(parts[2]) + int(parts[3])/_sync_fps()
    return 0.0


def tc_to_srt_format(s):
    """Seconds → SRT timecode hh:mm:ss,mmm"""
    h = int(s // 3600)
    m = int((s % 3600) // 60)
    sec = s % 60
    return f"{h:02d}:{m:02d}:{sec:06.3f}".replace(".", ",")


# ——— EDL parsing ———

def parse_edl(path):
    """Parse EDL → list of {clip_name, record_in_s, record_out_s, source_in_s, source_out_s}"""
    clips = []
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        # Match event line: event_num  reel  V  C  source_in source_out record_in record_out
        m = re.match(r'^(\d{3})\s+(\S+)\s+V\s+C\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)', lines[i])
        if m:
            source_in = edl_tc_to_seconds(m.group(3))
            source_out = edl_tc_to_seconds(m.group(4))
            record_in = edl_tc_to_seconds(m.group(5))
            record_out = edl_tc_to_seconds(m.group(6))
            clip_name = ""
            # Look ahead for FROM CLIP NAME
            j = i + 1
            while j < len(lines) and lines[j].strip():
                cm = re.search(r'FROM CLIP NAME:\s*(.+)', lines[j])
                if cm:
                    clip_name = cm.group(1).strip()
                    break
                j += 1
            if clip_name:
                clips.append({
                    "clip_name": clip_name,
                    "record_in_s": record_in,
                    "record_out_s": record_out,
                    "source_in_s": source_in,
                    "source_out_s": source_out,
                    "duration_s": record_out - record_in,
                })
            i = j + 1 if j > i else i + 1
        else:
            i += 1
    return clips


# ——— SRT parsing ———

def parse_srt(path):
    """Parse SRT → list of {start_s, end_s, text}"""
    segments = []
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    pat = re.compile(
        r'\d+\n(\d{2}:\d{2}:\d{2}[,\.]\d{3}) --> (\d{2}:\d{2}:\d{2}[,\.]\d{3})\n(.*?)(?=\n\n|\Z)',
        re.DOTALL
    )
    for m in pat.finditer(raw):
        segments.append({
            "text": m.group(3).strip().replace("\n", " "),
            "start_s": tc_to_seconds(m.group(1)),
            "end_s": tc_to_seconds(m.group(2)),
        })
    return segments


def parse_srtx(path):
    """Parse SRTX → list of {start_s, end_s, text, speaker}"""
    segments = []
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    pat = re.compile(
        r'\d+\n(\d{2}:\d{2}:\d{2}[,\.]\d{3}) --> (\d{2}:\d{2}:\d{2}[,\.]\d{3})\n(.*?)(?=\n\n|\Z)',
        re.DOTALL
    )
    for m in pat.finditer(raw):
        block = m.group(3).strip()
        speaker = ""
        text = block
        lines = block.split("\n")
        if len(lines) >= 2 and lines[0].strip().startswith("Speaker"):
            speaker = lines[0].strip()
            text = " ".join(l.strip() for l in lines[1:] if l.strip())
        segments.append({
            "text": re.sub(r'<[^>]+>', '', text).strip(),
            "start_s": tc_to_seconds(m.group(1)),
            "end_s": tc_to_seconds(m.group(2)),
            "speaker": speaker,
        })
    return segments


# ——— Assign SRT segments to clips ———

def assign_to_clips(segments, clips):
    """Assign each SRT segment to the containing clip based on timeline timecode."""
    clip_segments = defaultdict(list)
    for seg in segments:
        mid = (seg["start_s"] + seg["end_s"]) / 2
        assigned = False
        for ci, clip in enumerate(clips):
            if clip["record_in_s"] - 0.1 <= mid <= clip["record_out_s"] + 0.1:
                clip_segments[ci].append(seg)
                assigned = True
                break
        if not assigned:
            pass  # gap segments (between clips) are discarded
    return clip_segments


# ——— Match clip text to field recording ———
# (Same logic as sync_transcripts.py)

def extract_content_words(text):
    words = re.findall(r"\b[A-Za-z'àáâãäæçèéêëìíîïðñòóôõöùúûü]{3,}\b", text.lower())
    return [w for w in words if w not in STOP_WORDS]


def extract_phrases(text, max_words=4):
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


def merge_blocks(segments, window_s=15):
    """Merge consecutive segments into ~15s blocks for phrase-indexing."""
    if not segments:
        return []
    merged = []
    block_texts = [segments[0]["text"]]
    block_start = segments[0]["start_s"]
    for seg in segments[1:]:
        if seg["start_s"] - block_start < window_s:
            block_texts.append(seg["text"])
        else:
            merged.append({"text": " ".join(block_texts), "start_s": block_start,
                           "end_s": seg["end_s"]})
            block_texts = [seg["text"]]
            block_start = seg["start_s"]
    if block_texts:
        merged.append({"text": " ".join(block_texts), "start_s": block_start,
                       "end_s": segments[-1]["end_s"]})
    return merged


def build_fts(blocks):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE VIRTUAL TABLE fr_fts USING fts5(text_content, start_s UNINDEXED, end_s UNINDEXED)")
    for blk in blocks:
        db.execute("INSERT INTO fr_fts(text_content, start_s, end_s) VALUES (?, ?, ?)",
                   (blk["text"], blk["start_s"], blk["end_s"]))
    db.commit()
    return db


def search_phrases(db, phrases):
    results = []
    for phrase, n_words in phrases:
        query = f'"{phrase}"'
        try:
            rows = db.execute(
                "SELECT start_s, end_s FROM fr_fts WHERE text_content MATCH ? LIMIT 10",
                (query,)
            ).fetchall()
        except sqlite3.OperationalError:
            continue
        for start_s, end_s in rows:
            results.append(((start_s + end_s) / 2, phrase, n_words))
    return results


def search_words(db, words, max_results=300):
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


def cluster_hits(hits, window_s=20):
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
            unique_phrases = len(set(h[1] for h in cl))
            total_words = sum(h[2] for h in cl)
            score = unique_phrases * 100 + total_words * 10
        else:
            total_overlap = sum(h[1] for h in cl)
            score = total_overlap * 10
        density = len(cl) / (spread + 1)
        score += density * 50
        scored.append({"midpoint": midpoint, "score": score,
                       "count": len(cl), "spread": spread})
    scored.sort(key=lambda x: -x["score"])
    return scored


# ——— Main ———

def log(msg):
    """Write progress to stderr so stdout contains only the final result JSON."""
    print(json.dumps({"progress": msg}), file=sys.stderr, flush=True)


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
    timeline_srt_path = req.get("timeline_srt", "")
    edl_path = req.get("edl", "")

    for p in [fr_path, timeline_srt_path, edl_path]:
        if not p or not os.path.isfile(p):
            print(json.dumps({"error": f"File not found: {p}"}))
            sys.exit(1)

    log("Parsing EDL…")
    clips = parse_edl(edl_path)
    if not clips:
        print(json.dumps({"error": "No clips found in EDL."}))
        sys.exit(1)
    log(f"Found {len(clips)} clips in EDL.")

    log("Parsing timeline subtitles…")
    srt_segments = parse_srt(timeline_srt_path)
    if not srt_segments:
        print(json.dumps({"error": "Could not parse timeline SRT."}))
        sys.exit(1)

    log(f"Parsed {len(srt_segments)} subtitle entries, assigning to clips…")
    clip_segments = assign_to_clips(srt_segments, clips)

    assigned_count = sum(len(v) for v in clip_segments.values())
    unassigned = len(srt_segments) - assigned_count
    clips_with_data = sum(1 for v in clip_segments.values() if v)

    log(f"Assigned {assigned_count}/{len(srt_segments)} entries ({unassigned} gaps). "
        f"{clips_with_data}/{len(clips)} clips have subtitles.")

    log("Parsing field recording subtitles…")
    fr_segments = parse_srtx(fr_path)
    if not fr_segments:
        print(json.dumps({"error": "Could not parse field recording SRTX."}))
        sys.exit(1)
    fr_duration = max(s["end_s"] for s in fr_segments)
    fr_blocks = merge_blocks(fr_segments)
    log(f"Field recording: {len(fr_segments)} entries, {len(fr_blocks)} blocks, {fr_duration:.0f}s.")

    log("Building search index…")
    db = build_fts(fr_blocks)

    results = []
    total = len(clips)

    for ci, clip in enumerate(clips):
        clip_name = clip["clip_name"]
        segs = clip_segments.get(ci, [])
        if not segs:
            results.append({
                "clip_name": clip_name,
                "clip_path": "",
                "error": "No subtitles assigned",
                "confidence": 0.0,
                "sync_time_s": 0.0,
                "matched_phrases": [],
                "total_phrases_checked": 0,
                "clip_duration_s": round(clip["duration_s"], 3),
                "field_recorder_duration_s": round(fr_duration, 3),
            })
            continue

        log(f"Syncing {clip_name} ({ci+1}/{total})…")

        clip_start = min(s["start_s"] for s in segs)
        clip_duration = clip["duration_s"]
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
                    matched_phrase_set = set()
                    for h in phrase_hits:
                        if abs(h[0] - best_time) <= 20:
                            matched_phrase_set.add(h[1])
                    confidence = min(1.0, len(matched_phrase_set) * 0.25 + 0.1)
                    matched = list(matched_phrase_set)[:5]
                    results.append({
                        "clip_name": clip_name,
                        "clip_path": "",
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
                    "clip_name": clip_name,
                    "clip_path": "",
                    "sync_time_s": round(best_time, 3),
                    "confidence": round(confidence, 4),
                    "matched_phrases": [],
                    "total_phrases_checked": len(unique_words),
                    "clip_duration_s": round(clip_duration, 3),
                    "field_recorder_duration_s": round(fr_duration, 3),
                })
                continue

        # No match
        results.append({
            "clip_name": clip_name,
            "clip_path": "",
            "sync_time_s": 0.0,
            "confidence": 0.0,
            "matched_phrases": [],
            "total_phrases_checked": 0,
            "clip_duration_s": round(clip_duration, 3),
            "field_recorder_duration_s": round(fr_duration, 3),
        })

    print(json.dumps({"results": results}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
