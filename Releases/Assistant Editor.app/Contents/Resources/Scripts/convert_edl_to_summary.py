"""
Convert _bullet_summary.txt + _timeline_markers.EDL → _summary.yaml for Belgium interviews.
Usage: python3 convert_edl_to_summary.py Transcripts/Belgium/INTERVIEW_FOLDER/
"""

import re, sys, os, yaml
import os

THEME_COLORS = {
    "Tan": "Project / Logistics",
    "Orange": "Food / Gastronomy",
    "Cyan": "Landscape / Terroir",
    "Mint": "Winemaking / Cellar",
    "Green": "Viticulture",
    "Rose": "Market / Industry",
    "Lemon": "Climate Change",
}

# Map EDL ResolveColor names to our theme
RESOLVE_TO_THEME = {
    "ResolveColorBlue": "Tan",
    "ResolveColorOrange": "Orange",
    "ResolveColorYellow": "Cyan",
    "ResolveColorGreen": "Green",
    "ResolveColorTeal": "Lemon",
    "ResolveColorPurple": "Rose",
    "ResolveColorRed": "Rose",
    "ResolveColorPink": "Rose",
    "ResolveColorMauve": "Mint",
    "ResolveColorCyan": "Cyan",
    "ResolveColorSage": "Cyan",
    "ResolveColorOlive": "Green",
    "ResolveColorPlum": "Mint",
    "ResolveColorNavy": "Tan",
    "ResolveColorLemon": "Lemon",
    "ResolveColorMint": "Mint",
    "ResolveColorTan": "Tan",
    "ResolveColorRose": "Rose",
    "ResolveColorGreen": "Green",
    "ResolveColorCyan": "Cyan",
}

def edl_tc_to_seconds(tc):
    """Convert HH:MM:SS:FF to float seconds (25 fps)."""
    parts = tc.split(":")
    h, m, s, f = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
    fps = float(os.environ.get("AE_FPS", "25"))
    return h * 3600 + m * 60 + s + f / fps

def guess_theme_from_text(text):
    """Simple heuristic to assign a theme category based on content keywords."""
    text_lower = text.lower()
    if any(kw in text_lower for kw in ["wine club", "member", "sales", "revenue", "market", "export", "label", "bottle", "pricing", "customer", "business"]):
        return ("Rose", "Market / Industry")
    if any(kw in text_lower for kw in ["climate", "frost", "spring frost", "weather", "warm", "heat", "rain", "scenario", "future", "change", "warming"]):
        return ("Lemon", "Climate Change")
    if any(kw in text_lower for kw in ["food", "gastronom", "chef", "restaurant", "dinner", "tast", "cook", "kitchen", "recipe", "meal"]):
        return ("Orange", "Food / Gastronomy")
    if any(kw in text_lower for kw in ["cellar", "ferment", "barrel", "press", "winemak", "sparkl", "bottle", "disgorg", "vini"]):
        return ("Mint", "Winemaking / Cellar")
    if any(kw in text_lower for kw in ["vine", "grape", "soil", "till", "cover crop", "compost", "plant", "root", "prune", "harvest", "spray", "pesticide", "herbicide", "piwi", "hybrid", "variety"]):
        return ("Green", "Viticulture")
    if any(kw in text_lower for kw in ["landscape", "terroir", "architect", "building", "region", "place", "territor", "mountain", "valley", "river"]):
        return ("Cyan", "Landscape / Terroir")
    if any(kw in text_lower for kw in ["project", "logistic", "introduct", "welcome", "closing", "open", "tour", "event", "program", "plan"]):
        return ("Tan", "Project / Logistics")
    return ("Tan", "Project / Logistics")

