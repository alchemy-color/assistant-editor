import Foundation

struct ProjectTheme: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    var keywords: [String]
    var weight: Double
    var color: String
}

struct ProjectSpeaker: Codable, Identifiable {
    var id: String { name }
    let name: String
    var durationS: Double
    var cueCount: Int
}

struct ProjectInterview: Codable, Identifiable {
    var id: String { "\(folderPath)/\(title)" }
    let title: String
    var folderPath: String
    var excluded: Bool
    var hasSubtitles: Bool
    var hasTranscript: Bool
    var hasChapters: Bool
    var hasSynopsis: Bool
    var durationS: Double
    var cueCount: Int
    var speakers: [String]
    var chapterCount: Int
    var synopsisSubjectCount: Int
    var transcriptWordCount: Int
    var fileSizeSrtx: Int64
    var fileSizeTranscript: Int64
    var fileSizeChapters: Int64
    var fileSizeSynopsis: Int64
}

struct ProjectFolder: Codable, Identifiable {
    var id: String { path }
    let path: String
    var interviews: [ProjectInterview]
}

struct ProjectStats: Codable {
    var totalInterviews: Int
    var totalDurationS: Double
    var totalCues: Int
    var speakers: [ProjectSpeaker]
    var frequentWords: [WordCount]
}

struct WordCount: Codable, Hashable {
    let word: String
    let count: Int
}

struct ProjectAnalysis: Codable {
    var version: Int
    var folders: [ProjectFolder]
    var themes: [ProjectTheme]
    var stats: ProjectStats
    var createdAt: String

    static let defaultThemeColors = ["Blue", "Orange", "Cyan", "Mint", "Green", "Rose", "Lemon", "Tan", "Sky", "Purple"]

    static func empty() -> ProjectAnalysis {
        ProjectAnalysis(
            version: 1,
            folders: [],
            themes: [],
            stats: ProjectStats(totalInterviews: 0, totalDurationS: 0, totalCues: 0, speakers: [], frequentWords: []),
            createdAt: ""
        )
    }
}

// MARK: - Persistence

extension ProjectAnalysis {
    /// Canonical filename for a folder's analysis, named after the containing
    /// folder: `Bairrada_project.yaml` for a root, `07-03_Carlos Campolargo_project.yaml`
    /// for a single-material folder. Matches the folder's own name so the file
    /// "acknowledges" the folder it describes.
    static func yamlFileName(for folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        return "\(name)_project.yaml"
    }

    static func yamlPath(for folder: String) -> String {
        (folder as NSString).appendingPathComponent(yamlFileName(for: folder))
    }

    /// Acknowledges manually-renamed analysis files. Preference order in `folder`:
    /// 1. exact canonical `<folderName>_project.yaml`
    /// 2. legacy `_project.yaml`
    /// 3. a single `*_project.yaml` (a manual rename)
    /// 4. among several, one whose prefix matches the folder name
    static func findProjectYaml(in folder: String) -> String? {
        let fm = FileManager.default
        let folderPath = (folder as NSString)
        guard let items = try? fm.contentsOfDirectory(atPath: folder) else { return nil }

        let canonical = yamlFileName(for: folder)
        if items.contains(canonical), fm.fileExists(atPath: yamlPath(for: folder)) {
            return yamlPath(for: folder)
        }

        let legacy = folderPath.appendingPathComponent("_project.yaml")
        if fm.fileExists(atPath: legacy) { return legacy }

        let candidates = items
            .filter { $0.hasSuffix("_project.yaml") }
            .filter { !$0.hasPrefix(".") }
        if candidates.count == 1 {
            return folderPath.appendingPathComponent(candidates[0])
        }
        if candidates.count > 1 {
            let base = folderPath.lastPathComponent
            if candidates.contains(base + "_project.yaml") {
                return folderPath.appendingPathComponent(base + "_project.yaml")
            }
            if let match = candidates.first(where: { $0.lowercased().hasPrefix(base.lowercased()) }) {
                return folderPath.appendingPathComponent(match)
            }
        }
        return nil
    }

    /// The path analysis should be written to for a folder: the existing found
    /// file (acknowledging a manual rename or legacy name) else the canonical one.
    static func yamlWriteTarget(for folder: String) -> String {
        findProjectYaml(in: folder) ?? yamlPath(for: folder)
    }

