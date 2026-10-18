import SwiftUI

/// A browser-owned control for native rule lists, which have no Web Extension action.
struct ContentBlockerButton: View {
    let item: InstalledExtension
    let browser: BrowserModel
    @State private var extensions = BrowserExtensions.shared
    @State private var isPresented = false
    @Environment(\.chromeHoverController) private var chromeHover

    private var name: String { extensions.toolbarName(for: item) }
    private var blockers: [InstalledExtension] { extensions.blockers(for: item) }
    private var activeCount: Int { blockers.reduce(0) { $0 + (extensions.activeRuleCounts[$1.id] ?? 0) } }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label {
                Text(name)
            } icon: {
                Group {
                    if let icon = extensions.blockerIcon(for: item) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else { Image(systemName: "shield.lefthalf.filled") }
                }
                .frame(width: 16, height: 16)
            }
        }
        .labelStyle(ChromeToolbarLabelStyle())
        .font(.system(size: BrowserChrome.toolbarSymbolSize))
        .chromeToolbarButtonStyle()
        .controlSize(.regular)
        .help("\(name): \(activeCount.formatted()) active rules")
        .accessibilityLabel(name)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(name).font(.headline)
                Text(activeCount > 0 ? "\(activeCount.formatted()) active rules" : "No blocking rules active")
                    .foregroundStyle(activeCount > 0 ? Color.secondary : Color.orange)
                Divider()
                ForEach(blockers) { blocker in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(blocker.name, isOn: Binding(get: { blocker.isEnabled }, set: { value in
                            Task { await extensions.setEnabled(blocker, value) }
                        }))
                        .disabled(extensions.isBusy || (blocker.ruleCount == 0 && !blocker.isEnabled))
                        if let error = extensions.errors[blocker.id] {
                            Text(error).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if blocker.ruleCount == 0 {
                            Text("No usable bundled rules for this category.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text("Rules apply to new page loads. Safari’s live settings and Scripts extension are separate.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reload This Page") { browser.reload(); isPresented = false }
                    .disabled(browser.activeTab?.isNewTab != false)
            }
            .lineLimit(nil)
            .padding(16)
            .frame(width: 320)
        }
        .chromePresentation(isPresented: isPresented, controller: chromeHover)
    }
}
