import AppKit
import UniformTypeIdentifiers
import WebKit

extension BrowserModel {
    func saveWebpage() {
        guard let tab = peek?.tab ?? activeTab, !tab.isNewTab, let webView = tab.webView,
              let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Webpage"
        panel.allowedContentTypes = [UTType(filenameExtension: "webarchive") ?? .data]
        panel.nameFieldStringValue = tab.title.replacingOccurrences(of: "/", with: "-") + ".webarchive"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        webView.createWebArchiveData { continuation.resume(with: $0) }
                    }
                    try data.write(to: destination, options: .atomic)
                } catch {
                    let alert = NSAlert(error: error)
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }
}
