import Foundation
import SwiftUI

struct TopicKnowledge: Codable {
    let theme: String
    let color: String
    let markerNames: [String]
    let notes: [String]
}

struct KeyQuote: Codable {
    let text: String
    let speaker: String
    let timecode: String
}

struct InterviewKnowledge: Codable {
    let title: String
    let location: String
    let speakers: [String]
    let summary: String
    let topics: [TopicKnowledge]
    let keyQuotes: [KeyQuote]
    let markerCount: Int
}

struct KnowledgeResult {
    let interview: InterviewKnowledge
    let score: Int
}

class KnowledgeStore: ObservableObject {
    @Published var interviews: [InterviewKnowledge] = []
    @Published var isBuilt = false
    var dynamicThemes: [ProjectTheme] = []

    private let buildQueue = DispatchQueue(label: "com.assistanteditor.knowledge")

    private var lastInputsStamp: String = ""

    /// Quick-change signature of the inputs knowledge was built from.
    private static func inputsStamp(subStore: SubtitleStore, docStore: DocumentStore) -> String {
        let markers = docStore.allDocuments.reduce(0) { $0 + $1.markers.count }
        return "\(docStore.allDocuments.count)|\(markers)|\(subStore.entries.count)|\(subStore.transcriptEntries.count)"
    }

    func build(subStore: SubtitleStore, docStore: DocumentStore) {
        guard !subStore.entries.isEmpty || !subStore.transcriptEntries.isEmpty || !docStore.allDocuments.isEmpty else {
            DispatchQueue.main.async { self.isBuilt = true }
            return
        }

        buildQueue.async { [weak self] in
            guard let self else { return }

            let stamp = Self.inputsStamp(subStore: subStore, docStore: docStore)
            if self.isBuilt && stamp == self.lastInputsStamp {
                return // nothing changed for this exact input set
            }

            // Fast path: cached knowledge for the SAME folder with the SAME inputs
            let folder = docStore.allDocuments.first?.sourceFolder ?? subStore.entries.first?.folder ?? ""
            if !folder.isEmpty, let cached = self.loadCache(folder: folder, stamp: stamp), !cached.isEmpty {
                self.lastInputsStamp = stamp
                DispatchQueue.main.async {
                    self.interviews = cached
                    self.isBuilt = true
                }
                return
            }

            var result: [InterviewKnowledge] = []

            let entriesByInterview = Dictionary(grouping: subStore.entries) { $0.interview }
            let docsByTitle = Dictionary(grouping: docStore.allDocuments) { $0.title }
                .compactMapValues { $0.first }

            for (title, entries) in entriesByInterview {
                let doc = docsByTitle[title]
                let speakers = doc?.speakers ?? Array(Set(entries.map(\.speaker).filter { !$0.isEmpty }))
                let location = doc?.location ?? entries.first?.location ?? ""
                let summary = loadSynopsis(doc: doc)
                let topics = buildTopics(doc: doc)
                let quotes = extractKeyQuotes(from: entries, embMap: subStore.embMap)
                let markerCount = doc?.markers.count ?? 0

                result.append(InterviewKnowledge(
                    title: title,
                    location: location,
                    speakers: speakers,
                    summary: summary,
                    topics: topics,
                    keyQuotes: quotes,
                    markerCount: markerCount
                ))
            }

            for doc in docStore.allDocuments {
                if !result.contains(where: { $0.title == doc.title }) {
                    let summary = loadSynopsis(doc: doc)
                    result.append(InterviewKnowledge(
                        title: doc.title,
                        location: doc.location,
                        speakers: doc.speakers ?? [],
                        summary: summary,
                        topics: buildTopics(doc: doc),
                        keyQuotes: [],
                        markerCount: doc.markers.count
                    ))
                }
            }

            self.lastInputsStamp = stamp
            self.cache(result, folder: docStore.allDocuments.first?.sourceFolder
                       ?? subStore.entries.first?.folder ?? "", stamp: stamp)

            DispatchQueue.main.async {
                self.interviews = result
                self.isBuilt = true
            }
        }
    }

