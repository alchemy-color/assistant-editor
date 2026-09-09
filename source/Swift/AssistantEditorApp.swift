import SwiftUI

extension Notification.Name {
    static let openPreferences = Notification.Name("openPreferences")
}

@main
struct AssistantEditorApp: App {
    @AppStorage("tabOrder") private var tabOrderJSON = ""
    @Environment(\.openWindow) private var openWindow
    @StateObject private var docStore = DocumentStore()
    @StateObject private var subStore = SubtitleStore(tag: "app")
    @StateObject private var assistantStore = AssistantStore()
    @StateObject private var knowledgeStore = KnowledgeStore()
    @StateObject private var progress = AppProgress()
    @AppStorage("appTextScale") private var appTextScale: Double = 1.0

    private var terminateObserver: NSObjectProtocol?

    init() {
        subStore.appProgress = progress
        // oMLX manages its own model lifecycle (tiered KV-cache, LRU eviction);
        // no manual stop needed on app termination.
    }

    private var selectedTabName: String {
        UserDefaults.standard.string(forKey: "selectedTab") ?? ""
    }

    private var tabMenuOrder: [String] {
        let liveTabs = ContentView.Tab.allCases.map(\.rawValue)
        var order = (try? JSONDecoder().decode([String].self, from: Data(tabOrderJSON.utf8)))
            ?? ContentView.Tab.defaultOrder
        order = order.filter { liveTabs.contains($0) }
        for t in liveTabs where !order.contains(t) { order.append(t) }
        return order
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(docStore)
                .environmentObject(subStore)
                .environmentObject(assistantStore)
                .environmentObject(knowledgeStore)
                .environmentObject(progress)
                .environment(\.appTextScale, appTextScale)
                .frame(minWidth: 1060, minHeight: 620)
        }

        Window("Assistant Editor Help", id: "assistant-help") {
            HelpWindowView()
        }
        .defaultSize(width: 940, height: 640)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Assistant Editor") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .textEditing) {
                Button("Priming…") {
                    NotificationCenter.default.post(name: .openPreferences, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Increase Text Size") {
                    appTextScale = min(1.75, (appTextScale + 0.125).rounded(toPlaces: 3))
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Text Size") {
                    appTextScale = max(0.75, (appTextScale - 0.125).rounded(toPlaces: 3))
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Reset Text Size") {
                    appTextScale = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Tabs") {
                ForEach(Array(tabMenuOrder.enumerated()), id: \.element) { idx, name in
                    Button(name == selectedTabName ? "\u{2713} \(name)" : name) {
                        UserDefaults.standard.set(name, forKey: "selectedTab")
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: .command)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Assistant Editor Help") {
                    openWindow(id: "assistant-help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
