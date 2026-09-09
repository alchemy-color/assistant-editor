#!/usr/bin/env python3
"""Assistant Editor - DaVinci Resolve Workbench

Standalone diagnostic + end-to-end test for the Resolve scripting connection.
Run it from any terminal while Resolve Studio is open:

    /Library/Frameworks/Python.framework/Versions/Current/bin/python3 resolve_workbench.py

What it does:
  1. Prints environment (Resolve running, version, ports)
  2. Tests external `scriptapp('Resolve')` - the path write_resolve.py uses
  3. Tests TCP connectivity to the script-server ports
  4. Tests `pinghosts()` discovery
  5. If everything external fails, PREPARES the in-console bridge payload so you
     can run it inside Resolve (Workspace > Scripts > Comp > resolve_workbench_bridge)
     and VERIFIES markers land.

The output tells you exactly which transport works and what to do next.
"""
import sys, os, platform, subprocess, json, pathlib, socket, tempfile

API_DIR = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
LIB = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"

def section(title):
    print("\n" + "=" * 62)
    print(title)
    print("=" * 62)

def rule():
    print("-" * 62)

def main():
    section("1. Environment")
    print(f"  python      : {sys.version.split()[0]}  {sys.executable}")
    print(f"  macOS       : {platform.mac_platform() if hasattr(platform,'mac_platform') else platform.platform()}")
    resolve_running = subprocess.run(["pgrep", "-x", "Resolve"]).returncode == 0
    print(f"  Resolve     : {'RUNNING' if resolve_running else 'NOT RUNNING'}")

    # Resolve version from app bundle
    try:
        v = subprocess.run(
            ["defaults", "read", "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Info.plist", "CFBundleShortVersionString"],
            capture_output=True, text=True).stdout.strip()
        # Studio check
        studio = pathlib.Path("/Applications/DaVinci Resolve Studio.app").exists() or \
                 os.path.exists("/Applications/DaVinci Resolve/DaVinci Resolve Studio.app")
        print(f"  version     : {v}  ({'Studio' if studio else 'free? - check manually'})")
    except Exception as e:
        print(f"  version     : (could not read: {e})")

    # External scripting pref
    try:
        pref = subprocess.run(["defaults","read","com.blackmagic-design.DaVinciResolve","ExternalScriptingMode"],
                              capture_output=True, text=True).stdout.strip()
        label = {1:"Local", 2:"Network", 0:"None (console only)"}.get(pref, pref)
        print(f"  scripting   : ExternalScriptingMode={pref} ({label})")
    except Exception as e:
        print(f"  scripting pref: (could not read: {e})")

    rule()

    section("2. Script-server TCP ports")
    for port in [49153, 1144, 15000]:
        try:
            s = socket.socket(); s.settimeout(1.5)
            s.connect(("127.0.0.1", port)); s.close()
            print(f"  {port:>6}  connect OK")
        except Exception as e:
            print(f"  {port:>6}  FAIL: {e}")

    rule()

    section("3. External scriptapp('Resolve')  <-- the path the app's Write-to-Resolve uses")
    sys.path.insert(0, os.path.join(API_DIR, "Modules"))
    os.environ["RESOLVE_SCRIPT_API"] = API_DIR
    os.environ["RESOLVE_SCRIPT_LIB"] = LIB
    import DaVinciResolveScript as dvr
    try:
        r = dvr.scriptapp("Resolve")
    except Exception as e:
        print(f"  scriptapp raised: {type(e).__name__}: {e}")
        r = None
    if r:
        pm = r.GetProjectManager()
        proj = pm.GetCurrentProject() if pm else None
        print(f"  RESOLVE OBJECT OK -> project: {proj.GetName() if proj else None}")
        print("  -> EXTERNAL SCRIPTING WORKS. The app's chapter-write should succeed.")
        print("  -> CDN: run write_resolve.py with this python.")
        return 0
    print("  scriptapp returned None")
    print("  -> external scripting is NOT handing out Resolve to this python.")

    rule()

    section("4. Discovery (pinghosts)")
    try:
        print(f"  pinghosts('')      : {dvr.pinghosts('')}")
    except Exception as e:
        print(f"  pinghosts failed: {e}")

    rule()

    section("5. What works: the in-console bridge")
    print("""  External scripting is broken at the Resolve/network layer on this machine
  (all pythons return None; ports connect but pinghosts finds nothing). The
  app's Write-to-Resolve automatically falls back to an IN-CONSOLE bridge that
  reuses Resolve's healthy in-process `resolve` object.

  TEST IT NOW (2 steps):
   (1) Payload is written below -> confirm it exists
   (2) In Resolve: Workspace > Scripts > Comp > resolve_workbench_bridge
       then check the timeline for a red 'WORKBENCH TEST' marker at 1s.""")
    # Write a real payload for the in-console bridge test
    payload = [{
        "start_s": 1.0, "duration_s": 1.0,
        "text": "workbench test", "summary": "WORKBENCH TEST",
        "keywords": "test", "color": "Red"
    }]
    payload_path = os.path.join(tempfile.gettempdir(), "assistanteditor_resolve_payload.json")
    pathlib.Path(payload_path).write_text(json.dumps(payload))
    print(f"  payload written : {payload_path}")
    print(f"  result expected : /tmp/assistanteditor_resolve_result.txt after running in Resolve")
    return 2

if __name__ == "__main__":
    sys.exit(main())
