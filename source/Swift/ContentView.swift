import SwiftUI

struct ContentView: View {
    @AppStorage("selectedTab") private var selectedTabRaw = "Project Setup"
    @AppStorage("ollamaSetupDismissed") private var ollamaSetupDismissed = false
    @EnvironmentObject var progress: AppProgress
    @EnvironmentObject var assistantStore: AssistantStore
    @EnvironmentObject var knowledgeStore: KnowledgeStore

    @State private var ollamaAvailable = false
    @State private var ollamaModel: String?
    @State private var ollamaCheckDone = false
    @State private var ollamaCheckError = ""
    @State private var availableModels: [String] = []
    @State private var modelLoaded = false
    @State private var showPreferences = false
    @State private var showMethodology = false
    @State private var showApiKeyEntry = false
    @State private var showModelDetail = false
    @State private var isRefreshingModels = false
    @State private var showResolveWizard = false
    @ObservedObject private var llmPerf = LLMPerf.shared
    @ObservedObject private var resolveConnector = ResolveConnector.shared
    private let modelRefreshInterval: TimeInterval = 30
    // Per-tab isolated stores — one tab's folder load can never clobber another's data
    @StateObject private var tlSub = SubtitleStore(tag: "tl")
    @StateObject private var tlDocs = DocumentStore()
    @StateObject private var tiSub = SubtitleStore(tag: "ti")
    @StateObject private var tiDocs = DocumentStore()
    @StateObject private var aiSub = SubtitleStore(tag: "ai")
    @StateObject private var aiDocs = DocumentStore()

    @AppStorage("selectedModel") private var selectedModel = OMLXClient.defaultModel
    @AppStorage("lastSrtFolder") private var lastSrtFolder = ""
    @AppStorage("lastYamlFolder") private var lastYamlFolder = ""


    enum Tab: String, CaseIterable {
        case sourceMaterial = "Project Setup"
        case aiEdit = "AI Edit"
        case timeline  = "Timeline Assist"
        case transcriptIntelligence = "Transcript Intelligence"

        static let defaultOrder: [String] = allCases.map(\.rawValue)
    }

    @AppStorage("tabOrder") private var tabOrderJSON = ""
    @AppStorage("tabOrderInitialized") private var tabOrderInitialized = false

    private var tab: Tab { Tab(rawValue: selectedTabRaw) ?? .sourceMaterial }

    private var tabDescription: String {
        switch tab {
        case .sourceMaterial:
            return "Point at your interview folders — the app extracts project themes and lets you weigh what matters."
        case .aiEdit:
            return "Turn a script or treatment into beats, cast real clips from your material against each beat, and assemble the timeline in Resolve."
        case .timeline:
            return "Search transcripts for the words and phrases that matter, then cut them into a rough cut — with chapters and synopses generated along the way."
        case .transcriptIntelligence:
            return "Ask questions across all loaded interviews — answers are grounded in transcripts, chapters, and synopses."
        }
    }