def parse_edl(edl_path):
    """Parse timeline_markers.EDL and return list of marker dicts."""
    markers = []
    with open(edl_path) as f:
        lines = f.readlines()
    
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if not line or line.startswith("TITLE:") or line.startswith("FCM:"):
            i += 1
            continue
        
        # Try to match marker header: NNN  AX or NNN  001 or NNN  AX etc
        m = re.match(r'^\s*(\d+)\s+\S+\s+V\s+C\s+(\d+:\d+:\d+:\d+)\s+(\d+:\d+:\d+:\d+)', line)
        if m:
            marker_id = int(m.group(1))
            start_tc = m.group(2)
            end_tc = m.group(3)
            start_s = edl_tc_to_seconds(start_tc)
            end_s = edl_tc_to_seconds(end_tc)
            
            i += 1
            if i >= len(lines):
                break
            
            # Collect metadata + notes lines until next marker or EOF
            meta_lines = []
            while i < len(lines):
                next_line = lines[i].rstrip()
                if not next_line:
                    i += 1
                    continue
                if re.match(r'^\s*\d+\s+\S+\s+V\s+C\s+\d+:\d+:\d+:\d+', next_line):
                    break
                meta_lines.append(next_line)
                i += 1
            
            # Skip * FROM CLIP NAME lines — they have no content
            meta_lines = [ln for ln in meta_lines if not ln.startswith("* FROM CLIP NAME")]
            notes_text = " ".join(meta_lines)
            
            # Extract metadata from pipe-delimited suffix
            color_match = re.search(r'\|\s*C\s*:\s*(\S+)', notes_text)
            name_match = re.search(r'\|\s*M\s*:\s*(.+?)(?:\s*\|\s*D\s*:|$)', notes_text)
            
            color = color_match.group(1) if color_match else "Tan"
            name = name_match.group(1).strip() if name_match else f"Marker {marker_id}"
            
            # Clean notes: remove metadata pipes
            clean_notes = re.sub(r'\|\s*C\s*:\s*\S+\s*', '', notes_text)
            clean_notes = re.sub(r'\|\s*M\s*:\s*[^|]+\s*', '', clean_notes)
            clean_notes = re.sub(r'\|\s*D\s*:\s*\S+\s*', '', clean_notes)
            # FROM CLIP NAME lines already filtered above
            clean_notes = clean_notes.strip()
            
            # Map color to our theme
            edl_color_clean = color.replace("ResolveColor", "")
            our_color = RESOLVE_TO_THEME.get(color, RESOLVE_TO_THEME.get(f"ResolveColor{edl_color_clean}", None))
            
            if our_color is None:
                # Fall back to guessing from content
                color_guess, theme_guess = guess_theme_from_text(f"{name} {clean_notes}")
                our_color = color_guess
                our_theme = theme_guess
            else:
                our_theme = THEME_COLORS.get(our_color, "Project / Logistics")
            
            markers.append({
                "id": marker_id,
                "start_s": round(start_s, 2),
                "end_s": round(end_s, 2),
                "name": name,
                "theme": our_theme,
                "color": our_color,
                "notes": clean_notes,
            })
        else:
            i += 1
    
    return markers

def extract_info_from_bullet(bullet_path):
    """Extract title info from bullet summary."""
    info = {"title": "", "speakers": [], "duration_seconds": 0}
    with open(bullet_path) as f:
        text = f.read()
    
    first_line = text.split("\n")[0].strip()
    info["title"] = first_line.replace("— Transcript Summary", "").replace("- Transcript Summary", "").strip()
    
    dur_match = re.search(r'Duration:\s*~?(\d+)\s*min', text)
    if dur_match:
        info["duration_seconds"] = int(dur_match.group(1)) * 60
    
    speaker_match = re.search(r'Interview by\s*(.+?)(?:\n|$)', text)
    if speaker_match:
        speakers_raw = speaker_match.group(1)
        speakers = [s.strip() for s in re.split(r'[,&]', speakers_raw)]
        info["speakers"] = speakers
    
    return info

def main():
    if len(sys.argv) < 2:
        print("Usage: convert_edl_to_summary.py <folder_path> [folder_path2 ...]")
        sys.exit(1)
    
    for folder in sys.argv[1:]:
        folder = folder.rstrip("/")
        basename = os.path.basename(folder)
        
        bullet_path = os.path.join(folder, f"{basename}_bullet_summary.txt")
        edl_path = os.path.join(folder, f"{basename}_timeline_markers.EDL")
        out_path = os.path.join(folder, f"{basename}_summary.yaml")
        
        if not os.path.exists(bullet_path):
            print(f"SKIP {folder}: no bullet summary")
            continue
        if not os.path.exists(edl_path):
            print(f"SKIP {folder}: no EDL")
            continue
        
        info = extract_info_from_bullet(bullet_path)
        markers = parse_edl(edl_path)
        
        # Date prefix is DD-MM format
        date_prefix = ""
        if "_" in basename:
            first_part = basename.split("_")[0]
            if re.match(r'^\d{2}-\d{2}$', first_part):
                date_prefix = first_part
        
        doc = {
            "title": info["title"] or basename,
            "location": "Belgium",
            "date": date_prefix,
            "speakers": info["speakers"] or [],
            "duration_seconds": info["duration_seconds"] or 0,
            "markers": markers,
        }
        
        if info["duration_seconds"] == 0 and markers:
            doc["duration_seconds"] = round(markers[-1]["end_s"])
        
        # Update title to include date prefix convention
        if doc["date"] and not doc["title"].startswith(doc["date"]):
            doc["title"] = f"{doc['date']} {doc['title']}"
        
        with open(out_path, "w") as f:
            yaml.dump(doc, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
        
        print(f"OK   {out_path}: {len(markers)} markers, {doc['duration_seconds']}s")

if __name__ == "__main__":
    main()
