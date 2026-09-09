import Foundation

enum PythonBridgeError: LocalizedError {
    case scriptNotFound(String)
    case executionFailed(String)
    case decodeFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let name): return "Script not found: \(name)"
        case .executionFailed(let msg): return "Python error: \(msg)"
        case .decodeFailed(let msg):    return "Parse error: \(msg)"
        case .timeout(let msg):         return "Timeout: \(msg)"
        }
    }
}

struct PythonBridge {

    static let transcriptsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Transcripts").path
    private static var runningProcess: Process?

    static var hasRunningProcess: Bool { runningProcess != nil }

    static func cancelRunning() {
        runningProcess?.terminate()
        runningProcess = nil
    }

    // MARK: - Frame Rate Detection

    static let knownFrameRates: [Double] = [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0]

    private static var fpsMemo: [String: Double] = [:]

    static func detectFrameRate(in folder: String, preferredBaseName: String? = nil) -> Double? {
        if let cached = fpsMemo[folder] { return cached }

        let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "mxf", "ts", "mts", "m2ts", "mpg", "mpeg"]
        var videos: [URL] = []
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else {
            fpsMemo[folder] = .nan
            return nil
        }
        for case let path as String in enumerator {
            let ext = (path as NSString).pathExtension.lowercased()
            guard videoExts.contains(ext) else { continue }
            videos.append(URL(fileURLWithPath: (folder as NSString).appendingPathComponent(path)))
        }
        guard !videos.isEmpty else {
            let rate = detectFrameRateFromTimecodes(in: folder)
            fpsMemo[folder] = rate ?? .nan
            return rate
        }
        if let base = preferredBaseName?.lowercased() {
            let stem = (base as NSString).deletingPathExtension
            videos.sort { a, b in
                let aStem = a.deletingPathExtension().lastPathComponent.lowercased()
                let bStem = b.deletingPathExtension().lastPathComponent.lowercased()
                let aMatch = aStem.hasPrefix(stem) || stem.hasPrefix(aStem)
                let bMatch = bStem.hasPrefix(stem) || stem.hasPrefix(bStem)
                if aMatch != bMatch { return aMatch }
                return aStem < bStem
            }
        }
        for video in videos {
            if let rate = videoFrameRate(video) {
                fpsMemo[folder] = rate
                return rate
            }
        }
        let fallback = detectFrameRateFromTimecodes(in: folder)
        fpsMemo[folder] = fallback ?? .nan
        return fallback
    }

    private static func videoFrameRate(_ video: URL) -> Double? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        proc.arguments = ["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=r_frame_rate:stream=avg_frame_rate",
                          "-of", "default=noprint_wrappers=1:nokey=1", video.path]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                if let rate = parseFrameRate(String(line)) {
                    return nearestKnownRate(rate)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func parseFrameRate(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "N/A", !t.hasPrefix("0/") else { return nil }
        let parts = t.split(separator: "/")
        guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 else { return nil }
        return n / d
    }

    private static func nearestKnownRate(_ rate: Double) -> Double {
        knownFrameRates.min { abs($0 - rate) < abs($1 - rate) } ?? 25.0
    }

    private static func detectFrameRateFromTimecodes(in folder: String) -> Double? {
        let regex = try? NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2}:(\d{2})"#)
        guard let regex else { return nil }
        var maxFrame = 0
        var foundAny = false
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return nil }
        for case let path as String in enumerator {
            let lower = path.lowercased()
            guard lower.hasSuffix(".srtx") || lower.hasSuffix(".txt") else { continue }
            let full = (folder as NSString).appendingPathComponent(path)
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let r = m.range(at: 1)
                if r.location != NSNotFound, let f = Int(ns.substring(with: r)) {
                    maxFrame = max(maxFrame, f)
                    foundAny = true
                }
            }
        }
        guard foundAny else { return nil }
        if maxFrame >= 59 { return 60.0 }
        if maxFrame >= 49 { return 50.0 }
        if maxFrame >= 29 { return 30.0 }
        if maxFrame >= 24 { return 25.0 }
        if maxFrame >= 23 { return 24.0 }
        return 23.976
    }

    static func scriptPath(_ name: String) -> String? {
        if let p = Bundle.main.path(forResource: name, ofType: "py", inDirectory: "Scripts") { return p }
        let dev = "\(transcriptsRoot)/../software/Assistant Editor-Xcode/Scripts/\(name).py"
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }


    /// Scripts print detailed {"error": "..."} to stdout but Swift used to surface
    /// only stderr — which left users staring at "Python error: " with no message.
    static func bestError(stdout: Data, stderr: Data) -> String {
        let out = String(data: stdout, encoding: .utf8) ?? ""
        // last non-empty line that parses as JSON with an "error" key
        for line in out.components(separatedBy: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let d = t.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let msg = obj["error"] as? String, !msg.isEmpty {
                return msg
            }
            break // only inspect the final line
        }
        let e = String(data: stderr, encoding: .utf8) ?? ""
        let trimmed = e.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown error (no output)" : String(trimmed.suffix(500))
    }

    /// oMLX connection info injected into every Python subprocess so scripts
    /// reach the same server the Swift UI is using — no hardcoded :11434.
    private static var omlxEnv: [String: String] {
        let ud = UserDefaults.standard
        let base = ud.string(forKey: "omlxBaseURL") ?? OMLXClient.defaultBaseURL
        let key = ud.string(forKey: "omlxAPIKey") ?? ""
        var e: [String: String] = ["OMLX_BASE_URL": base]
        if !key.isEmpty { e["OMLX_API_KEY"] = key }
        return e
    }

    static func runRaw(_ script: String, args: [String] = [],
                        stdin: Data? = nil,
                        envOverrides: [String: String] = [:],
                        timeoutSeconds: Double = 30) throws -> String {
        guard let scriptPath = scriptPath(script) else {
            throw PythonBridgeError.scriptNotFound(script)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/Library/Frameworks/Python.framework/Versions/Current/bin"
        let path = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
        env["PATH"] = path
        for (k, v) in omlxEnv { if env[k] == nil { env[k] = v } }
        for (k, v) in envOverrides {
            env[k] = v
        }
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        runningProcess = proc

        if let stdinData = stdin {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            try proc.run()
            inPipe.fileHandleForWriting.write(stdinData)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try proc.run()
        }

        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1000))
        let queue = DispatchQueue.global()
        let group = DispatchGroup()

        var timedOut = false
        group.enter()
        queue.async {
            let result = DispatchWorkItem {
                if proc.isRunning {
                    proc.terminate()
                    timedOut = true
                }
            }
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: result)
            proc.waitUntilExit()
            result.cancel()
            DispatchQueue.main.async { if runningProcess === proc { runningProcess = nil } }
            group.leave()
        }

        var outData = Data()
        var errData = Data()
        group.enter()
        queue.async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()

        if timedOut {
            throw PythonBridgeError.timeout("Python script '\(script)' exceeded \(Int(timeoutSeconds))s")
        }
        if proc.terminationStatus != 0 {
            throw PythonBridgeError.executionFailed(bestError(stdout: outData, stderr: errData))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    static func runRawProgress(_ script: String, args: [String] = [],
                                 stdin: Data? = nil,
                                 envOverrides: [String: String] = [:],
                                 timeoutSeconds: Double = 300,
                                 progress: @escaping (String) -> Void) throws -> String {
        guard let scriptPath = scriptPath(script) else {
            throw PythonBridgeError.scriptNotFound(script)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/Library/Frameworks/Python.framework/Versions/Current/bin"
        let path = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
        env["PATH"] = path
        for (k, v) in omlxEnv { if env[k] == nil { env[k] = v } }
        for (k, v) in envOverrides {
            env[k] = v
        }
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        runningProcess = proc

        if let stdinData = stdin {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            try proc.run()
            inPipe.fileHandleForWriting.write(stdinData)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try proc.run()
        }

        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1000))
        let group = DispatchGroup()
        var timedOut = false
        var capturedOutput = ""
        var capturedError = ""

        // Read stdout line by line in real time
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let line = String(data: data, encoding: .utf8) {
                capturedOutput += line
                for part in line.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
                    if let pdata = part.data(using: .utf8),
                       let pjson = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any],
                       let msg = pjson["progress"] as? String {
                        DispatchQueue.main.async { progress(msg) }
                    }
                }
            }
        }

        group.enter()
        DispatchQueue.global().async {
            let work = DispatchWorkItem {
                if proc.isRunning { proc.terminate(); timedOut = true }
            }
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: work)
            proc.waitUntilExit()
            work.cancel()
            out.fileHandleForReading.readabilityHandler = nil
            let remaining = out.fileHandleForReading.readDataToEndOfFile()
            if let rest = String(data: remaining, encoding: .utf8), !rest.isEmpty {
                capturedOutput += rest
            }
            capturedError = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { if runningProcess === proc { runningProcess = nil } }
            group.leave()
        }
        group.wait()

        if timedOut {
            throw PythonBridgeError.timeout("Python script '\(script)' exceeded \(Int(timeoutSeconds))s")
        }
        if proc.terminationStatus != 0 {
            let stdoutData = Data(capturedOutput.utf8)
            throw PythonBridgeError.executionFailed(bestError(stdout: stdoutData, stderr: Data(capturedError.utf8)))
        }
        return capturedOutput
    }

    static func runJSON<T: Decodable>(_ script: String, args: [String] = [],
                                        as type: T.Type) throws -> T {
        let raw = try runRaw(script, args: args)
        guard let data = raw.data(using: .utf8) else {
            throw PythonBridgeError.decodeFailed("Not UTF-8")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func scanSummaries(root: String = transcriptsRoot) throws -> [SummaryDocument] {
        let docs: [SummaryDocument] = try runJSON("scan_summaries",
            args: [root], as: [SummaryDocument].self)
        return docs
    }
}
