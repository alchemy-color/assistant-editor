import SwiftUI

struct ResolveWizardView: View {
    @ObservedObject var connector = ResolveConnector.shared
    @State private var showHelperInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to DaVinci Resolve")
                .scaledFont(.title2).bold()

            Text("The app talks to Resolve via FusionScript. If the external helper is stale, it falls back to running the same logic *inside* Resolve’s Py3 console (which you proved healthy).")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Circle().fill(connector.isConnected == true ? Color.green : (connector.isConnected == false ? Color.red : Color.gray)).frame(width: 10, height: 10)
                if connector.isChecking {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").scaledFont(.caption).foregroundColor(.secondary)
                } else if connector.isConnected == true {
                    Text("Connected — external helper responding").scaledFont(.caption).foregroundColor(.green)
                } else if connector.isConnected == false {
                    Text("External helper not responding — in-console fallback available").scaledFont(.caption).foregroundColor(.orange)
                } else {
                    Text("Not checked").scaledFont(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Test") { connector.probe() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            if connector.isConnected == false {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("External DaVinciResolveScript.scriptapp('Resolve') → None, but Workspace > Console > Py3 > print(resolve) is live. The wizard below installs a helper that runs inside Resolve.").scaledFont(.caption).foregroundColor(.orange)
                    Spacer()
                }.padding(8).background(Color.orange.opacity(0.1)).cornerRadius(6)

                if ResolveConnector.isScriptServerDown() {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "memories").foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resolve’s script server is not responding — restart Resolve").scaledFont(.subheadline).bold().foregroundColor(.red)
                            Text("Resolve is running, but its script *server* never handed out the app object this session — offline even for bmd.scriptapp ported in-process. This is a Resolve-side stale state; the app can’t recover it by itself.")
                                .scaledFont(.caption).foregroundColor(.secondary)
                            Text("Fix: Quit DaVinci Resolve fully (CMD+Q, not just the window), relaunch, reopen your project. The dot here should turn green and Write-to-Resolve / chapter delivery resumes.")
                                .scaledFont(.caption).bold()
                            Button("I’ve restarted Resolve — re-test") {
                                connector.probe()
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        Spacer()
                    }.padding(8).background(Color.red.opacity(0.08)).cornerRadius(6)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom bridge script").scaledFont(.subheadline).bold()
                Text("Installs to /Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp/AssistantEditor_ResolveBridge.py — invoked from Workspace > Scripts > Comp.")
                    .scaledFont(.caption).foregroundColor(.secondary)
                HStack {
                    Button("Install helper") {
                        ResolveConnector.installHelperScript()
                        showHelperInstalled = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+1.5){ showHelperInstalled = false }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    if showHelperInstalled { Text("Installed ✓").scaledFont(.caption).foregroundColor(.green) }
                    Spacer()
                    Button("Run helper now") { ResolveConnector.triggerViaMenu() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            Text("Until external recovers, use Export EDL / Export ▾ Subtitles (no scriptapp needed) or the helper above.")
                .scaledFont(.caption2).foregroundColor(.secondary)

            HStack { Spacer()
                Button("Close") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { connector.probe() }
    }
}


