import SwiftUI

/// Descriptor-only search. Displaying this sheet never restores a web view.
struct TabArchiveView: View {
    @Bindable var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var records: [ArchivedTab] {
        browser.tabArchive.visibleRecords(spaceID: browser.activeSpaceID, profileID: browser.profileID, search: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archive — \(browser.spaces.space(browser.activeSpaceID)?.title ?? "Space")")
                    .font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search titles and addresses", text: $search)
                .accessibilityLabel("Search archived tabs")
            List(records) { record in
                HStack {
                    VStack(alignment: .leading) {
                        Text(record.title.isEmpty ? record.url.host() ?? "Page" : record.title).lineLimit(1)
                        Text(record.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(record.archivedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") {
                        Task {
                            if await browser.restoreArchivedTab(record.id) { dismiss() }
                        }
                    }
                    .accessibilityLabel("Restore \(record.title.isEmpty ? record.url.absoluteString : record.title)")
                }
            }
            .overlay {
                if records.isEmpty { ContentUnavailableView("No Archived Tabs", systemImage: "archivebox") }
            }
            HStack {
                Button("Undo Last Archive") { browser.undoArchive() }
                    .disabled(browser.lastArchivedRecordID == nil || browser.tabArchive.isBusy)
                Button("Retry Recovery Cleanup") { Task { await browser.reconcileArchiveRecovery() } }
                    .disabled(browser.tabArchive.isBusy)
                Spacer()
                Text("\(records.count) tabs in this Space").foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Automatically archive read-only temporary tabs after one idle day", isOn: Binding(
                get: { browser.tabArchive.snapshot.automaticEnabled },
                set: { enabled in
                    Task {
                        do { try await browser.tabArchive.setAutomaticEnabled(enabled) }
                        catch { browser.archiveError = error.localizedDescription }
                    }
                }))
                .disabled(browser.tabArchive.isBusy)
            Text("Local Browser policy, off by default. Checks one background tab per minute after a 30-minute startup or wake grace period. Editors, embedded pages, unknown work, and saved tabs are kept. Archive is not memory suspension.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if browser.tabArchive.recovered {
                Text("The archive was recovered from its previous valid copy.").foregroundStyle(.secondary)
            }
            if let error = browser.archiveError {
                Text(error).foregroundStyle(.primary).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { await browser.reconcileArchiveRecovery() }
    }
}
