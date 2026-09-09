import SwiftUI

/// Popover shown via the (i) next to the model picker. Combines the curated
/// local rating (ModelCatalog) with a live fetch from the model provider
/// (Hugging Face API) so any newly-pulled model gets a real description.
struct ModelDetailPopover: View {
    var modelID: String
    var onClose: (() -> Void)? = nil

    @State private var hfCard: HFCARD?
    @State private var hfError: String?
    @State private var isLoading = true

    struct HFCARD {
        var repo: String
        var pipeline: String?
        var likes: Int?
        var downloads: Int?
        var cardExcerpt: String?
        var hfURL: String
    }

    var catalogInfo: ModelInfo { ModelCatalog.info(for: modelID) }

    /// Repo to query on HF — oMLX ids are short (Llama-3.1-8B-…) so we try
    /// mlx-community/<id> first, then the raw id as a fallback.
    private var hfCandidates: [String] {
        let raw = modelID.trimmingCharacters(in: .whitespaces)
        if raw.contains("/") { return [raw] }
        return ["mlx-community/\(raw)", raw]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — curated rating
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(catalogInfo.shortName)
                            .scaledFont(.headline)
                        Text(catalogInfo.tier)
                            .scaledFont(.caption2).bold()
                            .foregroundColor(tierColor(catalogInfo.tier))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tierColor(catalogInfo.tier).opacity(0.12))
                            .clipShape(Capsule())
                        Text(ModelCatalog.starsString(catalogInfo.stars))
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(catalogInfo.detail)
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label(catalogInfo.contextLabel, systemImage: "text.alignleft")
                        Label(catalogInfo.ramLabel, systemImage: "memorychip")
                        if !catalogInfo.virtues.isEmpty {
                            Text(catalogInfo.virtues.joined(separator: " · "))
                                .foregroundColor(.secondary)
                        }
                    }
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                }
                Spacer()
                if let handler = onClose {
                    Button(action: { handler() }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Provider (Hugging Face) live section
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Provider")
                        .scaledFont(.caption).bold()
                    if isLoading { ProgressView().controlSize(.mini) }
                    Spacer()
                    if let card = hfCard {
                        Link("Open on HF →", destination: URL(string: card.hfURL)!)
                            .scaledFont(.caption2)
                    }
                }

                if let card = hfCard {
                    if let excerpt = card.cardExcerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .scaledFont(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let pipe = card.pipeline {
                        Text("Pipeline: \(pipe)")
                            .scaledFont(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let l = card.likes { Label("\(l)", systemImage: "heart") }
                        if let d = card.downloads { Label("\(d)", systemImage: "arrow.down.circle") }
                        Text(card.repo).foregroundColor(.secondary)
                    }
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                } else if isLoading {
                    Text("Fetching model card from Hugging Face…")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                } else if let err = hfError {
                    Text(err)
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Text("Curated rating above still applies for this app's workloads (JSON/schema, multilingual, analysis).")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // How the rating is derived
            Text("Rating: curated for this app — JSON/schema reliability, reasoning & multilingual (Dutch/Belgian), ctx/RAM fit. Generic aliases fall back to inference from the name; (i) fetches the live HF card.")
                .scaledFont(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear(perform: fetchHF)
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier {
        case "S": return .green
        case "A": return .blue
        case "B": return .orange
        case "C": return .gray
        case "ASR": return .red
        default: return .secondary
        }
    }

    private func fetchHF() {
        isLoading = true
        hfError = nil
        tryNextCandidate(index: 0)
    }

    private func tryNextCandidate(index: Int) {
        guard index < hfCandidates.count else {
            isLoading = false
            hfError = "No provider card found for “\(modelID)” on Hugging Face."
            return
        }
        let repo = hfCandidates[index]
        let urlStr = "https://huggingface.co/api/models/\(repo)"
        guard let url = URL(string: urlStr) else {
            tryNextCandidate(index: index + 1); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { tryNextCandidate(index: index + 1) }
                return
            }
            let card = parseHF(json: json, repo: repo)
            DispatchQueue.main.async {
                hfCard = card
                isLoading = false
            }
        }.resume()
    }

    private func parseHF(json: [String: Any], repo: String) -> HFCARD {
        let pipeline = json["pipeline_tag"] as? String
        let likes = json["likes"] as? Int
        let downloads = json["downloads"] as? Int
        var excerpt: String?
        if let cardData = json["cardData"] as? [String: Any] {
            // cardData may contain description-ish fields; fall back to raw card snippet
            if let ds = cardData["description"] as? String { excerpt = ds }
        }
        if excerpt == nil, let card = json["card"] as? String, !card.isEmpty {
            // card is markdown — take first paragraph
            let lines = card.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let paras = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") }
            excerpt = paras.prefix(3).joined(separator: " ")
            if let e = excerpt, e.count > 500 { excerpt = String(e.prefix(500)) + "…" }
        }
        if excerpt == nil, let desc = json["description"] as? String, !desc.isEmpty {
            excerpt = String(desc.prefix(500))
        }
        return HFCARD(
            repo: repo,
            pipeline: pipeline,
            likes: likes,
            downloads: downloads,
            cardExcerpt: excerpt,
            hfURL: "https://huggingface.co/\(repo)"
        )
    }
}
