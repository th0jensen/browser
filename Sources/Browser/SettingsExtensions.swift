import SwiftUI

struct ExtensionSettings: View {
    @State private var extensions = BrowserExtensions.shared

    var body: some View {
        Form {
            Section("Installed Extensions") {
                if extensions.installed.isEmpty { Text("No extensions found").foregroundStyle(.secondary) }
                ForEach(extensions.installed) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Toggle(item.name, isOn: Binding(get: { item.isEnabled }, set: { enabled in
                                Task { await extensions.setEnabled(item, enabled) }
                            }))
                            .disabled(extensions.isBusy || item.needsNativeMessaging || (item.ruleCount == 0 && !item.isEnabled))
                            if item.sourceAppName == nil && !item.isManaged {
                                Button("Remove", role: .destructive) { extensions.remove(item) }.disabled(extensions.isBusy)
                            }
                        }
                        if item.isManaged {
                            Text("Built in and updated with Browser").font(.caption).foregroundStyle(.secondary)
                        } else if item.needsNativeMessaging {
                            Text("Requires Safari’s companion app support").font(.caption).foregroundStyle(.secondary)
                        } else if item.kind == .contentBlocker {
                            Text(extensions.activeRuleCounts[item.id].map { "\($0.formatted()) active rules" }
                                 ?? (item.ruleCount == 0 ? "No usable content-blocking rules" : "Content blocker"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = extensions.errors[item.id] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }
                Button("Refresh Extensions") { Task { await extensions.refreshInstalledApplications() } }.disabled(extensions.isBusy)
                if let error = extensions.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Development") {
                DisclosureGroup("Developer tools") {
                    Button("Import Extension…") { Task { await extensions.chooseImport() } }.disabled(extensions.isBusy)
                }
            }
        }
        .task { await extensions.restore() }
    }
}
