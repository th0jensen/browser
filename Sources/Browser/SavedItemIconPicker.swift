import SwiftUI

/// The existing folder palette is shared verbatim with Space editing.
enum SavedItemIconSymbols {
    nonisolated static let all = ["folder", "briefcase", "house", "airplane", "book", "doc.text", "terminal", "curlybraces",
                                 "gamecontroller", "film", "music.note", "cart", "heart", "star", "leaf", "flame",
                                 "photo", "pencil", "graduationcap", "globe", "map", "cup.and.saucer", "building.2", "lightbulb"]
}

struct SavedItemIconPicker: View {
    @Binding var symbol: String
    @Binding var emoji: String
    @Binding var color: FolderColor
    let emojiAccessibilityLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Icon").font(.subheadline.weight(.medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(SavedItemIconSymbols.all, id: \.self) { candidate in
                    Button { symbol = candidate; emoji = "" } label: {
                        Image(systemName: candidate).font(.system(size: 16)).foregroundStyle(color.tint)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(symbol == candidate && emoji.isEmpty ? Color.primary.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).help(candidate).accessibilityLabel("\(candidate) icon")
                }
            }
            HStack(spacing: 10) {
                Text("Emoji")
                TextField("Or use an emoji", text: $emoji).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(emojiAccessibilityLabel)
                    .onChange(of: emoji) { _, value in if value.count > 1 { emoji = String(value.prefix(1)) } }
                Text("⌃⌘Space").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Color")
                ForEach(FolderColor.allCases, id: \.self) { candidate in
                    Button { color = candidate } label: {
                        Circle().fill(candidate.tint).frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().strokeBorder(color == candidate ? Color.primary.opacity(0.6) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(candidate.rawValue.capitalized) icon color")
                }
            }
        }
    }
}
