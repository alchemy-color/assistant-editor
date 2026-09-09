import SwiftUI
import UniformTypeIdentifiers
import Combine

struct AIEditSession: Codable {
    var script: String
    var parsedTitle: String?
    var estimatedDuration: Double?
    var beats: [ScriptBeat]
    var flowNotes: [FlowNote]
}

// MARK: - Materials Report

private extension Array where Element == String {
    func toJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

struct MaterialsReport {
    var synopsisCount = 0
    var chaptersCount = 0
    var transcriptCount = 0
    var subtitleCount = 0
    var scanned = false
}

// MARK: - Flow Note (continuity review)

struct FlowNote: Identifiable, Codable {
    var id = UUID()
    let beatIndex: Int?   // 0-based; nil = global note
    let severity: String  // "warning" | "info"
    let message: String
}

class AIEditStore: ObservableObject {
    @Published var scriptText = ""
    @Published var beats: [ScriptBeat] = []
    @Published var isParsing = false
    @Published var isAssembling = false
    /// Bumped on cancel — stale background completions compare and bail.
    private(set) var generationID = UUID()

    /// Cancels ongoing parse/find/review work (ESC).
    func cancelAll() {
        generationID = UUID()
        guard isParsing || isAssembling || isReviewingFlow else { return }
        isParsing = false
        isAssembling = false
        isReviewingFlow = false
        statusMessage = "Cancelled"
    }
    @Published var isCreating = false
    @Published var statusMessage = ""
    @Published var parsedTitle: String?
    @Published var estimatedDuration: Double?
    @Published var lastError: String?
    @Published var lastTimelineName: String?
    @Published var resolvedMarkers: [SummaryMarker] = []
    @Published var materials = MaterialsReport()
    @Published var flowNotes: [FlowNote] = []
    @Published var isReviewingFlow = false

    @AppStorage("aiEditScript") private(set) var savedScript = ""
    @AppStorage("aiEditGapSeconds") var gapSeconds: Double = 2.0
    @AppStorage("aiEditMarkerMode") var markerModeRaw: String = MarkerMode.beats.rawValue
    @AppStorage("aiEditNameTimestamp") var includeNameTimestamp = true
    var markerMode: MarkerMode { MarkerMode(rawValue: markerModeRaw) ?? .beats }
    @AppStorage("aiEditContextSlots") var contextSlots: Double = 2
    @AppStorage("aiEditAddSubtitles") var addSubtitles = false
    // Multiple source folders (migrated from single aiEditFolder on first run)
    @AppStorage("aiEditFoldersJSON") var foldersJSON: String = "[]"

    var folders: [String] {
        (try? JSONDecoder().decode([String].self, from: foldersJSON.data(using: .utf8) ?? Data())) ?? []
    }

    var folderPath: String { folders.first ?? "" }   // compat for display/media-match fallback

    func setFolders(_ list: [String]) {
        foldersJSON = list.toJSON()
        rescanMaterials()
    }

    func migrateLegacyFolder() {
        guard folders.isEmpty,
              let legacy = UserDefaults.standard.string(forKey: "aiEditFolder"),
              !legacy.isEmpty else { return }
        foldersJSON = [legacy].toJSON()
    }
    @AppStorage("aiEditCandidateCap") var candidateCap: Double = 24
    @AppStorage("aiEditMaxClips") var maxClipsPerBeat: Double = 5
    @AppStorage("aiEditUseSynopsis") var useSynopsisInSelection = true

    private var saveCancellable: AnyCancellable?

    init() {
        migrateLegacyFolder()
        loadSession()
        // Persist the whole session (beats, clips, toggles, notes) 600ms after any change settles
        saveCancellable = objectWillChange
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.saveSession() }
    }

    private func loadSession() {
        guard let data = UserDefaults.standard.data(forKey: "aiEditSessionJSON") else { return }
        guard let session = try? JSONDecoder().decode(AIEditSession.self, from: data) else { return }
        scriptText = session.script
        savedScript = session.script
        parsedTitle = session.parsedTitle
        estimatedDuration = session.estimatedDuration
        beats = session.beats
        flowNotes = session.flowNotes
    }

