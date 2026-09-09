#!/usr/bin/env python3
"""Convert all existing *_summary.txt → *_summary.yaml.

Usage: python3 convert_summaries.py <transcripts_root>
"""
import sys, os, json, re, yaml

def tc_to_seconds(tc):
    tc = tc.strip().replace(",", ".")
    h, m, rest = tc.split(":")
    s, ms = rest.split(".")
    return round(int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000, 3)

MARKER_RE = re.compile(
    r"\[(\d+)\]\s+(\d{2}:\d{2}:\d{2},\d{3})\s*-\s*(\d{2}:\d{2}:\d{2},\d{3}).*?" +
    r"Theme:\s*(.+?)\s*\[(.+?)\]\s*" +
    r"Name:\s*(.+?)\s*" +
    r"Notes:\s*(.+?)(?=\n\n|\n\[|\Z)",
    re.DOTALL | re.IGNORECASE)

def parse_title(path):
    """Extract title and location from the old txt header."""
    base = os.path.basename(os.path.dirname(path))
    return base, ""

def convert_file(txt_path):
    with open(txt_path, encoding="utf-8") as f:
        content = f.read()
    title = os.path.basename(os.path.dirname(txt_path))
    location = os.path.basename(os.path.dirname(os.path.dirname(txt_path)))
    date = title.split("_")[0] if "_" in title else ""
    markers = []
    for m in MARKER_RE.finditer(content):
        markers.append({
            "id": int(m.group(1)),
            "start_s": tc_to_seconds(m.group(2)),
            "end_s": tc_to_seconds(m.group(3)),
            "name": m.group(6).strip(),
            "theme": m.group(4).strip(),
            "color": m.group(5).strip(),
            "notes": m.group(7).strip(),
        })
    data = {
        "title": title,
        "location": location,
        "date": date,
        "markers": markers,
    }
    yaml_path = txt_path.rsplit(".", 1)[0] + ".yaml"
    with open(yaml_path, "w", encoding="utf-8") as f:
        yaml.dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
    print(f"  {os.path.basename(txt_path)} → {os.path.basename(yaml_path)}  ({len(markers)} markers)")
    return yaml_path

def main(root):
    for dirpath, dirnames, fnames in os.walk(root):
        for f in fnames:
            if f.endswith("_summary.txt"):
                convert_file(os.path.join(dirpath, f))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 convert_summaries.py <transcripts_root>")
        sys.exit(1)
    main(sys.argv[1])
