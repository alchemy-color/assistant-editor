import Foundation

/// Curated quality metadata for the models that appear in the oMLX library
/// (subset of what the user has pulled). Unknown models get a generic entry
/// so the UI never shows a blank.
struct ModelInfo {
    var shortName: String
    var tier: String        // S / A / B / C / ASR
    var stars: Int          // 1…5, overall quality for this app's workloads
    var virtues: [String]   // 2–3 short tags shown inline
    var detail: String      // one-line why it fits (or doesn't) this app
    var contextLabel: String
    var ramLabel: String
}

enum ModelCatalog {

    static func info(for id: String) -> ModelInfo {
        let key = id.lowercased()
        // Strip mlx-community/ prefix and -mlx suffixes for matching
        let stem: String = {
            var s = key
            if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
            s = s.replacingOccurrences(of: "-mlx-8bit", with: "")
            s = s.replacingOccurrences(of: "-mlx", with: "")
            return s
        }()

        // Exact / prefix matches first
        switch true {
        case stem.hasPrefix("qwen3-30b-a3b"):
            return ModelInfo(shortName: "Qwen3-30B-A3B", tier: "S", stars: 5,
                virtues: ["Best JSON", "Multilingual", "MoE-efficient"],
                detail: "Top pick for script parsing & theme analysis — 3B active via MoE, 131k ctx, excellent JSON/schema.",
                contextLabel: "131k", ramLabel: "16 GB")
        case stem.hasPrefix("qwen3.8-27b-4bit") || stem == "qwen3.8-27b-4bit":
            return ModelInfo(shortName: "Qwen3.8-27B", tier: "S", stars: 5,
                virtues: ["Strong analysis", "Multilingual", "Long ctx"],
                detail: "Newest Qwen3.8 — superb thematic reasoning; heavier than the A3B (15 GB).",
                contextLabel: "131k", ramLabel: "15 GB")
        case stem.hasPrefix("qwen3.8-27b-8bit"):
            return ModelInfo(shortName: "Qwen3.8-27B 8-bit", tier: "S", stars: 5,
                virtues: ["Strong analysis", "Multilingual"],
                detail: "Same as 4-bit Qwen3.8 but 27 GB — quality bump, much heavier.",
                contextLabel: "131k", ramLabel: "27 GB")
        case stem.hasPrefix("gemma-4-31b") || stem.hasPrefix("gemma4-31b"):
            return ModelInfo(shortName: "Gemma-4 31B", tier: "S", stars: 5,
                virtues: ["Strong analysis", "Long ctx"],
                detail: "Large Gemma — powerful but 17 GB; Qwen MoE is cheaper per token.",
                contextLabel: "256k", ramLabel: "17 GB")
        case stem.hasPrefix("devstral-small-2-24b") || stem.hasPrefix("devstral"):
            return ModelInfo(shortName: "Devstral 24B", tier: "A", stars: 4,
                virtues: ["Code-focused", "Good JSON"],
                detail: "Coding-specialized (Mistral) — strong JSON, weaker on prose/thematic analysis.",
                contextLabel: "131k", ramLabel: "14 GB")
        case stem.hasPrefix("gpt-oss-20b"):
            return ModelInfo(shortName: "GPT-OSS 20B", tier: "A", stars: 4,
                virtues: ["Balanced", "Long ctx"],
                detail: "OpenAI OSS — capable generalist; MXFP4+Q8 quant is less proven for schema-constrained JSON.",
                contextLabel: "131k", ramLabel: "12 GB")
        case stem.hasPrefix("qwen3-14b"):
            return ModelInfo(shortName: "Qwen3-14B", tier: "A", stars: 4,
                virtues: ["Strong analysis", "Multilingual"],
                detail: "Mid-size Qwen3 — good all-rounder, lighter than the 27/30B tier.",
                contextLabel: "131k", ramLabel: "7.7 GB")
        case stem == "qwen3-8b" || stem.hasPrefix("qwen3-8b-"):
            return ModelInfo(shortName: "Qwen3-8B", tier: "A", stars: 4,
                virtues: ["Balanced", "Multilingual", "Fast"],
                detail: "Sweet spot for daily use — fast, multilingual, solid JSON; perfect for live editing.",
                contextLabel: "131k", ramLabel: "~5 GB")
        case stem.hasPrefix("llama-3.1-8b"):
            return ModelInfo(shortName: "Llama-3.1 8B", tier: "A", stars: 4,
                virtues: ["Balanced", "Reliable", "Fast"],
                detail: "Solid all-rounder — reliable instruction following, good for RAG chat & chapters.",
                contextLabel: "131k", ramLabel: "4.2 GB")
        case stem.hasPrefix("gemma-3-4b"):
            return ModelInfo(shortName: "Gemma-3 4B", tier: "B", stars: 3,
                virtues: ["Light & fast", "Decent JSON"],
                detail: "Lightweight (2.8 GB) — quick for prompt interpretation, less depth on heavy analysis.",
                contextLabel: "131k", ramLabel: "2.8 GB")
        case stem.hasPrefix("qwen2.5-coder-7b"):
            return ModelInfo(shortName: "Qwen2.5-Coder 7B", tier: "B", stars: 3,
                virtues: ["Code-focused"],
                detail: "Coder-tuned — strong on structure, weaker on prose/thematic nuance.",
                contextLabel: "32k", ramLabel: "4 GB")
        case stem.hasPrefix("qwen3-0.6b"):
            return ModelInfo(shortName: "Qwen3-0.6B", tier: "C", stars: 2,
                virtues: ["Tiny & fast"],
                detail: "Too small for structured JSON/theme analysis — only for trivial prompts.",
                contextLabel: "32k", ramLabel: "<1 GB")
        case stem.hasPrefix("parakeet"):
            return ModelInfo(shortName: "Parakeet", tier: "ASR", stars: 0,
                virtues: ["Speech-to-text"],
                detail: "ASR model — transcribes audio, not a chat LLM. Not usable for this app's tasks.",
                contextLabel: "—", ramLabel: "2.3 GB")
        case stem.hasPrefix("qwen3-asr"):
            return ModelInfo(shortName: "Qwen3-ASR", tier: "ASR", stars: 0,
                virtues: ["Speech-to-text"],
                detail: "ASR model — transcribes audio, not a chat LLM.",
                contextLabel: "—", ramLabel: "1 GB")
        default:
            // Heuristic fallback for any model not yet curated — infer tier
            // from name so a newly-pulled model still gets a meaningful badge.
            return heuristicInfo(for: id, stem: stem)
        }
    }

