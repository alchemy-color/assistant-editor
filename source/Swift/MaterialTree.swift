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

        var subs = 0, trans = 0, hasCh = false, hasSyn = false
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
        node.isMaterial = subs > 0 || trans > 0 || hasCh || hasSyn
        node.hasProjectFile = ProjectAnalysis.findProjectYaml(in: root) != nil
        return node
    }

    static func scan(_ roots: [String]) -> [MaterialNode] {
        roots.map { scan(root: $0) }
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

/// Collapsible tree showing every material-bearing subfolder and whether each
/// carries a valid project file (green film icon = present, red = missing).
/// Pure display: the caller supplies its own `materialTrees` data.
struct MaterialTreeView: View {
    let trees: [MaterialNode]
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if trees.isEmpty {
                Text("No folders detected yet.")
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(trees) { node in
                            row(node, depth: 0)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 260)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.tree")
                    .scaledFont(.caption2)
                Text("Materials")
                    .scaledFont(.headline)
                Spacer()
                Text(summary(trees))
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                    .scaledFont(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isMaterial {
                    HStack(spacing: 4) {
                        if node.subtitleCount > 0 {
                            MaterialBadge(text: "\(node.subtitleCount) sub")
                        }
                        if node.transcriptCount > 0 {
                            MaterialBadge(text: "\(node.transcriptCount) tr")
                        }
                        if node.hasChapters {
                            MaterialBadge(text: "ch")
                        }
                        if node.hasSynopsis {
                            MaterialBadge(text: "syn")
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

    private func summary(_ nodes: [MaterialNode]) -> String {
        var subs = 0, trans = 0, mats = 0
        func walk(_ ns: [MaterialNode]) {
            for n in ns {
                subs += n.subtitleCount
                trans += n.transcriptCount
                if n.isMaterial { mats += 1 }
                walk(n.children)
            }
        }
        walk(nodes)
        var parts = ["\(mats) materials"]
        if subs + trans > 0 { parts.append("\(subs) sub · \(trans) tr") }
        return parts.joined(separator: " · ")
    }
}
