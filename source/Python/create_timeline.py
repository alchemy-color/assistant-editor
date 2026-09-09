#!/usr/bin/env python3
"""Create a Resolve timeline from a list of marker excerpts.

Input (stdin): {"name":"...", "markers":[{...}], "groupGapFrames":0}
Output (stdout): JSON status.

Strategy: Append subclips back-to-back with AppendToTimeline.
Between groups, a black video clip is generated via ffmpeg, imported
via ImportMedia, and appended as a gap filler. Each clip gets a
colored marker (Blue for match, Rose for context) plus a SetClipColor
on the timeline item itself.
"""
import sys, json, os, glob, time, re, tempfile

FPS = 25

GAP_LOG_PATH = os.path.join(tempfile.gettempdir(), "assistanteditor_gap_debug.log")

def gap_log(msg):
    with open(GAP_LOG_PATH, "a") as f:
        f.write(msg + "\n")

def frames_to_tc(frames, fps):
    frames = int(frames)
    fps = int(fps)
    h = frames // (fps * 3600)
    m = (frames // (fps * 60)) % 60
    s = (frames // fps) % 60
    f = frames % fps
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"

COLOR_MAP = {
    "Tan": "Yellow", "Orange": "Rose", "Cyan": "Sky",
    "Mint": "Mint", "Green": "Green", "Rose": "Rose", "Lemon": "Lemon",
    "Peach": "Rose", "Gold": "Yellow", "Chocolate": "Cream",
    "Cream": "Cream", "Lime": "Mint", "Blue": "Blue", "Yellow": "Yellow",
    "Red": "Red", "Pink": "Pink", "Purple": "Purple", "Fuchsia": "Fuchsia",
    "Lavender": "Lavender", "Sky": "Sky",
    "Teal": "Sky",
}

def sec_to_frame(s, fps=None):
    return int(round(s * (fps or FPS)))

def find_api():
    for c in [
        os.environ.get("RESOLVE_SCRIPT_API", ""),
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting",
        os.path.expanduser("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"),
    ]:
        if c and os.path.isdir(os.path.join(c, "Modules")):
            return c
    return None

def find_lib():
    for c in [
        os.environ.get("RESOLVE_SCRIPT_LIB", ""),
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so",
        os.path.expanduser("~/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"),
    ]:
        if c and os.path.isfile(c):
            return c
    for root in ["/Applications", os.path.expanduser("~/Applications")]:
        for m in glob.glob(os.path.join(root, "DaVinci Resolve*/**/fusionscript.so"), recursive=True):
            return m
    return None

def build_lookup(project):
    """Walk media pool, return {clip_name: (media_type, MediaPoolItem)}.

    Collects both Video clips and Timeline items; on a name collision the
    Video clip wins so sections are cut from the actual footage.
    """
    mp = project.GetMediaPool()
    root = mp.GetRootFolder()
    lookup = {}
    def add(name, media_type, item):
        if name in lookup and lookup[name][0] == "Video":
            return
        lookup[name] = (media_type, item)
    def walk(f):
        for c in f.GetClipList():
            props = c.GetClipProperty()
            if not props:
                continue
            t = props.get("Type", "")
            if t == "Timeline" or t.startswith("Video"):
                add(props.get("Clip Name", ""), "Video" if t.startswith("Video") else "Timeline", c)
        for s in f.GetSubFolderList():
            walk(s)
    walk(root)
    return lookup, mp, root


def normalize(s: str) -> str:
    s = s.replace("_", " ").replace("-", " ").replace(".", " ")
    while "  " in s:
        s = s.replace("  ", " ")
    return s.strip().lower()

def source_base(source_file):
    """Derive media name from subtitle file path.
    E.g. /path/Valke Vleug_subtitles.srtx -> Valke Vleug
    """
    if not source_file:
        return ""
    base = os.path.basename(source_file)
    base = re.sub(r"_subtitles$", "", os.path.splitext(base)[0])
    base = re.sub(r"_(?:transcript|transcripts)$", "", base)
    base = re.sub(r"_rough$", "", base)
    return base

def find_item(lookup, marker):
    """Find the media pool item for a marker. Prefers Video clips over
    Timeline items even on exact name matches (fall back to Timeline)."""
    folder = marker.get("folder", "")
    interview = marker.get("interview", "")
    source_file = marker.get("sourceFile", "") or ""
    dirname = os.path.basename(folder) if folder else ""
    src_base = source_base(source_file)
    names_to_try = [n for n in [src_base, dirname, folder, interview] if n]
    norms_to_try = [normalize(n) for n in names_to_try]

    def score_for(ndx, media_type):
        return 60 + (100 - ndx * 15) + (50 if media_type == "Video" else 0)

    def best_for(media_types):
        best_score = -1
        best_item = None
        for tl_name, (media_type, item) in lookup.items():
            if media_type not in media_types:
                continue
            tl_norm = normalize(tl_name)
            for ndx, raw_name in enumerate(names_to_try):
                my_norm = norms_to_try[ndx]
                if not my_norm:
                    continue
                exact = (raw_name == tl_name) or (my_norm == tl_norm)
                overlap = len(set(my_norm.split()) & set(tl_norm.split()))
                if exact:
                    score = 1000 + score_for(ndx, media_type) + overlap * 10
                elif my_norm in tl_norm or tl_norm in my_norm:
                    score = score_for(ndx, media_type) + overlap * 10
                else:
                    continue
                if score > best_score:
                    best_score = score
                    best_item = item
        return best_item

    # Prefer an unambiguous EXACT normalized match before fuzzy scoring;
    # substring matches between short interview names are the main
    # wrong-footage risk in multi-folder pools.
    def exact_for(media_types):
        for ndx, raw_name in enumerate(names_to_try):
            my_norm = norms_to_try[ndx]
            if not my_norm:
                continue
            hits = [item for tl_name, (mt, item) in lookup.items()
                    if mt in media_types and normalize(tl_name) == my_norm]
            if len(hits) == 1:
                return hits[0]
            # multiple identical names: prefer a Video hit deterministically
            if len(hits) > 1:
                return hits[0]
        return None

    video = exact_for({"Video"}) or best_for({"Video"})
    if video is not None:
        return video
    return exact_for({"Timeline"}) or best_for({"Timeline"})

    video = best_for({"Video"})
    if video is not None:
        return video
    return best_for({"Timeline"})

def find_chapters_yaml(marker):
    """Locate the interview's _chapters.yaml: prefer the name derived from the
    marker's sourceFile; fall back to any *_chapters.yaml in the folder."""
    folder = marker.get("folder", "")
    if not folder or not os.path.isdir(folder):
        return None
    src_base = source_base(marker.get("sourceFile", ""))
    candidates = []
    if src_base:
        candidates.append(os.path.join(folder, f"{src_base}_chapters.yaml"))
    try:
        candidates += [os.path.join(folder, f) for f in sorted(os.listdir(folder))
                       if f.endswith("_chapters.yaml") and os.path.join(folder, f) not in candidates]
    except Exception:
        pass
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def load_yaml_markers(chapters_path):
    """Load markers from a _chapters.yaml, sorted by start_s. Returns None on failure."""
    if not chapters_path or not os.path.isfile(chapters_path):
        return None
    try:
        import yaml as ymod
        with open(chapters_path, encoding="utf-8") as f:
            doc = ymod.safe_load(f)
        ms = doc.get("markers", []) if doc else []
        ms.sort(key=lambda x: x.get("start_s", 0))
        return ms
    except ImportError:
        # fallback: use json to parse basic YAML structure
        return _fallback_parse_yaml(chapters_path)
    except Exception:
        return None

def _fallback_parse_yaml(path):
    """Basic YAML parser for the summary structure (no PyYAML)."""
    markers = []
    cur = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^- id:\s*(\d+)", line)
            if m:
                if cur:
                    markers.append(cur)
                cur = {"start_s": 0, "end_s": 0, "name": "", "theme": "", "color": "", "notes": ""}
                cur["id"] = int(m.group(1))
                continue
            if cur is None:
                continue
            m = re.match(r"\s+start_s:\s*([\d.]+)", line)
            if m:
                cur["start_s"] = float(m.group(1))
                continue
            m = re.match(r"\s+end_s:\s*([\d.]+)", line)
            if m:
                cur["end_s"] = float(m.group(1))
                continue
            m = re.match(r"\s+name:\s*(.*)", line)
            if m:
                cur["name"] = m.group(1).strip().strip("'\"")
                continue
    if cur:
        markers.append(cur)
    markers.sort(key=lambda x: x.get("start_s", 0))
    return markers

def compute_section(markers, idx, source_duration):
    """Return (section_start_s, section_end_s) for marker at idx.

    Uses midpoints between adjacent markers as boundaries.
    """
    prev_s = 0
    if idx > 0:
        prev_mid = (markers[idx - 1]["start_s"] + markers[idx]["start_s"]) / 2
        prev_s = max(0, prev_mid)
    next_s = source_duration
    if idx + 1 < len(markers):
        next_mid = (markers[idx]["start_s"] + markers[idx + 1]["start_s"]) / 2
        next_s = min(source_duration, next_mid)
    return (prev_s, next_s)

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

def frame_to_srtx_tc(frames, fps):
    """Convert frame count to SRT timecode HH:MM:SS,mmm."""
    fps = max(1, fps)
    total_ms = int(round(frames / fps * 1000))
    h, rem = divmod(total_ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def write_srtx(path, entries, fps):
    """Write entries [(start_frame, dur_frames, text, speaker)] to an SRTX file.
    Format matches Resolve export: standard SRT millisecond timecodes,
    speaker on its own line, text with leading space."""
    with open(path, "w", encoding="utf-8") as f:
        for i, (sf, dur, text, speaker) in enumerate(entries, 1):
            tc_in = frame_to_srtx_tc(sf, fps)
            tc_out = frame_to_srtx_tc(sf + dur, fps)
            f.write(f"{i}\n{tc_in} --> {tc_out}\n\n{speaker}\n {text}\n\n")
    return path

def clean_srt_text(s):
    if not s:
        return ""
    s = re.sub(r"\s+", " ", s).strip()
    return s[:400].rstrip()

def main():
    try:
        _main()
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        with open(os.path.join(tempfile.gettempdir(), "create_timeline_error.log"), "w") as f:
            f.write(tb)
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

def _main():
    raw = sys.stdin.read()
    if not raw or not raw.strip():
        print(json.dumps({"error": "No input data."}))
        sys.exit(1)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON: {e}"}))
        sys.exit(1)

    timeline_name = data.get("name", "Untitled")
    markers = data.get("markers", [])
    group_gap_frames = data.get("groupGapFrames", 0)
    add_clip_markers = bool(data.get("addClipMarkers", True))
    add_subtitles = data.get("addSubtitles", False)
    srt_folder = data.get("srtFolder", "")
    if not markers:
        print(json.dumps({"error": "No markers."}))
        sys.exit(1)

    api_path = find_api()
    lib_path = find_lib()
    if not api_path or not lib_path:
        print(json.dumps({"error": "Resolve API not found."}))
        sys.exit(1)

    sys.path.insert(0, os.path.join(api_path, "Modules"))
    os.environ["RESOLVE_SCRIPT_API"] = api_path
    os.environ["RESOLVE_SCRIPT_LIB"] = lib_path

    import DaVinciResolveScript as dvr_script
    resolve = dvr_script.scriptapp("Resolve")
    if not resolve:
        hint = ("Could not connect to Resolve. "
                "Is DaVinci Resolve running with a project open? "
                "Check Resolve > Preferences > System > General > External scripting (Local/Network). "
                f"Looked for API at {api_path} and lib at {lib_path}.")
        print(json.dumps({"error": hint}))
        sys.exit(1)

    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        print(json.dumps({"error": "No project open."}))
        sys.exit(1)

    global FPS
    FPS = int(float(project.GetSetting("timelineFrameRate") or "25"))

    lookup, mp, root = build_lookup(project)
    if not lookup:
        print(json.dumps({"error": "No timelines in media pool."}))
        sys.exit(1)

    mp.SetCurrentFolder(root)

    # Remove existing timeline with same name — ONLY timeline-type items.
    # Deleting by name alone could destroy an unrelated video clip that
    # happens to share the name.
    for c in root.GetClipList():
        props = c.GetClipProperty()
        if props and props.get("Type") == "Timeline" and props.get("Clip Name") == timeline_name:
            mp.DeleteClips([c])

    new_tl = mp.CreateEmptyTimeline(timeline_name)
    if not new_tl:
        print(json.dumps({"error": f"Failed to create timeline '{timeline_name}'."}))
        sys.exit(1)

    project.SetCurrentTimeline(new_tl)

    added = 0
    failed = 0
    prev_group_id = None
    matched_names = []
    unmatched_keys = []
    yaml_cache: dict[str, list] = {}
    markers_log = []

    current_pos = 0
    record_frame_works = True  # assume true until we detect otherwise

    srt_entries = []  # (assembled_start_frame, dur_frames, text, speaker) in timeline frame space

    for m in markers:
        group_id = m.get("groupId")
        if prev_group_id is not None and group_id is not None and group_id != prev_group_id:
            if group_gap_frames > 0:
                current_pos += group_gap_frames
        prev_group_id = group_id

        key = m.get("folder", "") or m.get("interview", "")

        tl_item = find_item(lookup, m)
        if not tl_item:
            unmatched_keys.append(key)
            failed += 1
            markers_log.append({"key": key, "status": "no_item"})
            continue

        props = tl_item.GetClipProperty()
        tl_name = props.get("Clip Name", "?") if props else "?"
        clip_fps = float(props.get("FPS", 0) or 0) if props else 0
        clip_fps = clip_fps if clip_fps > 0 else FPS
        dur_s = float(props.get("Frames", 0)) / clip_fps if props else 0
        if tl_name not in matched_names:
            matched_names.append(tl_name)

        start_s = m.get("start_s", 0)
        end_s = m.get("end_s", start_s + 1)
        diff = end_s - start_s

        if diff < 5:
            yaml_file = find_chapters_yaml(m)
            if yaml_file not in yaml_cache:
                yaml_cache[yaml_file] = load_yaml_markers(yaml_file)
            all_ms = yaml_cache.get(yaml_file)
            if all_ms:
                idx = min(range(len(all_ms)), key=lambda i: abs(all_ms[i].get("start_s", 0) - start_s))
                src_dur = dur_s if dur_s > 0 else 99999
                section_start, section_end = compute_section(all_ms, idx, src_dur)
                start_s = max(0, section_start)
                end_s = min(src_dur, section_end)
                diff = end_s - start_s

        start_frame = max(0, sec_to_frame(start_s, clip_fps))
        end_frame = min(sec_to_frame(end_s, clip_fps), sec_to_frame(dur_s, clip_fps))
        dur_frames = max(1, end_frame - start_frame)

        try:
            item_info = {
                "mediaPoolItem": tl_item,
                "startFrame": start_frame,
                "endFrame": end_frame,
            }
            if record_frame_works and group_gap_frames > 0:
                item_info["recordFrame"] = current_pos
            result = mp.AppendToTimeline([item_info])
            gap_log(f"  append pos_requested={item_info.get('recordFrame', 'end')} key={key}")
            if result is None:
                unmatched_keys.append(key)
                failed += 1
                markers_log.append({"key": key, "status": "append_none"})
                continue
        except Exception as e:
            unmatched_keys.append(f"{key} ({e})")
            failed += 1
            markers_log.append({"key": key, "status": "append_error", "error": str(e)})
            continue
        time.sleep(0.3)

        # Verify recordFrame was respected
        if record_frame_works and group_gap_frames > 0:
            try:
                tl_items = new_tl.GetItemListInTrack("video", 1)
                if tl_items:
                    actual_start = int(tl_items[-1].GetStart() or 0)
                    expected_start = current_pos
                    gap_log(f"  verify: expected_start={expected_start} actual_start={actual_start}")
                    if actual_start != expected_start:
                        gap_log(f"  recordFrame IGNORED — disabling for rest of run")
                        record_frame_works = False
                        current_pos = actual_start + dur_frames
            except Exception as ex:
                gap_log(f"  verify error: {ex}")
                record_frame_works = False
                current_pos = 0

        # Advance position for next clip
        if record_frame_works and group_gap_frames > 0:
            current_pos += dur_frames
            gap_log(f"  pos after advance={current_pos}")

        # --- Set clip color (timeline item) ---
        try:
            new_tl_items = new_tl.GetItemListInTrack("video", 1)
            if new_tl_items:
                last_item = new_tl_items[-1]
                raw_color = m.get("color", "Tan")
                clip_color = "Blue" if raw_color == "Blue" else "Orange"
                last_item.SetClipColor(clip_color)
        except Exception:
            pass

        if add_clip_markers:
            # --- Marker position: try recordFrame first, else GetStart ---
            marker_frame = 1
            if record_frame_works and group_gap_frames > 0:
                marker_frame = max(1, current_pos - dur_frames + 1)
                gap_log(f"  marker at recordFrame={marker_frame}")
            else:
                try:
                    new_tl_items = new_tl.GetItemListInTrack("video", 1)
                    if new_tl_items:
                        last_item = new_tl_items[-1]
                        clip_start = last_item.GetStart()
                        if clip_start is not None:
                            marker_frame = max(1, int(clip_start) + 1)
                except Exception:
                    pass

            # --- Add marker ---
            raw_color = m.get("color", "Tan")
            color = COLOR_MAP.get(raw_color, "Blue")
            marker_name = m.get("name", "")
            notes = m.get("notes", "")[:300].replace('"', "'").replace("\\n", " ")
            added_ok = new_tl.AddMarker(marker_frame, color, marker_name, notes, dur_frames)
            markers_log.append({
                "key": key, "status": "ok",
                "raw_color": raw_color, "mapped_color": color,
                "marker_frame": marker_frame, "dur_frames": dur_frames,
                "add_marker_ok": added_ok,
            })
        added += 1

        # --- Caption text for subtitles (assembled timeline frame space) ---
        # Inside the loop: every clip contributes its own caption; frame
        # fallbacks cover addClipMarkers=false (beat-structure mode).
        if add_subtitles:
            cap_text = clean_srt_text(m.get("subtitleText") or m.get("name") or "")
            if cap_text:
                cap_frame = marker_frame if add_clip_markers else max(1, current_pos - dur_frames + 1)
                cap_start = max(0, cap_frame - 1)
                cap_end = cap_start + dur_frames
                try:
                    tl_items = new_tl.GetItemListInTrack("video", 1)
                    if tl_items:
                        last_item = tl_items[-1]
                        st = last_item.GetStart()
                        en = last_item.GetEnd()
                        if st is not None and en is not None:
                            cap_start = max(0, int(st))
                            cap_end = int(en)
                except Exception:
                    pass
                if cap_end > cap_start:
                    cap_speaker = m.get("speaker") or ""
                    srt_entries.append((cap_start, cap_end - cap_start, cap_text, cap_speaker))

    # ---- Beat-span markers (structure overlay; assembled-timeline seconds) ----
    beat_markers = data.get("beatMarkers") or []
    for bi, bm in enumerate(beat_markers):
        try:
            bs = float(bm.get("start_s", 0)); be = float(bm.get("end_s", 0))
            if be <= bs:
                continue
            b_start = max(0, sec_to_frame(bs, FPS))
            b_dur = max(1, sec_to_frame(be - bs, FPS))
            raw_bc = bm.get("color", "Purple")
            bc = COLOR_MAP.get(raw_bc, "Purple")
            b_name = str(bm.get("name", f"Beat {bi+1}"))[:200].replace('"', "'")
            b_note = str(bm.get("note", ""))[:300].replace('"', "'").replace("\\n", " ")
            ok = new_tl.AddMarker(b_start, bc, b_name, b_note, b_dur)
            gap_log(f"  beat span '{b_name}' @{b_start} dur={b_dur} color={bc} ok={ok}")
        except Exception as e:
            gap_log(f"  beat span error: {e}")

    srt_path = ""
    if add_subtitles and srt_entries:
        out_dir = srt_folder if srt_folder and os.path.isdir(srt_folder) else ""
        if not out_dir:
            for m in markers:
                cand = m.get("folder", "") or ""
                if cand and os.path.isdir(cand):
                    out_dir = cand
                    break
        if not out_dir:
            out_dir = "/tmp"
        safe_name = re.sub(r"[^A-Za-z0-9 _-]", "_", timeline_name).strip()
        srt_path = os.path.join(out_dir, f"{safe_name}.srtx")
        try:
            write_srtx(srt_path, srt_entries, FPS)
        except Exception as e:
            gap_log(f"  srtx write error: {e}")
            srt_path = ""

    with open(os.path.join(tempfile.gettempdir(), "assistanteditor_timeline_log.json"), "w") as lf:
        json.dump({
            "input_name": timeline_name,
            "group_gap_frames": group_gap_frames,
            "add_subtitles": add_subtitles,
            "total_markers": len(markers),
            "markers_log": markers_log,
            "srt_entries_count": len(srt_entries),
            "srt_path": srt_path,
        }, lf, indent=2)

    print(json.dumps({
        "status": "ok",
        "name": new_tl.GetName(),
        "total_markers": added,
        "failed": failed,
        "matched": matched_names,
        "unmatched": unmatched_keys,
        "srt_path": srt_path,
    }))

if __name__ == "__main__":
    main()
