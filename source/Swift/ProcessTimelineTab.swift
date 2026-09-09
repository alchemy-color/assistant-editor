import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum DisplayRow: Identifiable {
    case match(SubSearchHit)
    case context(SubtitleEntry, _ hitIdx: Int)
    case divider

    var id: String {
        switch self {
        case .match(let hit): return hit.id
        case .context(_, let hitIdx): return "ctx-\(hitIdx)-" + entry.id
        case .divider: return "div"          // stable id — fresh UUIDs each render churn List identity
        }
    }

    var entry: SubtitleEntry {
        switch self {
        case .match(let hit): return hit.entry
        case .context(let entry, _): return entry
        case .divider: return SubtitleEntry(sourceFile: "", interview: "", folder: "", location: "", start_s: 0, end_s: 0, speaker: "", text: "")
        }
    }

    var isContext: Bool {
        if case .context = self { return true }
        return false
    }

    var isDivider: Bool {
        if case .divider = self { return true }
        return false
    }
}

struct ProcessTimelineTab: View {
    @ObservedObject var subStore: SubtitleStore
    @ObservedObject var docStore: DocumentStore
    @EnvironmentObject var progress: AppProgress

    init(subStore: SubtitleStore, docStore: DocumentStore) {
        self.subStore = subStore
        self.docStore = docStore
    }

    // ——— Processing state ———
    @AppStorage("lastSrtFolder") private var lastSrtFolder = ""
    @AppStorage("timelineAssistFolders") private var ownFoldersJSON = "[]"
    @State private var srtFolder: String?
    @State private var showClearAlert = false
    @State private var srtFiles: [String] = []
    @State private var processedResults: [(srt: String, yaml: String, synopsis: String)] = []
    @State private var isProcessing = false
    @State private var processingProgress: Double = 0
    @State private var processingProgressMessage = ""
    @State private var processStatus = ""
    @State private var materialTrees: [MaterialNode] = []
    @State private var materialsExpanded = false
    @State private var chaptersVerbosity: Double = 0.5
    @State private var synopsisVerbosity: Double = 0.5
    @State private var showOverwriteAlert = false
    @State private var overwriteFileList: [String] = []
    @State private var processedMarkers: [SummaryMarker] = []
    @State private var isWritingResolve = false
    @State private var showUndoButton = false
    @State private var backupURL: URL?
    @State private var showUndoAlert = false
    @State private var showYouTubeSheet = false
    @State private var showSummarySheet = false
    @State private var summaryText = ""
    @State private var isGeneratingSummary = false
    @State private var summaryCache: [String: String] = [:]
    @State private var summaryTimes: [String: Double] = [:]
    @State private var summaryCacheDoc = ""
    @State private var generationStart: Date?
    @State private var showCopiedFlash = false
    @AppStorage("youtubeTextSize") private var youtubeTextSize: Double = 13
    @AppStorage("summaryLength") private var summaryLength: String = SummaryLength.medium.rawValue
    @AppStorage("summaryCacheJSON") private var summaryCacheJSON = ""
    @State private var generateChapters = true
    @State private var generateSynopsis = true
    @State private var synopsisIntro = true
    @State private var synopsisParagraphs = true
    @State private var synopsisBullets = true
    @State private var synopsisTimecode = true
    @State private var selectedDoc: SummaryDocument?

    // ——— Subtitle timeline state ———
    @State private var query = ""
    @State private var selectedProcessingFiles: Set<String> = []
    @State private var filterSourceFiles: Set<String> = []
    @State private var filterSpeakers: Set<String> = []
    @State private var searchResults: [SubSearchHit] = []
    @State private var selectedEntryIDs = Set<String>()
    @State private var queryDirty = false
    @State private var isCreating = false
    @AppStorage("subContextSlots") private var contextSlots: Double = 3
    @AppStorage("subGroupGap") private var groupGap: Double = 5.0
    @AppStorage("timelineFPS") private var timelineFPS: Double = 25.0
    @AppStorage("timelineSearchSource") private var searchSource: SearchSource = .subtitles
    @AppStorage("timelineAddSubtitles") private var addSubtitles: Bool = false
    @State private var sortOrder: SortOrder = .chronological
    @State private var cachedByFile: [String: [SubtitleEntry]] = [:]
    @State private var reasoningMessages: [(role: String, content: String)] = []
    @State private var smartOrder: [Int]? = nil
    @State private var isInterpreting = false
    @State private var lastSearchTerms = ""
    @AppStorage("speakerListHeight") private var speakerListHeight: Double = 80
    @AppStorage("tlRefineCollapsed") private var refineCollapsed = false
    @AppStorage("speakerListCollapsed") private var speakerListCollapsed = false
    @AppStorage("tlPanelLeftWidth") private var panelLeftWidth: Double = 420
    @State private var panelLeftSnapshot: Double = 420
    @AppStorage("projectThemesJSON") private var projectThemesJSON = "[]"
    @State private var yamlStatus: [String: Bool] = [:]
    @State private var synopsisStatus: [String: Bool] = [:]
    @State private var lastProcessedWeights: [String: Double] = [:]
    @State private var weighingChanged = false
    @State private var lastChaptersVerbosity: Double = 0.5
    @State private var lastSynopsisVerbosity: Double = 0.5
    @State private var chaptersVerbosityChanged = false
    @State private var synopsisVerbosityChanged = false
    @State private var chapterDensity: Double = 0.5
    @State private var lastChapterDensity: Double = 0.5
    @State private var chapterDensityChanged = false

    enum SortOrder: String, CaseIterable {
        case relevance = "Relevance"
        case chronological = "Chronological"
        case speaker = "Speaker"
        case location = "Location"
        case prompt = "Prompt"
    }

    enum SearchSource: String, CaseIterable {
        case subtitles = "Subtitles"
        case transcripts = "Transcripts"
    }

    enum SummaryLength: String, CaseIterable {
        case short = "Short"
        case medium = "Medium"
        case long = "Long"

        var lengthInstruction: String {
            switch self {
            case .short:
                return "Write a very short summary of 2-3 sentences (~40-60 words)."
            case .medium:
                return "Write a medium-length summary of about 100-150 words (2 short paragraphs)."
            case .long:
                return "Write a detailed summary of about 250-350 words (3 paragraphs)."
            }
        }
    }

    var entriesByFile: [String: [SubtitleEntry]] {
        if searchSource == .transcripts, subStore.isTranscriptsLoaded {
            return Dictionary(grouping: subStore.transcriptEntries) { $0.sourceFile }
        }
        return cachedByFile
    }

    var resolvedIDs: Set<String> {
        let slots = Int(contextSlots)
        guard slots > 0 else { return selectedEntryIDs }
        let byFile = entriesByFile
        let matchIDs = Set(searchResults.map(\.id))
        var ids = selectedEntryIDs
        for (hitIdx, hit) in searchResults.enumerated() where ids.contains(hit.id) {
            guard var fileEntries = byFile[hit.entry.sourceFile] else { continue }
            fileEntries.sort { $0.start_s < $1.start_s }
            guard let idx = fileEntries.firstIndex(where: { $0.id == hit.entry.id }) else { continue }
            let start = max(0, idx - slots)
            let end = min(fileEntries.count, idx + slots + 1)
            for i in start..<end where i != idx {
                let e = fileEntries[i]
                guard !matchIDs.contains(e.id) else { continue }
                ids.insert("ctx-\(hitIdx)-" + e.id)
            }
        }
        return ids
    }

    var displayRows: [DisplayRow] {
        let slots = Int(contextSlots)
        let byFile = entriesByFile
        let matchIDs = Set(searchResults.map(\.id))
        var rows: [DisplayRow] = []
        for (hitIdx, hit) in searchResults.enumerated() {
            if hitIdx > 0 { rows.append(.divider) }
            let hasContext = slots > 0 && selectedEntryIDs.contains(hit.id)
            let (beforeCtx, afterCtx): ([SubtitleEntry], [SubtitleEntry]) = {
                guard hasContext,
                      var fe = byFile[hit.entry.sourceFile],
                      let idx = { fe.sort { $0.start_s < $1.start_s }; return fe.firstIndex(where: { $0.id == hit.entry.id }) }()
                else { return ([], []) }
                let start = max(0, idx - slots)
                let end = min(fe.count, idx + slots + 1)
                let ctx = (start..<end).compactMap { i -> SubtitleEntry? in
                    i != idx && !matchIDs.contains(fe[i].id) ? fe[i] : nil
                }
                let before = ctx.filter { $0.start_s < hit.entry.start_s }
                let after = ctx.filter { $0.start_s > hit.entry.start_s }
                return (before, after)
            }()
            for e in beforeCtx { rows.append(.context(e, hitIdx)) }
            rows.append(.match(hit))
            for e in afterCtx { rows.append(.context(e, hitIdx)) }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            folderBar

            Divider()

            fileSection

            HStack(spacing: 0) {
                leftPanel
                    .frame(width: panelLeftWidth)
                    .frame(maxHeight: .infinity)

                DragDivider(
                    onStart: { panelLeftSnapshot = panelLeftWidth },
                    onChanged: { t in
                        panelLeftWidth = min(760, max(240, panelLeftSnapshot + Double(t)))
                    }
                )

                rightPanel
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadOwnFolders() }
        .onChange(of: ownFoldersJSON) { _ in loadOwnFolders() }
        .onChange(of: projectThemesJSON) { _ in checkWeighingChanged() }
    }

    var ownFolders: [String] {
        (try? JSONDecoder().decode([String].self, from: ownFoldersJSON.data(using: .utf8) ?? Data())) ?? []
    }

    func clearWorkFolders() {
        saveOwnFolders([])
        srtFiles = []
        selectedProcessingFiles = []
        processStatus = ""
    }

    func saveOwnFolders(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list),
           let json = String(data: data, encoding: .utf8) {
            ownFoldersJSON = json
        }
    }

