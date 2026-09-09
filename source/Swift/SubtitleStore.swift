import Foundation
import NaturalLanguage

class SubtitleStore: ObservableObject {
    let tag: String

    init(tag: String = "") {
        self.tag = tag
    }
    @Published var entries: [SubtitleEntry] = []
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var statusMessage = ""

    private var currentFolder = ""
    private var lastLoadPath = ""
    private var lastLoadWasFolder = false
    let db = SearchDatabase()
    var embMap: [String: [Double]] = [:]
    private let embQueue = DispatchQueue(label: "com.assistanteditor.embMap")
    let engine = EmbeddingEngine.shared
    @Published var semanticThreshold: Double = 0.5
    var frameRate: Double = 25.0

    // Transcript support
    @Published var transcriptEntries: [SubtitleEntry] = []
    @Published var isTranscriptsLoaded = false
    @Published var isTranscriptsLoading = false
    private var transcriptDb = SearchDatabase()
    /// Bumped on every load/reload/clear — a running AI-index build stops
    /// instead of writing embeddings into a replaced database.
    private var indexGeneration = UUID()
    private let transcriptQueue = DispatchQueue(label: "com.assistanteditor.transcript")

    func clearAll() {
        indexGeneration = UUID()

        entries = []
        isLoaded = false
        isLoading = false
        statusMessage = ""
        currentFolder = ""
        lastLoadPath = ""
        lastLoadWasFolder = false
        transcriptEntries = []
        isTranscriptsLoaded = false
        isTranscriptsLoading = false
        embQueue.sync { embMap = [:] }
    }

    func loadOnce(folder: String) {
        guard !isLoaded, !isLoading else { return }
        currentFolder = folder
        lastLoadPath = folder
        lastLoadWasFolder = true
        isLoading = true
        statusMessage = "Loading subtitles…"

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            let root = folder
            let dbPath = SearchDatabase.cachePath(for: root, kind: "subtitles", tag: tag)
            do {
                try self.db.open(path: dbPath)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "DB error: \(error.localizedDescription)"
                    self.isLoading = false
                    self.isLoaded = false
                }
                return
            }

