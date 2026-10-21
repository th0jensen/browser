import SwiftUI

struct LinkRoutingSettings: View {
    let rules: LinkRouteRuleStore
    let spaces: BrowserSpaceStore
    @State private var draft: LinkRouteRule?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Rules apply to web links opened from other apps. The first matching rule wins. Move rules up or down to set their order.")
                Text("Other links use the front ordinary window and its selected Space. If a destination is missing or unavailable, the same fallback applies. Private windows are never selected.")
                    .foregroundStyle(.secondary)
                Text("Spaces share the Existing Profile and its logins. Source-app conditions are not available.")
                    .foregroundStyle(.secondary)
            }
            Section("Host Rules") {
                ForEach(Array(rules.rules.enumerated()), id: \.element.id) { index, rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(index + 1). \(rule.host)").fontWeight(.medium)
                            Spacer()
                            Button { perform { try rules.move(rule.id, by: -1) } } label: {
                                Image(systemName: "arrow.up")
                            }
                            .accessibilityLabel("Move \(rule.host) earlier")
                            .disabled(index == 0)
                            Button { perform { try rules.move(rule.id, by: 1) } } label: {
                                Image(systemName: "arrow.down")
                            }
                            .accessibilityLabel("Move \(rule.host) later")
                            .disabled(index == rules.rules.count - 1)
                            Button("Edit") { draft = rule }
                                .accessibilityLabel("Edit rule for \(rule.host)")
                            Button("Delete", role: .destructive) { perform { try rules.remove(rule.id) } }
                                .accessibilityLabel("Delete rule for \(rule.host)")
                        }
                        Text(rule.includesSubdomains ? "This host and its subdomains" : "This host only")
                            .foregroundStyle(.secondary)
                        if let destination = spaces.space(rule.destinationSpaceID), destination.profileID == BrowserProfile.defaultID {
                            Text("Destination Space: \(destination.title)")
                        } else {
                            Text("Destination Space: unavailable — uses the ordinary fallback")
                                .foregroundStyle(.secondary)
                        }
                        if rule.sourceBundleID != nil {
                            Text("This rule requires a source identity that is not available. It will not match.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if rules.rules.isEmpty { Text("No host rules. Links use the ordinary fallback.").foregroundStyle(.secondary) }
                Button("Add Host Rule") {
                    draft = LinkRouteRule(host: "", includesSubdomains: false,
                                          destinationSpaceID: BrowserSpaceStore.defaultSpaceID)
                }
            }
            .disabled(rules.loadFailed)
            if rules.loadFailed { Text(LinkRouteRuleStore.Failure.unreadableFile.localizedDescription).foregroundStyle(.secondary) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary).accessibilityLabel("Rule error: \(errorMessage)") }
        }
        .sheet(item: $draft) { rule in
            LinkRouteEditor(rule: rule, rules: rules, spaces: spaces)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct LinkRouteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: LinkRouteRule
    let rules: LinkRouteRuleStore
    let spaces: BrowserSpaceStore
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Host Rule").font(.title2)
            Form {
                TextField("Host", text: $rule.host, prompt: Text("example.com"))
                Toggle("Include subdomains", isOn: $rule.includesSubdomains)
                Picker("Destination Space", selection: $rule.destinationSpaceID) {
                    ForEach(spaces.spaces.filter { $0.profileID == BrowserProfile.defaultID }) { space in
                        Text(space.title).tag(space.id)
                    }
                    if spaces.space(rule.destinationSpaceID) == nil {
                        Text("Unavailable Space").tag(rule.destinationSpaceID)
                    }
                }
                Text("Enter only a host, not a URL. New rules are added last. The first matching rule wins.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary).accessibilityLabel("Rule error: \(errorMessage)") }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try rules.save(rule, spaces: spaces); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
