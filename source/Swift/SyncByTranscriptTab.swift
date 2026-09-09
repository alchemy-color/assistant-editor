import SwiftUI
import UniformTypeIdentifiers

struct SyncByTranscriptTab: View {
    @EnvironmentObject var progress: AppProgress
    @AppStorage("timelineFPS") private var timelineFPS: Double = 25

    @AppStorage("lastSyncTimelineFolder") private var lastSyncFolder = ""

    @State private var syncFolder: String?
    @State private var fieldRecorderFile: String?
    @State private var timelineSrtFile: String?
    @State private var edlFile: String?
    @State private var syncResults: [SyncClipResult] = []
    @State private var isSyncing = false
    @State private var showResults = false
    @State private var buildStatus: String?
    @State private var isBuilding = false
    @State private var sortOrder: SyncSortOrder = .confidence

    enum SyncSortOrder: String, CaseIterable {
        case confidence = "Confidence"
        case name = "Name"
        case timecode = "Timecode"
    }

    struct SyncFromTimelineResponse: Decodable {
        let results: [SyncClipResult]?
        let error: String?
    }

    var sortedResults: [SyncClipResult] {
        switch sortOrder {
        case .confidence: return syncResults.sorted { $0.confidence > $1.confidence }
        case .name:       return syncResults.sorted { $0.clipName < $1.clipName }
        case .timecode:   return syncResults.sorted { $0.syncTimeS < $1.syncTimeS }
        }
    }

    var allSelected: Bool {
        fieldRecorderFile != nil && timelineSrtFile != nil && edlFile != nil
    }

