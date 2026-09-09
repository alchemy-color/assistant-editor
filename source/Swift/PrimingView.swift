import SwiftUI
import AppKit

struct PrimingView: View {
    @AppStorage("primingSidebarWidth") private var sidebarWidth: Double = 200
    @State private var sidebarSnapshot: Double = 200
    @AppStorage("activePrimingPreset") private var activePreset = ""
    @AppStorage(PrimingPresetStore.folderKey) private var presetFolder = ""
    @State private var selectedKey: String = PrimingRegistry.stages.first?.key ?? ""
    @State private var text: String = ""
    @State private var showResetConfirm = false
    @State private var showApplyConfirm = false
    @State private var foundPresets: [(label: String, name: String, preset: PrimingPreset)] = []
    @State private var chosenPreset: String = ""
    @State private var showSaveSheet = false
    @State private var newPresetName = ""
    @State private var newPresetBasedOn = ""
    @State private var showDeleteConfirm = false
    @State private var deleteFailed = false

    private let factoryLabel = "Factory — generic film editor"

    private var stage: PrimingStage? {
        PrimingRegistry.stage(for: selectedKey)
    }

    private var sourceLabel: String {
        presetFolder.isEmpty
            ? "Source: Project Setup folders"
            : "Source: \((presetFolder as NSString).lastPathComponent)"
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane

            DragDivider(
                onStart: { sidebarSnapshot = sidebarWidth },
                onChanged: { t in
                    sidebarWidth = min(340, max(150, sidebarSnapshot + Double(t)))
                }
            )

            editorPane
        }
        // Open at a stable ideal size; flexible max lets the user drag-resize freely.
        .frame(idealWidth: 1000, idealHeight: 660)
        .frame(minWidth: 880, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .onAppear {
            foundPresets = PrimingPresetStore.scan()
            chosenPreset = activePreset
            text = stage?.load() ?? ""
        }
        .onChange(of: presetFolder) { _, _ in
            rescanPresets()
        }
        .onChange(of: chosenPreset) { _, newValue in
            guard newValue != activePreset else { return }
            let hasManualEdits = PrimingRegistry.stages.contains { $0.isCustomized() }
            if hasManualEdits {
                showApplyConfirm = true
            } else {
                commitPreset(newValue)
            }
        }
        .onChange(of: text) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: selectedKey)
        }
        .alert("Apply preset?", isPresented: $showApplyConfirm) {
            Button("Cancel", role: .cancel) { chosenPreset = activePreset }
            Button("Apply", role: .destructive) { commitPreset(chosenPreset) }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showSaveSheet) {
            savePresetSheet
        }
        .alert("Delete “\(chosenPreset)”?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deletePreset() }
        } message: {
            Text("This removes the preset from the project's priming preset file. It cannot be undone.")
        }
        .alert("Delete Failed", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No folder is configured to hold presets. Set a preset folder (folder button) or add a project folder in Project Setup first.")
        }
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Preset")
                .scaledFont(.title3).fontWeight(.semibold)

            Text("Captures the currently edited prompts for all 9 steps into a named preset, saved to \(sourceLabel).")
                .scaledFont(.caption)
                .foregroundColor(.secondary)

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .scaledFont(.body)

            TextField("Description (optional)", text: $newPresetBasedOn)
                .textFieldStyle(.roundedBorder)
                .scaledFont(.body)

            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    finishSavePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var alertMessage: String {
        chosenPreset.isEmpty
            ? "All steps return to the factory generic-editor prompts."
            : "Your manually edited prompts will be replaced with the “\(chosenPreset)” texts."
    }

    private var resetMessage: String {
        "Your customized prompt for \(stage?.title ?? "this step") will be replaced by the built-in default."
    }

    // MARK: Sidebar

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            presetHeader

            Divider()

            Text("LLM Steps")
                .scaledFont(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(PrimingRegistry.stages) { s in
                stageRow(s)
            }

            Spacer()

            Text("Each step gets exactly the text shown here — nothing else is added.")
                .scaledFont(.caption2)
                .foregroundColor(.secondary)
                .padding(12)
        }
        .frame(width: sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var presetHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset")
                .scaledFont(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Picker("", selection: $chosenPreset) {
                Text(factoryLabel).tag("")
                ForEach(foundPresets, id: \.name) { f in
                    Text(f.name).tag(f.name)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            statusRow

            Divider()

            HStack(spacing: 4) {
                Button(action: pickPresetFolder) {
                    Image(systemName: "folder.badge.plus")
                        .help("Choose the folder that holds the project's priming preset file")
                }
                .buttonStyle(.plain)

                Text(sourceLabel)
                    .scaledFont(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: savePreset) {
                    Image(systemName: "square.and.arrow.down")
                        .help("Save current prompts as a preset")
                }
                .buttonStyle(.plain)
                .disabled(!canSavePreset)

                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                        .help("Delete the selected preset")
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .disabled(chosenPreset.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var canSavePreset: Bool {
        guard !presetFolder.isEmpty || (UserDefaults.standard.string(forKey: "sourceMaterialFolders")?.isEmpty == false) else {
            return false
        }
        return PrimingRegistry.stages.contains { $0.isCustomized() }
    }

    @ViewBuilder
    private var statusRow: some View {
        if activePreset.isEmpty {
            Text("Factory defaults active")
                .scaledFont(.caption2)
                .foregroundColor(.secondary)
        } else {
            Label("\(activePreset) active", systemImage: "checkmark.circle.fill")
                .scaledFont(.caption2)
                .foregroundColor(.green)
                .lineLimit(1)
        }
    }

    private func stageRow(_ s: PrimingStage) -> some View {
        Button(action: { select(s.key) }) {
            HStack(spacing: 8) {
                Image(systemName: s.icon)
                    .frame(width: 18)
                    .foregroundColor(selectedKey == s.key ? .white : .accentColor)
                Text(s.title)
                    .scaledFont(.subheadline)
                    .foregroundColor(selectedKey == s.key ? .white : .primary)
                Spacer()
                if s.isCustomized() {
                    Circle()
                        .fill(selectedKey == s.key ? Color.white.opacity(0.9) : Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selectedKey == s.key ? Color.accentColor : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: Editor pane

    @ViewBuilder
    private var editorPane: some View {
        if let stage {
            editorContent(stage)
        } else {
            Spacer()
        }
    }

    private func editorContent(_ stage: PrimingStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(stage.title, systemImage: stage.icon)
                    .scaledFont(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if stage.isCustomized() {
                    Button("Reset to Default") { showResetConfirm = true }
                        .controlSize(.small)
                }
            }

            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "bolt.fill")
                    .scaledFont(.caption2)
                    .foregroundColor(.orange)
                    .padding(.top, 1)
                Text("Fires when: " + stage.firesWhen)
                    .scaledFont(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            TextEditor(text: $text)
                .scaledFont(.body, design: .monospaced)
                .border(Color.gray.opacity(0.25))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("Reset to default?", isPresented: $showResetConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset", role: .destructive) {
                        stage.reset()
                        text = stage.defaultText
                    }
                } message: {
                    Text(resetMessage)
                }

            footerBar(stage)
        }
        .padding(16)
    }

    private func footerBar(_ stage: PrimingStage) -> some View {
        HStack {
            Text(text == stage.defaultText ? "Default prompt" : "Customized — saved automatically")
                .scaledFont(.caption2)
                .foregroundColor(text == stage.defaultText ? .secondary : .accentColor)
            Spacer()
            Text("\(text.count) chars")
                .scaledFont(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Actions

    private func select(_ key: String) {
        selectedKey = key
        text = PrimingRegistry.stage(for: key)?.load() ?? ""
    }

    private func pickPresetFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Folder containing the project's priming preset file"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        presetFolder = url.path
    }

    private func rescanPresets() {
        foundPresets = PrimingPresetStore.scan()
        if !foundPresets.contains(where: { $0.name == chosenPreset }) {
            chosenPreset = activePreset
        }
    }

    /// Applies the selected preset (or Factory when empty) and refreshes every visible signal.
    private func commitPreset(_ name: String) {
        if name.isEmpty {
            PrimingPresetStore.revertToFactory()
        } else if let found = foundPresets.first(where: { $0.name == name }) {
            PrimingPresetStore.apply(found.preset)
        }
        activePreset = name
        foundPresets = PrimingPresetStore.scan()
        text = stage?.load() ?? ""
    }

    /// Opens the save-as-preset sheet (guards the mirror: needs a write folder
    /// configured by the time the sheet's Save is tapped).
    private func savePreset() {
        newPresetName = ""
        newPresetBasedOn = ""
        showSaveSheet = true
    }

    /// Builds a preset from the currently edited stage texts and writes it.
    private func finishSavePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let basedOn = newPresetBasedOn.trimmingCharacters(in: .whitespaces)
        if let root = PrimingPresetStore.save(name: name, basedOn: basedOn) {
            showSaveSheet = false
            foundPresets = PrimingPresetStore.scan()
            PrimingPresetStore.apply(PrimingPreset(name: name, basedOn: basedOn, stages: currentStageTexts()))
            activePreset = name
            chosenPreset = name
            text = stage?.load() ?? ""
        }
    }

    private func currentStageTexts() -> [String: String] {
        var out: [String: String] = [:]
        for stage in PrimingRegistry.stages {
            out[stage.key] = stage.load()
        }
        return out
    }

    /// Removes the currently selected preset from disk and reverts to Factory
    /// if it was active.
    private func deletePreset() {
        let wasActive = chosenPreset == activePreset
        if let _ = PrimingPresetStore.delete(name: chosenPreset) {
            showDeleteConfirm = false
            if wasActive {
                PrimingPresetStore.revertToFactory()
                activePreset = ""
            }
            foundPresets = PrimingPresetStore.scan()
            chosenPreset = activePreset
            text = stage?.load() ?? ""
        } else {
            showDeleteConfirm = false
            deleteFailed = true
        }
    }
}
