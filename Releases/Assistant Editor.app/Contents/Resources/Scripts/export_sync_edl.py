#!/usr/bin/env python3
"""Generate a CMX3600 EDL from sync results for Resolve import.

Places each clip at its sync offset on a single video track.
When imported, Resolve creates a timeline — overlapping clips
(which capture the same moment from different angles) land on
the same track, ready for manual track expansion.

Usage: cat sync_results.json | python3 export_sync_edl.py > sync_timeline.edl

Input (stdin): {"results": [...], "field_recorder": "path"}
"""
import sys, json, os, re
import os

FPS = float(os.environ.get("AE_FPS", "25"))
FPS_INT = max(1, int(round(FPS)))

def sec_to_tc(s):
    # Integer frame math — float floor-division fed %d and crashed every run.
    f = int(round(s * FPS))
    h = f // (FPS_INT * 3600)
    m = (f // (FPS_INT * 60)) % 60
    sec = (f // FPS_INT) % 60
    fr = f % FPS_INT
    return f"{h:02d}:{m:02d}:{sec:02d}:{fr:02d}"

def source_base(path):
    name = os.path.basename(path)
    name = re.sub(r'_(?:transcript|transcripts)$', '', os.path.splitext(name)[0])
    return name

def main():
    raw = sys.stdin.read()
    data = json.loads(raw)
    results = data.get("results", [])
    fr_path = data.get("field_recorder", "")

    fr_name = source_base(fr_path) if fr_path else "Field Recorder"
    lines = []
    lines.append(f"TITLE: Sync Timeline - {fr_name}")
    lines.append("FCM: NON-DROP FRAME")
    lines.append("")

    event_num = 1
    for r in results:
        clip_name = r.get("clip_name", f"Clip_{event_num}")
        sync_s = r.get("sync_time_s", 0.0)
        duration_s = r.get("clip_duration_s", 1.0)
        confidence = r.get("confidence", 0.0)
        clip_path = r.get("clip_path", "")

        src_in = sec_to_tc(0)
        src_out = sec_to_tc(duration_s)
        rec_in = sec_to_tc(sync_s)
        rec_out = sec_to_tc(sync_s + duration_s)

        lines.append(f"{event_num:03d}  {clip_name:20} V     C        {src_in} {src_out} {rec_in} {rec_out}")
        if clip_path:
            lines.append(f"* FROM CLIP NAME: {os.path.basename(clip_path)}")
        lines.append(f"* SYNC: {sec_to_tc(sync_s)} CONFIDENCE: {confidence*100:.0f}% DURATION: {duration_s:.1f}s")
        lines.append("")

        event_num += 1

    print("\n".join(lines))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)