    func saveSession() {
        let session = AIEditSession(
            script: scriptText,
            parsedTitle: parsedTitle,
            estimatedDuration: estimatedDuration,
            beats: beats,
            flowNotes: flowNotes
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: "aiEditSessionJSON")
        }
    }

    func clearSession() {
        UserDefaults.standard.removeObject(forKey: "aiEditSessionJSON")
    }

    var scriptChanged: Bool { scriptText != savedScript }
    func saveScript() { savedScript = scriptText }
    func loadSavedScript() { scriptText = savedScript }

    // MARK: - Material Scan

    func rescanMaterials() {
        let roots = folders
        guard !roots.isEmpty else {
            materials = MaterialsReport()
            return
        }
        DispatchQueue.global().async {
            var report = MaterialsReport()
            for root in roots {
                let r = Self.scanMaterials(folder: root)
                report.synopsisCount += r.synopsisCount
                report.chaptersCount += r.chaptersCount
                report.transcriptCount += r.transcriptCount
                report.subtitleCount += r.subtitleCount
                report.scanned = r.scanned
            }
            DispatchQueue.main.async { self.materials = report }
        }
    }

    @discardableResult
    static func scanMaterials(folder root: String) -> MaterialsReport {
        var report = MaterialsReport()
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil
        ) else { return report }

        var chapterBases = Set<String>()
        var synopsisBases = Set<String>()
        var transcriptBases = Set<String>()
        var subtitleBases = Set<String>()

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let lower = name.lowercased()
            guard !lower.hasPrefix(".") else { continue }
            if lower.hasSuffix("_chapters.yaml") {
                chapterBases.insert(lower
                    .replacingOccurrences(of: "_chapters.yaml", with: "")
                    .replacingOccurrences(of: "_transcript", with: ""))
            } else if lower.hasSuffix("_synopsis.txt") {
                synopsisBases.insert(lower
                    .replacingOccurrences(of: "_synopsis.txt", with: "")
                    .replacingOccurrences(of: "_transcript", with: ""))
            } else if lower.hasSuffix(".srtx") || lower.hasSuffix(".srt") {
                subtitleBases.insert(lower
                    .replacingOccurrences(of: ".srtx", with: "")
                    .replacingOccurrences(of: ".srt", with: "")
                    .replacingOccurrences(of: "_subtitles", with: ""))
            } else if lower.hasSuffix(".txt") && lower.contains("_transcript") {
                transcriptBases.insert(lower
                    .replacingOccurrences(of: ".txt", with: "")
                    .replacingOccurrences(of: "_transcript", with: ""))
            } else if lower.hasSuffix(".txt") {
                subtitleBases.insert(lower.replacingOccurrences(of: ".txt", with: ""))
            }
        }

        // Report what physically exists: a paired transcript is still a transcript.
        // Pairing affects how we search (paragraph-level), not whether material is present.
        report.subtitleCount = subtitleBases.filter { !$0.isEmpty }.count
        report.transcriptCount = transcriptBases.filter { !$0.isEmpty }.count
        report.chaptersCount = chapterBases.count
        report.synopsisCount = synopsisBases.count
        report.scanned = true
        return report
    }

    var totalIncludedClips: Int {
        beats.reduce(0) { $0 + $1.clips.filter(\.included).count }
    }

    func clearAll() {
        clearSession()
        scriptText = ""
        beats = []
        parsedTitle = nil
        estimatedDuration = nil
        lastError = nil
        statusMessage = ""
        resolvedMarkers = []
    }

    func addBeat() {
        let idx = beats.count + 1
        beats.append(ScriptBeat(
            index: idx, title: "New Beat", description: "",
            searchQueries: [], targetDuration: nil, mood: nil,
            clips: []
        ))
    }

    func removeBeat(at offsets: IndexSet) {
        beats.remove(atOffsets: offsets)
        for i in beats.indices { beats[i].index = i + 1 }
    }

    func moveBeat(from source: IndexSet, to destination: Int) {
        beats.move(fromOffsets: source, toOffset: destination)
        for i in beats.indices { beats[i].index = i + 1 }
    }

    func clipsToMarkers() -> [SummaryMarker] {
        var markers: [SummaryMarker] = []
        for beat in beats {
            for clip in beat.clips where clip.included {
                markers.append(SummaryMarker(
                    start_s: clip.start_s,
                    end_s: clip.end_s,
                    theme: beat.title,
                    color: clip.isContext ? "Orange" : "Blue",
                    name: "\(clip.speaker): \(String(clip.text.prefix(60)))",
                    notes: clip.matchReason
                ))
            }
        }
        return markers
    }

    // MARK: - Material-Driven Retrieval

    /// Finds clips for one beat by ranking REAL material against the beat's meaning:
    /// Stage A — candidate pool from transcripts (beat queries + intent words + theme keywords)
    /// Stage B — LLM selects which candidates serve the beat, grounded in synopses
    /// Stage C — snap selected passages to subtitle cues for precise cut bounds
    func findClips(for beatIndex: Int, subStore: SubtitleStore, docStore: DocumentStore, themes: [ProjectTheme]) {
        guard beats.indices.contains(beatIndex) else { return }
        let beat = beats[beatIndex]

        var queries = beat.searchQueries.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if queries.isEmpty {
            queries = Self.contentWords(beat.title)
        }

        isAssembling = true
        statusMessage = "Gathering material for '\(beat.title)'…"

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let usedKeys = self.usedClipKeys(excluding: beatIndex)

            Self.retrieveMaterialDriven(
                for: beat,
                queries: queries,
                themes: themes,
                subStore: subStore,
                docStore: docStore,
                usedKeys: usedKeys,
                contextSlots: Int(self.contextSlots),
                candidateCap: Int(self.candidateCap),
                maxClips: Int(self.maxClipsPerBeat),
                useSynopsis: self.useSynopsisInSelection,
                progress: { msg in
                    DispatchQueue.main.async { self.statusMessage = msg }
                },
                completion: { result in
                    DispatchQueue.main.async {
                        if self.beats.indices.contains(beatIndex) {
                            self.beats[beatIndex].clips = result.clips
                        }
                        self.isAssembling = false
                        let included = result.clips.filter(\.included).count
                        self.statusMessage = result.usedLLM
                            ? "'\(beat.title)': \(included) clip(s) selected from \(result.candidateCount) passages"
                            : (included > 0
                               ? "'\(beat.title)': \(included) clip(s) found (lexical fallback)"
                               : "'\(beat.title)': no matching material found")
                    }
                }
            )
        }
    }

    func findAllClips(subStore: SubtitleStore, docStore: DocumentStore, themes: [ProjectTheme]) {
        guard !beats.isEmpty else { return }
        isAssembling = true
        lastError = nil

        let gen = generationID
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            for i in self.beats.indices {
                let beat = self.beats[i]
                DispatchQueue.main.async {
                    self.statusMessage = "Beat \(i + 1)/\(self.beats.count): searching '\(beat.title)'…"
                }
                let usedKeys = self.usedClipKeys(excluding: i)
                let sema = DispatchSemaphore(value: 0)
                var finishedClips: [BeatClip] = []
                Self.retrieveMaterialDriven(
                    for: beat,
                    queries: beat.searchQueries.isEmpty ? Self.contentWords(beat.title) : beat.searchQueries,
                    themes: themes,
                    subStore: subStore,
                    docStore: docStore,
                    usedKeys: usedKeys,
                    contextSlots: Int(self.contextSlots),
                    candidateCap: Int(self.candidateCap),
                    maxClips: Int(self.maxClipsPerBeat),
                    useSynopsis: self.useSynopsisInSelection,
                    progress: { _ in },
                    completion: { result in
                        finishedClips = result.clips
                        sema.signal()
                    }
                )
                sema.wait()
                let cancelled = self.generationID != gen
                DispatchQueue.main.async {
                    if !cancelled { self.beats[i].clips = finishedClips }
                }
                if cancelled { return }
            }
            DispatchQueue.main.async {
                self.isAssembling = false
                let total = self.beats.reduce(0) { $0 + $1.clips.filter(\.included).count }
                self.statusMessage = "Found \(total) clip(s) across \(self.beats.count) beat(s)"
            }
        }
    }

    /// Material-driven retrieval. Candidates come FROM the transcripts; the LLM only chooses among them.
    static func retrieveMaterialDriven(
        for beat: ScriptBeat,
        queries: [String],
        themes: [ProjectTheme],
        subStore: SubtitleStore,
        docStore: DocumentStore,
        usedKeys: Set<String>,
        contextSlots: Int,
        candidateCap: Int = 24,
        maxClips: Int = 5,
        useSynopsis: Bool = true,
        progress: @escaping (String) -> Void,
        completion: @escaping (_ result: (clips: [BeatClip], usedLLM: Bool, candidateCount: Int)) -> Void
    ) {
        let targetDuration = beat.targetDuration ?? 10
        let fromTranscripts = subStore.isTranscriptsLoaded && !subStore.transcriptEntries.isEmpty

        // ---- Stage A: candidate pool from real material ----
        var pool: [String: SubtitleEntry] = [:]
        var markerPulled = Set<String>()

        let probeTerms = queries + contentWords(beat.title + " " + beat.description)

        // A0: marker-directed retrieval. Beats that name chapters ("Use the markers
        // under Viticulture: Vineyard") resolve deterministically to those time ranges.
        if !docStore.allDocuments.isEmpty {
            let beatText = (beat.title + " " + beat.description).lowercased()
            let beatWords = Set(contentWords(beat.title + " " + beat.description))
            for doc in docStore.allDocuments {
                for m in doc.markers {
                    let nameWords = Set(contentWords(m.name + " " + m.theme))
                    guard !nameWords.isEmpty else { continue }
                    let phrase = m.name.lowercased()
                        .replacingOccurrences(of: ":", with: " ")
                        .replacingOccurrences(of: "/", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    let overlap = nameWords.intersection(beatWords)
                    guard overlap.count >= 2 || beatText.contains(phrase) else { continue }
                    let source = fromTranscripts ? subStore.transcriptEntries : subStore.entries
                    for e in source where e.interview == doc.title
                        && e.start_s >= m.start_s - 2 && e.start_s <= m.end_s + 2 {
                        pool[e.id] = e
                        markerPulled.insert(e.id)
                    }
                }
            }
        }

        // A1: LLM-provided queries act as hints
        for q in queries {
            if fromTranscripts {
                for e in subStore.searchTranscripts(q) { pool[e.id] = e }
            } else if subStore.isLoaded {
                for h in subStore.search(query: q) { pool[h.entry.id] = h.entry }
            }
        }

        if fromTranscripts && subStore.isLoaded && !subStore.embMap.isEmpty {
            // Meaning-matching on subtitles stays available even with transcripts loaded:
            // exact + NLEmbedding semantic hits give paragraph-blind candidates that
            // lexical FTS5 alone would never surface.
            for term in probeTerms.prefix(10) {
                for h in subStore.search(query: term).prefix(4) {
                    pool["sub-" + h.entry.id] = h.entry
                }
            }
        }

        if fromTranscripts {
            // A2: content words of the beat's own intent
            for w in probeTerms {
                for e in subStore.searchTranscripts(w).prefix(6) { pool[e.id] = e }
            }
            // A3: theme keywords — the weighing drives discovery
            for theme in themes where theme.weight > 0.02 {
                for kw in theme.keywords.prefix(12) {
                    for e in subStore.searchTranscripts(kw).prefix(3) { pool[e.id] = e }
                }
            }
        }

        var candidates = Array(pool.values)

        // Chapters say WHERE topics live: passages inside a chapter whose name/notes
        // match the beat's intent float to the top of the pool.
        let intentWords = Set(probeTerms)
        if !docStore.allDocuments.isEmpty {
            func chapterBoost(_ entry: SubtitleEntry) -> Double {
                guard let doc = docStore.allDocuments.first(where: { $0.title == entry.interview }) else { return 0 }
                var best = 0.0
                for m in doc.markers {
                    let text = (m.name + " " + m.notes + " " + m.theme).lowercased()
                    let hitCount = intentWords.filter { text.contains($0) }.count
                    guard hitCount > 0 else { continue }
                    if entry.start_s >= m.start_s - 2 && entry.start_s <= m.end_s + 2 {
                        best = max(best, Double(hitCount) * 6.0)
                    }
                }
                return best
            }
            candidates.sort {
                chapterBoost($0) > chapterBoost($1)
            }
        }

        // Cap pool: marker-directed candidates are reserved; the rest rank by lexical fit
        let cap = max(8, candidateCap)
        if candidates.count > cap {
            let reserved = candidates.filter { markerPulled.contains($0.id) }
            let rest = candidates.filter { !markerPulled.contains($0.id) }
            let scoredRest = rest.map { e -> (SubtitleEntry, Double) in
                let (s, _) = scoreText(e.text, queries: probeTerms)
                return (e, s)
            }.sorted { $0.1 > $1.1 }
            candidates = reserved + scoredRest.prefix(max(0, cap - reserved.count)).map(\.0)
        }

        guard !candidates.isEmpty else {
            completion(([], false, 0))
            return
        }

        // Sort candidates chronologically per source so numbering reads coherently
        candidates.sort { ($0.sourceFile, $0.start_s) < ($1.sourceFile, $1.start_s) }

        // Synopsis excerpts per interview (what is MEANT)
        var synopsisByInterview: [String: String] = [:]
        let interviewSet = useSynopsis ? Set(candidates.map(\.interview)) : Set<String>()
        for iv in interviewSet {
            if let doc = docStore.allDocuments.first(where: { $0.title == iv }),
               let folder = doc.sourceFolder, let src = doc.sourceFile {
                let base = (src as NSString).deletingPathExtension
                let p = URL(fileURLWithPath: folder).appendingPathComponent("\(base)_synopsis.txt").path
                let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                synopsisByInterview[iv] = String(text.prefix(700))
            }
        }

        // ---- Stage B: LLM selection among real passages ----
        var listing = ""
        for (i, c) in candidates.enumerated() {
            let tc = formatTcStatic(c.start_s)
            listing += "\(i). [\(c.interview) · \(tc)] \(c.speaker): \"\(c.text.prefix(200))\"\n"
        }
        var synopsisBlock = ""
        for (iv, syn) in synopsisByInterview.sorted(by: { $0.key < $1.key }) where !syn.isEmpty {
            synopsisBlock += "\nSYNOPSIS — \(iv):\n\(syn)\n"
        }

        let instructions = PrimingRegistry.stage(for: "priming_clipSelection")?.load() ?? """
        Select which numbered transcript passages best serve the beat's editorial intent.
        Return ONLY JSON: {"selections": [{"index": <number>, "reason": "<one line>"}]}. At most 5.
        """

        let prompt = """
        \(instructions)

        BEAT: \(beat.title)
        INTENT: \(beat.description)\(beat.mood.map { " (mood: \($0))" } ?? "")
        TARGET DURATION: \(Int(targetDuration))s
        \(synopsisBlock)
        CANDIDATE PASSAGES (verbatim from transcripts):
        \(listing)
        """

        DispatchQueue.main.async { progress("Selecting from \(candidates.count) passages…" ) }

        let selectionSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "selections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "index": ["type": "integer"],
                            "reason": ["type": "string"]
                        ],
                        "required": ["index", "reason"]
                    ]
                ]
            ],
            "required": ["selections"]
        ]

        func lexicalFallback() {
            var keys = usedKeys
            var clips: [BeatClip] = []
            let ranked = candidates
                .map { e -> (SubtitleEntry, Double, [String]) in
                    let (s, m) = scoreText(e.text, queries: queries + contentWords(beat.title + " " + beat.description))
                    return (e, s, m)
                }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            for (entry, score, matched) in ranked {
                let key = "\(entry.sourceFile)|\(Int(entry.start_s))"
                guard !keys.contains(key) else { continue }
                keys.insert(key)
                clips.append(makeClip(from: entry, interview: entry.interview, score: min(score / 30.0, 1.0),
                                      reason: matched.isEmpty ? "" : "Matched: \(matched.joined(separator: ", "))",
                                      target: targetDuration, subStore: subStore, fromTranscripts: fromTranscripts))
                if clips.count >= maxClips { break }
            }
            appendContext(to: &clips, subStore: subStore, slots: contextSlots, keys: &keys)
            completion((clips, false, candidates.count))
        }

        OMLXClient.shared.complete(
            prompt: prompt,
            temperature: 0.2,
            maxTokens: 2048,
            jsonSchema: selectionSchema,
            timeout: 300
        ) { result in
            guard let response = result.text, result.error == nil,
                  !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let jsonData = extractSelectionJSON(response),
                  let sel = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let selections = sel["selections"] as? [[String: Any]] else {
                lexicalFallback()
                return
            }

            var keys = usedKeys
            var clips: [BeatClip] = []
            for selection in selections.prefix(8) {
                guard let idx = selection["index"] as? Int, candidates.indices.contains(idx) else { continue }
                let entry = candidates[idx]
                let key = "\(entry.sourceFile)|\(Int(entry.start_s))"
                guard !keys.contains(key) else { continue }
                keys.insert(key)
                let reason = (selection["reason"] as? String) ?? ""
                clips.append(makeClip(from: entry, interview: entry.interview, score: 1.0,
                                      reason: reason.isEmpty ? "Selected to serve beat" : reason,
                                      target: targetDuration, subStore: subStore, fromTranscripts: fromTranscripts))
                if clips.count >= maxClips { break }
            }
            if clips.isEmpty {
                lexicalFallback()
                return
            }
            appendContext(to: &clips, subStore: subStore, slots: contextSlots, keys: &keys)
            completion((clips, true, candidates.count))
        }
    }

    private static func makeClip(
        from entry: SubtitleEntry,
        interview: String,
        score: Double,
        reason: String,
        target: Double,
        subStore: SubtitleStore,
        fromTranscripts: Bool
    ) -> BeatClip {
        let root = entry.folder.isEmpty ? nil : entry.folder
        if fromTranscripts {
            let snapped = snapToSubtitles(paragraph: entry, target: target, subStore: subStore)
            return BeatClip(
                id: UUID().uuidString,
                sourceFile: snapped.sourceFile,
                sourceRoot: snapped.folder.isEmpty ? root : snapped.folder,
                interview: interview,
                speaker: entry.speaker.isEmpty ? (snapped.speaker.isEmpty ? "?" : snapped.speaker) : entry.speaker,
                start_s: snapped.start_s,
                end_s: snapped.end_s,
                text: String(entry.text.prefix(300)),
                matchScore: score,
                matchReason: reason,
                included: true,
                isContext: false
            )
        }
        return BeatClip(
            id: UUID().uuidString,
            sourceFile: entry.sourceFile,
            sourceRoot: root,
            interview: interview,
            speaker: entry.speaker.isEmpty ? "?" : entry.speaker,
            start_s: entry.start_s,
            end_s: entry.end_s,
            text: String(entry.text.prefix(300)),
            matchScore: score,
            matchReason: reason,
            included: true,
            isContext: false
        )
    }

    private static func appendContext(to clips: inout [BeatClip], subStore: SubtitleStore, slots: Int, keys: inout Set<String>) {
        guard slots > 0, subStore.isTranscriptsLoaded else { return }
        var withContext: [BeatClip] = []
        for clip in clips {
            withContext.append(clip)
            guard !clip.isContext else { continue }
            let adjacent = adjacentParagraphs(after: clip.sourceFile, at: clip.end_s, subStore: subStore)
            for para in adjacent.prefix(slots) {
                let cKey = "\(para.sourceFile)|\(Int(para.start_s))"
                guard !keys.contains(cKey) else { continue }
                keys.insert(cKey)
                withContext.append(BeatClip(
                    id: UUID().uuidString,
                    sourceFile: para.sourceFile,
                    interview: clip.interview,
                    speaker: para.speaker.isEmpty ? "?" : para.speaker,
                    start_s: para.start_s,
                    end_s: para.end_s,
                    text: String(para.text.prefix(300)),
                    matchScore: 0,
                    matchReason: "Following context",
                    included: false,
                    isContext: true
                ))
            }
        }
        clips = withContext
    }

    /// Strips fences / finds the outermost JSON object in an LLM response.
    private static func extractSelectionJSON(_ text: String) -> Data? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "^```(?:json)?\\s*\\n?", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\n?```\\s*$", with: "", options: .regularExpression)
        if let d = cleaned.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil { return d }
        guard let s = cleaned.firstIndex(of: "{"), let e = cleaned.lastIndex(of: "}") else { return nil }
        return String(cleaned[s...e]).data(using: .utf8)
    }

    /// Meaningful words from free text for FTS5 probing.
    static func contentWords(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "about", "into", "what", "when", "how", "why", "who", "their", "they", "them", "have", "has", "was", "were", "will", "would", "could", "should", "than", "then", "over", "under", "some", "more", "most", "very", "just", "also", "been", "being", "does", "doing", "done"]
        return text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stop.contains($0.lowercased()) }
            .map { $0.lowercased() }
    }

    // MARK: - Continuity Review (LLM)

    /// LLM reviews the selected clip sequence against the script for narrative flow.
    /// No timecode math — language judgment only; all timing stays deterministic.
    func reviewFlow() {
        let includedByBeat = beats.enumerated().compactMap { idx, beat -> (Int, ScriptBeat)? in
            beat.clips.contains(where: \.included) ? (idx, beat) : nil
        }
        guard !includedByBeat.isEmpty else {
            lastError = "No included clips to review"
            return
        }

        isReviewingFlow = true
        flowNotes = []
        statusMessage = "Reviewing narrative flow…"

        var sequence = ""
        for (idx, beat) in includedByBeat {
            sequence += "\nBEAT \(idx + 1): \(beat.title) — \(beat.description)\n"
            for clip in beat.clips where clip.included {
                let tc = formatTc(clip.start_s)
                sequence += "  [\(tc)] \(clip.speaker): \"\(clip.text.prefix(220))\"\n"
            }
        }

        let scriptContext = String(scriptText.prefix(6000))

        let instructions = PrimingRegistry.stage(for: "priming_flowReview")?.load() ?? """
        Review ONLY the narrative flow of this sequence. Return ONLY a JSON array \
        (no markdown fences): [{"beatIndex": 0-based or null, "severity": "warning"|"info", "message": "..."}]. \
        Return [] if the flow is clean.
        """

        let prompt = """
        \(instructions)

        --- SCRIPT / TREATMENT ---
        \(scriptContext)

        --- SELECTED SEQUENCE ---
        \(sequence)
        """

        DispatchQueue.global().async { [weak self] in
            let gen = self?.generationID ?? UUID()
            OMLXClient.shared.complete(
                prompt: prompt,
                temperature: 0.2,
                maxTokens: 2048,
                timeout: 300
            ) { [weak self] result in
                guard let self, self.generationID == gen else { return }
                guard let response = result.text, result.error == nil else {
                    DispatchQueue.main.async {
                        self.isReviewingFlow = false
                        self.lastError = result.error ?? "No response from oMLX"
                    }
                    return
                }

                let cleaned = Self.stripThink(response)
                let notes = Self.parseFlowNotes(cleaned)
                DispatchQueue.main.async {
                    self.flowNotes = notes
                    self.isReviewingFlow = false
                    self.statusMessage = notes.isEmpty
                        ? "Flow review: sequence is clean"
                        : "Flow review: \(notes.count) note(s)"
                }
            }
        }
    }

    private static func stripThink(_ text: String) -> String {
        var result = text
        if let lastEnd = result.range(of: "</think>", options: .backwards) {
            result = String(result[lastEnd.upperBound...])
        }
        if let leftover = result.range(of: "<think>") {
            result = String(result[leftover.upperBound...])
        }
        return result
    }

    private static func parseFlowNotes(_ text: String) -> [FlowNote] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "^```(?:json)?\\s*\\n?", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\n?```\\s*$", with: "", options: .regularExpression)

        var jsonData: Data?
        if let data = cleaned.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            jsonData = data
        } else if let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]") {
            jsonData = String(cleaned[start...end]).data(using: .utf8)
        }
        guard let data = jsonData,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { item in
            guard let message = item["message"] as? String, !message.isEmpty else { return nil }
            let beatIdx = item["beatIndex"] as? Int
            let severity = (item["severity"] as? String == "info") ? "info" : "warning"
            return FlowNote(beatIndex: beatIdx, severity: severity, message: message)
        }
    }

    static func formatTcStatic(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func formatTc(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Clip identity keys already used by other beats (dedup across beats)
    private func usedClipKeys(excluding beatIndex: Int) -> Set<String> {
        var keys = Set<String>()
        for (i, beat) in beats.enumerated() where i != beatIndex {
            for clip in beat.clips where clip.included {
                keys.insert("\(clip.sourceFile)|\(Int(clip.start_s))")
            }
        }
        return keys
    }

    /// Snaps a transcript paragraph to overlapping subtitle cues; returns precise cut bounds.
    static func snapToSubtitles(paragraph: SubtitleEntry, target: Double, subStore: SubtitleStore) -> (sourceFile: String, start_s: Double, end_s: Double, speaker: String, folder: String) {
        let cues = subStore.findMatchingSubtitles(for: paragraph)
            .map(\.entry)
            .sorted { $0.start_s < $1.start_s }
        guard !cues.isEmpty else {
            var end = min(paragraph.end_s, paragraph.start_s + max(target * 2, 15))
            if end - paragraph.start_s < 5 { end = paragraph.start_s + 5 }
            return (paragraph.sourceFile, paragraph.start_s, end, paragraph.speaker, paragraph.folder)
        }
        let maxLen = max(target * 2, 12)
        var start = cues[0].start_s
        var end = cues[0].end_s
        for cue in cues.dropFirst() {
            if cue.end_s - start > maxLen { break }
            end = cue.end_s
        }
        // Keep every cut >= 5s — create_timeline.py expands sub-5s entries into
        // whole _chapters.yaml sections, which would blow up precise AI Edit cuts.
        if end - start < 5 {
            end = start + 5
        }
        return (cues.first?.sourceFile ?? paragraph.sourceFile, start, end, cues.first?.speaker ?? paragraph.speaker, cues.first?.folder ?? paragraph.folder)
    }

    static func adjacentParagraphs(after sourceFile: String, at endS: Double, subStore: SubtitleStore) -> [SubtitleEntry] {
        subStore.transcriptEntries
            .filter { $0.sourceFile == sourceFile && $0.start_s >= endS - 0.5 && $0.start_s <= endS + 45 }
            .sorted { $0.start_s < $1.start_s }
    }

    static func scoreText(_ text: String, queries: [String]) -> (Double, [String]) {
        let lower = text.lowercased()
        var total: Double = 0
        var matched: [String] = []
        for q in queries {
            let ql = q.lowercased().trimmingCharacters(in: .whitespaces)
            guard ql.count > 2 else { continue }
            if lower.contains(ql) {
                total += 10
                matched.append(q)
                continue
            }
            let tokens = Set(ql.split(separator: " ").map(String.init).filter { $0.count > 2 })
            guard !tokens.isEmpty else { continue }
            var hits = 0
            for t in tokens where lower.contains(t) { hits += 1 }
            if hits > 0 {
                total += Double(hits) / Double(tokens.count) * 4
                if hits >= max(1, tokens.count / 2) { matched.append(q) }
            }
        }
        return (total, matched)
    }

    func exportEDL(markers: [SummaryMarker], fps: Double) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ai_edit_\(timestamp()).EDL"
        panel.allowedContentTypes = [UTType(filenameExtension: "EDL") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var lines = ["TITLE: ai_edit", "FCM: NON-DROP FRAME", ""]
        for (i, m) in markers.enumerated() {
            let n = String(format: "%03d", i + 1)
            let tc1 = secondsToEdfTc(m.start_s, fps: fps)
            let tc2 = secondsToEdfTc(m.end_s, fps: fps)
            let dur = max(1, Int(round((m.end_s - m.start_s) * fps)))
            lines.append("\(n)  001      V     C        \(tc1) \(tc2) \(tc1) \(tc2)")
            lines.append("\(m.notes) |C:ResolveColor\(m.color) |M:\(m.name) |D:\(dur)")
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func exportSubtitles(markers: [SummaryMarker]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ai_edit_\(timestamp()).srtx"
        panel.allowedContentTypes = [UTType(filenameExtension: "srtx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var lines: [String] = []
        for m in markers {
            let tc1 = String(format: "%02d:%02d:%02d,%03d",
                Int(m.start_s) / 3600,
                (Int(m.start_s) % 3600) / 60,
                Int(m.start_s) % 60,
                Int((m.start_s.truncatingRemainder(dividingBy: 1)) * 1000))
            let tc2 = String(format: "%02d:%02d:%02d,%03d",
                Int(m.end_s) / 3600,
                (Int(m.end_s) % 3600) / 60,
                Int(m.end_s) % 60,
                Int((m.end_s.truncatingRemainder(dividingBy: 1)) * 1000))
            lines.append("\(tc1) --> \(tc2)")
            lines.append(m.notes)
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    var includedClipCount: Int {
        beats.reduce(0) { $0 + $1.clips.filter(\.included).count }
    }

    /// Assembly math: clips run back-to-back inside a beat; one gap between beats.
    /// create_timeline.py inserts groupGapFrames when groupId changes, and each
    /// beat is a single group.
    var assembledDurationS: Double {
        var raw = 0.0
        var beatsWithClips = 0
        for beat in beats {
            let d = beat.clips.filter(\.included).reduce(0.0) { $0 + max(0, $1.end_s - $1.start_s) }
            if d > 0 { beatsWithClips += 1 }
            raw += d
        }
        return raw + (beatsWithClips > 1 ? Double(beatsWithClips - 1) * gapSeconds : 0)
    }

    static func formatLength(_ t: Double) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    func createTimeline(progress: AppProgress) {
        let markers = clipsToMarkers()
        guard !markers.isEmpty else {
            lastError = "No included clips to assemble"
            return
        }
        resolvedMarkers = markers

        isCreating = true
        lastError = nil
        let base = (parsedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "AI_Edit"
        let safeBase = base
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let name = includeNameTimestamp ? safeBase + "_" + timestamp() : safeBase
        progress.start("Creating timeline\u{2026}")

        // Identity fields (sourceFile/folder/interview) are REQUIRED —
        // create_timeline.py matches them against media pool clips AND
        // timeline names to know what footage to cut.
        let fallbackRoot = folderPath
        var entries: [TimelineEntry] = []
        for (beatIdx, beat) in beats.enumerated() {
            let groupId = beatIdx   // one group per beat → gap lands between beats
            for clip in beat.clips where clip.included {
                let entry = TimelineEntry(
                    start_s: clip.start_s, end_s: clip.end_s,
                    name: "\(clip.speaker): \(String(clip.text.prefix(60)))",
                    notes: clip.matchReason.isEmpty ? beat.title : clip.matchReason,
                    color: clip.isContext ? "Orange" : "Blue",
                    interview: clip.interview,
                    folder: clip.sourceRoot ?? fallbackRoot,
                    location: "",
                    sourceFile: clip.sourceFile,
                    groupId: groupId,
                    subtitleText: clip.text,
                    speaker: clip.speaker
                )
                entries.append(entry)
            }
        }

        guard !entries.isEmpty else {
            isCreating = false
            lastError = "No included clips to assemble"
            return
        }

        let gapFrames = Int(round(gapSeconds * 25))
        // Beat-span markers in ASSEMBLED time (what Resolve shows), mirroring
        // create_timeline.py exactly: items back-to-back at their own durations
        // (≈ end−start seconds) with one gap between every adjacent pair.
        let spanPalette = ["Purple", "Teal", "Blue", "Orange", "Green", "Pink", "Yellow"]
        var beatMarkers: [BeatSpanMarker] = []
        if markerMode == .beats {
            var cursor = 0.0
            var spanStart: Double? = nil
            var spanEnd = 0.0
            var currentBeatIndex = -1

            func flushBeat() {
                guard currentBeatIndex >= 0, let st = spanStart, spanEnd > st else { return }
                let beat = beats[currentBeatIndex]
                beatMarkers.append(BeatSpanMarker(
                    name: "Beat \(currentBeatIndex + 1): \(beat.title)",
                    note: [beat.mood, beat.description]
                        .compactMap { $0 }.joined(separator: " — ")
                        .prefix(280).description,
                    start_s: st, end_s: spanEnd,
                    color: spanPalette[currentBeatIndex % spanPalette.count]
                ))
            }

            for (bi, beat) in beats.enumerated() {
                let included = beat.clips.filter(\.included)
                    .sorted { ($0.sourceFile, $0.start_s) < ($1.sourceFile, $1.start_s) }
                guard !included.isEmpty else { continue }
                let isNewBeat = bi != currentBeatIndex
                if isNewBeat {
                    flushBeat()
                    // A gap separates this beat from the previous one only when
                    // the previous beat actually placed clips.
                    if currentBeatIndex >= 0 {
                        let prevHadClips = beats[currentBeatIndex].clips.contains(where: \.included)
                        if prevHadClips { cursor += gapSeconds }
                    }
                    currentBeatIndex = bi
                    spanStart = nil
                    spanEnd = 0
                }
                for c in included {
                    let aStart = cursor
                    let aEnd = cursor + max(0, c.end_s - c.start_s)
                    spanStart = min(spanStart ?? aStart, aStart)
                    spanEnd = max(spanEnd, aEnd)
                    cursor = aEnd   // clips run back-to-back within the beat
                }
            }
            flushBeat()
        }

        let request = TimelineRequest(
            name: name, markers: entries,
            groupGapFrames: gapFrames,
            addSubtitles: false,
            srtFolder: nil,
            beatMarkers: beatMarkers.isEmpty ? nil : beatMarkers,
            addClipMarkers: markerMode == .clips ? true : false
        )

        guard let jsonData = try? JSONEncoder().encode(request) else {
            isCreating = false
            lastError = "Failed to encode timeline request"
            progress.finish("Failed to encode")
            return
        }

        let env: [String: String] = [:] // Auto-detect Resolve install

        DispatchQueue.global().async {
            do {
                // Scale timeout with assembly size — a fixed 120s killed large timelines mid-build
                let timelineTimeout = 180.0 + Double(entries.count) * 6.0
                let output = try PythonBridge.runRaw("create_timeline", stdin: jsonData, envOverrides: env, timeoutSeconds: timelineTimeout)
                if let data = output.data(using: .utf8),
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result["status"] as? String == "ok" {
                        let total = result["total_markers"] as? Int ?? 0
                        let failed = result["failed"] as? Int ?? 0
                        let tlName = result["name"] as? String ?? name
                        var msg = "Timeline \u{201C}\(tlName)\u{201D} created: \(total) clip(s)."
                        if failed > 0 {
                            let unmatched = (result["unmatched"] as? [String])?.prefix(3).joined(separator: ", ") ?? ""
                            msg += " \(failed) clip(s) could not be matched to media"
                            if !unmatched.isEmpty { msg += " (\(unmatched))" }
                            msg += ". Check that the source video/timeline is in the Resolve media pool."
                        }
                        if let srt = result["srt_path"] as? String, !srt.isEmpty {
                            msg += " Subtitles written to \(URL(fileURLWithPath: srt).lastPathComponent)."
                            let url = URL(fileURLWithPath: srt)
                            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        DispatchQueue.main.async {
                            self.lastTimelineName = tlName
                            self.isCreating = false
                            self.statusMessage = msg
                            progress.finish(msg)
                            if total == 0 {
                                self.lastError = "No clips were added — media matching failed. \(msg)"
                            }
                        }
                    } else {
                        let errMsg = result["error"] as? String ?? "Unknown error"
                        if errMsg.contains("Could not connect to Resolve") {
                            DispatchQueue.main.async { self.statusMessage = "External helper not responding — trying in-console bridge…" }
                            ResolveConnector.shared.writeViaConsoleBridge(markersJSON: jsonData) { ok, info in
                                DispatchQueue.main.async {
                                    self.statusMessage = ok ? "Resolve (in-console): \(info)" : "Resolve error: \(info)"
                                    self.lastError = ok ? nil : info
                                    self.isCreating = false
                                    progress.finish(ok ? info : "Resolve error: \(info)")
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.isCreating = false
                                self.lastError = errMsg
                                progress.finish("Timeline creation failed")
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isCreating = false
                        self.lastError = "Could not parse response"
                        progress.finish("Timeline creation failed")
                    }
                }
            } catch {
                let msg = error.localizedDescription
                if msg.contains("Could not connect to Resolve") {
                    DispatchQueue.main.async { self.statusMessage = "External helper not responding — trying in-console bridge…" }
                    ResolveConnector.shared.writeViaConsoleBridge(markersJSON: jsonData) { ok, info in
                        DispatchQueue.main.async {
                            self.statusMessage = ok ? "Resolve (in-console): \(info)" : "Resolve error: \(info)"
                            self.lastError = ok ? nil : info
                            self.isCreating = false
                            progress.finish(ok ? info : "Resolve error: \(info)")
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isCreating = false
                        self.lastError = msg
                        progress.finish("Timeline creation failed")
                    }
                }
            }
        }
    }
}