            if !self.db.needsSubtitleRebuild(folder: root) {
                let cached = self.db.allSubtitleEntries()
                let cachedEmb = self.db.loadAllSubtitleEmbeddings()
            DispatchQueue.main.async {
                self.entries = cached
                self.embMap = cachedEmb
                self.isLoaded = true
                self.isLoading = false
                let idx = cachedEmb.isEmpty ? "" : ", AI index loaded"
                self.statusMessage = "\(cached.count) sentence(s) loaded from cache\(idx)"
                if self.engine.isAvailable && cachedEmb.isEmpty && !self.isBuildingIndex {
                    self.buildIndex()
                }
            }
                return
            }

            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil
            ) else {
                DispatchQueue.main.async {
                    self.statusMessage = "Cannot access transcripts folder"
                    self.isLoading = false
                }
                return
            }

            var newEntries: [SubtitleEntry] = []
            var filesFound = 0
            var skipped = 0
            var failedFiles: [String] = []
            for case let url as URL in enumerator {
                let filename = url.lastPathComponent
                let lower = filename.lowercased()
                guard lower.hasSuffix(".srtx") || lower.hasSuffix(".srt") || lower.hasSuffix(".txt") else { continue }
                guard !lower.contains("rough") else { continue }
                if lower.contains("_transcript") {
                    if self.subtitleSiblings(forTranscript: url).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        skipped += 1
                        continue
                    }
                }
                filesFound += 1

                let relPath = url.path.replacingOccurrences(of: root + "/", with: "")
                let parts = relPath.split(separator: "/")

                let interview = self.inferInterviewName(from: filename)
                let fldr: String
                let location: String
                if parts.count >= 2 {
                    fldr = parts.dropLast().joined(separator: "/")
                    location = parts.first.map(String.init) ?? ""
                } else {
                    fldr = root
                    location = URL(fileURLWithPath: root).lastPathComponent
                }
                let loc = self.locationFullName(location)

                guard let cues = self.parseSRT(url: url) else {
                    skipped += 1
                    failedFiles.append(filename)
                    continue
                }

                let merged = self.mergeCues(cues)
                for (speaker, text, s, e) in merged {
                    newEntries.append(SubtitleEntry(
                        sourceFile: relPath,
                        interview: interview,
                        folder: fldr,
                        location: loc,
                        start_s: s,
                        end_s: e,
                        speaker: speaker,
                        text: text
                    ))
                }
            }
            let failedSuffix = skipped > 0 ? " (\(skipped) failed: \(failedFiles.joined(separator: ", ")))" : ""

            do {
                try self.db.loadSubtitles(newEntries, folder: root)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "DB error: \(error.localizedDescription)"
                    self.isLoading = false
                    self.isLoaded = false
                }
                return
            }

            DispatchQueue.main.async {
                self.entries = newEntries
                self.isLoaded = true
                self.isLoading = false
                if self.isTranscriptsLoaded, self.transcriptEntries.count > 0 {
                    self.statusMessage = "\(newEntries.count) sentence(s) + \(self.transcriptEntries.count) paragraph(s)"
                } else {
                    self.statusMessage = "\(newEntries.count) sentence(s) from \(filesFound) file(s)\(failedSuffix)"
                }
                if self.engine.isAvailable && self.embMap.isEmpty && !self.isBuildingIndex {
                    self.buildIndex()
                }
            }
        }
    }

    func reload(folder: String) {
        isLoaded = false
        isLoading = false
        entries = []
        embQueue.sync { embMap = [:] }
        indexGeneration = UUID()
        db.close()
        let cachePath = SearchDatabase.cachePath(for: folder, kind: "subtitles", tag: tag)
        try? FileManager.default.removeItem(atPath: cachePath)
        isTranscriptsLoaded = false
        isTranscriptsLoading = false
        transcriptEntries = []
        transcriptDb.close()
        let tCachePath = SearchDatabase.cachePath(for: folder, kind: "transcripts", tag: tag)
        try? FileManager.default.removeItem(atPath: tCachePath)
        loadOnce(folder: folder)
    }

    func reloadCurrent() {
        guard !lastLoadPath.isEmpty else { return }
        isLoaded = false
        isLoading = false
        entries = []
        embQueue.sync { embMap = [:] }
        indexGeneration = UUID()
        db.close()
        let cachePath = SearchDatabase.cachePath(for: currentFolder, kind: "subtitles", tag: tag)
        try? FileManager.default.removeItem(atPath: cachePath)
        isTranscriptsLoaded = false
        isTranscriptsLoading = false
        transcriptEntries = []
        transcriptDb.close()
        let tCachePath = SearchDatabase.cachePath(for: currentFolder, kind: "transcripts", tag: tag)
        try? FileManager.default.removeItem(atPath: tCachePath)
        if lastLoadWasFolder {
            loadOnce(folder: lastLoadPath)
        } else {
            loadSingleSRT(path: lastLoadPath)
        }
    }


    /// Cheap content fingerprint of the subtitle file set (path+size+mtime).
    /// Lets loadFolders reuse the SQLite cache — and its persisted embeddings —
    /// when nothing changed, instead of deleting and re-embedding every launch.
    static func removeDbArtifacts(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private static func folderFingerprint(_ folders: [String]) -> String {
        var h: UInt64 = 1469598103934665603
        func mix(_ s: String) {
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        }
        for folder in folders.sorted() {
            mix(folder)
            guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in en {
                let lower = url.lastPathComponent.lowercased()
                guard lower.hasSuffix(".srtx") || lower.hasSuffix(".srt") || lower.hasSuffix(".txt") else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                mix(url.path + "|\(size)|\(Int(mtime))")
            }
        }
        return String(format: "%016llx", h)
    }

    // MARK: - Multi-Folder Loading

    func loadFolders(_ folders: [String], forceRebuild: Bool = false) {
        guard !isLoading, !folders.isEmpty else { return }
        isLoaded = false
        isLoading = true
        entries = []
        embQueue.sync { embMap = [:] }
        indexGeneration = UUID()
        db.close()

        currentFolder = folders[0]
        lastLoadPath = folders[0]
        lastLoadWasFolder = true

        let dbPath = SearchDatabase.cachePath(for: folders[0], kind: "subtitles", tag: tag)
        let fingerprint = Self.folderFingerprint(folders)

        do {
            // Ensure cache directory exists
            let cacheDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: cacheDir.path) {
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            var servedFromCache = false

            if !forceRebuild, FileManager.default.fileExists(atPath: dbPath) {
                try db.open(path: dbPath)
                let saved = db.getCachedFingerprint()
                if saved == fingerprint, !db.needsSubtitleRebuild(folder: folders[0]) {
                    servedFromCache = true
                } else {
                    // Fingerprint mismatch or partial legacy cache — rebuild from
                    // scratch below; the DB is closed and recreated first.
                    db.close()
                }
            }

            if servedFromCache {
                // Nothing changed — serve cache including persisted embeddings.
                // Do the bulk read OFF the main thread; only post results.
                DispatchQueue.global().async { [weak self] in
                    guard let self else { return }
                    let cached = self.db.allSubtitleEntries()
                    let cachedEmb = self.db.loadAllSubtitleEmbeddings()
                    DispatchQueue.main.async {
                        self.entries = cached
                        self.embQueue.sync { self.embMap = cachedEmb }
                        self.isLoaded = true
                        self.isLoading = false
                        let idx = cachedEmb.isEmpty ? "" : ", AI index loaded"
                        self.statusMessage = "\(cached.count) sentence(s) loaded from cache\(idx)"
                    }
                }
                return
            }

            // Fresh build: force rebuild, missing file, or stale fingerprint.
            // Always arrive at the background block with the DB OPEN.
            Self.removeDbArtifacts(dbPath)
            if !FileManager.default.fileExists(atPath: cacheDir.path) {
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
            }
            do {
                try db.open(path: dbPath)
            } catch {
                Self.removeDbArtifacts(dbPath)
                do {
                    try db.open(path: dbPath)
                } catch {
                    DispatchQueue.main.async {
                        self.statusMessage = "DB open error: \(error.localizedDescription)"
                        self.isLoading = false
                    }
                    return
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "DB error: \(error.localizedDescription)"
                self.isLoading = false
            }
            return
        }

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var allEntries: [SubtitleEntry] = []
            var totalFiles = 0
            var skipped = 0

            for folder in folders {
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: folder),
                    includingPropertiesForKeys: nil
                ) else { continue }

                for case let url as URL in enumerator {
                    let filename = url.lastPathComponent
                    let lower = filename.lowercased()
                    guard lower.hasSuffix(".srtx") || lower.hasSuffix(".srt") || lower.hasSuffix(".txt") else { continue }
                    guard !lower.contains("rough") else { continue }
                    if lower.contains("_transcript") && lower.hasSuffix(".txt") {
                        if self.subtitleSiblings(forTranscript: url).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                            skipped += 1
                            continue
                        }
                    }
                    totalFiles += 1
                    let relPath = url.path.replacingOccurrences(of: folder + "/", with: "")
                    let parts = relPath.split(separator: "/")
                    let interview = self.inferInterviewName(from: filename)
                    let fldr: String
                    let location: String
                    if parts.count >= 2 {
                        fldr = parts.dropLast().joined(separator: "/")
                        location = parts.first.map(String.init) ?? ""
                    } else {
                        fldr = folder
                        location = URL(fileURLWithPath: folder).lastPathComponent
                    }
                    let loc = self.locationFullName(location)
                    guard let cues = self.parseSRT(url: url) else {
                        skipped += 1
                        continue
                    }
                    let merged = self.mergeCues(cues)
                    for (speaker, text, s, e) in merged {
                        allEntries.append(SubtitleEntry(
                            sourceFile: relPath,
                            interview: interview,
                            folder: fldr,
                            location: loc,
                            start_s: s,
                            end_s: e,
                            speaker: speaker,
                            text: text
                        ))
                    }
                }
            }

            do {
                try self.db.loadSubtitles(allEntries, folder: folders[0])
                // Mark the cache valid only after a completed build — a failed or
                // interrupted load must never be served as if it were whole.
                self.db.storeCachedFingerprint(fingerprint)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "DB error: \(error.localizedDescription)"
                    self.isLoading = false
                    self.isLoaded = false
                }
                return
            }

            DispatchQueue.main.async {
                self.entries = allEntries
                self.isLoaded = true
                self.isLoading = false
                self.statusMessage = "\(allEntries.count) sentence(s) from \(totalFiles) file(s)"
                if self.engine.isAvailable && self.embMap.isEmpty && !self.isBuildingIndex {
                    self.buildIndex()
                }
            }
        }
    }

    func loadTranscriptsFolders(_ folders: [String], forceRebuild: Bool = false) {
        guard !isTranscriptsLoading, !folders.isEmpty else { return }
        isTranscriptsLoaded = false
        isTranscriptsLoading = true

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var allEntries: [SubtitleEntry] = []
            var filesFound = 0

            for folder in folders {
                let dbPath = SearchDatabase.cachePath(for: folder, kind: "transcripts", tag: tag)
                try? FileManager.default.removeItem(atPath: dbPath)

                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: folder),
                    includingPropertiesForKeys: nil
                ) else { continue }

                for case let url as URL in enumerator {
                    let lower = url.lastPathComponent.lowercased()
                    guard lower.hasSuffix(".txt"), lower.contains("_transcript") else { continue }
                    guard !lower.contains("rough") else { continue }
                    filesFound += 1
                    let relPath = url.path.replacingOccurrences(of: folder + "/", with: "")
                    let parts = relPath.split(separator: "/")
                    let interview = self.inferInterviewName(from: url.lastPathComponent)
                    let fldr = parts.count >= 2 ? parts.dropLast().joined(separator: "/") : folder
                    let location = self.locationFullName(parts.first.map(String.init) ?? URL(fileURLWithPath: folder).lastPathComponent)
                    guard let cues = self.parseSRT(url: url) else { continue }
                    let merged = self.mergeCues(cues)
                    for (speaker, text, s, e) in merged {
                        allEntries.append(SubtitleEntry(
                            sourceFile: relPath,
                            interview: interview,
                            folder: fldr,
                            location: location,
                            start_s: s,
                            end_s: e,
                            speaker: speaker,
                            text: text
                        ))
                    }
                }
            }

            if let firstFolder = folders.first {
                let dbPath = SearchDatabase.cachePath(for: firstFolder, kind: "transcripts", tag: tag)
                // Always start from a clean file — stale sidecars or a half-written
                // main DB would fail schema creation on the retry too.
                Self.removeDbArtifacts(dbPath)
                do {
                    try self.transcriptDb.open(path: dbPath)
                    try self.transcriptDb.loadSubtitles(allEntries, folder: firstFolder)
                } catch {
                    Self.removeDbArtifacts(dbPath)
                    do {
                        try self.transcriptDb.open(path: dbPath)
                        try self.transcriptDb.loadSubtitles(allEntries, folder: firstFolder)
                    } catch {
                        DispatchQueue.main.async {
                            self.statusMessage = "Transcript DB error: \(error.localizedDescription)"
                            self.isTranscriptsLoaded = false
                            self.isTranscriptsLoading = false
                        }
                        return
                    }
                }
            }

            DispatchQueue.main.async {
                self.transcriptEntries = allEntries
                self.isTranscriptsLoaded = true
                self.isTranscriptsLoading = false
                let subCount = self.entries.count
                if subCount > 0, allEntries.count > 0 {
                    self.statusMessage = "\(subCount) sentence(s) + \(allEntries.count) paragraph(s)"
                } else if allEntries.count > 0 {
                    self.statusMessage = "\(allEntries.count) paragraph(s) from \(filesFound) file(s)"
                }
            }
        }
    }

    func loadSingleSRT(path: String) {
        isLoading = true
        statusMessage = "Loading SRT…"
        let folder = (path as NSString).deletingLastPathComponent
        currentFolder = folder
        lastLoadPath = path
        lastLoadWasFolder = false
        let cachePath = SearchDatabase.cachePath(for: folder, kind: "subtitles", tag: tag)
        try? FileManager.default.removeItem(atPath: cachePath)

        let filename = URL(fileURLWithPath: path).lastPathComponent
        if filename.lowercased().contains("_transcript") {
            if let paired = self.subtitleSiblings(forTranscript: URL(fileURLWithPath: path))
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                self.loadSingleSRT(path: paired.path)
                return
            }
        }

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            let url = URL(fileURLWithPath: path)
            guard let cues = self.parseSRT(url: url) else {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to parse \(url.lastPathComponent)"
                    self.isLoading = false
                }
                return
            }

            let merged = self.mergeCues(cues)
            let interview = self.inferInterviewName(from: url.lastPathComponent)
            let parent = url.deletingLastPathComponent().lastPathComponent
            let location = self.locationFullName(parent)

            var newEntries: [SubtitleEntry] = []
            for (speaker, text, s, e) in merged {
                newEntries.append(SubtitleEntry(
                    sourceFile: url.lastPathComponent,
                    interview: interview,
                    folder: url.deletingLastPathComponent().path,
                    location: location,
                    start_s: s,
                    end_s: e,
                    speaker: speaker,
                    text: text
                ))
            }

            do {
                let dbPath = SearchDatabase.cachePath(for: currentFolder, kind: "subtitles", tag: tag)
                try self.db.open(path: dbPath)
                try self.db.loadSubtitles(newEntries, folder: currentFolder)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "DB error: \(error.localizedDescription)"
                    self.isLoading = false
                    self.isLoaded = false
                }
                return
            }

            DispatchQueue.main.async {
                self.entries = newEntries
                self.isLoaded = true
                self.isLoading = false
                self.statusMessage = "\(newEntries.count) sentence(s) from \(url.lastPathComponent)"
                if self.engine.isAvailable && self.embMap.isEmpty && !self.isBuildingIndex {
                    self.buildIndex()
                }
            }
        }
    }

    func search(query: String, filterFolder: String? = nil, filterSourceFiles: Set<String> = []) -> [SubSearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        let exact = exactSearch(q, filterFolder: filterFolder)
        let exactFiltered = filterSourceFiles.isEmpty ? exact : exact.filter { filterSourceFiles.contains($0.entry.sourceFile) }

        guard engine.isAvailable, !embMap.isEmpty else { return exactFiltered }

        let semantic = semanticSearch(q, filterFolder: filterFolder, filterSourceFiles: filterSourceFiles)

        var seen = Set<String>()
        var merged: [SubSearchHit] = []
        for hit in exactFiltered {
            seen.insert(hit.id)
            merged.append(hit)
        }
        for hit in semantic {
            if !seen.contains(hit.id) {
                merged.append(hit)
            }
        }
        return merged.isEmpty ? exactFiltered : merged
    }

    private func semanticSearch(_ query: String, filterFolder: String? = nil, filterSourceFiles: Set<String> = []) -> [SubSearchHit] {
        guard let qVec = engine.embed(query) else { return exactSearch(query, filterFolder: filterFolder) }
        let snapshot: [String: [Double]] = embQueue.sync { embMap }
        var results: [(SubtitleEntry, Double)] = []
        for entry in entries {
            if let folder = filterFolder, !entry.folder.hasPrefix(folder) { continue }
            if !filterSourceFiles.isEmpty, !filterSourceFiles.contains(entry.sourceFile) { continue }
            if let vec = snapshot[entry.id] {
                let sim = engine.cosineSimilarity(qVec, vec)
                if sim >= semanticThreshold {
                    results.append((entry, sim))
                }
            }
        }
        results.sort { $0.1 > $1.1 }
        return results.map { SubSearchHit(entry: $0.0, similarity: $0.1) }
    }

    func exactSearch(_ query: String, filterFolder: String? = nil) -> [SubSearchHit] {
        let results = db.searchSubtitles(query, folder: filterFolder)
        return results.map { SubSearchHit(entry: $0) }
    }

    // MARK: - Transcript Search

    func loadTranscripts(folder: String) {
        guard !isTranscriptsLoaded, !isTranscriptsLoading else { return }
        isTranscriptsLoading = true
        statusMessage = "Loading transcripts…"

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            let root = folder
            let dbPath = SearchDatabase.cachePath(for: root, kind: "transcripts", tag: tag)
            try? FileManager.default.removeItem(atPath: dbPath)

            do {
                try self.transcriptDb.open(path: dbPath)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Transcript DB error: \(error.localizedDescription)"
                    self.isTranscriptsLoading = false
                }
                return
            }

            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil
            ) else {
                DispatchQueue.main.async {
                    self.statusMessage = "Cannot access transcripts folder"
                    self.isTranscriptsLoading = false
                }
                return
            }

            var newEntries: [SubtitleEntry] = []
            var filesFound = 0
            for case let url as URL in enumerator {
                let lower = url.lastPathComponent.lowercased()
                guard lower.hasSuffix(".txt"), lower.contains("_transcript") else { continue }
                guard !lower.contains("rough") else { continue }

                filesFound += 1
                let relPath = url.path.replacingOccurrences(of: root + "/", with: "")
                let parts = relPath.split(separator: "/")
                let interview = self.inferInterviewName(from: url.lastPathComponent)
                let fldr = parts.count >= 2 ? parts.dropLast().joined(separator: "/") : root
                let location = self.locationFullName(parts.first.map(String.init) ?? URL(fileURLWithPath: root).lastPathComponent)

                guard let cues = self.parseSRT(url: url) else { continue }
                let merged = self.mergeCues(cues)
                for (speaker, text, s, e) in merged {
                    newEntries.append(SubtitleEntry(
                        sourceFile: relPath,
                        interview: interview,
                        folder: fldr,
                        location: location,
                        start_s: s,
                        end_s: e,
                        speaker: speaker,
                        text: text
                    ))
                }
            }

            do {
                try self.transcriptDb.loadSubtitles(newEntries, folder: root)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Transcript DB error: \(error.localizedDescription)"
                    self.isTranscriptsLoading = false
                }
                return
            }

            DispatchQueue.main.async {
                self.transcriptEntries = newEntries
                self.isTranscriptsLoaded = true
                self.isTranscriptsLoading = false
                let subCount = self.entries.count
                if subCount > 0, newEntries.count > 0 {
                    self.statusMessage = "\(subCount) sentence(s) + \(newEntries.count) paragraph(s)"
                } else if newEntries.count > 0 {
                    self.statusMessage = "\(newEntries.count) paragraph(s) from \(filesFound) file(s)"
                }
            }
        }
    }

    func searchTranscripts(_ query: String) -> [SubtitleEntry] {
        // Never touch the transcript DB while it is being rebuilt —
        // the loader deletes and recreates the file, which would fail the search.
        guard isTranscriptsLoaded, !isTranscriptsLoading else { return [] }
        return transcriptDb.searchSubtitles(query)
    }

    func searchAll(query: String, limit: Int = 20) -> [SubtitleEntry] {
        var results: [SubtitleEntry] = []
        // Search subtitles (FTS5)
        if isLoaded {
            let subHits = db.searchSubtitles(query, limit: limit)
            results.append(contentsOf: subHits)
        }
        // Search transcripts (FTS5) — merge, dedup by id
        if isTranscriptsLoaded {
            let trHits = transcriptDb.searchSubtitles(query, limit: limit)
            let existingIDs = Set(results.map(\.id))
            for hit in trHits where !existingIDs.contains(hit.id) {
                results.append(hit)
            }
        }
        // Sort by start time for coherent reading
        results.sort { $0.start_s < $1.start_s }
        return Array(results.prefix(limit))
    }

    func findMatchingSubtitles(for transcriptEntry: SubtitleEntry) -> [SubSearchHit] {
        let base = inferInterviewName(from: transcriptEntry.sourceFile)
        return entries.filter { entry in
            entry.interview == base &&
            entry.start_s < transcriptEntry.end_s &&
            entry.end_s > transcriptEntry.start_s
        }.map { SubSearchHit(entry: $0) }
    }

    @Published var isBuildingIndex = false
    @Published var indexBuildProgress = 0
    @Published var indexBuildTotal = 0

    weak var appProgress: AppProgress?

    func buildIndex() {
        guard engine.isAvailable, !isBuildingIndex else { return }
        isBuildingIndex = true
        indexBuildProgress = 0
        indexBuildTotal = entries.count
        statusMessage = "Building AI index… 0/\(entries.count)"
        appProgress?.start("AI index 0/\(entries.count)")
        let gen = indexGeneration

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            for (i, entry) in self.entries.enumerated() {
                // A newer load/reload invalidated this build — stop touching the DB.
                if gen != self.indexGeneration { return }
                if let vec = self.engine.embed(entry.text) {
                    self.embQueue.sync { self.embMap[entry.id] = vec }
                    try? self.db.saveSubtitleEmbeddingByEntry(sourceFile: entry.sourceFile, start_s: entry.start_s, vec: vec)
                }
                if i % 50 == 0 || i == self.entries.count - 1 {
                    DispatchQueue.main.async {
                        guard gen == self.indexGeneration else { return }
                        self.indexBuildProgress = i + 1
                        self.statusMessage = "Building AI index… \(i+1)/\(self.entries.count)"
                        self.appProgress?.update("AI index", progress: Double(i + 1) / Double(self.entries.count))
                    }
                }
            }
            if gen != self.indexGeneration { return }
            let count = self.embQueue.sync { self.embMap.count }
            DispatchQueue.main.async {
                guard gen == self.indexGeneration else { return }
                self.isBuildingIndex = false
                self.statusMessage = "AI index ready (\(count) sentences)"
                self.appProgress?.finish("AI index ready")
            }
        }
    }


    // MARK: - SRT Parsing

    private func parseSRT(url: URL) -> [(speaker: String, text: String, start_s: Double, end_s: Double)]? {
        let content: String
        if let c = try? String(contentsOf: url, encoding: .utf8) {
            content = c
        } else if let c = try? String(contentsOf: url, encoding: .windowsCP1252) {
            content = c
        } else if let c = try? String(contentsOf: url, encoding: .isoLatin1) {
            content = c
        } else if let c = try? String(contentsOf: url, encoding: .utf16) {
            content = c
        } else {
            return nil
        }
        let allLines = content.components(separatedBy: .newlines)
        let isSRTX = url.lastPathComponent.lowercased().hasSuffix(".srtx") || url.lastPathComponent.lowercased().hasSuffix(".txt")

        if isSRTX {
            let frameRegex = try? NSRegularExpression(
                pattern: #"\[(\d+):(\d+):(\d+):(\d+)\s*-\s*(\d+):(\d+):(\d+):(\d+)\]"#
            )
            if let frameRegex,
               let probe = allLines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               frameRegex.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) != nil {
                return parseFrameSRT(allLines: allLines, regex: frameRegex, fps: frameRate)
            }
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)"#
        ) else { return nil }
        var cues: [(String, String, Double, Double)] = []

        // Group lines into cues by their timecode (robust to blank lines that
        // would otherwise split a timecode from its text in the DaVinci export
        // style, where a blank line separates timecode and text).
        var currentTimecode: String? = nil
        var currentTextLines: [String] = []
        let indexPattern = #"^\d+$"#

        func flush() {
            guard let tc = currentTimecode else { currentTextLines = []; return }
            let nsRange = NSRange(tc.startIndex..., in: tc)
            guard let m = regex.firstMatch(in: tc, range: nsRange), m.numberOfRanges == 9,
                  let h1 = tcInt(tc, m, 1),
                  let m1 = tcInt(tc, m, 2),
                  let s1 = tcInt(tc, m, 3),
                  let ms1 = tcInt(tc, m, 4),
                  let h2 = tcInt(tc, m, 5),
                  let m2 = tcInt(tc, m, 6),
                  let s2 = tcInt(tc, m, 7),
                  let ms2 = tcInt(tc, m, 8)
            else { currentTextLines = []; currentTimecode = nil; return }
            let start = Double(h1 * 3600 + m1 * 60 + s1) + Double(ms1) / 1000
            let end = Double(h2 * 3600 + m2 * 60 + s2) + Double(ms2) / 1000
            let (speaker, text) = self.extractSpeakerAndText(lines: currentTextLines, isSRTX: isSRTX)
            if !text.isEmpty {
                cues.append((speaker, text, start, end))
            }
            currentTextLines = []
            currentTimecode = nil
        }

        for raw in allLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(line.startIndex..., in: line)
            if let _ = regex.firstMatch(in: line, range: nsRange) {
                flush()
                currentTimecode = line
                currentTextLines = []
                continue
            }
            if line.isEmpty { continue }
            if line.range(of: indexPattern, options: .regularExpression) != nil {
                if !currentTextLines.isEmpty {
                    flush()
                }
                continue
            }
            if currentTimecode == nil { continue }
            currentTextLines.append(line)
        }
        flush()

        return cues.isEmpty ? nil : cues
    }

    private func extractSpeakerAndText(lines: [String], isSRTX: Bool) -> (String, String) {
        guard lines.count >= 1 else { return ("", "") }
        if isSRTX, lines.count >= 2 {
            return (lines[0], lines.dropFirst(1).joined(separator: " "))
        }
        let raw = lines.joined(separator: " ")
        let cleaned = raw.replacingOccurrences(of: "</?b>", with: "", options: .regularExpression)
        return ("", cleaned)
    }

    private func parseFrameSRT(allLines: [String], regex: NSRegularExpression, fps: Double) -> [(speaker: String, text: String, start_s: Double, end_s: Double)]? {
        let safeFps = fps > 0 ? fps : 25.0
        var cues: [(String, String, Double, Double)] = []
        var currentTimecode: String? = nil
        var currentTextLines: [String] = []
        let indexPattern = #"^\d+$"#

        func flush() {
            guard let tc = currentTimecode else { currentTextLines = []; return }
            let nsRange = NSRange(tc.startIndex..., in: tc)
            guard let m = regex.firstMatch(in: tc, range: nsRange), m.numberOfRanges == 9,
                  let h1 = tcInt(tc, m, 1),
                  let m1 = tcInt(tc, m, 2),
                  let s1 = tcInt(tc, m, 3),
                  let f1 = tcInt(tc, m, 4),
                  let h2 = tcInt(tc, m, 5),
                  let m2 = tcInt(tc, m, 6),
                  let s2 = tcInt(tc, m, 7),
                  let f2 = tcInt(tc, m, 8)
            else { currentTextLines = []; currentTimecode = nil; return }
            let start = Double(h1 * 3600 + m1 * 60 + s1) + Double(f1) / safeFps
            let end = Double(h2 * 3600 + m2 * 60 + s2) + Double(f2) / safeFps
            let speaker = currentTextLines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let text = currentTextLines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                cues.append((speaker, text, start, end))
            }
            currentTextLines = []
            currentTimecode = nil
        }

        for raw in allLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(line.startIndex..., in: line)
            if let _ = regex.firstMatch(in: line, range: nsRange) {
                flush()
                currentTimecode = line
                currentTextLines = []
                continue
            }
            if line.isEmpty { continue }
            if line.range(of: indexPattern, options: .regularExpression) != nil {
                if !currentTextLines.isEmpty { flush() }
                continue
            }
            if currentTimecode == nil { continue }
            currentTextLines.append(line)
        }
        flush()

        return cues.isEmpty ? nil : cues
    }

    private func tcInt(_ block: String, _ match: NSTextCheckingResult, _ idx: Int) -> Int? {
        let r = match.range(at: idx)
        guard r.location != NSNotFound else { return nil }
        guard let range = Range(r, in: block) else { return nil }
        return Int(block[range])
    }

    private func mergeCues(_ cues: [(speaker: String, text: String, start_s: Double, end_s: Double)]) -> [(String, String, Double, Double)] {
        return cues.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Helpers

    private func inferInterviewName(from filename: String) -> String {
        let name = filename
            .replacingOccurrences(of: ".srtx", with: "")
            .replacingOccurrences(of: ".srt", with: "")
            .replacingOccurrences(of: ".txt", with: "")
            .replacingOccurrences(of: "_transcripts", with: "")
            .replacingOccurrences(of: "_transcript", with: "")
            .replacingOccurrences(of: "_subtitles", with: "")
            .replacingOccurrences(of: "_rough", with: "")
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// Given a transcript file (`Foo_transcript.txt` or `Foo_transcripts.txt`), returns the
    /// same-directory subtitle siblings (`Foo_subtitles.srtx/.srt`, `Foo.srtx/.srt`).
    /// Empty when the file isn't a transcript.
    private func subtitleSiblings(forTranscript url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var base: String?
        for suffix in ["_transcripts.txt", "_transcript.txt"] {
            if name.hasSuffix(suffix) { base = String(name.dropLast(suffix.count)); break }
        }
        guard let b = base else { return [] }
        return ["\(b)_subtitles.srtx", "\(b)_subtitles.srt", "\(b).srtx", "\(b).srt"]
            .map { dir.appendingPathComponent($0) }
    }

    private func locationFullName(_ short: String) -> String {
        switch short.lowercased() {
        case "bairrada": return "Bairrada"
        case "belgium": return "Belgium"
        default: return short
        }
    }
}
