#!/usr/bin/env python3
"""Build a synced Resolve timeline from sync results.

Strategy:
  1. Look up each clip in media pool to get source timecode
  2. Generate EDL with real source TC so Resolve can match clips
  3. Load EDL into Resolve via Project.LoadEDLFile
  4. Place field recording at frame 0
"""
import sys, json, os, re, glob, tempfile

def log(msg):
    print(json.dumps({"progress": msg}), file=sys.stderr, flush=True)

def fail(msg):
    s = json.dumps({"error": msg})
    print(s)
    print(s, file=sys.stderr)
    sys.exit(1)

FPS = 25

def tc_to_frames(tc):
    parts = tc.replace(",", ":").split(":")
    if len(parts) >= 4:
        h, m, s, f = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
    elif len(parts) == 3:
        h, m, s, f = 0, int(parts[0]), int(parts[1]), int(parts[2])
    else:
        return 0
    return (h * 3600 + m * 60 + s) * FPS + f

def frames_to_tc(frames):
    rf = max(0, int(round(frames)))
    h = rf // (FPS * 3600)
    m = (rf // (FPS * 60)) % 60
    s = (rf // FPS) % 60
    f = rf % FPS
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"

def sec_to_frames(s):
    return int(round(s * FPS))

def seconds_to_tc(s):
    return frames_to_tc(sec_to_frames(s))

def tc_add_frames(tc, add_frames, fps):
    return frames_to_tc(tc_to_frames(tc) + add_frames)

def find_resolve_api():
    for c in [
        os.environ.get("RESOLVE_SCRIPT_API", ""),
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting",
        os.path.expanduser("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"),
    ]:
        if c and os.path.isdir(os.path.join(c, "Modules")):
            return c
    return None

def find_resolve_lib():
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

def source_base(p):
    if not p:
        return ""
    b = os.path.basename(p)
    b = re.sub(r'_(?:transcript|transcripts)$', '', os.path.splitext(b)[0])
    b = re.sub(r'_subtitles$', '', b)
    b = re.sub(r'_rough$', '', b)
    return b

def build_lookup(project):
    mp = project.GetMediaPool()
    root = mp.GetRootFolder()
    lookup = {}
    def walk(f):
        for c in f.GetClipList():
            props = c.GetClipProperty()
            if props:
                lookup[props.get("Clip Name", "")] = c
        for s in f.GetSubFolderList():
            walk(s)
    walk(root)
    return lookup, mp, root

def find_item(lookup, hints):
    for raw in hints:
        if not raw:
            continue
        for name, item in lookup.items():
            if name == raw:
                return item
    return None

def safe_frames(props):
    if props is None:
        return 0
    raw = props.get("Frames", "0") or "0"
    return int(raw.strip()) if raw.strip() else 0

def main():
    try:
        _main()
    except Exception as e:
        import traceback
        with open(os.path.join(tempfile.gettempdir(), "sync_timeline_error.log"), "w") as ef:
            ef.write(traceback.format_exc())
        fail(str(e))

def _main():
    raw = sys.stdin.read()
    if not raw.strip():
        fail("No input.")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        fail(f"Invalid JSON: {e}")

    fr_path = data.get("field_recorder", "")
    results = data.get("results", [])
    if not results:
        fail("No results.")

    api_path = find_resolve_api()
    lib_path = find_resolve_lib()
    if not api_path or not lib_path:
        fail("Resolve API not found.")

    sys.path.insert(0, os.path.join(api_path, "Modules"))
    os.environ["RESOLVE_SCRIPT_API"] = api_path
    os.environ["RESOLVE_SCRIPT_LIB"] = lib_path

    import DaVinciResolveScript as dvr_script
    resolve = dvr_script.scriptapp("Resolve")
    if not resolve:
        fail("Could not connect to Resolve.")

    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        fail("No project open.")

    global FPS
    FPS = int(float(project.GetSetting("timelineFrameRate") or "25"))

    lookup, mp, root = build_lookup(project)
    log(f"Lookup has {len(lookup)} items")
    mp.SetCurrentFolder(root)

    log(f"Building EDL for {len(results)} clips at {FPS}fps")

    # Build EDL with REAL source timecodes from media pool
    edl_lines = ["TITLE: Assistant Editor Sync Timeline", "FCM: NON-DROP FRAME", ""]
    event = 1
    markers_only = []
    used = 0

    for r in results:
        cn = r["clip_name"]
        sync_s = r.get("sync_time_s", 0)
        dur_s = r.get("clip_duration_s", 0)
        conf = r.get("confidence", 0)
        if r.get("error") or conf < 0.05 or dur_s <= 0:
            markers_only.append({"clip": cn, "reason": r.get("error", f"Low confidence ({conf:.2f})")})
            continue

        item = find_item(lookup, [cn, os.path.basename(r.get("clip_path", ""))])
        if not item:
            markers_only.append({"clip": cn, "reason": "Not found in media pool"})
            continue

        props = item.GetClipProperty()
        src_tc = (props or {}).get("Start TC", "00:00:00:00")
        item_frames = safe_frames(props)
        if item_frames <= 0:
            item_frames = max(1, sec_to_frames(dur_s))

        # Source range = first dur_s of clip (matches record duration)
        src_out_tc = tc_add_frames(src_tc, sec_to_frames(dur_s), FPS)
        rec_in = seconds_to_tc(sync_s)
        rec_out = seconds_to_tc(sync_s + dur_s)

        edl_lines.append(f"{event:03d}  AX       V     C        {src_tc} {src_out_tc} {rec_in} {rec_out}")
        edl_lines.append(f"* FROM CLIP NAME: {cn}")
        edl_lines.append("")
        used += 1
        event += 1

    edl = "\n".join(edl_lines)
    edl_path = os.path.join(tempfile.gettempdir(), "assistanteditor_sync_timeline.edl")
    with open(edl_path, "w") as ef:
        ef.write(edl)
    log(f"EDL: {used} events, {len(edl)} bytes")

    # Delete any previous sync timeline
    fr_name = source_base(fr_path)
    tl_name = f"Sync: {fr_name}"
    for c in root.GetClipList():
        p = c.GetClipProperty()
        if p and p.get("Clip Name") == tl_name:
            mp.DeleteClips([c])

    # Load EDL
    log("Loading EDL...")
    new_tl = project.LoadEDLFile(edl_path)
    if not new_tl:
        fail("LoadEDLFile failed — Resolve could not create timeline from EDL.")

    try:
        new_tl.SetName(tl_name)
    except:
        pass
    project.SetCurrentTimeline(new_tl)
    log(f"Timeline '{tl_name}' created.")

    # Place field recording at frame 0 on A1
    if fr_path and os.path.isfile(fr_path):
        audio_count = new_tl.GetTrackCount("audio") or 0
        if audio_count < 1:
            new_tl.AddTrack("audio", 1)
            audio_count = 1
        for attempt in [audio_count, 0]:
            try:
                new_tl.SetCurrentTimecode("00:00:00:00")
                ok = new_tl.ImportIntoTimeline(fr_path, attempt)
                if ok:
                    log(f"Field recording placed on A{attempt}")
                    break
            except:
                pass

    print(json.dumps({
        "status": "ok",
        "timeline_name": tl_name,
        "edl_events": used,
        "markers_only": markers_only,
        "edl_preview": "\n".join(edl_lines[:6]),
    }, indent=2))

if __name__ == "__main__":
    main()