    static func displayName(for id: String) -> String {
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        // Trim common suffixes for display
        for suffix in ["-instruct-4bit", "-instruct", "-it-qat-4bit", "-it-4bit", "-4bit", "-8bit"] {
            if s.lowercased().hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                break
            }
        }
        return s
    }

    static func starsString(_ n: Int) -> String {
        guard n > 0 else { return "—" }
        return String(repeating: "★", count: n) + String(repeating: "☆", count: 5 - n)
    }

    /// Heuristic rating for models not in the curated table — lets the badge
    /// stay meaningful for any newly-pulled model (rated on param count,
    /// family reputation for this app's workloads, and purpose tag).
    static func heuristicInfo(for id: String, stem: String) -> ModelInfo {
        let name = displayName(for: id)
        let s = stem
        // Detect purpose: coder/ASR are graded down for prose work
        let isCoder = s.contains("coder") || s.contains("code") || s.contains("devstral")
        let isASR = s.contains("asr") || s.contains("parakeet") || s.contains("whisper")
        if isASR {
            return ModelInfo(shortName: name, tier: "ASR", stars: 0,
                virtues: ["Speech-to-text"],
                detail: "ASR model — not a chat LLM for this app.",
                contextLabel: "—", ramLabel: "—")
        }
        // Rough param bucket from name
        let sizeHint: (tier: String, stars: Int, ram: String) = {
            if s.contains("30b") || s.contains("27b") || s.contains("31b") || s.contains("32b") { return ("S", 5, "~15 GB") }
            if s.contains("24b") || s.contains("20b") || s.contains("14b") { return ("A", 4, "~8 GB") }
            if s.contains("8b") || s.contains("7b") { return ("A", 4, "~5 GB") }
            if s.contains("4b") || s.contains("3b") { return ("B", 3, "~3 GB") }
            if s.contains("1b") || s.contains("0.6b") || s.contains("0.5b") { return ("C", 2, "<1 GB") }
            return ("?", 3, "—")
        }()
        let virtues: [String] = isCoder ? ["Code-focused"] : ["Uncatalogued"]
        let detail = isCoder
            ? "Not yet curated — looks code-tuned; may be weaker on prose/thematic analysis."
            : "Not yet curated — inferred from name; open (i) for provider card. Try it on Parse Script to compare."
        return ModelInfo(shortName: name, tier: sizeHint.tier, stars: sizeHint.stars,
            virtues: virtues,
            detail: detail,
            contextLabel: "—", ramLabel: sizeHint.ram)
    }

    static func tierColor(tier: String) -> String {
        switch tier {
        case "S": return "green"
        case "A": return "blue"
        case "B": return "orange"
        case "C": return "secondary"
        case "ASR": return "red"
        default: return "secondary"
        }
    }
}
