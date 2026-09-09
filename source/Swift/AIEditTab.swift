import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AIEditTab: View {
    @ObservedObject var subStore: SubtitleStore
    @ObservedObject var docStore: DocumentStore
    @EnvironmentObject var progress: AppProgress
    @AppStorage("projectThemesJSON") private var projectThemesJSON = "[]"

    init(subStore: SubtitleStore, docStore: DocumentStore) {
        self.subStore = subStore
        self.docStore = docStore
    }
    @AppStorage("aiEditRetrievalExpanded") private var retrievalExpanded = false
    @AppStorage("aiEditTimelineExpanded") private var timelineExpanded = true
    @State private var treatmentExpanded = false

    private var projectThemes: [ProjectTheme] {
        (try? JSONDecoder().decode([ProjectTheme].self, from: projectThemesJSON.data(using: .utf8) ?? Data())) ?? []
    }

    private var timelineSummary: String {
        var parts: [String] = []
        if let name = aiStore.parsedTitle, !name.isEmpty { parts.append(name) }
        if let dur = aiStore.estimatedDuration, dur > 0 { parts.append("~\(Int(dur))s") }
        return parts.isEmpty ? "unnamed" : parts.joined(separator: " \u{00B7} ")
    }

    @StateObject private var aiStore = AIEditStore()

    @AppStorage("aiEditSplitRatio") private var splitRatio: Double = 0.45
    @State private var splitRatioSnapshot: Double = 0.45
    @State private var restoredFolders = false
    @State private var showClearAlert = false
    @State private var materialTrees: [MaterialNode] = []
    @State private var materialsExpanded = true
    @State private var draggedBeatID: UUID?
    @State private var dropTargets: [UUID: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Edit")
                    .scaledFont(.title2)
                Spacer()
            }
            .padding(.horizontal, UIDesign.padH)
            .padding(.top, UIDesign.padHeaderTop)
            .padding(.bottom, 4)

            Divider()

            WorkFolderBar(
                folders: aiStore.folders,
                emptyPrompt: "Select source folder…",
                onAdd: { pickFolder() },
                onRemove: { removeFolder($0) },
                onRescan: { applyFolders(aiStore.folders, force: true) },
                onClear: { showClearAlert = true }
            ) {
                if subStore.isLoading || subStore.isTranscriptsLoading {
                    ProgressView().scaleEffect(0.7)
                } else if subStore.isLoaded || subStore.isTranscriptsLoaded {
                    Label(subStore.isTranscriptsLoaded
                          ? "\(subStore.entries.count)+\(subStore.transcriptEntries.count)"
                          : "\(subStore.entries.count)",
                          systemImage: "checkmark.circle.fill")
                        .scaledFont(.caption2)
                        .foregroundColor(.green)
                        .help("Cues+paragraphs loaded")
                } else if !subStore.statusMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subStore.statusMessage)
                            .scaledFont(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                        Button("Force Rebuild") { applyFolders(aiStore.folders, force: true) }
                            .scaledFont(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                    }
                } else {
                    Label("not loaded", systemImage: "exclamationmark.circle")
                        .scaledFont(.caption2)
                        .foregroundColor(.orange)
                }
            }
            .confirmationDialog(
                "Remove all folders and clear loaded subtitles/transcripts?",
                isPresented: $showClearAlert,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    aiStore.setFolders([])
                    subStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }

            Divider()

            if !aiStore.folders.isEmpty {
                MaterialTreeView(trees: materialTrees, expanded: $materialsExpanded)
            }

            Divider()

            GeometryReader { geo in
                HStack(spacing: 0) {
                    leftPanel
                        .frame(width: geo.size.width * splitRatio)
                    DragDivider(
                        onStart: { splitRatioSnapshot = splitRatio },
                        onChanged: { t in
                            splitRatio = min(0.7, max(0.28, splitRatioSnapshot + Double(t / max(geo.size.width, 1))))
                        }
                    )
                    rightPanel
                        .frame(minWidth: geo.size.width * (1 - splitRatio))
                }
            }
        }
        .onAppear {
            aiStore.rescanMaterials()
            restoreFoldersIfNeeded()
            installEscapeMonitor()
        }
    }

    // MARK: - Left Panel (Structured Editor)

    var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Edit") {
                Group {
                    if !aiStore.folders.isEmpty {
                        HStack(spacing: 6) {
                            StatusChip(label: "Synopsis", count: aiStore.materials.synopsisCount, icon: "doc.text")
                            StatusChip(label: "Chapters", count: aiStore.materials.chaptersCount, icon: "flag")
                            StatusChip(label: "Transcripts", count: aiStore.materials.transcriptCount, icon: "doc.plaintext")
                            StatusChip(label: "Subtitles", count: aiStore.materials.subtitleCount, icon: "captions.bubble")

                            Button(action: { aiStore.rescanMaterials() }) {
                                Image(systemName: "arrow.clockwise")
                                    .scaledFont(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Rescan materials")

                            if !aiStore.scriptText.isEmpty || !aiStore.beats.isEmpty {
                                Divider().frame(height: 12)
                                Button(action: { aiStore.clearAll() }) {
                                    Image(systemName: "trash")
                                        .help("Clear treatment, beats, and clips")
                                }
                                .buttonStyle(.plain)
                                .disabled(aiStore.isParsing || aiStore.isAssembling)
                            }
                        }
                    } else if !aiStore.scriptText.isEmpty || !aiStore.beats.isEmpty {
                        Button(action: { aiStore.clearAll() }) {
                            Image(systemName: "trash")
                                .help("Clear treatment, beats, and clips")
                        }
                        .buttonStyle(.plain)
                        .disabled(aiStore.isParsing || aiStore.isAssembling)
                    }
                }
            }

            // MARK: Timeline metadata — names the edit and its intent

            CollapseHeader(
                title: "Timeline",
                systemImage: "film",
                summary: timelineSummary,
                isCollapsed: !timelineExpanded,
                onToggle: { withAnimation(.easeInOut(duration: 0.15)) { timelineExpanded.toggle() } }
            )
            .padding(.horizontal, UIDesign.padH)
            .padding(.bottom, 8)

            if timelineExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Name")
                            .scaledFont(.caption2, weight: .semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        TextField("e.g. Relics of the Coast \u{2014} Teaser",
                                  text: Binding(
                                    get: { aiStore.parsedTitle ?? "" },
                                    set: { aiStore.parsedTitle = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                                  prompt: Text("Timeline name \u{2014} names the Resolve timeline")
                                    .foregroundColor(.secondary.opacity(0.5)))
                            .textFieldStyle(.roundedBorder)
                            .scaledFont(.caption)
                        TextField("est", value: Binding(
                            get: { aiStore.estimatedDuration ?? 0 },
                            set: { aiStore.estimatedDuration = $0 > 0 ? $0 : nil }
                        ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .scaledFont(.caption, monospacedDigit: true)
                            .frame(width: 52)
                            .help("Estimated timeline length in seconds (editable)")
                        Text("sec")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Text("Intent")
                            .scaledFont(.caption2, weight: .semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                            .padding(.top, 5)
                        TextField("Short description \u{2014} what this edit is trying to say\u{2026}",
                                  text: aiStore.intentBinding,
                                  axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                            .scaledFont(.caption)
                    }
                    Toggle("Append timestamp to the timeline name (_HHMMSS)", isOn: $aiStore.includeNameTimestamp)
                        .toggleStyle(.checkbox)
                        .scaledFont(.caption2)
                        .help("Append _HHMMSS to the created timeline name")
                }
                .padding(.horizontal, UIDesign.padH)
                .padding(.bottom, 8)
            }

            // MARK: Treatment drawer

            CollapseHeader(
                title: "Treatment",
                systemImage: "doc.text",
                summary: aiStore.scriptText.isEmpty ? "empty" : "\(aiStore.scriptText.count) chars",
                isCollapsed: !treatmentExpanded,
                onToggle: { withAnimation(.easeInOut(duration: 0.15)) { treatmentExpanded.toggle() } }
            )
            .padding(.horizontal, UIDesign.padH)
            .padding(.bottom, 8)

            if treatmentExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $aiStore.scriptText)
                            .scaledFont(.body, design: .default)
                            .scrollContentBackground(.visible)
                        if aiStore.scriptText.isEmpty {
                            Text("Paste your script, treatment, or outline here\u{2026}")
                                .scaledFont(.body)
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )

                    Button(action: { autoFillFromText() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .scaledFont(.caption)
                            Text("Auto-fill from text")
                                .scaledFont(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiStore.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || aiStore.isParsing || aiStore.isAssembling)
                    .help("Parse the treatment into structured beats")
                }
                .padding(.horizontal, UIDesign.padH)
                .padding(.bottom, 8)
            }

            // MARK: Retrieval tuning (advanced — last in the setup cluster)

            CollapseHeader(
                title: "Retrieval",
                systemImage: "slider.horizontal.3",
                summary: "\(Int(aiStore.candidateCap)) candidates · ≤\(Int(aiStore.maxClipsPerBeat)) clips\(aiStore.useSynopsisInSelection ? " · synopsis" : "")",
                isCollapsed: !retrievalExpanded,
                onToggle: { withAnimation(.easeInOut(duration: 0.15)) { retrievalExpanded.toggle() } }
            )
            .padding(.horizontal, UIDesign.padH)
            .padding(.bottom, 8)

            if retrievalExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    CompactSliderRow(
                        label: "Candidates", value: $aiStore.candidateCap,
                        range: 8...48, step: 4, format: "%.0f", labelWidth: 80,
                        onValueChange: {}
                    )
                    CompactSliderRow(
                        label: "Clips / beat", value: $aiStore.maxClipsPerBeat,
                        range: 1...8, step: 1, format: "%.0f", labelWidth: 80,
                        onValueChange: {}
                    )
                    Toggle("Ground selection in synopses", isOn: $aiStore.useSynopsisInSelection)
                        .scaledFont(.caption)
                        .toggleStyle(.checkbox)
                }
                .padding(.horizontal, UIDesign.padH)
                .padding(.bottom, 8)
            }

            Divider()

            // MARK: Beat card list

            if aiStore.isParsing {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("AI is parsing your treatment\u{2026}")
                        .scaledFont(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if aiStore.beats.isEmpty {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No beats yet",
                    message: "Add beats manually with the + button below, or expand the Treatment drawer and click **Auto-fill from text** to have the AI break your treatment into beats."
                )
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(aiStore.beats.enumerated()), id: \.element.id) { idx, beat in
                            LeftBeatCard(
                                beat: binding(for: idx),
                                beatIndex: idx,
                                totalBeats: aiStore.beats.count,
                                busy: aiStore.isParsing || aiStore.isAssembling,
                                isDropTarget: dropTargets[beat.id] == true,
                                onDelete: { aiStore.removeBeat(at: IndexSet(integer: idx)) },
                                onMoveUp: idx > 0
                                    ? { aiStore.moveBeat(from: IndexSet(integer: idx), to: idx - 1) }
                                    : nil,
                                onMoveDown: idx < aiStore.beats.count - 1
                                    ? { aiStore.moveBeat(from: IndexSet(integer: idx), to: idx + 1) }
                                    : nil,
                                onFindClips: (!aiStore.folders.isEmpty && !aiStore.isAssembling && !aiStore.isParsing)
                                    ? { aiStore.findClips(for: idx, subStore: subStore, docStore: docStore, themes: projectThemes) }
                                    : nil
                            )
                            .onDrag {
                                draggedBeatID = beat.id
                                return NSItemProvider(object: beat.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], isTargeted: dropTargetBinding(for: beat.id)) { _ in
                                handleDrop(targetID: beat.id)
                            }
                        }
                    }
                    .padding(.horizontal, UIDesign.padH)
                }

                HStack {
                    Button(action: { aiStore.addBeat() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .scaledFont(.caption)
                            Text("Add beat")
                                .scaledFont(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiStore.isParsing || aiStore.isAssembling)

                    Button(action: { aiStore.undo() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .scaledFont(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!aiStore.canUndo || aiStore.isParsing || aiStore.isAssembling)
                    .help("Undo last beat change (add, delete, reorder, or edit)")

                    Button(action: { aiStore.redo() }) {
                        Image(systemName: "arrow.uturn.forward")
                            .scaledFont(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!aiStore.canRedo || aiStore.isParsing || aiStore.isAssembling)
                    .help("Redo last undone beat change")

                    if !aiStore.beats.isEmpty {
                        Spacer()
                        Button(action: { aiStore.removeAllBeats() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .scaledFont(.caption2)
                                Text("Remove all")
                                    .scaledFont(.caption2)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.secondary)
                        .disabled(aiStore.isParsing || aiStore.isAssembling)
                    }
                }
                .padding(.horizontal, UIDesign.padH)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            Divider()

            // MARK: Create Edit

            Button(action: {
                aiStore.findAllClips(subStore: subStore, docStore: docStore, themes: projectThemes)
            }) {
                HStack(spacing: 6) {
                    if aiStore.isAssembling {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(aiStore.isAssembling ? "Finding clips\u{2026}" : "Create Edit")
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .primaryActionBar()
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.defaultAction)
            .disabled(aiStore.beats.isEmpty || aiStore.isParsing || aiStore.isAssembling)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Right Panel (Beats)

    var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Beats") {
                if !aiStore.beats.isEmpty {
                    Text("\(aiStore.beats.count) beat\(aiStore.beats.count == 1 ? "" : "s")  \u{00B7}  \(aiStore.totalIncludedClips) clip\(aiStore.totalIncludedClips == 1 ? "" : "s")")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                    Divider().frame(height: 12)
                    Button(action: { aiStore.findAllClips(subStore: subStore, docStore: docStore, themes: projectThemes) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text("Find Clips")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!subStore.isLoaded && !subStore.isTranscriptsLoaded || aiStore.isAssembling)
                    .help("Search transcripts/subtitles for clips matching each beat")
                    Button(action: { aiStore.reviewFlow() }) {
                        HStack(spacing: 4) {
                            if aiStore.isReviewingFlow {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "text.badge.checkmark")
                            }
                            Text("Review Flow")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiStore.totalIncludedClips == 0 || aiStore.isReviewingFlow)
                    .help("AI reviews the selected sequence for narrative flow, jumps, and gaps")
                    Button(action: { aiStore.addBeat() }) {
                        Image(systemName: "plus")
                            .help("Add beat")
                    }
                    .buttonStyle(.plain)
                    .disabled(aiStore.isParsing || aiStore.isAssembling)
                    Button(action: { aiStore.removeAllBeats() }) {
                        Image(systemName: "trash")
                            .help("Remove all beats")
                    }
                    .buttonStyle(.plain)
                    .disabled(aiStore.isParsing || aiStore.isAssembling)
                }
            }

            if !aiStore.flowNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Flow Review", systemImage: "text.badge.checkmark")
                            .scaledFont(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button("Dismiss") { aiStore.flowNotes = [] }
                            .buttonStyle(.plain)
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                    ForEach(aiStore.flowNotes) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: note.severity == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .scaledFont(.caption2)
                                .foregroundColor(note.severity == "warning" ? .orange : .accentColor)
                                .frame(width: 14)
                            if let bi = note.beatIndex, aiStore.beats.indices.contains(bi) {
                                Text("\(bi + 1).")
                                    .scaledFont(.caption2, design: .monospaced)
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                            } else {
                                Text("·")
                                    .frame(width: 22)
                            }
                            Text(note.message)
                                .scaledFont(.caption2)
                                .foregroundColor(.primary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.07))
                .cornerRadius(6)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            beatsCard

            Spacer(minLength: 0)

            if aiStore.isAssembling {
                Divider()
                HStack {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Assembling clips\u{2026}")
                        .scaledFont(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if !aiStore.beats.isEmpty && aiStore.totalIncludedClips > 0 && !aiStore.isParsing {
                Divider()
                VStack(spacing: 8) {
                    if let name = aiStore.lastTimelineName {
                        HStack {
                            Spacer()
                            Label("Created: \(name)", systemImage: "checkmark.circle.fill")
                                .scaledFont(.caption)
                                .foregroundColor(.green)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 12) {
                        Menu {
                            Button(action: {
                                if let url = aiStore.exportEDL(markers: aiStore.clipsToMarkers(), fps: subStore.frameRate) {
                                    aiStore.statusMessage = "EDL saved: \(url.lastPathComponent)"
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }) {
                                Label("Export EDL", systemImage: "doc.text")
                            }
                            Button(action: {
                                if let url = aiStore.exportSubtitles(markers: aiStore.clipsToMarkers()) {
                                    aiStore.statusMessage = "Subtitles saved: \(url.lastPathComponent)"
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }) {
                                Label("Export Subtitles", systemImage: "captions.bubble")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export")
                                Image(systemName: "chevron.down")
                                    .scaledFont(.caption2)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        HStack(spacing: 5) {
                            Text("Markers:")
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                            Picker("", selection: Binding(
                                get: { aiStore.markerMode },
                                set: { aiStore.markerModeRaw = $0.rawValue })) {
                                ForEach(MarkerMode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .help("Which markers are written onto the created timeline:\n\u{00B7} Beat structure \u{2014} one spanning marker per beat\n\u{00B7} Clip descriptions \u{2014} one marker per clip, named from its text")
                        }

                        Spacer()

                        Text(aiStore.includedClipCount == 0
                             ? "No clips included"
                             : String(format: "%d clips · total %@",
                                      aiStore.includedClipCount,
                                      AIEditStore.formatLength(aiStore.assembledDurationS)))
                            .scaledFont(.caption, monospacedDigit: true)
                            .foregroundColor(aiStore.includedClipCount == 0 ? .secondary : .primary)
                            .help("Included clip time plus the gap between every adjacent clip")

                        HStack(spacing: 4) {
                            Text("Gap:")
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                            TextField("s", value: $aiStore.gapSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 40)
                                .scaledFont(.caption)
                            Text("s")
                                .scaledFont(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: { aiStore.createTimeline(progress: progress) }) {
                        HStack(spacing: 6) {
                            if aiStore.isCreating {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "film")
                            }
                            Text(aiStore.isCreating ? "Creating Timeline\u{2026}" : "Create Timeline in Resolve")
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .primaryActionBar()
                    .frame(maxWidth: .infinity)
                    .disabled(aiStore.isCreating || aiStore.totalIncludedClips == 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if let err = aiStore.lastError {
                Divider()
                Banner(kind: .error, text: err, onDismiss: { aiStore.lastError = nil })
            }
        }
    }

    // MARK: Beats card — header + body share the script editor's rounded styling

    private var beatsCard: some View {
        VStack(spacing: 0) {
            Group {
                if aiStore.isParsing {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("AI is parsing your script\u{2026}")
                            .scaledFont(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if aiStore.beats.isEmpty {
                    emptyState
                } else {
                    beatsList
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }


    // MARK: - Empty State

    var emptyState: some View {
        EmptyStateView(
            icon: "doc.text",
            title: "No clips yet",
            message: "Use the left panel to author beats, then click **Create Edit** to find matching clips from your material."
        )
    }

    // MARK: - Beats List

    var beatsList: some View {
        List {
            ForEach(Array(aiStore.beats.enumerated()), id: \.element.id) { idx, beat in
                BeatRow(
                    beat: binding(for: idx),
                    beatIndex: idx,
                    hasFolder: !aiStore.folders.isEmpty,
                    busy: aiStore.isParsing || aiStore.isAssembling
                )
            }
            .onMove { source, dest in
                guard !aiStore.isParsing, !aiStore.isAssembling else { return }
                aiStore.moveBeat(from: source, to: dest)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Helpers

    private func binding(for index: Int) -> Binding<ScriptBeat> {
        Binding(
            get: {
                // Deleting a beat shifts indices; SwiftUI can re-evaluate a
                // disappearing row's binding with a stale index → out-of-bounds trap.
                aiStore.beats.indices.contains(index) ? aiStore.beats[index] : Self.staleBeat
            },
            set: { newValue in
                guard aiStore.beats.indices.contains(index) else { return }
                aiStore.beats[index] = newValue
            }
        )
    }

    private static let staleBeat = ScriptBeat(
        index: 0, title: "", description: "",
        searchQueries: [], targetDuration: nil, mood: nil, clips: []
    )

    private func dropTargetBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTargets[id] ?? false },
            set: { dropTargets[id] = $0 }
        )
    }

    /// Moves the dragged beat onto the drop target's position.
    private func handleDrop(targetID: UUID) -> Bool {
        let fromID = draggedBeatID
        draggedBeatID = nil
        dropTargets[targetID] = false
        if let fromID {
            aiStore.reorderBeat(fromId: fromID, toId: targetID)
        }
        return true
    }

    /// Re-loads persisted folders once per launch so materials are ready
    /// without manual re-picking (cache fingerprint makes this cheap).
    private func restoreFoldersIfNeeded() {
        guard !restoredFolders else { return }
        restoredFolders = true
        let f = aiStore.folders
        guard !f.isEmpty,
              !subStore.isLoaded, !subStore.isLoading,
              !subStore.isTranscriptsLoaded, !subStore.isTranscriptsLoading else { return }
        applyFolders(f)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more folders with subtitles/transcripts"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var list = aiStore.folders
        for url in panel.urls where !list.contains(url.path) {
            list.append(url.path)
        }
        applyFolders(list)
    }

    private func removeFolder(_ path: String) {
        applyFolders(aiStore.folders.filter { $0 != path })
    }

    private func applyFolders(_ list: [String], force: Bool = false) {
        aiStore.setFolders(list)
        materialTrees = MaterialTree.scan(list)
        guard !list.isEmpty else {
            subStore.clearAll()
            return
        }
        subStore.loadFolders(list, forceRebuild: force)
        subStore.loadTranscriptsFolders(list)
    }


    // MARK: - Parse Script

    /// Parse the treatment text into structured beats (called by "Auto-fill from text").
    private func autoFillFromText() {
        parseScript()
    }

    private func parseScript() {
        let script = aiStore.scriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        aiStore.isParsing = true
        aiStore.lastError = nil
        aiStore.statusMessage = "Parsing script\u{2026}"

        let systemPrompt = PrimingRegistry.stage(for: "priming_scriptParsing")?.load()
            ?? "You are a documentary assistant editor. Break the script into sequential beats for a timeline. Return JSON with title, estimatedDuration, and beats (title, description, searchQueries, targetDuration, mood). No text outside the JSON."

        let fullPrompt = "\(systemPrompt)\n\n---\n\nSCRIPT TO PARSE:\n\(script)"

        // Grammar-constrained decoding: makes malformed JSON tokens impossible
        let beatItem: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "description": ["type": "string"],
                "searchQueries": ["type": "array", "items": ["type": "string"]],
                "targetDuration": ["type": "number"],
                "mood": ["type": "string"]
            ],
            "required": ["title", "description", "searchQueries", "targetDuration", "mood"]
        ]
        let jsonSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "estimatedDuration": ["type": "number"],
                "beats": ["type": "array", "items": beatItem]
            ],
            "required": ["title", "beats"]
        ]

        DispatchQueue.global().async {
            let gen = aiStore.generationID
            OMLXClient.shared.complete(
                prompt: fullPrompt,
                temperature: 0.3,
                maxTokens: 4096,
                jsonSchema: jsonSchema,
                timeout: 600
            ) { result in
                guard gen == aiStore.generationID else { return }
                guard let response = result.text, result.error == nil else {
                    DispatchQueue.main.async {
                        aiStore.isParsing = false
                        aiStore.lastError = result.error ?? "No response from oMLX"
                        aiStore.statusMessage = "Parse failed"
                    }
                    return
                }

                let cleaned = Self.stripThinkBlocks(response)

                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    DispatchQueue.main.async {
                        aiStore.isParsing = false
                        aiStore.lastError = "Model returned an empty response — it may still be loading or was interrupted. Try again."
                        aiStore.statusMessage = "Parse failed"
                    }
                    return
                }

                guard let parsed = Self.extractJSON(from: cleaned) else {
                    let snippet = String(cleaned.prefix(180))
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    DispatchQueue.main.async {
                        aiStore.isParsing = false
                        aiStore.lastError = "Could not extract JSON from LLM response. Response started: \u{201C}\(snippet)\u{2026}\u{201D}"
                        aiStore.statusMessage = "Parse failed"
                    }
                    return
                }

                do {
                    let result = try Self.parseResponse(cleaned)
                    DispatchQueue.main.async {
                        let newBeats = result.beats.enumerated().map { idx, p in
                            ScriptBeat(
                                index: idx + 1,
                                title: p.title,
                                description: p.description,
                                searchQueries: p.searchQueries,
                                targetDuration: p.targetDuration,
                                mood: p.mood,
                                clips: [],
                            )
                        }
                        aiStore.applyParsedBeats(newBeats, title: result.title, duration: result.estimatedDuration)
                        aiStore.isParsing = false
                        aiStore.statusMessage = "\(aiStore.beats.count) beat(s) parsed"
                    }
                } catch {
                    DispatchQueue.main.async {
                        aiStore.isParsing = false
                        aiStore.lastError = error.localizedDescription
                        aiStore.statusMessage = "Parse failed"
                    }
                }
            }
        }
    }

    // MARK: - LLM Helpers

    private static func stripThinkBlocks(_ text: String) -> String {
        var result = text
        let endTag = "</think>"
        let startTag = "<think>"
        if let lastEnd = result.range(of: endTag, options: .backwards) {
            result = String(result[lastEnd.upperBound...])
        }
        if let leftover = result.range(of: startTag) {
            result = String(result[leftover.upperBound...])
        }
        return result
    }

    private static func extractJSON(from text: String) -> Data? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown fences
        let fencePattern = "^```(?:json)?\\s*\\n?"
        let endFencePattern = "\\n?```\\s*$"
        cleaned = cleaned.replacingOccurrences(of: fencePattern, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: endFencePattern, with: "", options: .regularExpression)
        // Try direct parse
        if let data = cleaned.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        // Find first { ... last }, validate, then attempt repairs
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}") else { return nil }
        let jsonStr = String(cleaned[start...end])
        if let data = jsonStr.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        let repaired = repairJSON(jsonStr)
        if let data = repaired.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        return nil
    }

    /// Best-effort fixes for common single-token LLM slips:
    /// stray characters on keys ("*mood\":"), unquoted keys, trailing commas, smart quotes.
    private static func repairJSON(_ text: String) -> String {
        var s = text
        // Smart quotes → straight quotes
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        // Stray junk before a key's opening quote: *mood": "x" → "mood": "x"
        s = s.replacingOccurrences(
            of: "([\\{\\[,]\\s*)[^\"\\[\\]\\{\\}\\s:]([^\"\\n]*?)\"(\\s*:)",
            with: "$1\"$2\"$3",
            options: .regularExpression
        )
        // Unquoted keys: { mood": → { "mood":
        s = s.replacingOccurrences(
            of: "([\\{\\[,]\\s*)([A-Za-z_][A-Za-z0-9_]*)\"?(\\s*:)",
            with: "$1\"$2\"$3",
            options: .regularExpression
        )
        // Trailing commas before closing braces/brackets
        for _ in 0..<2 {
            s = s.replacingOccurrences(
                of: ",\\s*([}\\]])",
                with: "$1",
                options: .regularExpression
            )
        }
        return s
    }

    private static func parseResponse(_ text: String) throws -> ScriptParseResult {
        guard let data = extractJSON(from: text) else {
            throw ParseError.noJSON
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        let title = obj["title"] as? String
        let estimatedDuration = obj["estimatedDuration"] as? Double
        guard let beatsArr = obj["beats"] as? [[String: Any]] else {
            throw ParseError.noBeats
        }
        let beats: [ParsedBeat] = beatsArr.map { b in
            ParsedBeat(
                title: b["title"] as? String ?? "Untitled",
                description: b["description"] as? String ?? "",
                searchQueries: b["searchQueries"] as? [String] ?? [],
                targetDuration: b["targetDuration"] as? Double,
                mood: b["mood"] as? String
            )
        }
        return ScriptParseResult(beats: beats, estimatedDuration: estimatedDuration, title: title)
    }

    enum ParseError: LocalizedError {
        case noJSON, invalidJSON, noBeats
        var errorDescription: String? {
            switch self {
            case .noJSON: return "No JSON found in response"
            case .invalidJSON: return "Response is not valid JSON"
            case .noBeats: return "No 'beats' array found in response"
            }
        }
    }
    /// ESC cancels parse/find/review work while this tab is visible.
    private func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            if aiStore.isParsing || aiStore.isAssembling || aiStore.isReviewingFlow {
                aiStore.cancelAll()
            }
            return event
        }
    }
}

// MARK: - Beat Row (right panel — title + clips only)

struct BeatRow: View {
    @Binding var beat: ScriptBeat
    let beatIndex: Int
    var hasFolder: Bool = false
    var busy: Bool = false
    @State private var clipsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(beatIndex + 1).")
                    .scaledFont(.subheadline, design: .monospaced)
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .trailing)

                Text(beat.title.isEmpty ? "Untitled" : beat.title)
                    .scaledFont(.headline, weight: .semibold)
                    .lineLimit(1)

                if let mood = beat.mood, !mood.isEmpty {
                    Text(mood)
                        .scaledFont(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                        .lineLimit(1)
                }

                Spacer()

                if let dur = beat.targetDuration {
                    Text("\(Int(dur))s")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !beat.clips.isEmpty {
                Button(action: { clipsExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "film")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(beat.clips.filter(\.included).count) of \(beat.clips.count) clips included")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary)
                        Image(systemName: clipsExpanded ? "chevron.up" : "chevron.down")
                            .scaledFont(.caption2)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)

                if clipsExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(beat.clips.indices, id: \.self) { ci in
                            ClipRow(clip: $beat.clips[ci], busy: busy)
                        }
                    }
                    .padding(.leading, 24)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: hasFolder ? "film.stack" : "folder.badge.questionmark")
                        .scaledFont(.caption2)
                        .foregroundColor(hasFolder ? .orange : .secondary.opacity(0.5))
                    Text(hasFolder
                         ? "No matching clips yet \u{2014} run Create Edit to search"
                         : "No source folder \u{2014} clips unavailable")
                        .scaledFont(.caption2)
                        .foregroundColor(hasFolder ? .orange.opacity(0.8) : .secondary.opacity(0.5))
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

// MARK: - Clip Row


struct ClipRow: View {
    @Binding var clip: BeatClip
    var busy: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: { clip.included.toggle() }) {
                Image(systemName: clip.included ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.caption)
                    .foregroundColor(clip.included ? .green : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(clip.included ? "Exclude from timeline" : "Include in timeline")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(clip.speaker.isEmpty ? "?" : clip.speaker)
                        .scaledFont(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(clip.isContext ? .orange : .primary)
                    Text(fmtTc(clip.start_s))
                        .scaledFont(.caption2, design: .monospaced)
                        .foregroundColor(.secondary)
                    if clip.isContext {
                        Text("context")
                            .scaledFont(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(3)
                    } else if clip.matchScore > 0 {
                        Text("match \(Int(clip.matchScore * 100))%")
                            .scaledFont(.caption2)
                            .foregroundColor(.green)
                    }
                    Spacer()
                    Text(String(format: "%.0fs", clip.end_s - clip.start_s))
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(clip.text)
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if !clip.matchReason.isEmpty && !clip.isContext {
                    Text(clip.matchReason)
                        .scaledFont(.caption2)
                        .foregroundColor(.accentColor.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func fmtTc(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

}

// MARK: - Left Beat Card (structured authoring)

struct LeftBeatCard: View {
    @Binding var beat: ScriptBeat
    let beatIndex: Int
    let totalBeats: Int
    var busy: Bool = false
    var isDropTarget: Bool = false
    let onDelete: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    var onFindClips: (() -> Void)? = nil

    @State private var editorExpanded = true
    @State private var newQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(beatIndex + 1).")
                    .scaledFont(.subheadline, design: .monospaced)
                    .foregroundColor(.secondary)
                    .frame(width: 22, alignment: .trailing)

                TextField("Beat title", text: $beat.title)
                    .textFieldStyle(.plain)
                    .scaledFont(.headline, weight: .semibold)

                if let mood = beat.mood, !mood.isEmpty {
                    Text(mood)
                        .scaledFont(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                        .lineLimit(1)
                }

                Spacer()

                if let dur = beat.targetDuration {
                    Text("\(Int(dur))s")
                        .scaledFont(.caption)
                        .foregroundColor(.secondary)
                }

                if let onFind = onFindClips {
                    Button(action: onFind) {
                        Image(systemName: "magnifyingglass")
                            .scaledFont(.body)
                    }
                    .buttonStyle(.plain)
                    .help("Find matching clips for this beat")
                }

                Button(action: { editorExpanded.toggle() }) {
                    Image(systemName: editorExpanded ? "chevron.up.circle" : "pencil.and.list.clipboard")
                        .scaledFont(.body)
                        .foregroundColor(editorExpanded ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Edit beat details (description, queries, mood, duration)")

                Menu {
                    if let onMoveUp { Button("Move Up") { onMoveUp() }.disabled(busy) }
                    if let onMoveDown { Button("Move Down") { onMoveDown() }.disabled(busy) }
                    Divider()
                    Button("Delete", role: .destructive) { onDelete() }
                        .disabled(busy)
                } label: {
                    Image(systemName: "ellipsis")
                        .scaledFont(.body)
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .scaledFont(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help("Delete this beat")
            }

            if editorExpanded {
                editorBody
            }
        }
        .padding(8)
        .background(isDropTarget
                    ? Color.accentColor.opacity(0.1)
                    : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.15))
        )
    }

    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description \u{2014} the beat's topic and narrative function")
                .scaledFont(.caption2)
                .foregroundColor(.secondary)
            TextEditor(text: $beat.description)
                .scaledFont(.subheadline)
                .frame(minHeight: 56)
                .border(Color.gray.opacity(0.2))

            Text("Search queries \u{2014} phrases likely in the speakers' own words")
                .scaledFont(.caption2)
                .foregroundColor(.secondary)
            if !beat.searchQueries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(beat.searchQueries, id: \.self) { query in
                            HStack(spacing: 2) {
                                Text(query)
                                    .scaledFont(.caption)
                                    .lineLimit(1)
                                Button(action: { beat.searchQueries.removeAll { $0 == query } }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .scaledFont(.caption2)
                                        .foregroundColor(.secondary.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(3)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add query…", text: $newQuery)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.caption)
                    .onSubmit(addQuery)
                Button("Add", action: addQuery)
                    .controlSize(.small)
                    .disabled(newQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Mood")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                    TextField("intimate", text: moodBinding)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.caption)
                        .frame(width: 90)
                }
                HStack(spacing: 4) {
                    Text("Target (s)")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                    TextField("10", value: durationBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.caption, monospacedDigit: true)
                        .frame(width: 50)
                }
                Spacer()
            }
        }
    }

    private var moodBinding: Binding<String> {
        Binding(
            get: { beat.mood ?? "" },
            set: { beat.mood = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }

    private var durationBinding: Binding<Double?> {
        Binding(
            get: { beat.targetDuration },
            set: { beat.targetDuration = $0.flatMap { $0 > 0 ? $0 : nil } }
        )
    }

    private func addQuery() {
        let q = newQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if !beat.searchQueries.contains(q) {
            beat.searchQueries.append(q)
        }
        newQuery = ""
    }
}
