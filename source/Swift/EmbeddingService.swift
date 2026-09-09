import NaturalLanguage

// MARK: - Embedding engine using NLEmbedding (macOS 11+)
// CoreNLP is NOT thread-safe — all calls are serialized on a dedicated queue.

struct EmbeddingEngine {
    static let shared = EmbeddingEngine()
    private let embedding: NLEmbedding? = .sentenceEmbedding(for: .english)
    private let queue = DispatchQueue(label: "com.assistanteditor.embedding")

    func embed(_ text: String) -> [Double]? {
        queue.sync {
            embedding?.vector(for: text)
        }
    }

    func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        let dot = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        let na = sqrt(a.reduce(0.0) { $0 + $1 * $1 })
        let nb = sqrt(b.reduce(0.0) { $0 + $1 * $1 })
        return na > 0 && nb > 0 ? dot / (na * nb) : 0
    }

    var isAvailable: Bool { embedding != nil }
}