    /// Multiple work folders → chapters are per-timeline and unavailable; only
    /// synopses can be generated across a whole project.
    var isMultiFolder: Bool {
        ownFolders.count > 1
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more work folders with subtitles/transcripts"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var list = ownFolders
        for url in panel.urls where !list.contains(url.path) {
            list.append(url.path)
        }
        saveOwnFolders(list)
    }

    func removeFolder(at index: Int) {
        var list = ownFolders
        guard index < list.count else { return }
        list.remove(at: index)
        saveOwnFolders(list)
    }

    /// ↻ — full reload: rescan files and rebuild subtitle/transcript caches.
    func forceReloadOwnFolders() {
        loadOwnFolders(forceRebuild: true)
        refreshYAMLStatus()
    }

    func loadOwnFolders(forceRebuild: Bool = false) {
        let folders = ownFolders
        materialTrees = MaterialTree.scan(folders)
        guard !folders.isEmpty else {
            srtFiles = []
            selectedProcessingFiles = []
            processStatus = ""
            srtFolder = ""
            subStore.clearAll()
            docStore.reloadFolders([])
            return
        }
        srtFolder = folders[0]

        // Scan all files across all folders
        var allFiles: [String] = []
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder),
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name.hasSuffix(".srt") || name.hasSuffix(".srtx") || name.hasSuffix(".txt") else { continue }
                if name.hasSuffix("_synopsis.txt") || name.hasSuffix("_chapters.yaml") || name.hasSuffix("_project.yaml") { continue }
                if name.lowercased().contains("_transcript") && name.lowercased().hasSuffix(".txt") {
                    // Paired transcript: skip it whenever ANY subtitle file exists in the same
                    // folder. (Bases can legitimately differ — e.g. space vs underscore — so a
                    // rigid _transcript.txt→.srtx name swap would miss those and double-process.)
                    let dir = url.deletingLastPathComponent()
                    guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                    let hasSubtitle = siblings.contains {
                        let n = $0 as NSString
                        return (n.pathExtension.lowercased() == "srtx" || n.pathExtension.lowercased() == "srt")
                            && !n.lastPathComponent.lowercased().contains("_transcript")
                    }
                    if hasSubtitle { continue }
                }
                allFiles.append(url.path)
            }
        }
        srtFiles = allFiles
        selectedProcessingFiles = Set(allFiles)
        processStatus = "Found \(srtFiles.count) file(s)"

        // Detect FPS from first folder
        DispatchQueue.global().async {
            let fps = PythonBridge.detectFrameRate(in: folders[0])
                DispatchQueue.main.async {
                    if let fps, fps != timelineFPS {
                        timelineFPS = fps
                        processStatus = "Auto-detected \(fpsLabel(fps)) fps"
                    }
                    subStore.frameRate = timelineFPS
                    subStore.loadFolders(folders, forceRebuild: forceRebuild)
                    subStore.loadTranscriptsFolders(folders, forceRebuild: forceRebuild)
                    docStore.reloadFolders(folders)
                    self.refreshYAMLStatus()
                }
        }
    }

    // MARK: - Left Panel

    var leftPanel: some View {
        VStack(spacing: 0) {
            SectionTitle("Create Chapters")

            processingSection

            if !processedMarkers.isEmpty {
                Divider()
                    .padding(.top, 8)
                markersSection
                    .frame(minHeight: 60)
            } else if !isProcessing {
                // Kill the dead void below the sliders when nothing is processed yet
                EmptyStateView(
                    icon: "flag",
                    title: "No chapters yet",
                    message: "Select files above and press Process to generate chapter markers and synopses."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var folderBar: some View {
        ProjectBar(
            folders: ownFolders,
            emptyPrompt: "Load work folder…",
            onAdd: { addFolder() },
            onRemove: { p in
                if let idx = ownFolders.firstIndex(of: p) { removeFolder(at: idx) }
            },
            onRescan: { forceReloadOwnFolders() },
            onClear: { showClearAlert = true },
            trees: materialTrees,
            materialsExpanded: $materialsExpanded
        ) {
            if !processStatus.isEmpty {
                Text(processStatus)
                    .scaledFont(.caption2)
                    .foregroundColor(processStatus.hasPrefix("Resolve error") ? .red : .secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(processStatus)
            }
        }
        .confirmationDialog(
            "Remove all work folders and clear the loaded files?",
            isPresented: $showClearAlert,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { clearWorkFolders() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - File Section (top, shared)

    var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                let missingCountValue = selectedProcessingFiles.reduce(0) { count, f in
                    let base = srtBaseName(f)
                    var missing = 0
                    if generateChapters && !(yamlStatus[base] ?? false) { missing += 1 }
                    if generateSynopsis && !(synopsisStatus[base] ?? false) { missing += 1 }
                    return count + missing
                }
                let needsReprocessLabel = weighingChanged && !processedMarkers.isEmpty
                let anyVerbosityChangedFlag = chaptersVerbosityChanged || synopsisVerbosityChanged || chapterDensityChanged

                HStack(spacing: 14) {
                    Toggle(isOn: $generateChapters) { Text("Chapters").scaledFont(.caption) }
                    Toggle(isOn: $generateSynopsis) { Text("Synopsis").scaledFont(.caption) }

                    Spacer()

                    Text("Frame rate")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { timelineFPS },
                        set: { newValue in
                            timelineFPS = newValue
                            subStore.frameRate = newValue
                            if subStore.isLoaded || subStore.isTranscriptsLoaded {
                                subStore.reloadCurrent()
                            }
                        }
                    )) {
                        ForEach([23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0], id: \.self) { fps in
                            Text(fpsLabel(fps)).tag(fps)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 18) {
                    CompactSliderRow(label: "Chapter density", value: $chapterDensity, range: 0.0...1.0, step: 0.1, labelWidth: 100) {
                        chapterDensityChanged = chapterDensity != lastChapterDensity
                    }

                    Divider().frame(height: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Usage — how much detail the notes carry")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                        HStack(spacing: 16) {
                            if generateChapters {
                                CompactSliderRow(label: "Chapters", value: $chaptersVerbosity, range: 0.0...1.0, step: 0.1, labelWidth: 70) {
                                    refreshVerbosityTracking()
                                }
                            }
                            if generateSynopsis {
                                CompactSliderRow(label: "Synopsis", value: $synopsisVerbosity, range: 0.0...1.0, step: 0.1, labelWidth: 74) {
                                    refreshVerbosityTracking()
                                }
                            }
                        }
                    }

                    Spacer()
                }

                if generateSynopsis {
                    HStack(spacing: 12) {
                        Text("Synopsis sections:")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                        Toggle(isOn: $synopsisIntro) { Text("Intro").scaledFont(.caption) }
                        Toggle(isOn: $synopsisParagraphs) { Text("Paragraphs").scaledFont(.caption) }
                        Toggle(isOn: $synopsisBullets) { Text("Bullets").scaledFont(.caption) }
                        Toggle(isOn: $synopsisTimecode) { Text("Timecode").scaledFont(.caption) }
                        Spacer()
                    }
                    .toggleStyle(.checkbox)
                }

                Button(action: { checkOverwriteThenProcess() }) {
                    HStack(spacing: 6) {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else if needsReprocessLabel {
                            Image(systemName: "exclamationmark.triangle.fill")
                        } else if anyVerbosityChangedFlag {
                            Image(systemName: "exclamationmark.triangle")
                        } else {
                            Image(systemName: "sparkle")
                        }
                        Text(processButtonLabel(missingCount: missingCountValue,
                                                needsReprocess: needsReprocessLabel,
                                                anyVerbosityChanged: anyVerbosityChangedFlag))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
                .primaryActionBar()
                .frame(maxWidth: .infinity)
                .disabled(isProcessing || selectedProcessingFiles.isEmpty || (!generateChapters && !generateSynopsis))

                if isProcessing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: processingProgress, total: 1.0)
                            .progressViewStyle(.linear)
                        if !processingProgressMessage.isEmpty {
                            Text(processingProgressMessage)
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Processing Section

    var processingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmptyView()
        }
        .alert("Overwrite Existing Files?", isPresented: $showOverwriteAlert) {
            Button("Overwrite", role: .destructive) { processAllSRTs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The following files already exist:\n" + overwriteFileList.joined(separator: "\n"))
        }
        .alert("Restore previous markers to Resolve?", isPresented: $showUndoAlert) {
            Button("Restore", role: .destructive) { undoResolve() }
            Button("Cancel", role: .cancel) { showUndoAlert = false }
        } message: {
            Text("This will overwrite the current markers in DaVinci Resolve with the previous set.")
        }
        .sheet(isPresented: $showYouTubeSheet) {
            youTubeMarkersSheet
        }
        .sheet(isPresented: $showSummarySheet) {
            youTubeSummarySheet
        }
        .frame(maxWidth: .infinity)
    }

    var youTubeMarkersSheet: some View {
        let text = youTubeMarkersText(markers: processedMarkers)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YouTube Markers")
                    .scaledFont(.title2).bold()
                Spacer()
                textSizeControl
            }
            Text("\(processedMarkers.count) chapters · copy or save below")
                .scaledFont(.subheadline)
                .foregroundColor(.secondary)
            ScrollView {
                Text(text)
                    .scaledFontSize(youtubeTextSize, design: .monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(6)
            }
            HStack {
                Button("Copy to Clipboard") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    showYouTubeSheet = false
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Save As…") { saveText(text, defaultName: "youtube_markers.txt") }
                Spacer()
                Button("Close") { showYouTubeSheet = false }
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    var youTubeSummarySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Summary")
                    .scaledFont(.title2).bold()
                Spacer()
                Picker("Length", selection: $summaryLength) {
                    ForEach(SummaryLength.allCases, id: \.rawValue) { len in
                        Text(len.rawValue).tag(len.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: summaryLength) { newLen in
                    summaryText = summaryCache[newLen] ?? ""
                }
            }

            ZStack {
                ScrollView {
                    Text(summaryText)
                        .scaledFontSize(youtubeTextSize, design: .monospaced)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

                if isGeneratingSummary {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating summary…")
                            .scaledFont(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.03))
                    .cornerRadius(6)
                }
            }
            .frame(minHeight: 220)

            if let elapsed = summaryTimes[summaryLength], !isGeneratingSummary, !summaryText.isEmpty {
                Text("Generated in \(formatElapsed(elapsed))")
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Copy to Clipboard") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(summaryText, forType: .string)
                    showCopiedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedFlash = false
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(summaryText.isEmpty || isGeneratingSummary)
                if showCopiedFlash {
                    Text("Copied ✓")
                        .scaledFont(.caption)
                        .foregroundColor(.green)
                }
                Button("Save As…") { saveText(summaryText, defaultName: "youtube_summary.txt") }
                    .disabled(summaryText.isEmpty || isGeneratingSummary)
                Spacer()
                if summaryText.isEmpty {
                    Button("Generate Summary") { generateYouTubeSummary() }
                        .buttonStyle(.borderedProminent)
                        .disabled(processedMarkers.isEmpty || isGeneratingSummary)
                } else {
                    Button("Regenerate") { generateYouTubeSummary() }
                        .disabled(isGeneratingSummary)
                }
                Button("Close") { showSummarySheet = false }
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    var textSizeControl: some View {
        HStack(spacing: 6) {
            Text("Size")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
            Slider(value: $youtubeTextSize, in: 9...24, step: 1)
                .frame(width: 100)
            Text(String(format: "%.0f", youtubeTextSize))
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .trailing)
        }
    }

    var markersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !docStore.allDocuments.isEmpty {
                    Picker("Document", selection: $selectedDoc) {
                        ForEach(docStore.allDocuments) { doc in
                            Text(doc.title).tag(doc as SummaryDocument?)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Export EDL") { exportEDL() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(processedMarkers.isEmpty)
                        .frame(maxWidth: .infinity)

                    Button("Write to Resolve") { writeResolve() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(processedMarkers.isEmpty || isWritingResolve)
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 8) {
                    Button("YouTube Markers") { showYouTubeSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(processedMarkers.isEmpty)
                        .frame(maxWidth: .infinity)

                    Button("AI Summary") { openSummarySheet() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(processedMarkers.isEmpty)
                        .frame(maxWidth: .infinity)
                }

                if showUndoButton {
                    Button("Undo") { showUndoAlert = true }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            List {
                ForEach(Array(processedMarkers.enumerated()), id: \.element.id) { idx, m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("\(idx + 1).")
                                .scaledFont(.caption, design: .monospaced)
                                .foregroundColor(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Circle()
                                .fill(colorForName(m.color))
                                .frame(width: 8, height: 8)
                            Text(m.timecode)
                                .scaledFont(.caption, design: .monospaced)
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(m.name)
                                .scaledFont(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text(m.theme)
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !m.notes.isEmpty {
                            Text(m.notes)
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .padding(.leading, 120)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Right Panel

    var rightPanel: some View {
        VStack(spacing: 12) {
            SectionTitle("Create Timeline")

            VStack(spacing: 12) {
                HStack {
                    if srtFiles.isEmpty {
                        Text("Load a folder above to search subtitles")
                            .scaledFont(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text(subStore.isTranscriptsLoaded
                            ? "\(subStore.entries.count) sentences + \(subStore.transcriptEntries.count) paragraphs"
                            : "\(subStore.entries.count) sentences")
                            .foregroundColor(.secondary)
                    }
                    if subStore.isLoading || subStore.isTranscriptsLoading {
                        ProgressView().scaleEffect(0.8)
                    }
                    Spacer()
                }

                if false, !reasoningMessages.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(reasoningMessages.indices, id: \.self) { i in
                                    let msg = reasoningMessages[i]
                                    if msg.role == "user" {
                                        Text("> \(msg.content)")
                                            .scaledFont(.subheadline, design: .monospaced)
                                            .foregroundColor(.accentColor)
                                            .textSelection(.enabled)
                                    } else {
                                        Text(msg.content)
                                            .scaledFont(.subheadline, design: .monospaced)
                                            .foregroundColor(.primary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                        .frame(maxHeight: 140)
                        .background(Color(.textBackgroundColor).opacity(0.4))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
                        )
                        .onChange(of: reasoningMessages.count) { _, _ in
                            withAnimation { proxy.scrollTo(reasoningMessages.count - 1, anchor: .bottom) }
                        }
                    }
                }

                if subStore.isTranscriptsLoaded {
                    HStack {
                        Picker("Source", selection: $searchSource) {
                            ForEach(SearchSource.allCases, id: \.rawValue) { src in
                                Text(src.rawValue).tag(src)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        .onChange(of: searchSource) { _, _ in
                            if !lastSearchTerms.isEmpty {
                                executeSearch(terms: lastSearchTerms)
                            }
                        }
                        .onAppear { if speakerListHeight > 90 { speakerListHeight = 80 }; refineCollapsed = false }
                        Text("Subtitles = atomized cues · Transcripts = long paragraphs")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.top, 2)
                }

                HStack {
                    TextField("Prompt or search…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { guard subStore.isLoaded || subStore.isTranscriptsLoaded else { return }; search() }
                        .onChange(of: query) { _, _ in queryDirty = true }
                    Button {
                        search()
                        queryDirty = false
                    } label: {
                        Image(systemName: "paperplane.fill")
                        Text("Send")
                    }
                    .buttonStyle(.borderless)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || (!subStore.isLoaded && !subStore.isTranscriptsLoaded) || isInterpreting)
                    .fontWeight(queryDirty ? .semibold : .regular)
                    .foregroundColor(queryDirty ? .orange : .accentColor)
                    if isInterpreting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 4)
                    }
                    if !searchResults.isEmpty || !reasoningMessages.isEmpty {
                        Button("Clear") {
                            searchResults = []
                            selectedEntryIDs = []
                            query = ""
                            queryDirty = false
                            filterSourceFiles = []
                            filterSpeakers = []
                            reasoningMessages = []
                            smartOrder = nil
                            subStore.statusMessage = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }

                Divider().padding(.vertical, 10)

                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Text("Refine Results")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    if refineCollapsed {
                        Text("±\(Int(contextSlots)) · gap \(groupGap, specifier: "%.1f")s\(searchSource == .subtitles && !subStore.embMap.isEmpty ? " · thr \(subStore.semanticThreshold, specifier: "%.2f")" : "")")
                            .scaledFont(.caption2)
                            .monospacedDigit()
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { refineCollapsed.toggle() } }) {
                        Image(systemName: refineCollapsed ? "chevron.down" : "chevron.up")
                            .scaledFont(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(refineCollapsed ? "Show search refinement sliders" : "Hide search refinement sliders")
                }

                if !refineCollapsed {
                    if searchSource == .subtitles, !subStore.embMap.isEmpty {
                        HStack(spacing: 8) {
                            Text("Looser")
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .leading)
                            Slider(value: $subStore.semanticThreshold, in: 0.05...0.95, step: 0.05)
                                .onChange(of: subStore.semanticThreshold) { _, _ in
                                    guard !lastSearchTerms.isEmpty else { queryDirty = true; return }
                                    executeSearch(terms: lastSearchTerms)
                                }
                            Text("Tighter")
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("Context")
                            .scaledFont(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $contextSlots, in: 0...10, step: 1)
                        Text("±\(Int(contextSlots)) sub\(contextSlots == 1 ? "" : "s")")
                            .scaledFont(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        Text("Group Gap")
                            .scaledFont(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $groupGap, in: 0...10, step: 0.5)
                        Text("\(groupGap, specifier: "%.1f")s")
                            .scaledFont(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                Toggle(isOn: $addSubtitles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Subtitles (.srtx)")
                            .scaledFont(.subheadline)
                        Text("Writes an SRTX captions file (frame-based, with speaker) to the work folder.")
                            .scaledFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if !availableSpeakers.isEmpty {
                    Divider().padding(.vertical, 8)
                    HStack(spacing: 6) {
                        Image(systemName: "person.2")
                            .scaledFont(.caption)
                            .foregroundColor(.secondary)
                        Text("Speakers (\(availableSpeakers.count))")
                            .scaledFont(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        if !filterSpeakers.isEmpty {
                            Text("\(filterSpeakers.count) selected")
                                .scaledFont(.caption2)
                                .foregroundColor(.accentColor)
                        }
                        Spacer()
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { speakerListCollapsed.toggle() } }) {
                            Image(systemName: speakerListCollapsed ? "chevron.down" : "chevron.up")
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(speakerListCollapsed ? "Show speakers" : "Hide speakers")
                    }

                    if !speakerListCollapsed {
                        // Compact chip grid — does not stretch full-width rows
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 6)], alignment: .leading, spacing: 6) {
                                SpeakerChip(title: "All Speakers", selected: filterSpeakers.isEmpty) {
                                    filterSpeakers = []
                                    if !lastSearchTerms.isEmpty { executeSearch(terms: lastSearchTerms) }
                                }
                                ForEach(availableSpeakers.sorted(), id: \.self) { s in
                                    SpeakerChip(title: s, selected: filterSpeakers.contains(s)) {
                                        if filterSpeakers.contains(s) {
                                            filterSpeakers.remove(s)
                                        } else {
                                            filterSpeakers.insert(s)
                                        }
                                        if !lastSearchTerms.isEmpty { executeSearch(terms: lastSearchTerms) }
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 84)
                        .background(
                            RoundedRectangle(cornerRadius: UIDesign.cornerCard, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: UIDesign.cornerCard, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: UIDesign.cornerCard, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack {
                if !searchResults.isEmpty {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.rawValue) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 400)
                    .onChange(of: sortOrder) { _, _ in applySort() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            HStack {
                Text(subStore.statusMessage)
                    .scaledFont(.caption)
                    .foregroundColor(transcriptDbFailed ? .orange : .secondary)
                if transcriptDbFailed {
                    Button("Force Rebuild Transcript Index") {
                        subStore.loadTranscriptsFolders(ownFolders, forceRebuild: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                if !searchResults.isEmpty {
                    let rows = displayRows
                    let ids = resolvedIDs
                    Text("Selected: \(durationString(rows: rows, ids: ids))")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .padding(.trailing, 8)
                    if isCreating {
                        Button("Cancel") {
                            PythonBridge.cancelRunning()
                            isCreating = false
                            subStore.statusMessage = "Cancelled"
                            progress.finish("Cancelled")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                    }
                    Button(isCreating ? "Creating…" : "Create Timeline") { createTimeline(rows: rows, ids: ids) }
                        .disabled(isCreating || selectedEntryIDs.isEmpty)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Group {
                if searchResults.isEmpty {
                    VStack {
                        Spacer()
                        Image(systemName: query.isEmpty ? "magnifyingglass" : "questionmark.folder")
                            .scaledFontSize(28)
                            .foregroundColor(.secondary.opacity(0.35))
                        Text(query.isEmpty
                            ? (subStore.isLoading || subStore.isTranscriptsLoading
                                ? "Parsing subtitles…"
                                : subStore.statusMessage.isEmpty
                                    ? "Load an SRT folder above to enable search and timeline creation."
                                    : subStore.statusMessage)
                            : "No matches")
                            .scaledFont(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let rows = displayRows
                    let ids = resolvedIDs
                    ScrollViewReader { proxy in
                        resultsTable(rows: rows, ids: ids)
                            .onChange(of: contextSlots) { _, _ in
                                if let firstID = rows.first?.id {
                                    proxy.scrollTo(firstID, anchor: .top)
                                }
                            }
                    }
                }
            }
        }
        .onAppear {
            loadOwnFolders()
            let grouped = Dictionary(grouping: subStore.entries) { $0.sourceFile }
            cachedByFile = grouped.mapValues { $0.sorted { $0.start_s < $1.start_s } }
            if selectedDoc == nil, let first = docStore.allDocuments.first {
                selectedDoc = first
                processedMarkers = first.markers
            }
        }
        .onReceive(subStore.$entries) { entries in
            let grouped = Dictionary(grouping: entries) { $0.sourceFile }
            cachedByFile = grouped.mapValues { $0.sorted { $0.start_s < $1.start_s } }
        }
        .onReceive(docStore.$allDocuments) { docs in
            if docs.isEmpty {
                // No documents (e.g. all work folders removed) → clear chapter list too.
                processedMarkers = []
                selectedDoc = nil
                return
            }
            if let doc = selectedDoc {
                if docs.contains(where: { $0.id == doc.id }) { return }
            }
            selectedDoc = docs.first
            if let doc = docs.first {
                processedMarkers = doc.markers
            }
        }
        .onChange(of: selectedDoc) { _, doc in
            if let doc { processedMarkers = doc.markers }
        }
    }

    // MARK: - Helpers

    var availableSourceFiles: [String] {
        if searchSource == .transcripts, subStore.isTranscriptsLoaded {
            return Array(Set(subStore.transcriptEntries.map(\.sourceFile))).sorted()
        }
        return Array(Set(subStore.entries.map(\.sourceFile))).sorted()
    }

    func fpsLabel(_ fps: Double) -> String {
        if fps == fps.rounded() {
            return String(format: "%.0f", fps)
        }
        return String(format: "%.3f", fps)
    }

    var availableSpeakers: [String] {
        if searchSource == .transcripts, subStore.isTranscriptsLoaded {
            return Array(Set(subStore.transcriptEntries.map(\.speaker).filter { !$0.isEmpty })).sorted()
        }
        return Array(Set(subStore.entries.map(\.speaker).filter { !$0.isEmpty })).sorted()
    }

    func resultsTable(rows: [DisplayRow], ids: Set<String>) -> some View {
        List(rows) { row in
            if row.isDivider {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 3)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            } else {
                HStack(alignment: .top) {
                    Image(systemName: row.isContext
                        ? "circle.fill"
                        : (ids.contains(row.id) ? "checkmark.circle.fill" : "circle"))
                        .foregroundColor(ids.contains(row.id)
                            ? (row.isContext ? .orange : .accentColor)
                            : .secondary)
                        .padding(.top, 2)
                        .onTapGesture {
                            guard !row.isContext else { return }
                            toggleSelection(row.id)
                        }
                        .imageScale(.large)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(row.entry.speaker)
                                .fontWeight(.semibold)
                                .foregroundColor(row.isContext ? .secondary : .accentColor)
                            Text(row.entry.timecode)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            Text(row.entry.interview)
                                .foregroundColor(.secondary)
                            if row.isContext {
                                Text("context")
                                    .scaledFont(.caption2)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(3)
                            }
                        }
                        Text(row.entry.text)
                            .lineLimit(3)
                            .foregroundColor(row.isContext ? .secondary : .primary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(durationLabel(row.entry.duration))
                            .scaledFont(.subheadline, monospacedDigit: true)
                            .foregroundColor(.secondary)
                        if case .match(let hit) = row, hit.similarity > 0 {
                            Text(similarityLabel(hit.similarity))
                                .scaledFont(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .listRowSeparator(.hidden)
                .onTapGesture {
                    guard !row.isContext else { return }
                    toggleSelection(row.id)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Actions

    func chooseSRTFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "srtx") ?? .plainText]
        panel.message = "Select an SRT file or a folder with SRT files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let fldr = url.path
            loadSubtitlesDetected(folder: fldr)
            filterSourceFiles = []
        } else {
            loadSubtitlesDetected(folder: (url.path as NSString).deletingLastPathComponent, singlePath: url.path)
            filterSourceFiles = []
        }
    }

    func loadSubtitlesDetected(folder: String, singlePath: String? = nil) {
        let preferred = singlePath.map { ($0 as NSString).lastPathComponent }
        DispatchQueue.global().async {
            let fps = PythonBridge.detectFrameRate(in: folder, preferredBaseName: preferred)
            DispatchQueue.main.async {
                if let fps, fps != timelineFPS {
                    timelineFPS = fps
                    processStatus = "Auto-detected \(fpsLabel(fps)) fps from folder"
                }
                subStore.frameRate = timelineFPS
                if let singlePath {
                    subStore.loadSingleSRT(path: singlePath)
                } else {
                    subStore.reload(folder: folder)
                    subStore.loadTranscripts(folder: folder)
                }
            }
        }
    }

    func clearFolder() {
        srtFolder = nil
        lastSrtFolder = ""
        srtFiles = []
        selectedProcessingFiles = []
        processedResults = []
        processedMarkers = []
        selectedDoc = nil
        processStatus = ""
        searchResults = []
        selectedEntryIDs = []
        query = ""
        queryDirty = false
        filterSourceFiles = []
        filterSpeakers = []
        reasoningMessages = []
        smartOrder = nil
        showUndoButton = false
        backupURL = nil
    }

    func chooseSRTFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select a folder with SRT files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        srtFolder = url.path
        lastSrtFolder = url.path
        scanSRTs()
        loadSubtitlesDetected(folder: url.path)
        docStore.reload(folder: url.path)
    }

    func scanSRTs() {
        guard let folder = srtFolder else { return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folder)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var files: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(".srt") || name.hasSuffix(".srtx") || name.hasSuffix(".txt") else { continue }
            if name.hasSuffix("_synopsis.txt") || name.hasSuffix("_chapters.yaml") || name.hasSuffix("_project.yaml") { continue }
            if name.lowercased().contains("_transcript") && name.lowercased().hasSuffix(".txt") {
                // Paired transcript: skip whenever ANY subtitle file exists in the same folder.
                let dir = url.deletingLastPathComponent()
                guard let siblings = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                let hasSubtitle = siblings.contains {
                    let n = $0 as NSString
                    return (n.pathExtension.lowercased() == "srtx" || n.pathExtension.lowercased() == "srt")
                        && !n.lastPathComponent.lowercased().contains("_transcript")
                }
                if hasSubtitle { continue }
            }
            files.append(url.path)
        }
        srtFiles = files
        selectedProcessingFiles = Set(files)
        processStatus = "Found \(srtFiles.count) file(s)"
    }

    func processButtonLabel(missingCount: Int, needsReprocess: Bool, anyVerbosityChanged: Bool) -> String {
        if isProcessing { return "Creating…" }
        if needsReprocess && anyVerbosityChanged { return "Recreate Chapters and Synopsis (weights + settings changed)" }
        if needsReprocess { return "Recreate Chapters and Synopsis (weights changed)" }
        if anyVerbosityChanged {
            if chaptersVerbosityChanged && !synopsisVerbosityChanged { return "Create Chapters (settings changed)" }
            if synopsisVerbosityChanged && !chaptersVerbosityChanged { return "Create Synopsis (settings changed)" }
            return "Recreate Chapters and Synopsis (settings changed)"
        }
        if missingCount > 0 { return "Create Chapters and Synopsis (\(missingCount) missing)" }
        return "Create Chapters and Synopsis"
    }

    var transcriptDbFailed: Bool {
        subStore.statusMessage.hasPrefix("Transcript DB error")
    }

    func checkOverwriteThenProcess() {
        let existing = findExistingOutputs()
        if existing.isEmpty {
            processAllSRTs()
        } else {
            overwriteFileList = existing
            showOverwriteAlert = true
        }
    }

    func findExistingOutputs() -> [String] {
        let fm = FileManager.default
        var existing: [String] = []
        let multiFolder = Set(srtFiles.map { ($0 as NSString).deletingLastPathComponent }).count > 1
        // Effective produce flag mirrors processAllSRTs logic.
        let produceChapters = generateChapters && !isMultiFolder
        let checkChapters: Bool
        let checkSynopsis: Bool
        if produceChapters && !generateSynopsis {
            checkChapters = true; checkSynopsis = false
        } else if generateSynopsis && !produceChapters {
            checkChapters = false; checkSynopsis = true
        } else if produceChapters && generateSynopsis {
            if chaptersVerbosityChanged && !synopsisVerbosityChanged {
                checkChapters = true; checkSynopsis = false
            } else if synopsisVerbosityChanged && !produceChapters {
                checkChapters = false; checkSynopsis = true
            } else {
                checkChapters = true; checkSynopsis = true
            }
        } else {
            checkChapters = false; checkSynopsis = false
        }
        var seenBases = Set<String>()
        for srt in srtFiles {
            let base = srtBaseName(srt)
            let dir = (srt as NSString).deletingLastPathComponent
            guard seenBases.insert(dir + "/" + base).inserted else { continue }
            if checkChapters {
                let p = (dir as NSString).appendingPathComponent(base + "_chapters.yaml")
                if fm.fileExists(atPath: p) {
                    let prefix = multiFolder ? ((dir as NSString).lastPathComponent + "/") : ""
                    existing.append(prefix + base + "_chapters.yaml")
                }
            }
            if checkSynopsis {
                let p = (dir as NSString).appendingPathComponent(base + "_synopsis.txt")
                if fm.fileExists(atPath: p) {
                    let prefix = multiFolder ? ((dir as NSString).lastPathComponent + "/") : ""
                    existing.append(prefix + base + "_synopsis.txt")
                }
            }
        }
        return existing
    }

    func refreshYAMLStatus() {
        let fm = FileManager.default
        var yStatus: [String: Bool] = [:]
        var sStatus: [String: Bool] = [:]
        for f in srtFiles {
            let base = srtBaseName(f)
            let dir = (f as NSString).deletingLastPathComponent
            yStatus[base] = fm.fileExists(atPath: (dir as NSString).appendingPathComponent(base + "_chapters.yaml"))
            sStatus[base] = fm.fileExists(atPath: (dir as NSString).appendingPathComponent(base + "_synopsis.txt"))
        }
        yamlStatus = yStatus
        synopsisStatus = sStatus
        checkWeighingChanged()
    }

    func captureProcessedWeights() {
        if let data = projectThemesJSON.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ProjectTheme].self, from: data) {
            lastProcessedWeights = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0.weight) })
            weighingChanged = false
        }
        lastChaptersVerbosity = chaptersVerbosity
        lastSynopsisVerbosity = synopsisVerbosity
        lastChapterDensity = chapterDensity
        chaptersVerbosityChanged = false
        synopsisVerbosityChanged = false
        chapterDensityChanged = false
    }

    func refreshVerbosityTracking() {
        chaptersVerbosityChanged = chaptersVerbosity != lastChaptersVerbosity
        synopsisVerbosityChanged = synopsisVerbosity != lastSynopsisVerbosity
        chapterDensityChanged = chapterDensity != lastChapterDensity
    }

    func checkWeighingChanged() {
        guard !lastProcessedWeights.isEmpty else { return }
        if let data = projectThemesJSON.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ProjectTheme].self, from: data) {
            let current = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0.weight) })
            weighingChanged = current != lastProcessedWeights
        }
    }

    func contextualExcerpt(text: String, query: String, window: Int = 150) -> String {
        let nsText = text as NSString
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowerQuery.isEmpty else { return String(text.prefix(window * 2)) }
        let nsRange = (lowerText as NSString).range(of: lowerQuery)
        if nsRange.location != NSNotFound {
            let start = max(0, nsRange.location - window)
            let end = min(nsText.length, nsRange.location + nsRange.length + window)
            var result = nsText.substring(with: NSMakeRange(start, end - start))
            if start > 0 { result = "…" + result }
            if end < nsText.length { result = result + "…" }
            return result
        }
        return String(text.prefix(window * 2))
    }

    func srtBaseName(_ path: String) -> String {
        var name = URL(fileURLWithPath: path).lastPathComponent
        for ext in [".srtx", ".srt", ".txt"] {
            if name.hasSuffix(ext) {
                name = String(name.dropLast(ext.count))
            }
        }
        if name.hasSuffix("_subtitles") {
            name = String(name.dropLast("_subtitles".count))
        }
        if name.hasSuffix("_transcripts") {
            name = String(name.dropLast("_transcripts".count))
        }
        if name.hasSuffix("_transcript") {
            name = String(name.dropLast("_transcript".count))
        }
        return name
    }

    func processAllSRTs() {
        let selected = srtFiles.filter { selectedProcessingFiles.contains($0) }
        guard !selected.isEmpty else { return }
        isProcessing = true
        processingProgress = 0
        processingProgressMessage = ""
        processedResults = []
        processStatus = "Processing 0/\(selected.count)…"
        progress.start("Processing 0/\(selected.count) files")

        DispatchQueue.global().async {
            var results: [(String, String, String)] = []
            var failedFiles: [String] = []
            var degradedNotes: [String] = []

            // Write priming prompt to temp file
            let primingPromptFile = "/tmp/assistanteditor_priming_prompt.txt"
            let priming = PrimingRegistry.stage(for: "priming_chaptersSynopsis")?.load() ?? ""
            if !priming.isEmpty {
                try? priming.write(toFile: primingPromptFile, atomically: true, encoding: .utf8)
            } else {
                try? "".write(toFile: primingPromptFile, atomically: true, encoding: .utf8)
            }

            // Write project themes to temp file if available
            let themesFile = "/tmp/assistanteditor_themes.json"
            if projectThemesJSON != "[]", let data = projectThemesJSON.data(using: .utf8),
               let themes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                try? JSONSerialization.data(withJSONObject: themes).write(to: URL(fileURLWithPath: themesFile))
            } else {
                try? "".write(toFile: themesFile, atomically: true, encoding: .utf8)
            }

            var debugLog = "=== Process All SRTs ===\n"
            debugLog += "Selected files: \(selected.map { ($0 as NSString).lastPathComponent })\n"

            for (i, srt) in selected.enumerated() {
                do {
                    let mappedChapters = 0.5 + chaptersVerbosity * 0.5
                    let mappedSynopsis = 0.5 + synopsisVerbosity * 0.5
                    // Multi-folder projects have no per-timeline chapters — synopsis only.
                    let produceChapters = generateChapters && !isMultiFolder
                    var args = [srt, "--chapters-verbosity", String(format: "%.1f", mappedChapters), "--synopsis-verbosity", String(format: "%.1f", mappedSynopsis)]
                    args += ["--fps", String(format: "%g", timelineFPS)]
                    args += ["--priming-prompt-file", primingPromptFile]
                    args += ["--themes-file", themesFile]
                    args += ["--chapter-density", String(format: "%.1f", chapterDensity)]
                    if let selModel = UserDefaults.standard.string(forKey: "selectedModel"), !selModel.isEmpty {
                        args += ["--model", selModel]
                    }
                    let base = srtBaseName(srt)
                    let dir = (srt as NSString).deletingLastPathComponent
                    var transcriptPath = (dir as NSString).appendingPathComponent(base + "_transcript.txt")
                    var hasTranscript = FileManager.default.fileExists(atPath: transcriptPath)
                    if !hasTranscript {
                        let pluralPath = (dir as NSString).appendingPathComponent(base + "_transcripts.txt")
                        if FileManager.default.fileExists(atPath: pluralPath) {
                            transcriptPath = pluralPath
                            hasTranscript = true
                        }
                    }
                    if !hasTranscript {
                        // Base names can differ (space vs underscore) — fall back to any
                        // _transcript.txt / _transcripts.txt sibling in the same folder so the LLM still gets context.
                        if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir),
                           let found = siblings.first(where: { $0.contains("_transcript") && ($0 as NSString).pathExtension.lowercased() == "txt" }) {
                            transcriptPath = (dir as NSString).appendingPathComponent(found)
                            hasTranscript = true
                        }
                    }
                    debugLog += "\nFile \(i+1): \(srt)\n"
                    debugLog += "  base: \(base)\n"
                    debugLog += "  dir: \(dir)\n"
                    debugLog += "  transcriptPath: \(transcriptPath)\n"
                    debugLog += "  hasTranscript: \(hasTranscript)\n"
                    if hasTranscript {
                        args += ["--transcript", transcriptPath]
                    }
                    if produceChapters && !generateSynopsis {
                        args.append("--chapters-only")
                    } else if generateSynopsis && !produceChapters {
                        args.append("--synopsis-only")
                    } else if produceChapters && generateSynopsis {
                        if chaptersVerbosityChanged && !synopsisVerbosityChanged {
                            args.append("--chapters-only")
                        } else if synopsisVerbosityChanged && !produceChapters {
                            args.append("--synopsis-only")
                        }
                    }
                    if generateSynopsis {
                        if synopsisIntro { args.append("--synopsis-intro") }
                        if synopsisParagraphs { args.append("--synopsis-paragraphs") }
                        if synopsisBullets { args.append("--synopsis-bullets") }
                        if synopsisTimecode { args.append("--synopsis-timecode") }
                    }
                    let totalFiles = selected.count
                    let fileBase = Double(i) / Double(totalFiles)
                    let phaseNames = [
                        "Parsing subtitle", "Merging subtitle", "Analyzing content",
                        "Found ", "Generating synopsis", "Generating chapter notes",
                        "Writing output", "Complete"
                    ]
                    let output = try PythonBridge.runRawProgress("process_srt", args: args, timeoutSeconds: 1200) { msg in
                        let phaseIdx = phaseNames.firstIndex { msg.hasPrefix($0) } ?? 0
                        let overall = fileBase + Double(phaseIdx + 1) / Double(phaseNames.count * totalFiles)
                        processingProgress = min(1.0, overall)
                        processingProgressMessage = msg
                    }
                    let last200 = output.count > 200 ? String(output.suffix(200)) : output
                    debugLog += "  output (last 200 chars): \(last200)\n"
                    DispatchQueue.main.async {
                        processStatus = "Processed \(i+1)/\(totalFiles): \(URL(fileURLWithPath: srt).lastPathComponent)"
                        processingProgress = Double(i + 1) / Double(totalFiles)
                        progress.update("Processing \(i+1)/\(totalFiles)", progress: Double(i + 1) / Double(totalFiles))
                    }
                    let lastJSONLine: String = {
                        let lines = output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        return lines.last ?? output
                    }()
                    if let data = lastJSONLine.data(using: .utf8),
                       let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       result["status"] as? String == "ok" {
                        let yamlPath = result["yaml"] as? String ?? ""
                        let synPath = result["synopsis"] as? String ?? ""
                        if let warning = result["warning"] as? String {
                            degradedNotes.append("\(URL(fileURLWithPath: srt).lastPathComponent): \(warning)")
                        }
                        if !yamlPath.isEmpty || !synPath.isEmpty {
                            results.append((srt, yamlPath, synPath))
                            debugLog += "  status: ok, yaml=\(yamlPath), syn=\(synPath)\n"
                            if results.count == 1, let markersData = try? JSONSerialization.data(withJSONObject: result["markers"] ?? []),
                               let markers = try? JSONDecoder().decode([SummaryMarker].self, from: markersData) {
                                DispatchQueue.main.async {
                                    processedMarkers = markers
                                    selectedDoc = nil
                                    showUndoButton = false
                                }
                            }
                        } else {
                            debugLog += "  status: ok but empty yaml+synopsis\n"
                            failedFiles.append(URL(fileURLWithPath: srt).lastPathComponent)
                        }
                    } else {
                        debugLog += "  JSON parse failed or status!=ok. output prefix: \(output.prefix(300))\n"
                        failedFiles.append(URL(fileURLWithPath: srt).lastPathComponent)
                    }
                } catch {
                    debugLog += "  ERROR: \(error.localizedDescription)\n"
                    failedFiles.append("\(URL(fileURLWithPath: srt).lastPathComponent) (\(error.localizedDescription))")
                }
            }
            try? debugLog.write(toFile: "/tmp/assistanteditor_process_debug.log", atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                processedResults = results
                isProcessing = false
                let total = selected.count
                var status = "Processed \(results.count)/\(total) file(s)"
                if !failedFiles.isEmpty {
                    status += "\nFailed: " + failedFiles.joined(separator: ", ")
                }
                if !degradedNotes.isEmpty {
                    status += "\n⚠️ LLM unavailable for some files — keyword fallback used:\n" + degradedNotes.joined(separator: "\n")
                }
                processStatus = status
                progress.finish("Processed \(results.count)/\(total) file(s)")
                // Chapters/synopses changed — only DocumentStore needs refreshing,
                // across ALL folders (the old code reloaded folders[0] only).
                if !self.ownFolders.isEmpty {
                    docStore.reloadFolders(self.ownFolders)
                }
                if let first = results.first {
                    let srtName = URL(fileURLWithPath: first.0).lastPathComponent
                    self.subStore.statusMessage = "Loaded: \(srtName)"
                }
                self.captureProcessedWeights()
                self.refreshYAMLStatus()
                if let first = results.first {
                    let base = (first.1 as NSString).deletingPathExtension
                    let synPath = first.2
                    if !synPath.isEmpty, let synText = try? String(contentsOf: URL(fileURLWithPath: synPath), encoding: .utf8) {
                        self.summaryCache["Medium"] = synText
                        self.saveSummaryCache()
                    }
                }
            }
        }
    }

    // MARK: - Markers from processing

    func exportEDL() {
        guard !processedMarkers.isEmpty else { return }
        let panel = NSSavePanel()
        let defaultName = "chapters_markers.EDL"
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["TITLE: chapters_markers", "FCM: NON-DROP FRAME", ""]
        for (i, m) in processedMarkers.enumerated() {
            let n = String(format: "%03d", i + 1)
            let tc1 = secondsToEdfTc(m.start_s, fps: timelineFPS)
            let tc2 = secondsToEdfTc(m.end_s, fps: timelineFPS)
            let dur = max(1, Int(round((m.end_s - m.start_s) * timelineFPS)))
            lines.append("\(n)  001      V     C        \(tc1) \(tc2) \(tc1) \(tc2)")
            lines.append("\(m.notes) |C:ResolveColor\(m.color) |M:\(m.name) |D:\(dur)")
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        processStatus = "EDL saved: \(url.lastPathComponent)"
    }

    func youTubeMarkersText(markers: [SummaryMarker]) -> String {
        let sorted = markers.sorted { $0.start_s < $1.start_s }
        return sorted.map { "\(youtubeTimecode($0.start_s)) \(chapterTitle($0))" }.joined(separator: "\n")
    }

    func chapterTitle(_ m: SummaryMarker) -> String {
        let prefix = "\(m.theme):"
        let t = m.name.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(prefix) {
            return t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    func youtubeTimecode(_ s: Double) -> String {
        let t = Int(s)
        let h = t / 3600
        let m = (t % 3600) / 60
        let sec = t % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    func formatElapsed(_ seconds: Double) -> String {
        let t = Int(seconds)
        let m = t / 60
        let s = t % 60
        if m > 0 {
            return String(format: "%d:%02d", m, s)
        }
        return String(format: "0:%02d", s)
    }

    func youTubeSummary(doc: SummaryDocument?) -> String {
        guard let doc, let sourceFolder = doc.sourceFolder, let sourceFile = doc.sourceFile else { return "" }
        let dir = URL(fileURLWithPath: sourceFolder)
        let base = (sourceFile as NSString).deletingPathExtension
        let synPath = dir.appendingPathComponent("\(base)_synopsis.txt")
        guard let text = try? String(contentsOf: synPath, encoding: .utf8) else { return "" }
        var paragraph: [String] = []
        var inHeader = false
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("====") { inHeader = true; continue }
            if inHeader {
                if t.uppercased().hasPrefix("TOPICS COVERED") { break }
                if !t.isEmpty { paragraph.append(t) }
            }
        }
        return paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openSummarySheet() {
        guard !processedMarkers.isEmpty else { return }
        loadSummaryCache()
        summaryText = summaryCache[summaryLength] ?? ""
        showSummarySheet = true
    }

    func generateYouTubeSummary() {
        guard !processedMarkers.isEmpty, !isGeneratingSummary else { return }
        isGeneratingSummary = true
        summaryText = ""
        showSummarySheet = true
        generationStart = Date()

        let length = SummaryLength(rawValue: summaryLength) ?? .medium
        let title = selectedDoc?.title ?? ""
        let intro = youTubeSummary(doc: selectedDoc)
        let sorted = processedMarkers.sorted { $0.start_s < $1.start_s }
        let chapterLines = sorted.map { m in
            "\(youtubeTimecode(m.start_s)) \(chapterTitle(m))" + (m.notes.isEmpty ? "" : " — \(m.notes)")
        }.joined(separator: "\n")
        let transcript = summaryTranscriptContext()

        let template = PrimingRegistry.stage(for: "priming_youtubeSummary")?.load()
            ?? "You are writing a YouTube video description. {LENGTH} Write a professional, factual summary of the video based on the title, chapter markers, notes, and the provided transcript. Do not include chapter lists or timestamps in the summary. Reply with the summary text only, with no preamble."
        let system = template.replacingOccurrences(of: "{LENGTH}", with: length.lengthInstruction)
        var prompt = "Video title: \(title)\n\nChapters:\n\(chapterLines)"
        if !transcript.isEmpty {
            prompt += "\n\nTranscript:\n\(transcript)"
        }
        if !intro.isEmpty {
            prompt += "\n\nAdditional context (may help but do not repeat verbatim):\n\(intro)"
        }

        OMLXClient.shared.complete(
            system: system,
            prompt: prompt,
            temperature: 0.4,
            maxTokens: 2048,
            timeout: 120
        ) { result in
            let resultText: String
            if let text = result.text, result.error == nil {
                resultText = Self.stripThinkBlocks(from: text)
            } else {
                resultText = "⚠️ \(result.error ?? "No response from oMLX")"
            }
            let elapsed = generationStart.map { Date().timeIntervalSince($0) } ?? 0
            DispatchQueue.main.async {
                summaryText = resultText
                isGeneratingSummary = false
                if !resultText.hasPrefix("⚠️") {
                    summaryCache[summaryLength] = resultText
                    summaryTimes[summaryLength] = elapsed
                    saveSummaryCache()
                }
            }
        }
    }

    func loadSummaryCache() {
        let doc = selectedDoc?.title ?? ""
        if summaryCacheDoc == doc, !summaryCacheDoc.isEmpty { return }
        summaryCache = [:]
        summaryTimes = [:]
        if !summaryCacheJSON.isEmpty,
           let data = summaryCacheJSON.data(using: .utf8),
           let cache = try? JSONDecoder().decode(SummaryCache.self, from: data),
           cache.doc == doc {
            summaryCache = cache.texts
            summaryTimes = cache.times
        }
        summaryCacheDoc = doc
    }

    func saveSummaryCache() {
        let cache = SummaryCache(doc: summaryCacheDoc, texts: summaryCache, times: summaryTimes)
        if let data = try? JSONEncoder().encode(cache) {
            summaryCacheJSON = String(data: data, encoding: .utf8) ?? ""
        }
    }

    func summaryTranscriptContext() -> String {
        let targetBase = selectedDoc?.sourceFile.map { ($0 as NSString).deletingPathExtension }
        var paragraphs = subStore.transcriptEntries
        if let targetBase, !targetBase.isEmpty {
            let matched = paragraphs.filter { ($0.sourceFile as NSString).deletingPathExtension == targetBase }
            if !matched.isEmpty { paragraphs = matched }
        }
        if paragraphs.isEmpty {
            let entries = subStore.entries
            if let targetBase, !targetBase.isEmpty {
                let matched = entries.filter { ($0.sourceFile as NSString).deletingPathExtension == targetBase }
                if !matched.isEmpty { return joinedEntries(matched) }
            }
            return joinedEntries(entries)
        }
        return joinedEntries(paragraphs)
    }

    private func joinedEntries(_ entries: [SubtitleEntry]) -> String {
        var text = entries.map { entry in
            (entry.speaker.isEmpty ? "" : "\(entry.speaker): ") + entry.text
        }.joined(separator: "\n")
        if text.count > 14000 {
            text = String(text.prefix(14000)) + "\n[…]"
        }
        return text
    }

    static func stripThinkBlocks(from text: String) -> String {
        var cleaned = text
        if let range = cleaned.range(of: "</think>", options: .backwards) {
            cleaned = String(cleaned[range.upperBound...])
        }
        cleaned = cleaned.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<think>", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveText(_ text: String, defaultName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        processStatus = "Saved: \(url.lastPathComponent)"
    }

    func writeResolve() {
        guard !processedMarkers.isEmpty else { return }
        isWritingResolve = true
        processStatus = "Connecting to Resolve…"
        progress.start("Writing markers to Resolve…")

        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistanteditor_undo")
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backupFile = backupDir.appendingPathComponent("markers_\(Date().timeIntervalSince1970).json")
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(processedMarkers) {
            try? data.write(to: backupFile)
            backupURL = backupFile
        }

        let groups = processedMarkers.map { m -> MarkerGroup in
            MarkerGroup(
                start_s: m.start_s,
                duration_s: m.end_s - m.start_s,
                text: m.notes,
                summary: m.name,
                keywords: m.theme,
                color: m.color
            )
        }

        guard let jsonData = try? JSONEncoder().encode(groups) else {
            processStatus = "Failed to encode marker data"
            isWritingResolve = false
            progress.finish("Failed to encode marker data")
            return
        }

        DispatchQueue.global().async {
            do {
                let env: [String: String] = [:] // Auto-detect Resolve install (see write_resolve.py find_resolve_api/lib)
                let output = try PythonBridge.runRaw("write_resolve", stdin: jsonData, envOverrides: env, timeoutSeconds: 60)
                if let data = output.data(using: .utf8),
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result["status"] as? String == "ok" {
                        let total = result["total_markers"] as? Int ?? 0
                        let failed = result["failed"] as? Int ?? 0
                        var msg = "\(total) timeline markers written to Resolve."
                        if failed > 0 { msg += " \(failed) failed." }
                        DispatchQueue.main.async {
                            processStatus = msg
                            isWritingResolve = false
                            showUndoButton = true
                            progress.finish(msg)
                        }
                    } else {
                        throw PythonBridgeError.executionFailed(result["error"] as? String ?? "Unknown error")
                    }
                } else {
                    DispatchQueue.main.async {
                        processStatus = output
                        isWritingResolve = false
                        progress.finish(output)
                    }
                }
            } catch {
                let msg: String
                switch error {
                case let PythonBridgeError.executionFailed(err): msg = err
                default: msg = error.localizedDescription
                }
                if msg.contains("Could not connect to Resolve") {
                    // Fallback to in-console bridge (uses the healthy Py3> print(resolve) path)
                    let payload = jsonData // captured from outer scope
                    DispatchQueue.main.async {
                        processStatus = "External helper not responding — trying in-console bridge…"
                        progress.finish("Trying in-console bridge…")
                    }
                    ResolveConnector.shared.writeViaConsoleBridge(markersJSON: payload) { ok, info in
                        DispatchQueue.main.async {
                            processStatus = ok ? "Resolve (in-console): \(info)" : "Resolve error: \(info)"
                            isWritingResolve = false
                            progress.finish(ok ? info : "Resolve error: \(info)")
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    processStatus = "Resolve error: \(msg)"
                    isWritingResolve = false
                    progress.finish("Resolve error: \(msg)")
                }
            }
        }
    }

    func undoResolve() {
        guard let backupURL = backupURL,
              let data = try? Data(contentsOf: backupURL),
              let restored = try? JSONDecoder().decode([SummaryMarker].self, from: data) else {
            processStatus = "No backup found to restore"
            progress.finish("No backup found")
            return
        }

        processStatus = "Restoring \(restored.count) markers…"
        progress.start("Restoring markers…")
        let groups = restored.map { m -> MarkerGroup in
            MarkerGroup(
                start_s: m.start_s,
                duration_s: m.end_s - m.start_s,
                text: m.notes,
                summary: m.name,
                keywords: m.theme,
                color: m.color
            )
        }

        guard let jsonData = try? JSONEncoder().encode(groups) else {
            processStatus = "Failed to encode markers"
            progress.finish("Failed to encode")
            return
        }

        DispatchQueue.global().async {
            do {
                let env: [String: String] = [:] // Auto-detect Resolve install (see write_resolve.py find_resolve_api/lib)
                let output = try PythonBridge.runRaw("write_resolve", stdin: jsonData, envOverrides: env, timeoutSeconds: 60)
                if let data = output.data(using: .utf8),
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result["status"] as? String == "ok" {
                        let total = result["total_markers"] as? Int ?? 0
                        DispatchQueue.main.async {
                            self.processedMarkers = restored
                            processStatus = "Undo complete: \(total) markers restored to Resolve"
                            showUndoButton = false
                            self.backupURL = nil
                            progress.finish("Undo complete")
                        }
                    } else {
                        let err = result["error"] as? String ?? "Unknown error"
                        if err.contains("Could not connect to Resolve") {
                            let payload = jsonData
                            DispatchQueue.main.async {
                                processStatus = "External helper not responding — trying in-console bridge…"
                                progress.finish("Trying in-console bridge…")
                            }
                            ResolveConnector.shared.writeViaConsoleBridge(markersJSON: payload) { ok, info in
                                DispatchQueue.main.async {
                                    processStatus = ok ? "Resolve (in-console): \(info)" : "Resolve error: \(info)"
                                    progress.finish(ok ? info : "Resolve error: \(info)")
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                processStatus = "Undo failed: \(err)"
                                progress.finish("Undo failed: \(err)")
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        processStatus = "Undo failed: \(output)"
                        progress.finish("Undo failed")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    processStatus = "Undo failed: \(error.localizedDescription)"
                    progress.finish("Undo failed")
                }
            }
        }
    }


    // -- Subtitle timeline actions --

    func durationString(rows: [DisplayRow], ids: Set<String>) -> String {
        let t = rows.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.entry.duration }
        guard t >= 1 else { return "—" }
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    func durationLabel(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        return m > 0 ? String(format: "%dm%02ds", m, s) : String(format: "%ds", s)
    }

    func toggleSelection(_ id: String) {
        if selectedEntryIDs.contains(id) { selectedEntryIDs.remove(id) }
        else { selectedEntryIDs.insert(id) }
    }

    func search() {
        queryDirty = false
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; selectedEntryIDs = []; return }

        isInterpreting = true
        subStore.statusMessage = "Interpreting prompt…"
        interpretPrompt(q) { searchTerms in
            DispatchQueue.main.async {
                isInterpreting = false
                let terms = searchTerms.isEmpty ? q : searchTerms
                lastSearchTerms = terms
                self.executeSearch(terms: terms)
            }
        }
    }

    func executeSearch(terms: String) {
        let lowered = terms.lowercased()

        if searchSource == .transcripts, subStore.isTranscriptsLoaded {
            let transcriptHits = subStore.searchTranscripts(lowered)
            let speakerFiltered = filterSpeakers.isEmpty
                ? transcriptHits
                : transcriptHits.filter { filterSpeakers.contains($0.speaker) }
            let fileFiltered = filterSourceFiles.isEmpty
                ? speakerFiltered
                : speakerFiltered.filter { filterSourceFiles.contains($0.sourceFile) }
            searchResults = fileFiltered.map { SubSearchHit(entry: $0) }
            selectedEntryIDs = Set(searchResults.map(\.id))
            subStore.statusMessage = "\(searchResults.count) paragraph(s) from transcripts"
            smartOrder = nil
            applySort()
            return
        }

        if subStore.isTranscriptsLoaded, lowered.contains(" ") {
            let transcriptHits = subStore.searchTranscripts(lowered)
            var allSubs: [SubSearchHit] = []
            var seen = Set<String>()
            for te in transcriptHits {
                let subs = subStore.findMatchingSubtitles(for: te)
                for sub in subs {
                    if seen.insert(sub.id).inserted {
                        allSubs.append(sub)
                    }
                }
            }
            if !allSubs.isEmpty {
                searchResults = allSubs
                selectedEntryIDs = Set(allSubs.map(\.id))
                subStore.statusMessage = "\(allSubs.count) sentence(s) from \(transcriptHits.count) transcript match(es)"
                smartOrder = nil
                applySort()
                return
            }
        }

        let results = subStore.search(query: terms, filterSourceFiles: filterSourceFiles)
        let speakerFiltered: [SubSearchHit]
        if filterSpeakers.isEmpty {
            speakerFiltered = results
        } else {
            speakerFiltered = results.filter { filterSpeakers.contains($0.entry.speaker) }
        }
        if speakerFiltered.isEmpty {
            let exact = subStore.exactSearch(lowered)
            let exactFiltered = filterSourceFiles.isEmpty ? exact : exact.filter { filterSourceFiles.contains($0.entry.sourceFile) }
            let exactSpeakerFiltered = filterSpeakers.isEmpty ? exactFiltered : exactFiltered.filter { filterSpeakers.contains($0.entry.speaker) }
            searchResults = exactSpeakerFiltered
            selectedEntryIDs = Set(exactSpeakerFiltered.map(\.id))
            subStore.statusMessage = "\(exactSpeakerFiltered.count) sentence(s) (exact match)"
        } else {
            searchResults = speakerFiltered
            selectedEntryIDs = Set(speakerFiltered.map(\.id))
            subStore.statusMessage = "\(speakerFiltered.count) sentence(s)"
        }
        smartOrder = nil
        applySort()
    }

    func interpretPrompt(_ prompt: String, completion: @escaping (String) -> Void) {
        let system = PrimingRegistry.stage(for: "priming_searchInterpretation")?.load() ?? ""

        DispatchQueue.main.async {
            reasoningMessages.append(("user", prompt))
        }

        OMLXClient.shared.complete(
            system: system,
            prompt: prompt,
            temperature: 0.1,
            maxTokens: 1024,
            timeout: 60
        ) { result in
            guard let response = result.text, result.error == nil else {
                DispatchQueue.main.async {
                    reasoningMessages.append(("assistant", "⚠️ \(result.error ?? "No response from oMLX")"))
                }
                completion("")
                return
            }
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                reasoningMessages.append(("assistant", trimmed))
            }
            completion(trimmed.isEmpty ? prompt : trimmed)
        }
    }

    func applySort() {
        switch sortOrder {
        case .chronological:
            searchResults.sort { a, b in
                if a.entry.sourceFile == b.entry.sourceFile {
                    return a.entry.start_s < b.entry.start_s
                }
                return a.entry.sourceFile < b.entry.sourceFile
            }
        case .speaker:
            searchResults.sort { $0.entry.speaker.localizedCompare($1.entry.speaker) == .orderedAscending }
        case .location:
            searchResults.sort { $0.entry.location.localizedCompare($1.entry.location) == .orderedAscending }
        case .relevance:
            searchResults.sort { $0.similarity > $1.similarity }
        case .prompt:
            if let order = smartOrder {
                searchResults = order.compactMap { searchResults.indices.contains($0) ? searchResults[$0] : nil }
            } else {
                searchResults.sort { $0.similarity > $1.similarity }
                promptSort()
            }
        }
    }

    func promptSort() {
        let entries = searchResults.enumerated().map { "\($0). \"\($1.entry.text)\" — \($1.entry.speaker)" }.joined(separator: "\n")
        let system = PrimingRegistry.stage(for: "priming_promptSort")?.load() ?? "Reorder the subtitle entries so they tell the most coherent narrative for the user's request. Return only the entry numbers in the new order as a comma-separated list. No explanation."
        let userMsg = "Request: \(query)\n\nEntries:\n\(entries)"

        DispatchQueue.main.async {
            reasoningMessages.append(("user", "Prompt sort: \(query) (\(searchResults.count) entries)"))
        }

        subStore.statusMessage = "Reordering by prompt…"
        OMLXClient.shared.complete(
            system: system,
            prompt: userMsg,
            temperature: 0.1,
            maxTokens: 1024,
            timeout: 60
        ) { [self] result in
            guard let response = result.text, result.error == nil else {
                DispatchQueue.main.async {
                    subStore.statusMessage = result.error != nil
                        ? "Prompt sort failed: \(result.error!)"
                        : "Prompt sort failed — kept relevance order"
                }
                return
            }
            let indices = response
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !indices.isEmpty else {
                DispatchQueue.main.async { subStore.statusMessage = "Prompt sort returned nothing — kept relevance order" }
                return
            }
            DispatchQueue.main.async {
                reasoningMessages.append(("assistant", response.trimmingCharacters(in: .whitespacesAndNewlines)))
                smartOrder = indices
                searchResults = indices.compactMap { searchResults.indices.contains($0) ? searchResults[$0] : nil }
                subStore.statusMessage = "\(searchResults.count) sentence(s) — sorted by prompt"
            }
        }
    }

    func createTimeline(rows: [DisplayRow]? = nil, ids: Set<String>? = nil) {
        let r = rows ?? displayRows
        let i = ids ?? resolvedIDs
        let selected = r.filter { i.contains($0.id) }
        guard !selected.isEmpty else { return }

        isCreating = true
        subStore.statusMessage = "Creating timeline in Resolve…"
        progress.start("Creating timeline…")

        let name = sanitizeName(query) + "_" + timestamp()
        let entries: [TimelineEntry] = selected.enumerated().compactMap { (idx, row) in
            guard !row.isDivider else { return nil }
            let e = row.entry
            let groupId: Int = {
                switch row {
                case .match(let hit):
                    return searchResults.firstIndex(where: { $0.id == hit.id }) ?? idx
                case .context(_, let hitIdx):
                    return hitIdx
                case .divider:
                    return idx
                }
            }()
            return TimelineEntry(start_s: e.start_s, end_s: e.end_s,
                                 name: e.speaker + ": " + String(e.text.prefix(60)),
                                 notes: contextualExcerpt(text: e.text, query: query),
                                 color: row.isContext ? "Orange" : "Blue",
                                 interview: e.interview,
                                 folder: e.folder,
                                 location: e.location,
                                 sourceFile: e.sourceFile,
                                 groupId: groupId,
                                 subtitleText: e.text,
                                 speaker: e.speaker)
        }
        let request = TimelineRequest(name: name, markers: entries, groupGapFrames: Int(round(groupGap * 25)), addSubtitles: addSubtitles, srtFolder: srtFolder)
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(request) else {
            subStore.statusMessage = "Failed to encode request"
            isCreating = false
            progress.finish("Failed to encode request")
            return
        }

        let env: [String: String] = [:] // Auto-detect Resolve install

        DispatchQueue.global().async {
            do {
                // Scale timeout with assembly size — a fixed 120s killed large timelines mid-build
                let timelineTimeout = 180.0 + Double(entries.count) * 6.0
                let output = try PythonBridge.runRaw("create_timeline", stdin: jsonData, envOverrides: env, timeoutSeconds: timelineTimeout)
                if let data = output.data(using: .utf8),
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result["status"] as? String == "ok" {
                        let total = result["total_markers"] as? Int ?? 0
                        let failed = result["failed"] as? Int ?? 0
                        let tlName = result["name"] as? String ?? name
                        var msg = "Timeline \"\(tlName)\" created: \(total) sentence(s)."
                        if failed > 0 { msg += " \(failed) failed." }
                        if let srt = result["srt_path"] as? String, !srt.isEmpty {
                            msg += " Subtitles written to \(URL(fileURLWithPath: srt).lastPathComponent)."
                            let url = URL(fileURLWithPath: srt)
                            DispatchQueue.main.async {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        DispatchQueue.main.async {
                            subStore.statusMessage = msg
                            isCreating = false
                            progress.finish(msg)
                        }
                    } else {
                        let err = result["error"] as? String ?? "Unknown error"
                        if err.contains("Could not connect to Resolve") {
                            DispatchQueue.main.async {
                                subStore.statusMessage = "External helper not responding — trying in-console bridge…"
                                progress.finish("Trying in-console bridge…")
                            }
                            ResolveConnector.shared.writeViaConsoleBridge(markersJSON: jsonData) { ok, info in
                                    DispatchQueue.main.async {
                                        subStore.statusMessage = ok ? "Resolve (in-console): \(info)" : "Resolve error: \(info)"
                                        isCreating = false
                                        progress.finish(ok ? info : "Resolve error: \(info)")
                                    }
                                }
                        } else {
                            DispatchQueue.main.async {
                                subStore.statusMessage = "Error: \(err)"
                                isCreating = false
                                progress.finish("Error: \(err)")
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        subStore.statusMessage = output
                        isCreating = false
                        progress.finish(output)
                    }
                }
            } catch {
                let msg = error.localizedDescription
                if msg.contains("Could not connect to Resolve") {
                    DispatchQueue.main.async {
                        subStore.statusMessage = "External helper not responding — trying in-console bridge…"
                        progress.finish("Trying in-console bridge…")
                    }
                    ResolveConnector.shared.writeViaConsoleBridge(markersJSON: jsonData) { ok, info in
                        DispatchQueue.main.async {
                            subStore.statusMessage = ok ? "Resolve (in-console): \(info)" : "Resolve error: \(info)"
                            isCreating = false
                            progress.finish(ok ? info : "Resolve error: \(info)")
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    subStore.statusMessage = "Error: \(msg)"
                    isCreating = false
                    progress.finish("Error: \(msg)")
                }
            }
        }
    }

}
