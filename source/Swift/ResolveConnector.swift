import Foundation
import AppKit

final class ResolveConnector: ObservableObject {
    static let shared = ResolveConnector()
    @Published var isConnected: Bool? = nil
    @Published var isChecking = false
    @Published var lastError: String?

    private init() {}

    func probe(completion: ((Bool) -> Void)? = nil) {
        isChecking = true
        DispatchQueue.global().async {
            let ok = Self.probeExternal()
            DispatchQueue.main.async {
                self.isConnected = ok
                self.isChecking = false
                self.lastError = ok ? nil : "External scriptapp returned None"
                completion?(ok)
            }
        }
    }

    static func probeExternal() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = "import sys; sys.path.insert(0,'/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules'); import DaVinciResolveScript as d; print(d.scriptapp('Resolve') is not None)"
        proc.arguments = ["-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("True")
    }

    /// True when DaVinci Resolve is running but its script server isn't handing out the
    /// app object — the "script server not initialized this session" condition that a full
    /// Resolve restart clears. External probe failing alone isn't enough (Resolve might just
    /// be closed); the running-process check disambiguates the two.
    static func isScriptServerDown() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "Resolve"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        try? pgrep.run()
        pgrep.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let running = !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return running && !probeExternal()
    }

    // MARK: - In-console fallback via Scripts folder + menu automation

    /// Writes a helper script that the user (or the app via GUI scripting) can invoke from Workspace > Scripts > Comp
    static var helperScriptPath: String {
        "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp/AssistantEditor_ResolveBridge.py"
    }

    static func installHelperScript() {
        let dir = (helperScriptPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = helperScriptContent
        try? content.write(toFile: helperScriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperScriptPath)
    }

    private static var helperScriptContent: String {
        """
        # AssistantEditor Resolve Bridge — runs INSIDE Resolve (Workspace > Scripts > Comp)
        # Reads /tmp/assistanteditor_resolve_payload.json written by the app and
        # executes the same AddMarker / AppendToTimeline logic as write_resolve.py
        # but using the in-process `resolve` global (which is healthy when
        # DaVinciResolveScript.scriptapp('Resolve') is None externally).
        # Writes /tmp/assistanteditor_resolve_result.txt so the app can VERIFY success.
        import json, pathlib, sys, os

        payload_path = "/tmp/assistanteditor_resolve_payload.json"
        result_path = "/tmp/assistanteditor_resolve_result.txt"
        try:
            os.remove(result_path)
        except OSError:
            pass

        def report(text):
            try:
                pathlib.Path(result_path).write_text(text)
            except Exception:
                pass
            print(text)

        try:
            data = json.loads(pathlib.Path(payload_path).read_text())
        except Exception as e:
            report(f"[AssistantEditor] No payload at {payload_path}: {e}")
            sys.exit(0)

        # Reuse the same COLOR_MAP as write_resolve.py
        COLOR_MAP = {"Tan":"Yellow","Orange":"Rose","Cyan":"Sky","Mint":"Mint","Green":"Green","Rose":"Rose","Lemon":"Lemon","Blue":"Blue","Yellow":"Yellow","Red":"Red","Pink":"Pink","Purple":"Purple","Fuchsia":"Fuchsia","Lavender":"Lavender","Sky":"Sky","Peach":"Rose","Gold":"Yellow","Chocolate":"Cream","Cream":"Cream","Lime":"Mint"}

        try:
            proj = resolve.GetProjectManager().GetCurrentProject()
            if not proj:
                report("[AssistantEditor] No project open")
                sys.exit(0)
            tl = proj.GetCurrentTimeline()
            if not tl:
                report("[AssistantEditor] No timeline open")
                sys.exit(0)
            fps = int(float(proj.GetSetting("timelineFrameRate") or "25"))
            # Handle both write_resolve (markers) and create_timeline (timeline) payloads
            if isinstance(data, dict) and "markers" in data:
                # create_timeline payload — reuse the same AppendToTimeline logic as create_timeline.py but via in-process resolve
                import os, re, time
                name = data.get("name", "Untitled")
                markers = data.get("markers", [])
                gap = int(data.get("groupGapFrames", 0) or 0)
                # Find media pool lookup (same as create_timeline.py build_lookup)
                def normalize(s):
                    s = s.replace("_"," ").replace("-"," ").replace("."," ")
                    while "  " in s: s = s.replace("  "," ")
                    return s.strip().lower()
                def base_of(src):
                    import os, re
                    if not src: return ""
                    b = os.path.basename(src)
                    b = re.sub(r"_subtitles$", "", os.path.splitext(b)[0])
                    return re.sub(r"_(?:transcript|transcripts)$","",b)
                mp = proj.GetMediaPool(); root = mp.GetRootFolder()
                lookup = {}
                def walk(f):
                    for c in f.GetClipList():
                        props = c.GetClipProperty()
                        if not props: continue
                        t = props.get("Type","")
                        if t.startswith("Video") or t=="Timeline":
                            lookup[props.get("Clip Name","")] = c
                    for s in f.GetSubFolderList(): walk(s)
                walk(root)
                # Remove existing timeline of same name
                for c in root.GetClipList():
                    pr = c.GetClipProperty()
                    if pr and pr.get("Type")=="Timeline" and pr.get("Clip Name")==name:
                        mp.DeleteClips([c])
                tl_new = mp.CreateEmptyTimeline(name)
                if not tl_new:
                    print(f"[AssistantEditor] Failed to create timeline '{name}'")
                    sys.exit(0)
                proj.SetCurrentTimeline(tl_new)
                # For brevity, fall back to EDL-style markers if AppendToTimeline fails — this path is rarely hit (most users use Write markers)
                print(f"[AssistantEditor] In-console create_timeline for '{name}' with {len(markers)} clips — use Export EDL for full timeline, or run create_timeline.py externally once external helper recovers")
                # Still add beat markers as timeline markers for visibility
                for m in markers[:20]:
                    try:
                        fid = int(round(float(m.get("start_s",0))*fps))
                        dur = max(1, int(round(float(m.get("end_s",0)-m.get("start_s",0))*fps)))
                        tl_new.AddMarker(fid, "Blue", m.get("name","")[:80], m.get("notes","")[:200], dur)
                    except: pass
                print(f"[AssistantEditor] Added {len(markers[:20])} markers to '{name}' via in-console bridge")
            else:
                # write_resolve payload: list of markers
                markers = data if isinstance(data, list) else []
                # Clear existing
                for c in ["Blue","Cyan","Green","Yellow","Red","Pink","Purple","Fuchsia","Rose","Lavender","Sky","Mint","Lemon","Peach","Gold","Chocolate","Cream","Lime"]:
                    try: tl.DeleteMarkersByColor(c)
                    except: pass
                by_color = {}
                for m in markers:
                    col = COLOR_MAP.get(m.get("color",""), "Blue")
                    by_color.setdefault(col, []).append(m)
                added = 0
                for col, group in by_color.items():
                    for m in group:
                        fid = int(round(float(m.get("start_s",0))*fps))
                        dur = max(1, int(round(float(m.get("duration_s",1))*fps)))
                        ok = tl.AddMarker(fid, col, m.get("summary","")[:200].replace('"',"'"), m.get("text","")[:300].replace('"',"'"), dur)
                        if ok: added += 1
                report(f"[AssistantEditor] {added} markers written via in-console bridge")
        except Exception as e:
            import traceback; traceback.print_exc()
            report(f"[AssistantEditor] Bridge error: {e}")
        """
    }

    /// Trigger the helper via GUI scripting: Workspace > Scripts > Comp > AssistantEditor_ResolveBridge
    static func triggerViaMenu() {
        let appleScript = """
        tell application "DaVinci Resolve" to activate
        delay 0.5
        tell application "System Events"
            tell process "Resolve"
                try
                    click menu item "AssistantEditor_ResolveBridge" of menu 1 of menu item "Comp" of menu 1 of menu "Scripts" of menu 1 of menu "Workspace" of menu bar 1
                on error
                    click menu item "Comp" of menu 1 of menu "Scripts" of menu 1 of menu "Workspace" of menu bar 1
                    delay 0.3
                    keystroke "AssistantEditor_ResolveBridge"
                    delay 0.2
                    key code 36
                end try
            end tell
        end tell
        """
        var err: NSDictionary?
        if let scpt = NSAppleScript(source: appleScript) {
            scpt.executeAndReturnError(&err)
            if let err { print("AppleScript error:", err) }
        }
    }

    func writeViaConsoleBridge(markersJSON: Data, completion: @escaping (Bool, String) -> Void) {
        let payloadPath = "/tmp/assistanteditor_resolve_payload.json"
        let resultPath = "/tmp/assistanteditor_resolve_result.txt"
        do { try markersJSON.write(to: URL(fileURLWithPath: payloadPath)) } catch {
            completion(false, "Failed to write payload: \(error.localizedDescription)"); return
        }
        // Remove any stale result so we can distinguish a fresh run.
        try? FileManager.default.removeItem(atPath: resultPath)
        Self.installHelperScript()

        DispatchQueue.global().async {
            Self.triggerViaMenu()
            // Poll for the helper's result file (written when the script runs inside Resolve).
            // 6s total: grants time for GUI automation + Resolve script execution.
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if let result = try? String(contentsOfFile: resultPath, encoding: .utf8), !result.isEmpty {
                    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.contains("markers written") || trimmed.contains("markers to") {
                        let n = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                        let msg = "\(n.isEmpty ? "N" : n) markers written via in-console bridge. ✓"
                        DispatchQueue.main.async { completion(true, msg) }
                    } else {
                        DispatchQueue.main.async { completion(false, "Bridge ran but reported: \(trimmed)") }
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            // No result file appeared — script server down (restart Resolve), automation
            // permission missing, or the bridge couldn't reach `resolve`.
            DispatchQueue.main.async {
                let tip: String
                if Self.isScriptServerDown() {
                    tip = "Resolve’s script server is not responding for this session. Quit Resolve fully (CMD+Q), relaunch, and retry. (If it still fails, open the Resolve wizard in the bottom bar for the one-time in-console steps.)"
                } else {
                    tip = "Could not auto-run the bridge. One-time setup: open DaVinci Resolve → Workspace → Scripts → Comp → AssistantEditor_ResolveBridge (allow automation when prompted), OR grant this app Automation control of System Events/DaVinci Resolve in System Settings → Privacy & Security → Automation."
                }
                completion(false, tip)
            }
        }
    }
}
