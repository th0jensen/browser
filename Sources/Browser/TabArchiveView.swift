import SwiftUI

/// Descriptor-only search. Displaying this sheet never restores a web view.
struct TabArchiveView: View {
    @Bindable var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var scope: TabArchivePolicyScope?

    init(browser: BrowserModel) {
        self.browser = browser
        _scope = State(initialValue: browser.archivePolicyScope())
    }

    private var records: [ArchivedTab] {
        guard let scope else { return [] }
        return browser.tabArchive.visibleRecords(spaceID: scope.spaceID, profileID: scope.profileID, search: search)
    }

    private var scopeIsCurrent: Bool { scope?.isCurrent(in: browser) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archive — \(scope?.spaceTitle ?? "Unavailable Space")")
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
            Text("Automatic archive — \(scope?.profileLabel ?? "Unavailable profile")").font(.headline)
            Text("Applies to all Spaces using this profile. The list above shows only \(scope?.spaceTitle ?? "the original Space").")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically archive read-only temporary tabs after one idle day", isOn: Binding(
                get: { scope.map { browser.tabArchive.policy(forProfileID: $0.profileID).automaticEnabled } ?? false },
                set: { enabled in
                    // Capture the owner and value before creating the task, not from the active profile later.
                    guard let scope, scope.isCurrent(in: browser) else {
                        browser.archiveError = TabArchiveError.policyScopeChanged.localizedDescription
                        return
                    }
                    var policy = browser.tabArchive.policy(forProfileID: scope.profileID)
                    policy.automaticEnabled = enabled
                    Task {
                        do {
                            if !(try await browser.setArchivePolicy(policy, for: scope)) {
                                browser.archiveError = "The policy was saved only for \(scope.profileLabel). The Space changed; reopen Archive to edit another profile."
                            }
                        } catch { browser.archiveError = error.localizedDescription }
                    }
                }))
                .accessibilityLabel("Automatic archive after one idle day for \(scope?.profileLabel ?? "unavailable profile")")
                .disabled(browser.tabArchive.isBusy || !scopeIsCurrent)
            if !scopeIsCurrent {
                Text("The Space or profile changed. Reopen Archive to edit its policy.").foregroundStyle(.secondary)
            }
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
