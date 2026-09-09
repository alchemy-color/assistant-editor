#!/usr/bin/env python3
"""Parse SRT/SRTX file → JSON with cues, speakers, duration, clip_name."""
import sys, json, re

def tc_to_seconds(tc):
    tc = tc.strip().replace(",", ".")
    h, m, rest = tc.split(":")
    s, ms = rest.split(".")
    return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000

def parse_srt(path):
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    pattern = re.compile(
        r"\d+\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})\n(.*?)(?=\n\n|\Z)",
        re.DOTALL)
    cues = []
    speakers = set()
    for m in pattern.finditer(raw):
        raw_text = m.group(3).strip()
        start = tc_to_seconds(m.group(1))
        end = tc_to_seconds(m.group(2))
        # Extract speaker name from first line
        lines = raw_text.split("\n")
        first = lines[0].strip() if lines else ""
        text = " ".join(l.strip() for l in lines[1:]) if len(lines) > 1 else first
        if first and first[0].isupper() and len(first) < 40:
            speakers.add(first)
        cues.append({"start_s": start, "end_s": end, "text": text or first})
    duration = max(c["end_s"] for c in cues) if cues else 0
    name = re.sub(r'_(subtitles|rough)$', '', path.replace("\\", "/").split("/")[-1].rsplit(".", 1)[0])
    return {
        "clip_name": name,
        "duration": duration,
        "speakers": sorted(speakers),
        "cues": cues
    }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: parse_srt.py <file.srt>"}))
        sys.exit(1)
    result = parse_srt(sys.argv[1])
    print(json.dumps(result, ensure_ascii=False))