    /// Escapes a value for safe inclusion inside a double-quoted YAML scalar.
    /// Backslashes, double quotes, and control/newline characters are escaped so
    /// titles/names/keywords containing them cannot corrupt `_project.yaml`.
    static func yamlEscaped(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.unicodeScalars.first?.value ?? 0 < 0x20 {
                    out += String(format: "\\u{%02X}", ch.unicodeScalars.first!.value)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    func save(to folder: String) {
        let path = ProjectAnalysis.yamlWriteTarget(for: folder)
        guard let data = try? JSONEncoder().encode(self) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var yaml = "version: \(json["version"] ?? 1)\n\n"

        // folders
        if let folders = json["folders"] as? [[String: Any]] {
            yaml += "folders:\n"
            for folder in folders {
                yaml += "  - path: \"\(Self.yamlEscaped(folder["path"] as? String ?? ""))\"\n"
                if let interviews = folder["interviews"] as? [[String: Any]] {
                    yaml += "    interviews:\n"
                    for iv in interviews {
                        let ex = (iv["excluded"] as? Bool) ?? (((iv["excluded"] as? Int) ?? 0) != 0)
                        let hs = (iv["hasSubtitles"] as? Bool) ?? (((iv["hasSubtitles"] as? Int) ?? 0) != 0)
                        let ht = (iv["hasTranscript"] as? Bool) ?? (((iv["hasTranscript"] as? Int) ?? 0) != 0)
                        yaml += "      - title: \"\(Self.yamlEscaped(iv["title"] as? String ?? ""))\"\n"
                        yaml += "        excluded: \(ex)\n"
                        yaml += "        hasSubtitles: \(hs)\n"
                        yaml += "        hasTranscript: \(ht)\n"
                    }
                }
            }
            yaml += "\n"
        }

        // themes
        if let themes = json["themes"] as? [[String: Any]] {
            yaml += "themes:\n"
            for theme in themes {
                yaml += "  - name: \"\(Self.yamlEscaped(theme["name"] as? String ?? ""))\"\n"
                if let keywords = theme["keywords"] as? [String] {
                    yaml += "    keywords: [\(keywords.map { "\"\(Self.yamlEscaped($0))\"" }.joined(separator: ", "))]\n"
                }
                yaml += "    weight: \(theme["weight"] ?? 0.5)\n"
                yaml += "    color: \"\(Self.yamlEscaped(theme["color"] as? String ?? "Tan"))\"\n"
            }
            yaml += "\n"
        }

        // stats
        if let stats = json["stats"] as? [String: Any] {
            yaml += "stats:\n"
            yaml += "  totalInterviews: \(stats["totalInterviews"] ?? 0)\n"
            yaml += "  totalDurationS: \(stats["totalDurationS"] ?? 0)\n"
            yaml += "  totalCues: \(stats["totalCues"] ?? 0)\n"
            if let speakers = stats["speakers"] as? [[String: Any]], !speakers.isEmpty {
                yaml += "  speakers:\n"
                for sp in speakers.prefix(15) {
                    yaml += "    - name: \"\(Self.yamlEscaped(sp["name"] as? String ?? ""))\"\n"
                    yaml += "      durationS: \(sp["durationS"] ?? 0)\n"
                    yaml += "      cueCount: \(sp["cueCount"] ?? 0)\n"
                }
            }
            if let words = stats["frequentWords"] as? [[String: Any]], !words.isEmpty {
                yaml += "  frequentWords:\n"
                for w in words.prefix(30) {
                    if let word = w["word"] as? String, let count = w["count"] as? Int {
                        yaml += "    - [\"\(Self.yamlEscaped(word))\", \(count)]\n"
                    }
                }
            }
        }

        try? yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Original-weights baseline (survives restarts)

