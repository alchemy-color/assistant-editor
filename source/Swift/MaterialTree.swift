import SwiftUI

/// One node in a per-tab material tree, built from a folder (or subfolder).
struct MaterialNode: Identifiable {
    let id: String
    let name: String
    let path: String
    var children: [MaterialNode] = []
    var isMaterial = false
    var subtitleCount = 0
    var transcriptCount = 0
    var hasChapters = false
    var hasSynopsis = false
    var timelineCount = 0
    var hasProjectFile = false
}

/// Walks a folder (depth-limited) building a tree of subfolders that directly
/// hold material files, flagging which folders carry a valid project file.
/// Pure filesystem read — safe to call on any thread. Each tab builds its own
/// tree from its own folders (no shared store).
enum MaterialTree {
    static func scan(root: String, depth: Int = 0) -> MaterialNode {
        let fm = FileManager.default
        var node = MaterialNode(id: root, name: (root as NSString).lastPathComponent, path: root)
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return node }

        var subs = 0, trans = 0, hasCh = false, hasSyn = false, timelines = 0
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if depth < 3 {
                    let child = scan(root: item.path, depth: depth + 1)
                    if child.isMaterial || !child.children.isEmpty {
                        node.children.append(child)
                    }
                }
            } else {
                let fn = item.lastPathComponent
                if fn.hasSuffix(".srtx") || fn.hasSuffix(".srt") || fn.hasSuffix(".txt") {
                    if fn.hasSuffix("_transcript.txt") || fn.hasSuffix("_transcripts.txt") {
                        trans += 1
                    } else {
                        subs += 1
                    }
                } else if fn.hasSuffix("_timeline.yaml") {
                    timelines += 1
                } else if fn.hasSuffix("_chapters.yaml") {
                    hasCh = true
                } else if fn.hasSuffix("_synopsis.txt") {
                    hasSyn = true
                }
            }
        }
        node.subtitleCount = subs
        node.transcriptCount = trans
        node.hasChapters = hasCh
        node.hasSynopsis = hasSyn
        node.timelineCount = timelines
        node.isMaterial = subs > 0 || trans > 0 || hasCh || hasSyn || timelines > 0
        node.hasProjectFile = ProjectAnalysis.findProjectYaml(in: root) != nil
        return node
    }

    static func scan(_ roots: [String]) -> [MaterialNode] {
        roots.map { scan(root: $0) }
    }

    /// Compact total counts for the inline Materials zone, e.g.
    /// "3 folders · 452 subs · 12 transcripts · 2 timelines". Labeled so the
    /// two bare numbers (subtitle/transcript counts) are self-explanatory.
    static func summary(_ nodes: [MaterialNode]) -> String {
        var subs = 0, trans = 0, mats = 0, tls = 0
        func walk(_ ns: [MaterialNode]) {
            for n in ns {
                subs += n.subtitleCount
                trans += n.transcriptCount
                tls += n.timelineCount
                if n.isMaterial { mats += 1 }
                walk(n.children)
            }
        }
        walk(nodes)
        var parts = ["\(mats) folder\(mats == 1 ? "" : "s")"]
        if subs > 0 { parts.append("\(subs) sub\(subs == 1 ? "" : "s")") }
        if trans > 0 { parts.append("\(trans) transcript\(trans == 1 ? "" : "s")") }
        if tls > 0 { parts.append("\(tls) timeline\(tls == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Number of non-root entries across the whole tree (drives the expander).
    static func subfolderCount(_ nodes: [MaterialNode]) -> Int {
        var count = 0
        func walk(_ ns: [MaterialNode]) {
            for n in ns {
                count += n.children.count
                walk(n.children)
            }
        }
        walk(nodes)
        return count
    }
}

struct MaterialBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .scaledFont(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(4)
    }
}

/// Full subfolder material tree, shown as the ProjectBar's expanded second row.
/// Roots first, then recursive children; every row carries the green/red
/// project-file health dot plus sub/tr/ch/syn/tl badges. Pure display —
/// the caller supplies its own `trees` data.
struct ProjectBarMaterials: View {
    let trees: [MaterialNode]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(trees) { node in
                    row(node, depth: 0)
                }
            }
            .padding(2)
        }
        .frame(maxHeight: 150, alignment: .top)
    }

    private func row(_ node: MaterialNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "film")
                    .scaledFont(.caption2)
                    .foregroundColor(node.hasProjectFile ? .green : .red)
                    .help(node.hasProjectFile
                        ? "Project file detected in \(node.name)"
                        : "No project file detected in \(node.name)")
                Text(node.name)
                    .scaledFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isMaterial {
                    HStack(spacing: 4) {
                        if node.subtitleCount > 0 {
                            MaterialBadge(text: "\(node.subtitleCount) sub\(node.subtitleCount == 1 ? "" : "s")")
                        }
                        if node.transcriptCount > 0 {
                            MaterialBadge(text: "\(node.transcriptCount) transcript\(node.transcriptCount == 1 ? "" : "s")")
                        }
                        if node.hasChapters {
                            MaterialBadge(text: "ch")
                        }
                        if node.hasSynopsis {
                            MaterialBadge(text: "syn")
                        }
                        if node.timelineCount > 0 {
                            MaterialBadge(text: "\(node.timelineCount) tl")
                        }
                    }
                }
                if !node.hasProjectFile {
                    MaterialBadge(text: "no project")
                        .foregroundColor(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth * 14))
            .padding(.vertical, 1)
            ForEach(node.children) { child in
                row(child, depth: depth + 1)
            }
        })
    }
}
