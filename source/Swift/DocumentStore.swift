import Foundation

class DocumentStore: ObservableObject {
    @Published var allDocuments: [SummaryDocument] = []
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var statusMessage = ""

    func loadOnce(folder: String) {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        statusMessage = "Loading\u{2026}"

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let docs = try PythonBridge.scanSummaries(root: folder)

                DispatchQueue.main.async {
                    self.allDocuments = docs
                    self.isLoaded = true
                    self.isLoading = false
                    self.statusMessage = "\(docs.count) document(s)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    func reload(folder: String) {
        isLoaded = false
        isLoading = false
        allDocuments = []
        loadOnce(folder: folder)
    }

    func reloadFolders(_ folders: [String]) {
        isLoaded = false
        isLoading = false
        allDocuments = []
        guard !folders.isEmpty else { return }
        isLoading = true
        statusMessage = "Loading\u{2026}"

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var allDocs: [SummaryDocument] = []
            for folder in folders {
                do {
                    let docs = try PythonBridge.scanSummaries(root: folder)
                    allDocs.append(contentsOf: docs)
                } catch {
                    continue
                }
            }
            DispatchQueue.main.async {
                self.allDocuments = allDocs
                self.isLoaded = true
                self.isLoading = false
                self.statusMessage = "\(allDocs.count) document(s)"
            }
        }
    }
}
