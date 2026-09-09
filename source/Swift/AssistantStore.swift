import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let content: String
    var isStreaming = false

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

class AssistantStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    private var currentTask: URLSessionDataTask?
    private var generationID = UUID()

    /// Cancels the in-flight chat request (ESC).
    func cancelAll() {
        generationID = UUID()
        currentTask?.cancel()
        currentTask = nil
        if isProcessing {
            isProcessing = false
            if let idx = messages.indices.last, messages[idx].isStreaming {
                messages[idx] = ChatMessage(role: "assistant", content: "Cancelled.")
            }
        }
    }

    func send(_ text: String, knowledgeStore: KnowledgeStore, subStore: SubtitleStore, docStore: DocumentStore) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessage(role: "user", content: trimmed)
        messages.append(userMsg)
        isProcessing = true

        let assistantMsg = ChatMessage(role: "assistant", content: "", isStreaming: true)
        messages.append(assistantMsg)
        let msgIdx = messages.count - 1

        // Build context on the calling (main) thread so we never read the
        // stores' @Published state from a background queue (data race). Only the
        // blocking Ollama call moves off the main thread.
        var contextParts: [String] = []

        // Always include knowledge base summaries as baseline context
        if knowledgeStore.isBuilt && !knowledgeStore.interviews.isEmpty {
            let baseline = knowledgeStore.allInterviewsContext()
            if !baseline.isEmpty {
                contextParts.append(baseline)
            }
            // Add keyword-specific search results on top if they add value
            let searchCtx = knowledgeStore.search(query: trimmed)
            if !searchCtx.isEmpty && searchCtx != baseline {
                contextParts.append("Relevant matches:\n\(searchCtx)")
            }
        }

        // FTS5 subtitle search for actual transcript text
        if subStore.isLoaded || subStore.isTranscriptsLoaded {
            let hits = subStore.searchAll(query: trimmed, limit: 20)
            if !hits.isEmpty {
                var hitLines = ["Relevant transcript excerpts:"]
                for hit in hits {
                    let speaker = hit.speaker.isEmpty ? "Speaker" : hit.speaker
                    let tc = hit.timecode
                    let interview = hit.interview
                    hitLines.append("[\(tc)] \(speaker) (\(interview)): \(hit.text)")
                }
                contextParts.append(hitLines.joined(separator: "\n"))
            }
        }

        // Fallback: if nothing found, list what's available
        if contextParts.isEmpty {
            contextParts.append(self.fallbackContext(subStore: subStore, docStore: docStore))
        }

        let context = contextParts.joined(separator: "\n\n")
        let prompt = self.buildPrompt(userMessage: trimmed, context: context, knowledgeStore: knowledgeStore, docStore: docStore)
        let gen = self.generationID

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            OMLXClient.shared.complete(
                prompt: prompt,
                temperature: 0.3,
                maxTokens: 4096,
                timeout: 120
            ) { [weak self] result in
                guard let self, self.generationID == gen else { return }
                if let text = result.text {
                    let cleaned = Self.stripThink(text)
                    DispatchQueue.main.async {
                        if self.messages.indices.contains(msgIdx) {
                            self.messages[msgIdx] = ChatMessage(role: "assistant", content: cleaned)
                        }
                        self.isProcessing = false
                    }
                } else {
                    let errMsg = result.error ?? "No response from oMLX"
                    DispatchQueue.main.async {
                        if self.messages.indices.contains(msgIdx) {
                            self.messages[msgIdx] = ChatMessage(role: "assistant", content: "Error: \(errMsg)")
                        }
                        self.isProcessing = false
                    }
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
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clear() {
        messages = []
    }

    /// Remove a user message and the assistant reply that follows it (if any).
    /// Returns the user text so the caller can restore it to the input field.
    @discardableResult
    func revertUserMessage(id: UUID) -> String? {
        guard let idx = messages.firstIndex(where: { $0.id == id && $0.role == "user" }) else { return nil }
        let text = messages[idx].content
        // Remove assistant reply immediately after this user message, if present
        if messages.indices.contains(idx + 1), messages[idx + 1].role == "assistant" {
            messages.remove(at: idx + 1)
        }
        messages.remove(at: idx)
        return text
    }

    /// Ask the local LLM for a concise title/synopsis for the current conversation.
    /// Used as the HTML export title. Falls back to nil on failure.
    func generateConversationSynopsis(completion: @escaping (String?) -> Void) {
        guard !messages.isEmpty else { completion(nil); return }
        let excerpt = messages.prefix(12).map { m in
            let role = m.role == "user" ? "User" : "Assistant"
            let clipped = m.content.count > 300 ? String(m.content.prefix(300)) + "…" : m.content
            return "\(role): \(clipped)"
        }.joined(separator: "\n\n")
        let prompt = """
        Summarize the following conversation into a single concise title (5-10 words, no quotes, no period, title case) that captures the main topic. Respond with the title only.

        Conversation:
        \(excerpt)

        Title:
        """
        OMLXClient.shared.complete(prompt: prompt, temperature: 0.3, maxTokens: 32, timeout: 30) { result in
            if let text = result.text {
                var t = Self.stripThink(text).trimmingCharacters(in: .whitespacesAndNewlines)
                t = t.replacingOccurrences(of: "^[\"'\\-–—]+", with: "", options: .regularExpression)
                t = t.replacingOccurrences(of: "[\"'\\-–—]+$", with: "", options: .regularExpression)
                if t.count > 80 { t = String(t.prefix(80)) }
                completion(t.isEmpty ? nil : t)
            } else {
                completion(nil)
            }
        }
    }

    /// HTML export of the current conversation — styled, self-contained.
    func htmlExport(folders: [String] = [], synopsisTitle: String? = nil) -> String {
        let esc: (String) -> String = { s in
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var rows = ""
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let dateStr = df.string(from: Date())
        for m in messages {
            let role = m.role == "user" ? "You" : "Assistant"
            let cls = m.role == "user" ? "user" : "assistant"
            let body = esc(m.content).replacingOccurrences(of: "\n", with: "<br>")
            rows += "<div class=\"msg \(cls)\"><div class=\"role\">\(role)</div><div class=\"body\">\(body)</div></div>\n"
        }
        let foldersHTML: String
        if folders.isEmpty {
            foldersHTML = ""
        } else {
            let items = folders.map { f in
                let name = (f as NSString).lastPathComponent
                return "<li><code>\(esc(f))</code> — \(esc(name))</li>"
            }.joined(separator: "\n")
            foldersHTML = """
            <div class="folders"><div class="folders-title">Loaded folders (\(folders.count))</div><ul>\(items)</ul></div>
            """
        }
        let titleText = synopsisTitle?.isEmpty == false ? synopsisTitle! : "Conversation — \(dateStr)"
        let titleEsc = esc(titleText)
        let subtitle: String
        if synopsisTitle?.isEmpty == false {
            subtitle = "<div style=\"font-size:12px;color:#8a8a8e;margin:-8px 0 14px 0\">\(esc(dateStr))</div>"
        } else {
            subtitle = ""
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <title>\(titleEsc)</title>
        <style>
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:720px;margin:40px auto;padding:0 16px;color:#1d1d1f;line-height:1.5}
        h1{font-size:19px;color:#1d1d1f;margin-bottom:6px}
        .folders{margin:12px 0 20px 0;padding:10px 12px;background:#f0f4f8;border-radius:8px;border:1px solid #dde3ea}
        .folders-title{font-size:12px;font-weight:600;color:#5a6b7a;margin-bottom:6px}
        .folders ul{margin:0;padding-left:18px}
        .folders li{font-size:12px;color:#333;margin:2px 0}
        .folders code{font-size:11px;background:#e8ecf0;padding:1px 4px;border-radius:4px}
        .msg{margin:16px 0;padding:12px 14px;border-radius:10px}
        .msg.user{background:rgba(0,122,255,0.10);margin-left:48px}
        .msg.assistant{background:#f5f5f7;margin-right:48px}
        .role{font-size:11px;font-weight:600;color:#6e6e73;margin-bottom:4px;text-transform:uppercase;letter-spacing:0.04em}
        .body{font-size:14px;white-space:pre-wrap;word-break:break-word}
        </style></head><body>
        <h1>\(titleEsc)</h1>
        \(subtitle)
        \(foldersHTML)
        \(rows)
        </body></html>
        """
    }

    private func fallbackContext(subStore: SubtitleStore, docStore: DocumentStore) -> String {
        var parts: [String] = []
        if !subStore.entries.isEmpty {
            let interviews = Array(Set(subStore.entries.map(\.interview))).sorted()
            parts.append("Available interviews (from subtitles):\n" + interviews.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !subStore.transcriptEntries.isEmpty {
            let tInterviews = Array(Set(subStore.transcriptEntries.map(\.interview))).sorted()
            parts.append("Available interviews (from transcripts):\n" + tInterviews.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !docStore.allDocuments.isEmpty {
            let docs = docStore.allDocuments.map { d in
                let markers = d.markers.prefix(3).map(\.name).joined(separator: "; ")
                let suffix = markers.isEmpty ? "" : " — \(markers)"
                return "- \(d.title) (\(d.location))\(suffix)"
            }.joined(separator: "\n")
            parts.append("Documents (\(docStore.allDocuments.count)):\n\(docs)")
        }
        if parts.isEmpty {
            parts.append("No interview material is currently loaded. Ask the user to choose a project folder.")
        } else {
            parts.append("\nNote: Interview titles, locations, and chapter names ARE part of the loaded material. If asked what something is (e.g. a place or person), answer from the interview title/location/speaker list even when transcript hits are empty. Do not claim 'no material' when interview metadata exists.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func buildPrompt(userMessage: String, context: String, knowledgeStore: KnowledgeStore, docStore: DocumentStore) -> String {
        let ivCount = knowledgeStore.interviews.count
        let markerCount = knowledgeStore.interviews.reduce(0) { $0 + $1.markerCount }
        var system = PrimingRegistry.stage(for: "priming_transcriptChat")?.load() ?? ""

        if system.isEmpty {
            system = "You are an assistant editor. You help the editor build narrative from source material — transcripts, subtitles, and recorded speech."
        }

        system += """

        You have access to \(ivCount) interview(s) with \(markerCount) chapter markers.
        """

        if !docStore.allDocuments.isEmpty {
            let docTitles = docStore.allDocuments.prefix(10).map { "  - \($0.title)" }.joined(separator: "\n")
            system += "\nLoaded documents:\n\(docTitles)"
        }

        system += """

        ---
        Context from loaded material:

        \(context)
        ---

        \(userMessage)
        """

        return system
    }
}