    func allInterviewsContext() -> String {
        var parts: [String] = []
        for iv in interviews {
            parts.append("## \(iv.title) (\(iv.location))")
            if !iv.speakers.isEmpty {
                parts.append("Speakers: \(iv.speakers.joined(separator: ", "))")
            }
            if !iv.summary.isEmpty {
                parts.append("Summary: \(iv.summary)")
            }
            if !iv.topics.isEmpty {
                var topicLines = ["Topics:"]
                for t in iv.topics {
                    let names = t.markerNames.prefix(4).joined(separator: "; ")
                    topicLines.append("- \(t.theme) (\(t.markerNames.count) markers): \(names)")
                }
                parts.append(topicLines.joined(separator: "\n"))
            }
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    func search(query: String) -> String {
        let q = query.lowercased()
        let terms = q.split(separator: " ").filter { $0.count > 2 }

        var scored: [(InterviewKnowledge, Int)] = []

        for iv in interviews {
            var score = 0
            let searchText = "\(iv.title) \(iv.location) \(iv.summary) \(iv.topics.map(\.theme).joined()) \(iv.keyQuotes.map(\.text).joined())".lowercased()

            if searchText.contains(q) { score += 10 }

            for term in terms {
                if iv.title.lowercased().contains(term) { score += 8 }
                if iv.summary.lowercased().contains(term) { score += 5 }
                if iv.location.lowercased().contains(term) { score += 3 }
                for topic in iv.topics {
                    if topic.theme.lowercased().contains(term) { score += 4 }
                    for name in topic.markerNames {
                        if name.lowercased().contains(term) { score += 3 }
                    }
                }
                for quote in iv.keyQuotes {
                    if quote.text.lowercased().contains(term) { score += 2 }
                }
            }

            if score > 0 {
                scored.append((iv, score))
            }
        }

        scored.sort { $0.1 > $1.1 }
        let top = scored.prefix(6)

        var parts: [String] = []
        for (iv, _) in top {
            parts.append("## \(iv.title) (\(iv.location))")
            if !iv.speakers.isEmpty {
                parts.append("Speakers: \(iv.speakers.joined(separator: ", "))")
            }
            if !iv.summary.isEmpty {
                parts.append("Summary: \(iv.summary)")
            }
            if !iv.topics.isEmpty {
                var topicLines = ["Topics:"]
                for t in iv.topics {
                    let names = t.markerNames.prefix(4).joined(separator: "; ")
                    topicLines.append("- \(t.theme) (\(t.markerNames.count) markers): \(names)")
                }
                parts.append(topicLines.joined(separator: "\n"))
            }
            if !iv.keyQuotes.isEmpty {
                var quoteLines = ["Key quotes:"]
                for q in iv.keyQuotes.prefix(3) {
                    let speaker = q.speaker.isEmpty ? "Speaker" : q.speaker
                    quoteLines.append("- \"\(q.text.prefix(200))\" — \(speaker)")
                }
                parts.append(quoteLines.joined(separator: "\n"))
            }
            parts.append("")
        }

        if parts.isEmpty {
            let allTitles = interviews.map { "- \($0.title) (\($0.location))" }.joined(separator: "\n")
            return "Available interviews:\n\(allTitles)"
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Private

    private func loadSynopsis(doc: SummaryDocument?) -> String {
        guard let doc, let sourceFolder = doc.sourceFolder, let sourceFile = doc.sourceFile else { return "" }
        let dir = URL(fileURLWithPath: sourceFolder)
        let base = (sourceFile as NSString).deletingPathExtension
        let synPath = dir.appendingPathComponent("\(base)_synopsis.txt")
        return (try? String(contentsOf: synPath, encoding: .utf8)) ?? ""
    }

    private func buildTopics(doc: SummaryDocument?) -> [TopicKnowledge] {
        guard let doc else { return [] }
        let grouped = Dictionary(grouping: doc.markers) { $0.theme }
        return grouped.map { theme, markers in
            let color: String
            if let dynamic = dynamicThemes.first(where: { $0.name == theme }) {
                color = dynamic.color
            } else {
                color = "Tan"
            }
            return TopicKnowledge(
                theme: theme,
                color: color,
                markerNames: markers.map(\.name),
                notes: markers.map(\.notes).filter { !$0.isEmpty }
            )
        }.sorted { $0.markerNames.count > $1.markerNames.count }
    }

    private func extractKeyQuotes(from entries: [SubtitleEntry], embMap: [String: [Double]]) -> [KeyQuote] {
        let vecs: [(idx: Int, vec: [Double])] = entries.enumerated().compactMap { (i, e) in
            guard let vec = embMap[e.id] else { return nil }
            return (i, vec)
        }
        guard vecs.count >= 3 else {
            return entries.prefix(3).map { e in
                KeyQuote(text: e.text, speaker: e.speaker, timecode: e.timecode)
            }
        }

        let dim = vecs[0].vec.count
        var centroid = [Double](repeating: 0, count: dim)
        for (_, vec) in vecs {
            for j in 0..<dim {
                centroid[j] += vec[j]
            }
        }
        for j in 0..<dim {
            centroid[j] /= Double(vecs.count)
        }

        let scored = vecs.map { (idx, vec) -> (Int, Double) in
            let dot = zip(centroid, vec).map(*).reduce(0, +)
            let normC = sqrt(centroid.map { $0*$0 }.reduce(0, +))
            let normV = sqrt(vec.map { $0*$0 }.reduce(0, +))
            let sim = dot / (max(normC, 1e-10) * max(normV, 1e-10))
            return (idx, sim)
        }.sorted { $0.1 > $1.1 }

        return scored.prefix(5).map { (idx, _) in
            let e = entries[idx]
            return KeyQuote(text: e.text, speaker: e.speaker, timecode: e.timecode)
        }
    }

    private struct CacheEnvelope: Codable {
        let folder: String
        let stamp: String
        let items: [InterviewKnowledge]
    }

    func invalidate() {
        lastInputsStamp = ""
        isBuilt = false
        interviews = []
    }

    private func cache(_ data: [InterviewKnowledge], folder: String, stamp: String) {
        guard let encoded = try? JSONEncoder().encode(
            CacheEnvelope(folder: folder, stamp: stamp, items: data)) else { return }
        let path = cachePath(folder: folder)
        try? encoded.write(to: URL(fileURLWithPath: path))
    }

    /// Returns items only when the envelope matches folder AND input stamp —
    /// a different folder (or changed files) must never be served stale knowledge.
    private func loadCache(folder: String, stamp: String) -> [InterviewKnowledge]? {
        let path = cachePath(folder: folder)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let env = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              env.folder == folder, env.stamp == stamp, !env.items.isEmpty else { return nil }
        return env.items
    }

    private func cachePath(folder: String) -> String {
        let folderName = URL(fileURLWithPath: folder).lastPathComponent
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("assistanteditor_knowledge_\(folderName).json").path
    }
}
