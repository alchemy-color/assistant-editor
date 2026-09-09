#!/usr/bin/env python3
"""Standalone test — builds a sync timeline via EDL import.

Usage:
  python3 test_build_timeline.py <sync_results.json> [field_recorder_path]

Reads sync results JSON (from sync_from_timeline.py), generates an EDL,
and imports it into Resolve via Project.LoadEDLFile.
"""
import sys, json, os, tempfile, re, glob
sys.path.insert(0, "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
os.environ["RESOLVE_SCRIPT_API"] = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
lib = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
if not os.path.isfile(lib):
    lib = os.path.expanduser("~/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so")
os.environ["RESOLVE_SCRIPT_LIB"] = lib

import DaVinciResolveScript as dvr_script

FPS = 25

def sec_to_tc(s):
    f = int(round(s * FPS))
    h = f // (FPS * 3600)
    m = (f // (FPS * 60)) % 60
    sec = (f // FPS) % 60
    fr = f % FPS
    return f"{h:02d}:{m:02d}:{sec:02d}:{fr:02d}"

def gen_edl(results, fr_path):
    lines = ["TITLE: Sync Timeline", "FCM: NON-DROP FRAME", ""]
    for i, r in enumerate(results, 1):
        cn = r["clip_name"]
        sync_s = r.get("sync_time_s", 0)
        dur_s = r.get("clip_duration_s", 1)
        src_in = "00:00:00:00"
        src_out = sec_to_tc(dur_s)
        rec_in = sec_to_tc(sync_s)
        rec_out = sec_to_tc(sync_s + dur_s)
        lines.append(f"{i:03d}  AX       V     C        {src_in} {src_out} {rec_in} {rec_out}")
        lines.append(f"* FROM CLIP NAME: {cn}")
        lines.append("")
    return "\n".join(lines)

def main():
    if len(sys.argv) < 2:
        print("Usage: test_build_timeline.py <sync_results.json> [field_recorder]", file=sys.stderr)
        sys.exit(1)
    
    with open(sys.argv[1]) as f:
        data = json.load(f)
    
    results = data.get("results", [])
    fr_path = sys.argv[2] if len(sys.argv) > 2 else data.get("field_recorder", "")
    
    print(f"Results: {len(results)} clips")
    print(f"Field: {fr_path}")
    
    resolve = dvr_script.scriptapp("Resolve")
    if not resolve:
        print("FAIL: Could not connect to Resolve", file=sys.stderr)
        sys.exit(1)
    
    proj = resolve.GetProjectManager().GetCurrentProject()
    if not proj:
        print("FAIL: No project open", file=sys.stderr)
        sys.exit(1)
    
    global FPS
    FPS = int(float(proj.GetSetting("timelineFrameRate") or "25"))
    
    # Generate EDL
    edl = gen_edl(results, fr_path)
    
    edl_path = os.path.join(tempfile.gettempdir(), "assistanteditor_sync_test.edl")
    with open(edl_path, "w") as f:
        f.write(edl)
    print(f"EDL written to {edl_path}")
    for line in edl.split("\n")[:5]:
        print(f"  {line}")
    
    # Import EDL into Resolve
    try:
        tl = proj.LoadEDLFile(edl_path)
        print(f"LoadEDLFile -> {tl}")
        if tl:
            name = tl.GetName()
            print(f"Timeline created: {name}")
            proj.SetCurrentTimeline(tl)
        else:
            print("FAIL: LoadEDLFile returned None")
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"LoadEDLFile exception: {e}")

if __name__ == "__main__":
    main()
