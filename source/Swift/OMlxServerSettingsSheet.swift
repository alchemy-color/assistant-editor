import SwiftUI

/// Bottom-bar "Server…" sheet: lets the user point the app at the local oMLX
/// server (base URL + API key), test the connection, and re-detect models.
struct OMlxServerSettingsSheet: View {
    var onSaved: () -> Void

    @AppStorage("omlxBaseURL") private var baseURL = OMLXClient.defaultBaseURL
    @AppStorage("omlxAPIKey") private var apiKey = ""
    @State private var testState: TestState = .idle
    @State private var detectedModels: [String] = []

    enum TestState: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local oMLX Server")
                .scaledFont(.title2).bold()

            Text("Point the app at your local oMLX LLM server. oMLX serves an OpenAI-compatible API and caches the model in memory across requests.")
                .scaledFont(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .scaledFont(.caption, design: .monospaced)
                TextField("http://localhost:8000", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.subheadline, design: .monospaced)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .scaledFont(.caption, design: .monospaced)
                SecureField("Enter server API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.subheadline, design: .monospaced)
            }

            HStack(spacing: 8) {
                Button(testState == .testing ? "Testing…" : "Test Connection") {
                    test()
                }
                .disabled(testState == .testing)

                Spacer()

                if !detectedModels.isEmpty {
                    Text("Detected: \(detectedModels.joined(separator: ", "))")
                        .scaledFont(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Contacting oMLX…")
                        .scaledFont(.caption)
                }
                .foregroundColor(.secondary)
            case .ok(let msg):
                Text("✓ \(msg)")
                    .scaledFont(.caption)
                    .foregroundColor(.green)
            case .failed(let msg):
                Text("✗ \(msg)")
                    .scaledFont(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onSaved()
                }
                Button("Save") {
                    UserDefaults.standard.set(baseURL, forKey: "omlxBaseURL")
                    UserDefaults.standard.set(apiKey, forKey: "omlxAPIKey")
                    UserDefaults.standard.set(true, forKey: "ollamaSetupDismissed")
                    onSaved()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: test)
    }

    private func test() {
        testState = .testing
        detectedModels = []
        // Persist transiently so OMLXClient uses what's typed during the test.
        let tmpBase = baseURL
        let tmpKey = apiKey
        let ud = UserDefaults.standard
        let savedBase = ud.string(forKey: "omlxBaseURL") ?? OMLXClient.defaultBaseURL
        let savedKey = ud.string(forKey: "omlxAPIKey") ?? ""
        ud.set(tmpBase, forKey: "omlxBaseURL")
        ud.set(tmpKey, forKey: "omlxAPIKey")
        OMLXClient.shared.checkServer { result in
            // Restore persisted pre-edit values unless the user just saved.
            ud.set(savedBase, forKey: "omlxBaseURL")
            ud.set(savedKey, forKey: "omlxAPIKey")
            DispatchQueue.main.async {
                if result.running {
                    detectedModels = result.models
                    testState = .ok(result.models.isEmpty
                        ? "Connected (\(result.error ?? "no models detected"))"
                        : "Connected · \(result.models.count) model(s)")
                } else {
                    testState = .failed(result.error ?? "Server not reachable")
                }
            }
        }
    }
}
