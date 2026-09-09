import SwiftUI

// MARK: - Native Help Window ("like a macOS app")

struct HelpSection: Identifiable {
    let id: Int
    let title: String
    let markdown: String
}

struct HelpWindowView: View {
    @State private var sections: [HelpSection] = []
    @State private var selectedID: Int = 0
    @State private var filter = ""

    private var filteredSections: [HelpSection] {
        guard !filter.isEmpty else { return sections }
        return sections.filter {
            $0.title.localizedCaseInsensitiveContains(filter) ||
            $0.markdown.localizedCaseInsensitiveContains(filter)
        }
    }

    private var current: HelpSection? {
        sections.first { $0.id == selectedID } ?? sections.first
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                List(filteredSections, selection: Binding(
                    get: { selectedID },
                    set: { selectedID = $0 ?? 0 })) { s in
                    Text(s.title)
                        .scaledFont(.subheadline)
                        .tag(s.id)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            if let s = current {
                ScrollView {
                    renderedBody(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                .navigationTitle(s.title)
            } else {
                Text("Loading manual…").foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { if sections.isEmpty { sections = Self.loadManual() } }
    }

    private func renderedBody(_ s: HelpSection) -> some View {
        var lines = s.markdown.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        }
        let attr = Self.render(lines.joined(separator: "\n"))
        return Text(attr).textSelection(.enabled)
    }

    // MARK: Parsing

    static func loadManual() -> [HelpSection] {
        let candidates: [(URL?) -> String?] = [
            { try? String(contentsOf: $0!, encoding: .utf8) }
        ]
        var text = ""

        // Deployed layout: MANUAL.md sits next to the .app bundle
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("MANUAL.md")
        if let t = try? String(contentsOf: sibling, encoding: .utf8) { text = t }

        if text.isEmpty, let b = Bundle.main.url(forResource: "MANUAL", withExtension: "md"),
           let t = try? String(contentsOf: b, encoding: .utf8) {
            text = t
        }

        _ = candidates
        guard !text.isEmpty else {
            return [HelpSection(id: 0, title: "Manual Not Found",
                                markdown: "MANUAL.md was not found next to Assistant Editor.app.\n\nExpected at:\n\(sibling.path)")]
        }
        return parse(text)
    }

    static func parse(_ text: String) -> [HelpSection] {
        var out: [HelpSection] = []
        var id = 0

        let parts = text.components(separatedBy: "\n## ")
        let intro = parts[0]
        let introTrimmed = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        if !introTrimmed.isEmpty {
            out.append(HelpSection(id: id, title: "Introduction", markdown: introTrimmed))
            id += 1
        }

        for p in parts.dropFirst() {
            let lines = p.components(separatedBy: "\n")
            let title = lines.first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                .trimmingCharacters(in: .whitespaces) ?? "Untitled"
            let bodyLines = Array(lines.dropFirst())
            out.append(HelpSection(id: id, title: title, markdown: bodyLines.joined(separator: "\n")))
            id += 1
        }
        return out
    }

    /// Inline-markdown rendering with light-weight table flattening,
    /// since AttributedString has no table support.
    static func render(_ markdown: String) -> AttributedString {
        var out: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("|") else {
                out.append(raw)
                continue
            }
            let core = t.dropFirst().hasSuffix("|") ? String(t.dropFirst().dropLast()) : String(t.dropFirst())
            let cells = core.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }  // separator row
            out.append("• **" + cells.first! + "** — " + cells.dropFirst().joined(separator: " · "))
        }
        let joined = out.joined(separator: "\n")
        return (try? AttributedString(
            markdown: joined,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(joined)
    }
}
