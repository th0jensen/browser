import Foundation
import SwiftUI

struct AddressSuggestion: Identifiable, Equatable {
    let url: URL
    let title: String
    let isBookmarked: Bool

    var id: URL { url }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url.host().map(Bookmark.trimmedHost) ?? url.absoluteString
    }
}

/// Pages from history and bookmarks that match what's typed in the address bar.
enum AddressSuggestions {
    static let limit = 6

    /// How well a page matches, best first: its address starts with the text, a word in its title does,
    /// or the address or title contains every word typed.
    private enum Match: Int, Comparable {
        case contains = 1
        case titleWord
        case addressPrefix

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Candidate {
        let url: URL
        var title: String
        var visitCount = 0
        var lastVisit = Date.distantPast
        var isBookmarked = false
    }

    /// Ranks matching pages by how well they match, then by how often and how recently they were visited.
    /// A bookmark counts like a few visits.
    static func rank(_ query: String, pages: [HistoryPage], bookmarks: [Bookmark], now: Date = .now,
                     limit: Int = limit) -> [AddressSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        var candidates: [URL: Candidate] = [:]
        for page in pages where ["http", "https"].contains(page.url.scheme?.lowercased() ?? "") {
            candidates[page.url] = Candidate(url: page.url, title: page.title, visitCount: page.visitCount,
                                             lastVisit: page.lastVisit)
        }
        for bookmark in bookmarks {
            var candidate = candidates[bookmark.url] ?? Candidate(url: bookmark.url, title: bookmark.title)
            candidate.isBookmarked = true
            if !bookmark.title.isEmpty { candidate.title = bookmark.title }
            candidates[bookmark.url] = candidate
        }

        let ranked = candidates.values.compactMap { candidate -> (Candidate, Match, Double, Int)? in
            let address = strippedAddress(candidate.url).lowercased()
            guard let match = match(query, address: address, url: candidate.url, title: candidate.title)
            else { return nil }
            let weight = frecency(visitCount: candidate.visitCount, lastVisit: candidate.lastVisit, now: now)
                + (candidate.isBookmarked ? 2 : 0)
            return (candidate, match, weight, address.count)
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            if a.3 != b.3 { return a.3 < b.3 }
            return a.0.url.absoluteString < b.0.url.absoluteString
        }

        return ranked.prefix(limit).map {
            AddressSuggestion(url: $0.0.url, title: $0.0.title, isBookmarked: $0.0.isBookmarked)
        }
    }

    private static func match(_ query: String, address: String, url: URL, title: String) -> Match? {
        let title = title.lowercased()
        if address.hasPrefix(query) || url.absoluteString.lowercased().hasPrefix(query) { return .addressPrefix }
        if title.hasPrefix(query)
            || title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) {
            return .titleWord
        }
        let text = "\(address) \(title)"
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { text.contains($0) } ? .contains : nil
    }

    /// Visits count for less as they age.
    static func frecency(visitCount: Int, lastVisit: Date, now: Date) -> Double {
        let days = now.timeIntervalSince(lastVisit) / (24 * 60 * 60)
        let recency = switch days {
        case ..<1: 1.0
        case ..<7: 0.7
        case ..<30: 0.4
        case ..<90: 0.2
        default: 0.1
        }
        return Double(visitCount) * recency
    }

    /// The address without its scheme, `www.`, or a trailing slash, as it's typed: "github.com/athasdev".
    static func strippedAddress(_ url: URL) -> String {
        var address = url.absoluteString
        for prefix in ["https://", "http://"] where address.lowercased().hasPrefix(prefix) {
            address.removeFirst(prefix.count)
        }
        if address.lowercased().hasPrefix("www.") { address.removeFirst(4) }
        if url.path == "/", url.query == nil, url.fragment == nil, address.hasSuffix("/") { address.removeLast() }
        return address
    }

    /// The text to complete the address bar to, keeping what was typed: the top suggestion's site while the text
    /// has no path, otherwise its full address. `nil` when the suggestion doesn't start with the text.
    static func inlineCompletion(of text: String, with suggestion: AddressSuggestion?) -> String? {
        guard let suggestion, !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let address = strippedAddress(suggestion.url)
        let site = String(address.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        let hasResource = text.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        var target = hasResource ? address : site
        if text.lowercased().hasPrefix("www.") { target = "www." + target }
        guard target.count > text.count else { return nil }
        // Hosts are case-insensitive; paths, queries and fragments need their original spelling.
        // Do not complete a resource prefix whose case differs, since keeping that input would
        // produce an address different from the suggestion.
        let typedPrefix = String(target.prefix(text.count))
        let resourceStart = target.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? target.endIndex
        let hostLength = target.distance(from: target.startIndex, to: resourceStart)
        guard String(typedPrefix.prefix(hostLength)).lowercased() == String(text.prefix(hostLength)).lowercased(),
              typedPrefix.dropFirst(hostLength) == text.dropFirst(hostLength) else { return nil }
        return text + target.dropFirst(text.count)
    }

    /// Resolves an accepted inline completion with the origin of the suggestion.
    /// The field hides the scheme and `www.`; that presentation must not change
    /// an HTTP site into HTTPS or send a `www.` site to a different host.
    static func completedURL(for text: String, with suggestion: AddressSuggestion?) -> URL? {
        guard let suggestion, !text.isEmpty, !text.contains(where: \.isWhitespace),
              let source = URLComponents(url: suggestion.url, resolvingAgainstBaseURL: false),
              let sourceScheme = source.scheme, ["http", "https"].contains(sourceScheme.lowercased()) else { return nil }
        let hasScheme = text.contains("://")
        guard var completed = URLComponents(string: hasScheme ? text : "\(sourceScheme)://\(text)"),
              ["http", "https"].contains(completed.scheme?.lowercased() ?? ""),
              let host = completed.host, let sourceHost = source.host,
              hostWithoutWWW(host) == hostWithoutWWW(sourceHost), completed.port == source.port,
              completed.user == source.user, completed.password == source.password else { return nil }
        let hasResource = !completed.percentEncodedPath.isEmpty || completed.percentEncodedQuery != nil
            || completed.percentEncodedFragment != nil
        if hasResource {
            guard completed.percentEncodedPath == source.percentEncodedPath,
                  completed.percentEncodedQuery == source.percentEncodedQuery,
                  completed.percentEncodedFragment == source.percentEncodedFragment else { return nil }
        }
        completed.host = sourceHost
        return completed.url
    }

    private static func hostWithoutWWW(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

}

/// The suggestions shown under the address bar while typing.
struct AddressSuggestionList: View {
    let suggestions: [AddressSuggestion]
    let selectedIndex: Int?
    let choose: (AddressSuggestion) -> Void
    @State private var hoveredID: URL?

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion, isSelected: index == selectedIndex)
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private func row(_ suggestion: AddressSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: 9) {
            SiteIcon(url: suggestion.url, size: 16)
            Text(suggestion.displayTitle)
                .lineLimit(1)
                .layoutPriority(1)
            Text(AddressSuggestions.strippedAddress(suggestion.url))
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            if suggestion.isBookmarked {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint)
                      : AnyShapeStyle(Color.primary.opacity(hoveredID == suggestion.id ? 0.07 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? suggestion.id : (hoveredID == suggestion.id ? nil : hoveredID) }
        // Chosen on mouse down, before the address bar loses focus and closes the list.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in choose(suggestion) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(suggestion) }
    }
}