    /// Sidecar holding the pristine post-analyze balance: `.project_original.json`
    /// next to `_project.yaml`. Written ONLY by analyze/merge — never by slider saves —
    /// so Reset Weighing can always return to the true original.
    static func originalWeightsPath(for baseFolder: String) -> String {
        let dir = (yamlPath(for: baseFolder) as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent(".project_original.json")
    }

    func saveOriginalWeights(to baseFolder: String) {
        let dict = Dictionary(uniqueKeysWithValues: themes.map { ($0.name, $0.weight) })
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.originalWeightsPath(for: baseFolder)))
    }

    static func loadOriginalWeights(from baseFolder: String) -> [String: Double]? {
        guard let data = FileManager.default.contents(atPath: originalWeightsPath(for: baseFolder)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              !dict.isEmpty else { return nil }
        return dict
    }

    /// Returns the closest folder (this one or an ancestor) that carries a
    /// project analysis file (any `*_project.yaml`). Analysis is written to a
    /// project root, while the stored source folder may be any subfolder of it.
    static func nearestProjectYamlFolder(for folder: String) -> String? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: folder)
        if findProjectYaml(in: url.path) != nil { return url.path }
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            guard url.path != "/" else { break }
            if findProjectYaml(in: url.path) != nil { return url.path }
        }
        return nil
    }

    static func load(from folder: String) -> ProjectAnalysis? {
        guard let path = findProjectYaml(in: folder),
              let yamlText = try? String(contentsOfFile: path, encoding: .utf8),
              let rawTree = Yaml.parse(yamlText) else { return nil }
        let tree = Yaml.sanitize(rawTree, rootFolder: folder)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: tree),
              let analysis = try? JSONDecoder().decode(ProjectAnalysis.self, from: jsonData) else { return nil }
        return analysis
    }
}

// MARK: - Material flag refresh (filesystem only, no LLM)

extension ProjectAnalysis {
    /// Re-checks which companion materials exist on disk for each interview.
    /// Fast (FileManager only) — keeps a YAML-loaded report accurate without re-analysis.
    mutating func refreshMaterialFlags() {
        let fm = FileManager.default
        for fi in folders.indices {
            for ii in folders[fi].interviews.indices {
                let iv = folders[fi].interviews[ii]
                let dir = iv.folderPath
                guard fm.fileExists(atPath: dir) else { continue }
                let cleanBase = iv.title.replacingOccurrences(of: " ", with: "_")
                let candidates = { (suffixes: [String]) -> String? in
                    for suffix in suffixes {
                        let p = (dir as NSString).appendingPathComponent(cleanBase + suffix)
                        if fm.fileExists(atPath: p) { return p }
                    }
                    return nil
                }

                var updated = iv

                // Subtitles: <base>.srtx / .srt / _subtitles.srtx / _subtitles.srt / .txt
                if candidates([".srtx", ".srt", "_subtitles.srtx", "_subtitles.srt", ".txt"]) != nil {
                    updated.hasSubtitles = true
                }

                // Transcript: paired transcript txt (accepts _transcript or _transcripts)
                if let tp = candidates(["_transcript.txt", "_transcripts.txt"]) {
                    updated.hasTranscript = true
                    if let attr = try? fm.attributesOfItem(atPath: tp),
                       let size = attr[.size] as? Int64, size > 0 {
                        updated.fileSizeTranscript = size
                    }
                }

                // Chapters
                if let cp = candidates(["_chapters.yaml", "_transcript_chapters.yaml"]) {
                    updated.hasChapters = true
                    if let attr = try? fm.attributesOfItem(atPath: cp) {
                        updated.fileSizeChapters = attr[.size] as? Int64 ?? 0
                    }
                } else {
                    updated.hasChapters = false
                    updated.chapterCount = 0
                }

                // Synopsis
                if let sp = candidates(["_synopsis.txt", "_transcript_synopsis.txt"]) {
                    updated.hasSynopsis = true
                    if let text = try? String(contentsOfFile: sp, encoding: .utf8) {
                        updated.synopsisSubjectCount = text.components(separatedBy: "\n")
                            .filter { $0.contains("Subject ") && $0.contains(":") }.count
                    }
                } else {
                    updated.hasSynopsis = false
                    updated.synopsisSubjectCount = 0
                }

                folders[fi].interviews[ii] = updated
            }
        }
    }
}

// MARK: - Minimal YAML reader (tailored to the _project.yaml format)

enum Yaml {

