import SwiftUI

/// Native menu controls work with keyboard focus and VoiceOver; switching has no motion.
struct SpaceSwitcher: View {
    let browser: BrowserModel
    @State private var isCreating = false
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        if !browser.isPrivate && !browser.isExtensionWindow {
            Menu {
                Text("\(BrowserProfile.displayName) · Shared logins")
                ForEach(browser.spaces.spaces) { space in
                    Button {
                        browser.selectSpace(space.id)
                    } label: {
                        if browser.activeSpaceID == space.id {
                            Label(space.title, systemImage: "checkmark")
                        } else { Text(space.title) }
                    }
                }
                Divider()
                Button("New Space…") { name = ""; errorMessage = nil; isCreating = true }
            } label: {
                Label(browser.spaces.space(browser.activeSpaceID)?.title ?? "Default", systemImage: "square.stack")
                    .lineLimit(1)
            }
            .disabled(browser.tabDrag.payload != nil)
            .help("Switch Space. Spaces use the Existing Profile and share logins.")
            .accessibilityLabel("Space: \(browser.spaces.space(browser.activeSpaceID)?.title ?? "Default")")
            .sheet(isPresented: $isCreating) { creationSheet }
        }
    }

    private var creationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space").font(.headline)
            Text("Spaces have separate tabs and saved pages. They share logins in the Existing Profile.")
                .foregroundStyle(.secondary)
            TextField("Space name", text: $name).focused($nameIsFocused)
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isCreating = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    do {
                        try browser.createSpace(title: name)
                        isCreating = false
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameIsFocused = true }
    }
}
