import SwiftUI
import AppKit

struct SourceMaterialTab: View {
    @EnvironmentObject var progress: AppProgress

    @AppStorage("sourceMaterialFolders") private var foldersJSON = "[]"
    @AppStorage("projectThemesJSON") private var themesJSON = "[]"
    @AppStorage("lastSourceFolder") private var lastSourceFolder = ""
    @AppStorage("lastAnalysisYamlFolder") private var lastAnalysisYamlFolder = ""

    @State private var analysis: ProjectAnalysis = .empty()
    @State private var isAnalyzing = false
    @State private var analysisProgress: Double = 0
    @State private var analysisMessage = ""
    @State private var weightSaved = false
    @State private var weightSavedTask: Task<Void, Never>?
    @State private var weightSaveWorkItem: DispatchWorkItem?
    @State private var originalWeights: [String: Double] = [:]
    @State private var analysisBaseFolder: String = ""
    @State private var dragSnapshot: [String: Double]?
    @State private var dragEndTask: Task<Void, Never>?
    /// Balance captured the moment a given slider's excursion began. Survives
    /// drag-end so returning to the origin position restores it exactly.
    @State private var preDragBalance: [String: Double]?
    @State private var balanceOriginSlider: String?
    @State private var dragOriginValue: Double?
    @State private var showClearAlert = false
    @State private var materialTrees: [MaterialNode] = []
    @State private var materialsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            ProjectBar(
                folders: folders,
                emptyPrompt: "Choose interview folder…",
                onAdd: { addFolder() },
                onRemove: { p in
                    if let idx = folders.firstIndex(of: p) { removeFolder(at: idx) }
                },
                onRescan: {
                    originalWeights = [:]
                    loadAnalysis()
                },
                onClear: { showClearAlert = true },
                trees: materialTrees,
                materialsExpanded: $materialsExpanded
            ) {
                if !analysis.themes.isEmpty {
                    Text("\(analysis.themes.count) themes")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .confirmationDialog(
                "Remove all folders, themes, and analysis?",
                isPresented: $showClearAlert,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) { clearAll() }
                Button("Cancel", role: .cancel) {}
            }
            .disabled(isAnalyzing)

            if analysis.themes.isEmpty && !isAnalyzing {
                VStack(spacing: 6) {
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "No project analysis yet",
                        message: "Add folders and click **Analyze** to extract themes and keywords from your interviews."
                    )
                    if !folders.isEmpty {
                        Button(action: analyze) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkle")
                                Text("Analyze")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                themesWeighingSection
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadAnalysis() }
    }

    // MARK: - Left Panel

    // MARK: - Weighing Section

    var themesWeighingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Weighing")
                    .scaledFont(.title2)
                if analysis.stats.totalInterviews > 0 {
                    Text(statsSummary)
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Spacer()
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .help(analysisMessage)
                } else if !folders.isEmpty {
                    Button(action: analyze) {
                        Label(analysis.themes.isEmpty ? "Analyze" : "Regenerate Themes",
                              systemImage: "sparkle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Analyze interview folders with the LLM to extract themes and weights")
                }
                Button("Reset Weighing") { resetWeights() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                if weightSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView(value: analysisProgress)
                        .scaleEffect(x: 1, y: 0.5, anchor: .center)
                    Text(analysisMessage)
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Inline speaker line — one scrollable row of mini bars
            if analysis.stats.totalInterviews > 0 && !analysis.stats.speakers.isEmpty {
                speakersLine
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(analysis.themes) { theme in
                        themeRow(theme)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    /// Compact theme entry with percentage and a proportional bar.
    func themeStatRow(_ theme: ProjectTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(themeSwiftColor(theme.color))
                    .frame(width: 8, height: 8)
                Text(theme.name)
                    .scaledFont(.caption)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.0f%%", theme.weight * 100))
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(themeSwiftColor(theme.color).opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(min(max(theme.weight, 0), 1)), height: 5)
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Option A — all totals as one dot-separated caption.
    var statsSummary: String {
        let s = analysis.stats
        let withTrans = analysis.folders.flatMap(\.interviews).filter(\.hasTranscript).count
        var parts = ["\(s.totalInterviews) interviews",
                     formatDuration(s.totalDurationS),
                     "\(s.totalCues) cues",
                     "\(s.speakers.count) speakers"]
        if withTrans > 0 {
            parts.append("\(withTrans)/\(s.totalInterviews) transcripts")
        }
        return parts.joined(separator: " · ")
    }

    /// One scrollable line of mini speaker bars — names at body scale.
    var speakersLine: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(analysis.stats.speakers.prefix(8), id: \.name) { sp in
                    HStack(spacing: 5) {
                        Text(sp.name)
                            .scaledFont(.subheadline)
                            .lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(themeAccent)
                                .frame(width: geo.size.width * barFraction(sp.cueCount), height: 6)
                        }
                        .frame(width: 64, height: 6)
                        Text("\(sp.cueCount)")
                            .scaledFont(.caption, monospacedDigit: true)
                            .foregroundColor(.secondary)
                    }
                }
                if analysis.stats.speakers.count > 8 {
                    Text("+\(analysis.stats.speakers.count - 8)")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var themeAccent: Color { Color.accentColor.opacity(0.7) }

    func barFraction(_ cues: Int) -> CGFloat {
        let maxCues = analysis.stats.speakers.map(\.cueCount).max() ?? 1
        guard maxCues > 0 else { return 0 }
        return CGFloat(Double(cues) / Double(maxCues))
    }

    func themeRow(_ theme: ProjectTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(themeSwiftColor(theme.color))
                    .frame(width: 10, height: 10)
                Text(theme.name)
                    .scaledFont(.subheadline)
                    .bold()
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(themeSwiftColor(theme.color).opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(min(max(theme.weight, 0), 1)), height: 5)
                }
                .frame(height: 5)
                Text(String(format: "%.0f%%", theme.weight * 100))
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Weight slider
            HStack {
                Text("0%")
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                Slider(value: binding(for: theme.id, keyPath: \.weight), in: 0...1, step: 0.05)
                Text("100%")
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 16)

            // Keywords
            let kwText = theme.keywords.joined(separator: ", ")
            Text(kwText)
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        .contextMenu {
            Button("Remove Theme") { removeTheme(theme) }
        }
    }

    // MARK: - Helpers

    func statChip(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .scaledFont(.caption, monospacedDigit: true)
                .fontWeight(.semibold)
            if !label.isEmpty {
                Text(label)
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(5)
    }

    func themeSwiftColor(_ name: String) -> Color {
        switch name {
        case "Blue": return .blue
        case "Orange": return .orange
        case "Cyan": return .cyan
        case "Mint": return .mint
        case "Green": return .green
        case "Rose": return .pink
        case "Lemon": return .yellow
        case "Tan": return .brown
        case "Sky": return .teal
        case "Purple": return .purple
        default: return .gray
        }
    }

    func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }

    // MARK: - Persistence

    var folders: [String] {
        (try? JSONDecoder().decode([String].self, from: foldersJSON.data(using: .utf8) ?? Data())) ?? []
    }

    func saveFolders(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list),
           let json = String(data: data, encoding: .utf8) {
            foldersJSON = json
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more folders with interviews"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var list = folders
        var added: [String] = []
        for url in panel.urls where !list.contains(url.path) {
            list.append(url.path)
            added.append(url.path)
        }
        guard !added.isEmpty else { return }
        saveFolders(list)
        lastSourceFolder = list.last ?? ""
        for path in added {
            loadAnalysisNewFolder(path)
        }
        refreshMaterialTrees()
    }

    func loadAnalysisNewFolder(_ newPath: String) {
        guard let loaded = ProjectAnalysis.load(from: newPath) else {
            captureOriginalWeights()
            return
        }
        var l = loaded
        l.refreshMaterialFlags()
        if analysis.themes.isEmpty {
            analysis = loaded
            originalWeights = [:]
            captureOriginalWeights()
        } else {
            // Merge themes: sum weights for matching names, add new ones
            var merged = analysis
            for newTheme in loaded.themes {
                if let existingIdx = merged.themes.firstIndex(where: { $0.name == newTheme.name }) {
                    merged.themes[existingIdx].weight += newTheme.weight
                    merged.themes[existingIdx].keywords.append(contentsOf: newTheme.keywords)
                } else {
                    merged.themes.append(newTheme)
                }
            }
            // Deduplicate keywords
            for i in merged.themes.indices {
                merged.themes[i].keywords = Array(Set(merged.themes[i].keywords))
            }
            analysis = merged
            originalWeights = [:]
            preDragBalance = nil
            balanceOriginSlider = nil
            captureOriginalWeights()
            saveAnalysis()
            lastAnalysisYamlFolder = folders.first ?? lastAnalysisYamlFolder
        }
    }
    func loadAnalysis() {
        // A debounced slider-save captured before this reload must never fire
        // afterwards and clobber the freshly read file with stale weights.
        weightSaveWorkItem?.cancel()
        weightSaveWorkItem = nil
        preDragBalance = nil
        balanceOriginSlider = nil
        refreshMaterialTrees()
        for folder in folders {
            if let base = ProjectAnalysis.nearestProjectYamlFolder(for: folder),
               var loaded = ProjectAnalysis.load(from: base) {
                loaded.refreshMaterialFlags()
                analysis = loaded
                analysisBaseFolder = base
                captureOriginalWeights()
                return
            }
        }
        // Remembered location (e.g. folder chip removed later but yaml still on disk)
        if let base = ProjectAnalysis.nearestProjectYamlFolder(for: lastAnalysisYamlFolder),
           var loaded = ProjectAnalysis.load(from: base), !loaded.themes.isEmpty {
            loaded.refreshMaterialFlags()
            analysis = loaded
            analysisBaseFolder = base
            captureOriginalWeights()
            return
        }
        if let data = themesJSON.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ProjectTheme].self, from: data), !themes.isEmpty {
            var empty = ProjectAnalysis.empty()
            empty.themes = themes
            analysis = empty
        }
        captureOriginalWeights()
    }

    func captureOriginalWeights() {
        guard originalWeights.isEmpty else { return }
        for theme in analysis.themes {
            originalWeights[theme.id] = theme.weight
        }
    }

    func resetWeights() {
        preDragBalance = nil
        balanceOriginSlider = nil

        // Prefer the persisted post-analyze baseline — it survives restarts,
        // even when clipped weights were already saved to _project.yaml.
        var restored = false
        if !analysisBaseFolder.isEmpty,
           let baseline = ProjectAnalysis.loadOriginalWeights(from: analysisBaseFolder) {
            for i in analysis.themes.indices {
                let name = analysis.themes[i].name
                if let orig = baseline[name] ?? originalWeights[analysis.themes[i].id] {
                    analysis.themes[i].weight = orig
                    restored = true
                }
            }
        }

        if !restored {
            for i in analysis.themes.indices {
                let id = analysis.themes[i].id
                if let orig = originalWeights[id] {
                    analysis.themes[i].weight = orig
                }
            }
        }

        saveAnalysis()
        captureOriginalWeights()
        showWeightSaved()
    }

    func removeFolder(at index: Int) {
        var list = folders
        guard index < list.count else { return }
        list.remove(at: index)
        saveFolders(list)
        if list.isEmpty {
            analysis = .empty()
            themesJSON = "[]"
            materialTrees = []
        } else {
            loadAnalysis()
        }
    }

    func clearAll() {
        saveFolders([])
        themesJSON = "[]"
        analysis = .empty()
        originalWeights = [:]
        dragSnapshot = nil
        materialTrees = []
        // Media stores are per-tab now — nothing to reset here
    }

    func removeTheme(_ theme: ProjectTheme) {
        analysis.themes.removeAll { $0.id == theme.id }
        saveAnalysis()
    }

    func binding(for themeId: String, keyPath: WritableKeyPath<ProjectTheme, Double>) -> Binding<Double> {
        Binding(
            get: { analysis.themes.first(where: { $0.id == themeId })?[keyPath: keyPath] ?? 0.5 },
            set: { newValue in
                guard let idx = analysis.themes.firstIndex(where: { $0.id == themeId }) else { return }

                let clamped = max(0, min(1, newValue))

                // Fresh gesture?
                if dragSnapshot == nil {
                    let current = Dictionary(uniqueKeysWithValues: analysis.themes.map { ($0.id, $0[keyPath: keyPath]) })
                    if balanceOriginSlider != themeId {
                        // Different slider than the memorized excursion:
                        // adopt current state as the new balance baseline.
                        preDragBalance = current
                        balanceOriginSlider = themeId
                        dragOriginValue = analysis.themes[idx][keyPath: keyPath]
                    }
                    // Same slider re-grabbed mid-excursion: KEEP preDragBalance,
                    // dragOriginValue — that is the whole point of the memory.
                    dragSnapshot = current
                }
                dragEndTask?.cancel()
                dragEndTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { dragSnapshot = nil }
                }

                let others = analysis.themes.indices.filter { $0 != idx }

                // Returned to where this slider started → put everything back exactly.
                let origin = dragOriginValue ?? clamped
                if let bal = preDragBalance, abs(clamped - origin) < 0.003 {
                    for i in analysis.themes.indices {
                        if let w = bal[analysis.themes[i].id] {
                            analysis.themes[i][keyPath: keyPath] = w
                        }
                    }
                } else {
                    var snapSum: Double = 0
                    for i in others {
                        snapSum += dragSnapshot?[analysis.themes[i].id] ?? analysis.themes[i][keyPath: keyPath]
                    }

                    if snapSum > 1e-9 {
                        let remaining = 1 - clamped
                        for i in others {
                            let snapWeight = dragSnapshot?[analysis.themes[i].id] ?? analysis.themes[i][keyPath: keyPath]
                            analysis.themes[i][keyPath: keyPath] = snapWeight / snapSum * remaining
                        }
                    } else {
                        // Everything else was crushed to zero — scale the memorized
                        // balance instead of flattening to an even split.
                        let balSum = others.reduce(0.0) {
                            $0 + (preDragBalance?[analysis.themes[$1].id] ?? 0)
                        }
                        let remaining = 1 - clamped
                        if balSum > 1e-9 {
                            for i in others {
                                let w = preDragBalance?[analysis.themes[i].id] ?? 0
                                analysis.themes[i][keyPath: keyPath] = w / balSum * remaining
                            }
                        } else {
                            let even = others.isEmpty ? 0.0 : remaining / Double(others.count)
                            for i in others {
                                analysis.themes[i][keyPath: keyPath] = even
                            }
                        }
                    }
                }

                analysis.themes[idx][keyPath: keyPath] = clamped
                scheduleSave()
                showWeightSaved()
            }
        )
    }

    /// Coalesces per-tick writes from dragging a weight slider into one
    /// `_project.yaml` write 400ms after movement stops. Captures the latest
    /// theme snapshot at schedule time — the last scheduled write wins.
    func scheduleSave() {
        let snapshot = analysis
        let target = folders.first
        weightSaveWorkItem?.cancel()
        let wi = DispatchWorkItem {
            guard let target else { return }
            snapshot.save(to: target)
            if let data = try? JSONEncoder().encode(snapshot.themes),
               let json = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: "projectThemesJSON")
            }
        }
        weightSaveWorkItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: wi)
    }

    func showWeightSaved() {
        weightSavedTask?.cancel()
        withAnimation { weightSaved = true }
        weightSavedTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { weightSaved = false }
        }
    }

    func saveAnalysis() {
        guard let first = folders.first else { return }
        analysis.save(to: first)
        if let data = try? JSONEncoder().encode(analysis.themes),
           let json = String(data: data, encoding: .utf8) {
            themesJSON = json
        }
    }

    // MARK: - Analysis

    func analyze() {
        guard !folders.isEmpty else { return }
        isAnalyzing = true
        analysisProgress = 0
        analysisMessage = "Starting analysis…"

        let folderList = folders

        DispatchQueue.global().async {
            do {
                let input = ["folders": folderList]
                let inputData = try JSONSerialization.data(withJSONObject: input)

                var args: [String] = [folderList.first!]
                let selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? OMLXClient.defaultModel
                args += ["--model", selectedModel]

                let prefs = UserDefaults.standard
                let priming = PrimingRegistry.stage(for: "priming_projectAnalysis")?.load() ?? ""
                if !priming.isEmpty {
                    let tmpPath = "/tmp/assistanteditor_priming.txt"
                    try? priming.write(toFile: tmpPath, atomically: true, encoding: .utf8)
                    args += ["--priming-prompt-file", tmpPath]
                }

                let output = try PythonBridge.runRawProgress(
                    "analyze_project",
                    args: args,
                    stdin: inputData,
                    timeoutSeconds: 300
                ) { msg in
                    DispatchQueue.main.async {
                        analysisMessage = msg
                    }
                }

                let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                guard let lastLine = lines.last,
                      let data = lastLine.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let foldersData = result["folders"] as? [[String: Any]],
                      let themesData = result["themes"] as? [[String: Any]] else {
                    let snippet = String(lines.last?.prefix(200) ?? "empty")
                    DispatchQueue.main.async {
                        isAnalyzing = false
                        analysisMessage = "Parse failed. Last line: \(snippet)"
                    }
                    return
                }

                let jsonData = try JSONSerialization.data(withJSONObject: result)
                let decoder = JSONDecoder()
                let decoded: ProjectAnalysis
                do {
                    decoded = try decoder.decode(ProjectAnalysis.self, from: jsonData)
                } catch {
                    DispatchQueue.main.async {
                        isAnalyzing = false
                        analysisMessage = "Decode error: \(error.localizedDescription)"
                    }
                    return
                }

                DispatchQueue.main.async {
                    analysis = decoded
                    analysis.save(to: folderList.first!)
                    decoded.saveOriginalWeights(to: folderList.first!)
                    lastAnalysisYamlFolder = folderList.first!
                    DispatchQueue.main.async { analysisBaseFolder = folderList.first! }
                    if let data = try? JSONEncoder().encode(decoded.themes),
                       let json = String(data: data, encoding: .utf8) {
                        themesJSON = json
                    }
                    originalWeights = [:]
                    captureOriginalWeights()
                    isAnalyzing = false
                    analysisMessage = ""
                }

            } catch {
                DispatchQueue.main.async {
                    isAnalyzing = false
                    analysisMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Material tree

    func refreshMaterialTrees() {
        materialTrees = MaterialTree.scan(folders)
    }
}

// MARK: - (resize handle removed — using plain Divider)
