#!/usr/bin/env python3
"""Read marker JSON from stdin and add timeline markers to the current Resolve project.

Input: JSON array of marker objects:
  [{"start_s": float, "duration_s": float, "text": "...", "summary": "...", "keywords": "...", "color": "..."}]
Seconds are converted to frames using the timeline's real frame rate (timelineFrameRate
project setting), so markers land correctly on 25fps, 30fps or any other timeline.
Legacy "frame_id"/"duration" (frame-based) fields are still accepted.

Workaround for Resolve API bug: AddMarker fails when color changes between successive calls.
Solution: group all markers by color first, then add each color group in one batch.
"""
import sys, json, os, glob

RESOLVE_COLORS = [
    "Blue","Cyan","Green","Yellow","Red","Pink","Purple","Fuchsia",
    "Rose","Lavender","Sky","Mint","Lemon","Peach","Gold","Chocolate","Cream","Lime"
]

# NOTE: Gold, Peach, Chocolate, and Lime are broken in Resolve's AddMarker API
# on this install.  We map them to Yellow, Rose, Cream, and Mint as best
# visual alternatives.
COLOR_MAP = {
    "Tan": "Yellow", "Orange": "Rose", "Cyan": "Sky",
    "Mint": "Mint", "Green": "Green", "Rose": "Rose", "Lemon": "Lemon",
    "Blue": "Blue", "Yellow": "Yellow", "Red": "Red", "Pink": "Pink",
    "Purple": "Purple", "Fuchsia": "Fuchsia", "Lavender": "Lavender",
    "Sky": "Sky",
    "Peach": "Rose",   # broken → Rose
    "Gold": "Yellow",  # broken → Yellow
    "Chocolate": "Cream",  # broken → Cream
    "Cream": "Cream",
    "Lime": "Mint",    # broken → Mint
}


def find_resolve_api():
    env = os.environ.get("RESOLVE_SCRIPT_API", "")
    if env and os.path.isdir(os.path.join(env, "Modules")):
        return env
    candidates = [
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting",
        os.path.expanduser("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "Modules")):
            return c
    return None


def find_resolve_lib():
    env = os.environ.get("RESOLVE_SCRIPT_LIB", "")
    if env and os.path.isfile(env):
        return env
    candidates = [
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so",
        os.path.expanduser("~/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    for root in ["/Applications", os.path.expanduser("~/Applications")]:
        pattern = os.path.join(root, "DaVinci Resolve*/**/fusionscript.so")
        for match in glob.glob(pattern, recursive=True):
            return match
    return None


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({"error": "No input data received on stdin."}))
        sys.exit(1)

    try:
        markers_in = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON on stdin: {e}"}))
        sys.exit(1)

    if not isinstance(markers_in, list):
        print(json.dumps({"error": "Expected a JSON array on stdin."}))
        sys.exit(1)

    api_path = find_resolve_api()
    lib_path = find_resolve_lib()
    if not api_path or not lib_path:
        print(json.dumps({"error": "Resolve API not found"}))
        sys.exit(1)

    modules_path = os.path.join(api_path, "Modules")
    if modules_path not in sys.path:
        sys.path.insert(0, modules_path)
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

    # Read the timeline's real frame rate (falls back to 25fps)
    try:
        fps = int(float(project.GetSetting("timelineFrameRate") or "25"))
    except (ValueError, TypeError):
        fps = 25

    timeline = project.GetCurrentTimeline()
    if not timeline:
        print(json.dumps({"error": "No timeline open."}))
        sys.exit(1)

    # Clear all existing timeline markers
    for c in RESOLVE_COLORS:
        timeline.DeleteMarkersByColor(c)

    # Group markers by resolved color to work around AddMarker API bug
    # (AddMarker fails when color changes between calls)
    by_color: dict[str, list] = {}
    for m in markers_in:
        app_color = m.get("color", "")
        resolve_color = COLOR_MAP.get(app_color, "Blue")
        by_color.setdefault(resolve_color, []).append(m)

    added = 0
    failed = 0
    for resolve_color, group in by_color.items():
        for m in group:
            if "start_s" in m:
                frame_id = int(round(float(m["start_s"]) * fps))
                duration = max(1, int(round(float(m.get("duration_s", 1.0)) * fps)))
            else:
                # Legacy frame-based input
                frame_id = int(m.get("frame_id", 0))
                duration = int(m.get("duration", 1))
            notes = m.get("text", "")[:300].replace('"', "'").replace("\\n", " ")
            name = m.get("summary", "").replace('"', "'")
            ok = timeline.AddMarker(frame_id, resolve_color, name, notes, duration)
            if ok:
                added += 1
            else:
                failed += 1

    print(json.dumps({
        "status": "ok",
        "total_markers": added,
        "failed": failed,
    }))


if __name__ == "__main__":
    main()