    @AppStorage("syncLeftWidth") private var syncLeftWidth: Double = 420
    @State private var syncLeftSnapshot: Double = 420

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync by Transcript")
                    .scaledFont(.title2)
                Spacer()
            }
            .padding(.horizontal, UIDesign.padH)
            .padding(.top, UIDesign.padHeaderTop)
            .padding(.bottom, 4)

            Divider()

            workFolderBar

            Divider()

            HStack(spacing: 0) {
                filePanel
                    .frame(width: max(300, syncLeftWidth))
                DragDivider(
                    onStart: { syncLeftSnapshot = syncLeftWidth },
                    onChanged: { t in
                        syncLeftWidth = min(700, max(300, syncLeftSnapshot + Double(t)))
                    }
                )
                resultsPanel
                    .frame(minWidth: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { restoreLastFolder() }
    }

    /// Restores the last-used sync folder on launch (single-folder tab).
    private func restoreLastFolder() {
        guard syncFolder == nil, !lastSyncFolder.isEmpty,
              FileManager.default.fileExists(atPath: lastSyncFolder) else { return }
        syncFolder = lastSyncFolder
        detectFiles(in: lastSyncFolder)
    }

    private var workFolderBar: some View {
        WorkFolderBar(
            folders: (syncFolder?.isEmpty ?? true) ? [] : [syncFolder!],
            emptyPrompt: "Choose sync folder…",
            onAdd: { chooseFolder() },
            onRemove: { _ in
                syncFolder = ""
                lastSyncFolder = ""
            },
            onRescan: { if let f = syncFolder { detectFiles(in: f) } },
            onClear: {
                syncFolder = ""
                lastSyncFolder = ""
            }
        ) {
            EmptyView()
        }
    }


    // MARK: - Left Panel

    var filePanel: some View {
        VStack(spacing: 0) {
            Text("Sync from Timeline")
                .scaledFont(.title2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, UIDesign.padH)
                .padding(.top, UIDesign.padHeaderTop)
                .padding(.bottom, 4)

            Divider().padding(.vertical, 8)

            // Folder picker
            HStack {
                if let folder = syncFolder {
                    Image(systemName: "folder.fill").foregroundColor(.accentColor)
                    Text(folder).scaledFont(.subheadline).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseFolder() }
                        .buttonStyle(.plain).foregroundColor(.accentColor)
                } else {
                    Button("Choose Timeline Folder…") { chooseFolder() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(.horizontal, UIDesign.padH)
            .padding(.bottom, 8)

            Divider()

            if let folder = syncFolder {
                VStack(alignment: .leading, spacing: 6) {
                    statusRow("Field Recording", path: fieldRecorderFile)
                    statusRow("Timeline Subtitles", path: timelineSrtFile)
                    statusRow("EDL", path: edlFile)
                }
                .padding(.horizontal, UIDesign.padH)
                .padding(.vertical, 8)

                Spacer()

                Divider()

                HStack {
                    Spacer()
                    if isSyncing {
                        ProgressView().controlSize(.small)
                        Text("Syncing…").scaledFont(.subheadline).foregroundColor(.secondary)
                    }
                    Button("Run Sync") { runSync() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!allSelected || isSyncing)
                }
                .padding(.horizontal, UIDesign.padH)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func statusRow(_ label: String, path: String?) -> some View {
        HStack {
            Text(label).scaledFont(.caption).foregroundColor(.secondary).frame(width: 110, alignment: .trailing)
            if let p = path {
                Image(systemName: "checkmark.circle.fill").scaledFont(.caption).foregroundColor(.green)
                Text(URL(fileURLWithPath: p).lastPathComponent)
                    .scaledFont(.caption).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Not found").scaledFont(.caption).foregroundColor(.red)
            }
            Spacer()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose folder containing field recording SRTX, timeline SRT, and EDL"
        if !lastSyncFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: lastSyncFolder)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        syncFolder = url.path
        lastSyncFolder = url.path
        detectFiles(in: url.path)
    }

    func detectFiles(in folder: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder) else { return }

        // Heuristic auto-detection
        var edl: String?
        var timelineSrt: String?
        var fieldSrtx: String?

        for item in items {
            let lower = item.lowercased()
            let full = (folder as NSString).appendingPathComponent(item)

            if item.hasSuffix(".edl") {
                edl = full
            } else if item == "timeline subtitle.srt" || (lower.contains("timeline") && item.hasSuffix(".srt")) {
                timelineSrt = full
            } else if item == "Field recorded subtitles.srtx" || (lower.contains("field") && item.hasSuffix(".srtx")) {
                fieldSrtx = full
            }
        }

        // If not found by name, use fallback heuristics
        let srtxFiles = items.filter { $0.hasSuffix(".srtx") }
        let srtFiles = items.filter { $0.hasSuffix(".srt") }

        if fieldSrtx == nil, !srtxFiles.isEmpty {
            // Pick the srtx that's not the rough file
            fieldSrtx = srtxFiles.first.map { (folder as NSString).appendingPathComponent($0) }
        }
        if timelineSrt == nil, !srtFiles.isEmpty {
            // Pick the srt that's not "Field recorded"
            let candidates = srtFiles.filter { !$0.lowercased().contains("field") }
            if let c = candidates.first {
                timelineSrt = (folder as NSString).appendingPathComponent(c)
            }
        }

        fieldRecorderFile = fieldSrtx
        timelineSrtFile = timelineSrt
        edlFile = edl
        showResults = false
        syncResults = []
        buildStatus = nil
    }

    // MARK: - Right Panel

    var resultsPanel: some View {
        VStack(spacing: 0) {
            if showResults && !syncResults.isEmpty {
                summaryBar
                    .padding(.horizontal, UIDesign.padH)
                    .padding(.vertical, 6)
                sortBar
                    .padding(.horizontal, UIDesign.padH)
                    .padding(.vertical, 4)
                Divider()
                resultsTable
                    .frame(maxHeight: .infinity)
                Divider()
                buildBar
                    .padding(.horizontal, UIDesign.padH)
                    .padding(.vertical, 8)
            } else if showResults {
                EmptyStateView(
                    icon: "waveform",
                    title: "No sync results returned"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "waveform",
                    title: "Choose a folder with subtitles and EDL"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var resultsTable: some View {
        List {
            HStack {
                Text("Clip").scaledFont(.caption).foregroundColor(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text("Sync TC").scaledFont(.caption).foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text("Confidence").scaledFont(.caption).foregroundColor(.secondary)
                    .frame(minWidth: 100, alignment: .leading)
                Text("Matches").scaledFont(.caption).foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Text("Duration").scaledFont(.caption).foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Spacer()
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            ForEach(sortedResults) { result in
                VStack(spacing: 1) {
                    HStack {
                        Text(result.clipName)
                            .scaledFont(.subheadline).lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        Text(secondsToTc(result.syncTimeS))
                            .scaledFont(.subheadline, design: .monospaced)
                            .frame(width: 90, alignment: .leading)
                            .foregroundColor(result.confidence < 0.3 ? .secondary : .primary)
                        HStack(spacing: 4) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.15)).frame(height: 10)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(confidenceColor(result.confidence))
                                        .frame(width: geo.size.width * CGFloat(result.confidence), height: 10)
                                }
                            }
                            .frame(width: 50)
                            Text("\(Int(result.confidence * 100))%")
                                .scaledFont(.caption, design: .monospaced).foregroundColor(.secondary)
                        }
                        .frame(minWidth: 100, alignment: .leading)
                        Text("\(result.matchedPhrases.count)")
                            .scaledFont(.subheadline)
                            .frame(width: 50, alignment: .trailing)
                        Text(formattedDuration(result.clipDurationS))
                            .scaledFont(.caption, design: .monospaced)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    if !result.matchedPhrases.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").scaledFont(.caption2).foregroundColor(.green)
                            Text(result.matchedPhrases.prefix(5).joined(separator: "  ·  "))
                                .scaledFont(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                            if result.matchedPhrases.count > 5 {
                                Text("+\(result.matchedPhrases.count - 5)").scaledFont(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 2)
                    }

                    if let error = result.error {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").scaledFont(.caption).foregroundColor(.red)
                            Text(error).scaledFont(.caption).foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.visible)
                .listRowBackground(
                    result.confidence < 0.3 ? Color.red.opacity(0.04)
                    : result.confidence < 0.6 ? Color.orange.opacity(0.04)
                    : Color.clear
                )
            }
        }
        .listStyle(.plain)
        .editorCard()
    }

    var summaryBar: some View {
        HStack {
            let ok = syncResults.filter { $0.confidence >= 0.3 }.count
            let low = syncResults.filter { $0.confidence < 0.3 && $0.error == nil }.count
            let err = syncResults.filter { $0.error != nil }.count
            Text("\(ok) synced, \(low) low confidence, \(err) errors")
                .scaledFont(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text("\(syncResults.count) clip(s)").scaledFont(.subheadline).foregroundColor(.secondary)
        }
    }

    var sortBar: some View {
        HStack {
            Text("Results").scaledFont(.subheadline).foregroundColor(.secondary)
            Spacer()
            Picker("Sort", selection: $sortOrder) {
                ForEach(SyncSortOrder.allCases, id: \.rawValue) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
        }
    }

    var buildBar: some View {
        HStack {
            if let status = buildStatus {
                Image(systemName: status.hasPrefix("Error") ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundColor(status.hasPrefix("Error") ? .red : .green).scaledFont(.caption)
                Text(status).scaledFont(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if isBuilding {
                ProgressView().controlSize(.small)
                Text("Building timeline in Resolve…").scaledFont(.subheadline).foregroundColor(.secondary)
            }
            Button("Export EDL") { exportSyncEDL() }
                .controlSize(.small)
                .disabled(syncResults.isEmpty)
            Button("Create Sync Timeline") { buildTimeline() }
                .buttonStyle(.borderedProminent)
                .disabled(isBuilding || syncResults.isEmpty)
        }
    }

    // MARK: - Sync

    func runSync() {
        guard let fr = fieldRecorderFile, let tsrt = timelineSrtFile, let edl = edlFile else { return }
        isSyncing = true
        showResults = false
        progress.start("Syncing from timeline…")

        let req: [String: String] = [
            "field_recorder": fr,
            "timeline_srt": tsrt,
            "edl": edl,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: req) else {
            progress.finish("Failed to encode request")
            isSyncing = false
            return
        }

        DispatchQueue.global().async {
            do {
                let raw = try PythonBridge.runRaw("sync_from_timeline",
                    args: [], stdin: jsonData, envOverrides: ["AE_FPS": String(format: "%g", timelineFPS)], timeoutSeconds: 300)
                DispatchQueue.main.async {
                    guard let data = raw.data(using: .utf8) else {
                        progress.finish("Failed to parse sync output (encoding)")
                        isSyncing = false
                        return
                    }
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    guard let response = try? decoder.decode(SyncFromTimelineResponse.self, from: data) else {
                        progress.finish("Failed to parse sync output")
                        isSyncing = false
                        return
                    }
                    if let error = response.error {
                        progress.finish("Sync failed: \(error)")
                    } else if let results = response.results {
                        let ok = results.filter { $0.confidence >= 0.3 }.count
                        syncResults = results
                        showResults = true
                        progress.finish("\(ok)/\(results.count) clips synced")
                    }
                    isSyncing = false
                }
            } catch {
                DispatchQueue.main.async {
                    progress.finish("Sync error: \(error.localizedDescription)")
                    isSyncing = false
                }
            }
        }
    }

    func buildTimeline() {
        guard let fr = fieldRecorderFile else { return }
        isBuilding = true
        buildStatus = nil

        let buildReq: [String: Any] = [
            "field_recorder": fr,
            "results": syncResults.map { r -> [String: Any] in
                [
                    "clip_name": r.clipName,
                    "clip_path": r.clipPath,
                    "sync_time_s": r.syncTimeS,
                    "confidence": r.confidence,
                    "clip_duration_s": r.clipDurationS,
                    "field_recorder_duration_s": r.fieldRecorderDurationS,
                    "matched_phrases": r.matchedPhrases,
                ]
            },
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: buildReq) else {
            buildStatus = "Failed to encode build request"
            isBuilding = false
            return
        }

        DispatchQueue.global().async {
            do {
                let raw = try PythonBridge.runRaw("build_sync_timeline",
                    args: [], stdin: jsonData, envOverrides: ["AE_FPS": String(format: "%g", timelineFPS)], timeoutSeconds: 120)
                DispatchQueue.main.async {
                    struct BuildResponse: Decodable {
                        let status: String?
                        let error: String?
                        let timelineName: String?
                        let edlEvents: Int?
                        let markersOnly: [BuildMarkerOnly]?
                    }
                    struct BuildMarkerOnly: Decodable {
                        let clip: String?
                        let reason: String?
                    }
                    // Python emits snake_case keys — convert instead of failing.
                    let dec = JSONDecoder()
                    dec.keyDecodingStrategy = .convertFromSnakeCase
                    guard let data = raw.data(using: .utf8),
                          let resp = try? dec.decode(BuildResponse.self, from: data) else {
                        buildStatus = "Failed to parse build output"
                        isBuilding = false
                        return
                    }
                    if let error = resp.error {
                        buildStatus = "Error: \(error)"
                    } else if resp.status == "ok" {
                        let n = resp.edlEvents ?? 0
                        var msg = "Timeline '\(resp.timelineName ?? "?")' built with \(n) clip(s)"
                        if let reasons = resp.markersOnly, !reasons.isEmpty {
                            let skipped = reasons.compactMap { $0.clip }.prefix(3).joined(separator: ", ")
                            msg += " · unmatched: \(skipped)\(reasons.count > 3 ? "…" : "")"
                        }
                        buildStatus = msg
                    }
                    isBuilding = false
                }
            } catch {
                DispatchQueue.main.async {
                    buildStatus = "Build error: \(error.localizedDescription)"
                    isBuilding = false
                }
            }
        }
    }

    func exportSyncEDL() {
        guard let fr = fieldRecorderFile else { return }
        let buildReq: [String: Any] = [
            "field_recorder": fr,
            "results": syncResults.map { r -> [String: Any] in
                [
                    "clip_name": r.clipName,
                    "clip_path": r.clipPath,
                    "sync_time_s": r.syncTimeS,
                    "confidence": r.confidence,
                    "clip_duration_s": r.clipDurationS,
                    "field_recorder_duration_s": r.fieldRecorderDurationS,
                    "matched_phrases": r.matchedPhrases,
                ]
            },
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: buildReq) else {
            buildStatus = "Failed to encode EDL request"
            return
        }
        // Ask where to save first (on main), then generate + write off-main.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.unixExecutable]
        panel.nameFieldStringValue = "sync_timeline.edl"
        panel.message = "Choose where to save the sync EDL"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        DispatchQueue.global().async {
            do {
                let edl = try PythonBridge.runRaw("export_sync_edl",
                    args: [], stdin: jsonData, envOverrides: ["AE_FPS": String(format: "%g", timelineFPS)], timeoutSeconds: 30)
                try edl.data(using: .utf8)?.write(to: target)
                DispatchQueue.main.async {
                    buildStatus = "EDL exported to \(target.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    buildStatus = "EDL export error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Helpers

    func confidenceColor(_ c: Double) -> Color {
        if c >= 0.7 { return .green }
        if c >= 0.4 { return .orange }
        return .red
    }

    func formattedDuration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s))s" }
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return "\(m)m\(sec)s"
    }
}
