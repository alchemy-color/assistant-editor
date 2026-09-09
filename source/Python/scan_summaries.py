#!/usr/bin/env python3
"""Walk a folder and output all *_summary.yaml files as a JSON array.

Usage:
  scan_summaries.py <root>           # walk full tree
  scan_summaries.py <root> --flat    # single folder, no recursion
Output: JSON array of summary documents.
"""
import sys, json, os, yaml, re

def extract_speakers(dirpath):
    """Try to extract speaker names from a companion SRT/SRTX file."""
    speakers = set()
    for f in os.listdir(dirpath):
        if not (f.endswith(".srt") or f.endswith(".srtx")):
            continue
        try:
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                text = fh.read()
        except Exception:
            continue
        # SRTX: lines before blank line, repeated across cues
        for block in re.split(r"\n\n+", text):
            lines = block.strip().split("\n")
            # Skip numeric-id and timecode lines
            content = [l for l in lines if not re.match(r"^\d+$|^\d{2}:\d{2}", l)]
            if content:
                first = content[0].strip()
                if first and first[0].isupper() and len(first) < 40:
                    speakers.add(first)
    return sorted(speakers)

def scan(root, recursive=True):
    results = []
    for dirpath, dirnames, fnames in os.walk(root) if recursive else [(root, [], os.listdir(root))]:
        for f in fnames:
            if not (f.endswith("_chapters.yaml") or f.endswith("_summary.yaml")):
                continue
            path = os.path.join(dirpath, f)
            try:
                with open(path, encoding="utf-8") as fh:
                    data = yaml.safe_load(fh)
            except Exception:
                continue
            if not isinstance(data, dict) or "markers" not in data:
                continue
            data["sourceFolder"] = dirpath
            data["sourceFile"] = path
            if "speakers" not in data or not data["speakers"]:
                sp = extract_speakers(dirpath)
                if sp:
                    data["speakers"] = sp
            results.append(data)
    return results

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: scan_summaries.py <root> [--flat]"}))
        sys.exit(1)
    recursive = "--flat" not in sys.argv
    results = scan(sys.argv[1], recursive)
    print(json.dumps(results, ensure_ascii=False))
