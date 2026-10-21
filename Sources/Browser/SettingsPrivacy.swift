import SwiftUI
import WebKit

struct PrivacySettings: View {
    let browsingData: BrowsingData
    let contentBlocker: ContentBlocker
    @State private var clearDataPresentation: ClearDataPresentation?
    @State private var websiteSearchQuery = ""
    @State private var isConfirmingWebsiteDataRemoval = false

    private var matchingSiteRecords: [WKWebsiteDataRecord] {
        let searchText = websiteSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !searchText.isEmpty else { return browsingData.siteRecords }
        return browsingData.siteRecords.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { contentBlocker.isEnabled }, set: { contentBlocker.setEnabled($0) })) {
                    Text("Block trackers")
                    Text("Stops known tracking and advertising services from loading on other sites. "
                         + "You can turn it off for a site from the shield in the address bar. Extension blockers are controlled separately.")
                }
                if let error = contentBlocker.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Button("Retry Tracker Protection") { Task { await contentBlocker.prepare() } }
                } else if contentBlocker.isEnabled && !contentBlocker.isReady {
                    Label("Preparing tracker protection…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("History and website data") {
                    Button("Clear…") {
                        guard clearDataPresentation == nil else { return }
                        clearDataPresentation = ClearDataPresentation(profileName: BrowserProfile.displayName, data: browsingData)
                    }
                }
            }

            Section {
                TextField("Search", text: $websiteSearchQuery, prompt: Text("Search Sites"))
                    .labelsHidden()
                if !browsingData.hasLoadedSiteRecords {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if matchingSiteRecords.isEmpty {
                    Text(websiteSearchQuery.isEmpty ? "No websites have stored data." : "No sites match “\(websiteSearchQuery)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matchingSiteRecords, id: \.displayName) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.displayName)
                                Text(BrowsingData.summary(of: record))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                Task { await browsingData.removeData(for: [record]) }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Website Data")
                    Spacer()
                    Button("Remove All") { isConfirmingWebsiteDataRemoval = true }
                        .disabled(browsingData.siteRecords.isEmpty)
                }
            }
        }
        .task { await browsingData.loadSiteRecords() }
        .sheet(item: $clearDataPresentation) { request in
            ClearDataView(request: request)
        }
        .confirmationDialog("Remove data stored by all websites?", isPresented: $isConfirmingWebsiteDataRemoval) {
            Button("Remove All", role: .destructive) {
                Task { await browsingData.removeData(for: browsingData.siteRecords) }
            }
        } message: {
            Text("This signs you out of most websites, and can’t be undone.")
        }
    }
}

struct SiteSettings: View {
    let contentBlocker: ContentBlocker
    let sitePermissions: SitePermissions
    let zoomLevels: ZoomStore

    var body: some View {
        Form {
            Section {
                let sites = sitePermissions.mediaDecisions
                if sites.isEmpty {
                    Text("No sites have asked to use the camera or microphone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sites) { site in
                    HStack {
                        Text(site.site)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        permissionPicker("Camera", .camera, current: site.camera, site: site.site)
                        permissionPicker("Microphone", .microphone, current: site.microphone, site: site.site)
                        removeButton { sitePermissions.removeDecisions(on: site.site) }
                    }
                }
            } header: {
                sectionHeader("Camera and Microphone", isEmpty: sitePermissions.mediaDecisions.isEmpty) {
                    sitePermissions.removeAllMediaDecisions()
                }
            } footer: {
                Text("Private windows ask again, and forget the answers when they close.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                let levels = zoomLevels.levelsByHost.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                if levels.isEmpty {
                    Text("Sites you zoom in or out on are remembered here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(levels, id: \.key) { host, level in
                    HStack {
                        Text(host)
                        Spacer()
                        Text(level, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        removeButton { zoomLevels.setLevel(1, for: host) }
                    }
                }
            } header: {
                sectionHeader("Page Zoom", isEmpty: zoomLevels.levelsByHost.isEmpty) { zoomLevels.removeAll() }
            }

            Section {
                if contentBlocker.exceptions.isEmpty {
                    Text("No sites are excluded from the built-in tracker protection.")
                        .foregroundStyle(.secondary)
                }
                ForEach(contentBlocker.exceptions, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        removeButton { Task { await contentBlocker.removeException(site) } }
                    }
                }
            } header: {
                sectionHeader("Tracker Blocking Turned Off", isEmpty: contentBlocker.exceptions.isEmpty) {
                    Task { await contentBlocker.removeAllExceptions() }
                }
            }
        }
    }

    private func permissionPicker(_ title: String, _ permission: SitePermissions.Permission, current: Bool?,
                                  site: String) -> some View {
        Picker(title, selection: Binding(get: { current },
                                         set: { sitePermissions.setDecision($0, for: permission, on: site) })) {
            Text("Ask").tag(Bool?.none)
            Text("Allow").tag(Bool?.some(true))
            Text("Don’t Allow").tag(Bool?.some(false))
        }
        .fixedSize()
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Reset")
    }

    private func sectionHeader(_ title: String, isEmpty: Bool, resetAll: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Reset All", action: resetAll)
                .disabled(isEmpty)
        }
    }
}

/// History ▸ Clear History and Website Data, also opened from Settings ▸ Privacy.
struct ClearDataView: View {
    let request: ClearDataPresentation
    private var data: BrowsingData { request.data }
    @Environment(\.dismiss) private var dismiss
    @State private var range = HistoryClearRange.lastHour
    @State private var options: ClearDataOptions = [.history, .siteData, .cache]
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear History and Website Data")
                .font(.system(size: 15, weight: .semibold))
            Text("Profile: \(request.profileName)")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityLabel("Clear data for profile \(request.profileName)")

            Picker("Clear:", selection: $range) {
                ForEach(HistoryClearRange.allCases) { range in
                    Text(range == .all ? "All Time" : range.title).tag(range)
                }
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("History", isOn: binding(for: .history))
                Toggle(isOn: binding(for: .siteData)) {
                    Text("Cookies and website data")
                    Text("Signs you out of most websites.")
                }
                Toggle("Cached images and files", isOn: binding(for: .cache))
                if data.includesSharedState { Toggle("Site icons", isOn: binding(for: .favicons)) }
            }

            Text(data.includesSharedState
                 ? "Only the Existing Profile is cleared. Private windows and other profiles are not affected."
                 : "Only this profile is cleared. Other profiles and private windows are not affected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if isClearing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clear") {
                    isClearing = true
                    Task {
                        await data.clear(options, range: range)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(options.isEmpty || isClearing)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func binding(for option: ClearDataOptions) -> Binding<Bool> {
        Binding(get: { options.contains(option) },
                set: { if $0 { options.insert(option) } else { options.remove(option) } })
    }
}