    /// One-time migration: first-pass tab renamed Source Material -> Project Setup,
    /// and the removed Sync by Transcript tab is dropped from persisted order/selection.
    private func migrateTabNames() {
        if selectedTabRaw == "Source Material" { selectedTabRaw = "Project Setup" }
        if selectedTabRaw == "Sync by Transcript" { selectedTabRaw = "Project Setup" }
        guard !tabOrderJSON.isEmpty else { return }
        var order = (try? JSONDecoder().decode([String].self, from: Data(tabOrderJSON.utf8))) ?? []
        var changed = false
        order = order.filter { $0 != "Sync by Transcript" }
        if order.count < (try? JSONDecoder().decode([String].self, from: Data(tabOrderJSON.utf8)))?.count ?? 0 {
            changed = true
        }
        order = order.map { $0 == "Source Material" ? "Project Setup" : $0 }
        if changed, let data = try? JSONEncoder().encode(order), let str = String(data: data, encoding: .utf8) {
            tabOrderJSON = str
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selectedTabRaw: $selectedTabRaw, tabOrderJSON: $tabOrderJSON)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Text(tabDescription)
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            if ollamaAvailable && !modelLoaded {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Model not loaded. Click **Server Setup** in the bottom bar to configure.")
                        .scaledFont(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(4)
            } else if !ollamaAvailable && ollamaCheckDone {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("oMLX server not reachable. Click **Server Setup** in the bottom bar to configure.")
                        .scaledFont(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(4)
            }

            Divider()

            ZStack {
                SourceMaterialTab()
                    .opacity(tab == .sourceMaterial ? 1 : 0)
                    .allowsHitTesting(tab == .sourceMaterial)
                ProcessTimelineTab(subStore: tlSub, docStore: tlDocs)
                    .opacity(tab == .timeline ? 1 : 0)
                    .allowsHitTesting(tab == .timeline)
                TranscriptIntelligenceTab(subStore: tiSub, docStore: tiDocs)
                    .opacity(tab == .transcriptIntelligence ? 1 : 0)
                    .allowsHitTesting(tab == .transcriptIntelligence)
                AIEditTab(subStore: aiSub, docStore: aiDocs)
                    .opacity(tab == .aiEdit ? 1 : 0)
                    .allowsHitTesting(tab == .aiEdit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            migrateTabNames()
            if !tabOrderInitialized {
                if let data = try? JSONEncoder().encode(Tab.defaultOrder),
                   let str = String(data: data, encoding: .utf8) {
                    tabOrderJSON = str
                }
                tabOrderInitialized = true
            }
            checkLLM()
            installEscapeMonitor()
        }
        .sheet(isPresented: $showApiKeyEntry) {
            ollamaSetupSheet
        }
        .sheet(isPresented: $showMethodology) {
            MethodologySplash(isPresented: $showMethodology)
        }
        .sheet(isPresented: $showPreferences) {
            PrimingView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPreferences)) { _ in
            showPreferences = true
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard !isRefreshingModels else { return }
            checkLLM()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkLLM()
        }
    }

    var bottomBar: some View {
        HStack(spacing: 10) {
            // ── Server Status ────────────────────────────────────────────────
            Circle()
                .fill(serverLightColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                .shadow(color: serverLightColor.opacity(0.4), radius: 2)
                .help(serverLightHelp)

            Text("Server Status")
                .scaledFont(.caption)
                .foregroundColor(.secondary)

            Button(ollamaAvailable ? "Server Setup" : "Server Setup…") { showApiKeyEntry = true }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Set the local oMLX server URL and API key")

            Button("oMLX") { openOMLX() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Open oMLX app")

            if ollamaAvailable {
                Button {
                    isRefreshingModels = true
                    checkLLM { isRefreshingModels = false }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshingModels ? 360 : 0))
                        .animation(isRefreshingModels ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshingModels)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.secondary)
                .disabled(isRefreshingModels)
                .help("Refresh model list from oMLX")

                Picker("Model", selection: $selectedModel) {
                    ForEach(availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .scaledFont(.callout, design: .monospaced)
                .frame(width: 180)
                .help("Select model served by local oMLX")

                ModelQualityBadge(modelID: selectedModel)

                Button {
                    showModelDetail = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.secondary)
                .help("Model details & provider description")
                .popover(isPresented: $showModelDetail, arrowEdge: .bottom) {
                    ModelDetailPopover(modelID: selectedModel) { showModelDetail = false }
                }

                Group {
                    if let tps = llmPerf.tokensPerSec {
                        Text(String(format: "%.0f tok/s", tps))
                            .help(String(format: "Last LLM call: %d tokens in %.0f ms", llmPerf.evalCount, llmPerf.evalMs))
                    } else {
                        Text("— tok/s")
                            .help("Tokens per second of the last local LLM call")
                    }
                }
                .scaledFont(.caption, monospacedDigit: true)
                .foregroundColor(llmPerf.tokensPerSec == nil ? .secondary.opacity(0.5) : .secondary)
            } else if ollamaCheckDone {
                Text("oMLX server not reachable — keyword engine")
                    .scaledFont(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 18)

            // ── Resolve Status ───────────────────────────────────────────────
            Circle()
                .fill(resolveConnector.isConnected == true ? Color.green : (resolveConnector.isConnected == false ? Color.orange : Color.gray))
                .frame(width: 10, height: 10)
                .padding(.leading, 2)
                .help(resolveConnector.isConnected == true ? "Connected to DaVinci Resolve" : "Connect to DaVinci Resolve (external helper or in-console fallback)")

            Text("Resolve Status")
                .scaledFont(.caption)
                .foregroundColor(.secondary)

            Button("Resolve Setup") { showResolveWizard = true }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(resolveConnector.isConnected == true ? "Connected to DaVinci Resolve — open wizard" : "Connect to DaVinci Resolve (external helper or in-console fallback)")
                .popover(isPresented: $showResolveWizard, arrowEdge: .bottom) {
                    ResolveWizardView()
                }
                .onAppear { resolveConnector.probe() }

            Divider().frame(height: 18)

            Button("Preferences…") { showPreferences = true }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Prompts, presets and pipeline tuning (⌘,)")

            Divider().frame(height: 18)

            Button("Methodology") { showMethodology = true }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Show workflow overview and methodology")

            Spacer(minLength: 12)

            if progress.isActive {
                ProgressView(value: progress.progress)
                    .frame(width: 120)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
                Text(progress.message)
                    .scaledFont(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var serverLightColor: Color {
        if ollamaAvailable { return .green }
        if ollamaCheckDone { return .red }
        return .gray
    }

    private var serverLightHelp: String {
        if ollamaAvailable { return "oMLX server reachable" }
        if ollamaCheckDone { return "oMLX server not reachable — keyword engine" }
        return "Checking oMLX server…"
    }

    var ollamaSetupSheet: some View {
        OMlxServerSettingsSheet(
            onSaved: {
                showApiKeyEntry = false
                ollamaAvailable = false
                ollamaCheckDone = false
                checkLLM()
            }
        )
    }

    func checkLLM(completion: (() -> Void)? = nil) {
        OMLXClient.shared.checkServer { result in
            DispatchQueue.main.async {
                ollamaAvailable = result.running && !result.models.isEmpty
                ollamaCheckDone = true
                ollamaCheckError = result.error ?? ""
                if ollamaAvailable {
                    availableModels = result.models
                    ollamaModel = result.models.first
                    modelLoaded = true
                    if !result.models.contains(selectedModel), let first = result.models.first {
                        selectedModel = first
                    }
                } else {
                    ollamaModel = nil
                    availableModels = []
                    modelLoaded = false
                    if !ollamaSetupDismissed && result.error != nil {
                        showApiKeyEntry = true
                    }
                }
                completion?()
            }
        }
    }

    private func openOMLX() {
        let fm = FileManager.default
        let candidates = ["/Applications/oMLX.app", "/Applications/omlx.app"]
        for path in candidates where fm.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        // Fallback — try CLI open, then reveal oMLX site
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "oMLX"]
        try? proc.run()
    }

    /// ESC cancels app-level AI work (chat, Python pipelines) without
    /// swallowing the key — alerts/sheets still dismiss normally.
    private func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            if assistantStore.isProcessing || PythonBridge.hasRunningProcess {
                assistantStore.cancelAll()
                PythonBridge.cancelRunning()
            }
            return event
        }
    }
}


// MARK: - Model quality badge (bottom bar, next to picker)

private struct ModelQualityBadge: View {
    var modelID: String

    var body: some View {
        let info = ModelCatalog.info(for: modelID)
        HStack(spacing: 4) {
            Text(info.tier)
                .scaledFont(.caption2)
                .fontWeight(.bold)
                .foregroundColor(tierColor(info.tier))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(tierColor(info.tier).opacity(0.12))
                .clipShape(Capsule())
            Text(ModelCatalog.starsString(info.stars))
                .scaledFont(.caption2)
                .foregroundColor(.secondary)
            if !info.virtues.isEmpty {
                Text(info.virtues.prefix(2).joined(separator: " · "))
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .help(helpText(info))
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

    private func helpText(_ info: ModelInfo) -> String {
        var lines: [String] = []
        lines.append("\(info.shortName) — Tier \(info.tier)  \(ModelCatalog.starsString(info.stars))")
        lines.append(info.detail)
        lines.append("Context \(info.contextLabel) · \(info.ramLabel)")
        if !info.virtues.isEmpty {
            lines.append("Virtues: \(info.virtues.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tab Bar with Reordering

private struct TabBar: View {
    @Binding var selectedTabRaw: String
    @Binding var tabOrderJSON: String

    private static let allTabValues: [String] = ContentView.Tab.allCases.map(\.rawValue)

    private var tabOrder: [String] {
        var order = (try? JSONDecoder().decode([String].self, from: Data(tabOrderJSON.utf8))) ?? ContentView.Tab.defaultOrder
        // Filter out any tab that no longer exists (e.g. removed Sync by Transcript)
        order = order.filter { Self.allTabValues.contains($0) }
        for t in Self.allTabValues where !order.contains(t) { order.append(t) }
        return order
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabOrder.enumerated()), id: \.element) { idx, name in
                Text(name)
                    .scaledFont(.subheadline)
                    .fontWeight(selectedTabRaw == name ? .semibold : .regular)
                    .foregroundColor(selectedTabRaw == name ? .accentColor : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTabRaw == name
                                  ? Color.accentColor.opacity(0.1)
                                  : Color.clear)
                    )
                    .onTapGesture { selectedTabRaw = name }
                    .contextMenu {
                        if idx > 0 {
                            Button("Move Left") { moveTab(name: name, direction: -1) }
                        }
                        if idx < tabOrder.count - 1 {
                            Button("Move Right") { moveTab(name: name, direction: 1) }
                        }
                    }
            }
        }
    }

    private func moveTab(name: String, direction: Int) {
        var order = tabOrder
        guard let idx = order.firstIndex(of: name) else { return }
        let target = idx + direction
        guard target >= 0, target < order.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            order.swapAt(idx, target)
        }
        if let data = try? JSONEncoder().encode(order), let str = String(data: data, encoding: .utf8) {
            tabOrderJSON = str
        }
    }
}