    /// Parses a strict subset of YAML: nested maps, lists of maps, scalars, inline arrays.
    static func parse(_ text: String) -> [String: Any]? {
        var lines: [(indent: Int, content: String)] = []
        // Split on any line-ending (LF, CRLF or bare CR) so Windows-written files load.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.count - raw.drop(while: { $0 == " " }).count
            lines.append((indent, trimmed))
        }
        guard !lines.isEmpty else { return nil }
        var idx = 0
        if lines[0].content.hasPrefix("- ") {
            let list = parseList(lines, &idx, indent: lines[0].indent)
            return ["__root": list]
        }
        return parseMap(lines, &idx, indent: lines[0].indent)
    }

    private static func parseMap(_ lines: [(indent: Int, content: String)], _ idx: inout Int, indent: Int) -> [String: Any] {
        var map: [String: Any] = [:]
        while idx < lines.count {
            let (ind, content) = lines[idx]
            if ind < indent || content.hasPrefix("- ") { break }
            guard ind == indent, let colon = content.firstIndex(of: ":") else { idx += 1; continue }
            let key = String(content[content.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            idx += 1
            if rest.isEmpty {
                if idx < lines.count, lines[idx].indent > ind {
                    if lines[idx].content.hasPrefix("- ") {
                        map[key] = parseList(lines, &idx, indent: lines[idx].indent)
                    } else {
                        map[key] = parseMap(lines, &idx, indent: lines[idx].indent)
                    }
                }
            } else {
                map[key] = scalar(rest)
            }
        }
        return map
    }

    private static func parseList(_ lines: [(indent: Int, content: String)], _ idx: inout Int, indent: Int) -> [[String: Any]] {
        var list: [[String: Any]] = []
        while idx < lines.count {
            let (ind, content) = lines[idx]
            guard ind == indent, content.hasPrefix("- ") else { break }
            let itemText = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            idx += 1

            // Inline-array item: - ["word", 42]
            if itemText.hasPrefix("[") {
                list.append(["__value": scalar(itemText)])
                continue
            }
            // Scalar item
            guard let colon = itemText.firstIndex(of: ":") else {
                list.append(["__value": scalar(itemText)])
                continue
            }
            // Map item: first key lives on the dash line, continuation keys at indent+2
            var itemMap: [String: Any] = [:]
            let key = String(itemText[itemText.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(itemText[itemText.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                if idx < lines.count, lines[idx].indent > ind {
                    if lines[idx].content.hasPrefix("- ") {
                        itemMap[key] = parseList(lines, &idx, indent: lines[idx].indent)
                    } else {
                        itemMap[key] = parseMap(lines, &idx, indent: lines[idx].indent)
                    }
                }
            } else {
                itemMap[key] = scalar(rest)
            }
            // Continuation keys: any non-dash lines deeper than the dash belong to this item
            while idx < lines.count, lines[idx].indent > ind, !lines[idx].content.hasPrefix("- ") {
                let contIndent = lines[idx].indent
                for (k, v) in parseMap(lines, &idx, indent: contIndent) {
                    itemMap[k] = v
                }
            }
            list.append(itemMap)
        }
        return list
    }

    /// Unescapes the escapes introduced by `ProjectAnalysis.yamlEscaped` so a
    /// saved-and-reloaded value round-trips exactly. Only touches `\` escapes.
    static func unescapeYAML(_ text: String) -> String {
        var out = ""
        var it = text.makeIterator()
        while let ch = it.next() {
            if ch == "\\", let nxt = it.next() {
                switch nxt {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(nxt)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func scalar(_ text: String) -> Any {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return unescapeYAML(String(text.dropFirst().dropLast()))
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast()
            var items: [Any] = []
            var current = ""
            var inSingle = false, inDouble = false
            for ch in inner {
                switch ch {
                case "'" where !inDouble: inSingle.toggle(); current.append(ch)
                case "\"" where !inSingle: inDouble.toggle(); current.append(ch)
                case "," where !inSingle && !inDouble:
                    items.append(scalar(current.trimmingCharacters(in: .whitespaces)))
                    current = ""
                default: current.append(ch)
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(scalar(current.trimmingCharacters(in: .whitespaces)))
            }
            return items
        }
        switch text {
        case "true": return true
        case "false": return false
        case "null", "~": return NSNull()
        default: break
        }
        if let i = Int(text) { return i }
        if let d = Double(text) { return d }
        return text
    }

    /// Coerces numeric 0/1 (from JSONSerialization interpolation) to proper Bool; fills default if absent.
    private static func coerceBool(_ dict: inout [String: Any], _ key: String, default def: Bool = false) {
        if let b = dict[key] as? Bool {
            dict[key] = b
        } else if let n = dict[key] as? Int {
            dict[key] = n != 0
        } else if let n = dict[key] as? Double {
            dict[key] = n != 0
        } else if let s = dict[key] as? String {
            dict[key] = s == "true" || s == "1"
        } else {
            dict[key] = def
        }
    }

    /// Fills keys missing from the lossy Python-written YAML so Codable decode succeeds.
    static func sanitize(_ node: [String: Any], rootFolder: String) -> [String: Any] {
        var map = node
        if var folders = map["folders"] as? [[String: Any]] {
            for fi in folders.indices {
                let folderPath = folders[fi]["path"] as? String ?? rootFolder
                var interviews = folders[fi]["interviews"] as? [[String: Any]] ?? []
                for ii in interviews.indices {
                    interviews[ii]["title"] = interviews[ii]["title"] ?? "Untitled"
                    interviews[ii]["folderPath"] = interviews[ii]["folderPath"] as? String ?? folderPath
                    coerceBool(&interviews[ii], "excluded")
                    coerceBool(&interviews[ii], "hasSubtitles")
                    coerceBool(&interviews[ii], "hasTranscript")
                    coerceBool(&interviews[ii], "hasChapters")
                    coerceBool(&interviews[ii], "hasSynopsis")
                    if interviews[ii]["durationS"] == nil { interviews[ii]["durationS"] = 0 }
                    if interviews[ii]["cueCount"] == nil { interviews[ii]["cueCount"] = 0 }
                    if interviews[ii]["speakers"] == nil { interviews[ii]["speakers"] = [String]() }
                    if interviews[ii]["chapterCount"] == nil { interviews[ii]["chapterCount"] = 0 }
                    if interviews[ii]["synopsisSubjectCount"] == nil { interviews[ii]["synopsisSubjectCount"] = 0 }
                    if interviews[ii]["transcriptWordCount"] == nil { interviews[ii]["transcriptWordCount"] = 0 }
                    for sizeKey in ["fileSizeSrtx", "fileSizeTranscript", "fileSizeChapters", "fileSizeSynopsis"] {
                        if interviews[ii][sizeKey] == nil { interviews[ii][sizeKey] = 0 }
                    }
                }
                folders[fi]["interviews"] = interviews
            }
            map["folders"] = folders
        }
        if var stats = map["stats"] as? [String: Any] {
            stats["totalInterviews"] = stats["totalInterviews"] ?? 0
            stats["totalDurationS"] = stats["totalDurationS"] ?? 0
            stats["totalCues"] = stats["totalCues"] ?? 0
            if var speakers = stats["speakers"] as? [[String: Any]] {
                for si in speakers.indices {
                    if speakers[si]["name"] == nil { speakers[si]["name"] = "?" }
                    if speakers[si]["durationS"] == nil { speakers[si]["durationS"] = 0 }
                    if speakers[si]["cueCount"] == nil { speakers[si]["cueCount"] = 0 }
                }
                stats["speakers"] = speakers
            } else {
                stats["speakers"] = [[String: Any]]()
            }
            if var words = stats["frequentWords"] as? [[String: Any]] {
                for wi in words.indices {
                    if let pair = words[wi]["__value"] as? [Any], pair.count >= 2 {
                        words[wi] = ["word": "\(pair[0])", "count": pair[1]]
                    }
                }
                stats["frequentWords"] = words.filter { $0["word"] != nil }
            } else {
                stats["frequentWords"] = [[String: Any]]()
            }
            map["stats"] = stats
        } else {
            map["stats"] = ["totalInterviews": 0, "totalDurationS": 0, "totalCues": 0,
                            "speakers": [[String: Any]](), "frequentWords": [[String: Any]]()]
        }
        map["themes"] = map["themes"] ?? [[String: Any]]()
        map["folders"] = map["folders"] ?? [[String: Any]]()
        map["version"] = map["version"] ?? 1
        map["createdAt"] = map["createdAt"] ?? ""
        return map
    }
}
