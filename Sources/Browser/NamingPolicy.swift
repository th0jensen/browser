import Foundation

/// Local deterministic rules, not recovered Arc code. Prefer a longer name over
/// losing identity. Bounded lexical anchors protect names and the main subject
/// without requiring every descriptive word or adding a language-model pass.
enum NamingPolicy {
    struct CacheKey: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case title, download }
        let kind: Kind
        let input: String
        let context: String
        let page: String
    }

    static func normalized(_ value: String) -> String {
        value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func withoutNotificationCount(_ value: String) -> String {
        // Four-digit values can be useful years, not notification counts.
        value.replacingOccurrences(of: #"^\s*(?:(?:\(\d{1,3}\)|\[\d{1,3}\])\s*)+"#,
                                   with: "", options: .regularExpression)
    }

    static func cleanedTitle(_ value: String) -> String {
        let title = normalized(withoutNotificationCount(value))
        guard !tokens(title).isEmpty else { return normalized(value) }
        // Remove only explicit boilerplate. A website can also be the subject.
        let cleaned = title.replacingOccurrences(
            of: #"(?i)\s+[-–—|]\s+(?:Google Search|Bing Search|Official Site|Official Website)\s*$"#,
            with: "", options: .regularExpression)
        return tokens(cleaned).isEmpty ? title : cleaned
    }

    static func titleNeedsModel(_ value: String) -> Bool {
        let title = cleanedTitle(value)
        // Already informative short titles stay in their original language/case.
        return (37...180).contains(title.count) && tokens(title).count > 3
    }

    static func selectTitle(original: String, cleaned: String, short: String) -> String {
        let fallback = cleanedTitle(original)
        guard titleNeedsModel(original) else { return fallback }
        for (candidate, limit) in [(short, 72), (cleaned, 160)] {
            let name = cleanedTitle(candidate)
            if validCandidate(candidate, limit: limit), name.count <= fallback.count,
               preservesIdentity(name, original: fallback) {
                return name
            }
        }
        return fallback
    }

    /// The extension is always selected by the application, never by the model.
    static func filenameParts(_ filename: String) -> (stem: String, suffix: String) {
        let compounds = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]
        let suffix = compounds.first { filename.lowercased().hasSuffix("." + $0) }
            .map { String(filename.suffix($0.count)) } ?? (filename as NSString).pathExtension
        return (suffix.isEmpty ? filename : String(filename.dropLast(suffix.count + 1)), suffix)
    }

    static func cleanedDownloadStem(_ stem: String) -> String {
        var name = normalized(stem)
        // Only terminal copy markers and explicit UUID suffixes are removed.
        // Unknown numbers and hash suffixes can be useful builds, versions,
        // commits or dates; keep them on informative names.
        name = name.replacingOccurrences(of: #"(?i)(?:\s*\((?:copy|\d{1,3})\)|[ _-]+copy[ _-]+\d{1,3})+$"#,
                                         with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)[ _-]+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                                         with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ")
        // Keep ISO dates and the minute in a familiar screenshot timestamp.
        // Do not reinterpret ambiguous locale-specific dates or numeric IDs.
        name = name.replacingOccurrences(of: #"(\d{4}-\d{2}-\d{2}) at (\d{2})\.(\d{2})\.\d{2}(?=\s|@|$)"#,
                                         with: "$1 at $2.$3", options: .regularExpression)
        name = normalized(name)
        return tokens(name).isEmpty ? stem : name
    }

    static func isSyntheticStem(_ stem: String) -> Bool {
        let name = normalized(stem).lowercased()
        if name.range(of: #"^(?:image|img|file|download|document|attachment|untitled)[ _-]*\d{0,3}$"#,
                      options: .regularExpression) != nil { return true }
        return name.range(of: #"^(?:(?=[0-9a-f]*[a-f])[0-9a-f]{16,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#,
                          options: .regularExpression) != nil
    }

    static func downloadNeedsModel(filename: String, sourceTitle: String) -> Bool {
        let stem = cleanedDownloadStem(filenameParts(filename).stem)
        let source = cleanedTitle(sourceTitle)
        return filename.count <= 160 && source.count <= 160 &&
            isSyntheticStem(stem) && !isGeneric(source) && !isSyntheticStem(source)
    }

    static func selectDownloadStem(filename: String, sourceTitle: String, candidate: String) -> String {
        let original = filenameParts(filename).stem
        let fallback = cleanedDownloadStem(original)
        // Informative names need no inference. In particular, preserve versions,
        // builds and dates rather than trying to classify a number as an ID.
        guard downloadNeedsModel(filename: filename, sourceTitle: sourceTitle) else { return fallback }
        let source = cleanedTitle(sourceTitle)
        let name = normalized(candidate)
        guard validCandidate(candidate, limit: 100),
              name.range(of: #"\.\p{L}{1,10}$"#, options: .regularExpression) == nil,
              !isSyntheticStem(name),
              preservesIdentity(name, original: source) else { return fallback }
        return name
    }

    private static func validCandidate(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit &&
            value.rangeOfCharacter(from: .controlCharacters) == nil &&
            value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:{}\"`")) == nil &&
            !value.hasPrefix(".") && !isGeneric(value)
    }

    private static func tokens(_ value: String) -> [String] {
        // Keep C++, C# and non-Latin text as identity-bearing tokens.
        let pattern = #"[\p{L}\p{N}]+[+#]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static func isGeneric(_ value: String) -> Bool {
        let words = tokens(value).map { $0.lowercased() }
        let generic: Set<String> = ["home", "page", "website", "untitled", "document", "file", "download", "image", "summary"]
        return words.isEmpty || words.allSatisfy { generic.contains($0) }
    }

    private static let connectors: Set<String> = [
        "a", "an", "the", "of", "for", "and", "to", "in", "with", "on", "at", "by", "from", "using"
    ]
    // Page formats and editorial wrappers, not arbitrary adjectives or nouns.
    // A lone short title still bypasses inference and keeps its original spelling.
    private static let wrappers: Set<String> = [
        "understanding", "introduction", "intro", "overview", "learn", "learning", "how",
        "guide", "tutorial", "video", "recipe", "photograph", "photo", "panoramic"
    ]

    private static func identityText(_ original: String) -> String {
        // A language name is identity even when it also names the publisher.
        // Only the fixed site description can disappear, never the captured name.
        var text = original.replacingOccurrences(
            of: #"\s+[-–—|]\s+The ([\p{L}\p{N}+#.-]+) Programming Language$"#,
            with: " $1", options: .regularExpression)
        if let separator = text.range(of: #"\s+[-–—|]\s+"#, options: [.regularExpression, .backwards]) {
            let primary = String(text[..<separator.lowerBound])
            let suffix = tokens(String(text[separator.upperBound...]))
            // A repeated publisher plus a site-kind suffix is boilerplate. An
            // unknown publisher or author is ambiguous and remains protected.
            let siteKinds: Set<String> = ["gallery", "blog", "documentation", "docs"]
            if let kind = suffix.last, siteKinds.contains(kind.lowercased()) {
                let identifiers = suffix.dropLast().filter { !connectors.contains($0.lowercased()) }
                let primaryWords = Set(tokens(primary))
                if !identifiers.isEmpty, identifiers.allSatisfy({ primaryWords.contains($0) }) { text = primary }
            }
        }
        return text
    }

    private static func preservesIdentity(_ candidate: String, original: String) -> Bool {
        let text = identityText(original)
        let sourceWords = tokens(text)
        let candidateTokens = Set(tokens(candidate))
        let candidateWords = Set(candidateTokens.map { $0.lowercased() })
        let sourceSet = Set(tokens(original).map { $0.lowercased() })
        // Ground every content word in the input. Small connective additions
        // allow natural labels such as "Ownership in Rust", not translation.
        guard candidateWords.subtracting(connectors).isSubset(of: sourceSet) else { return false }
        let content = sourceWords.filter {
            !connectors.contains($0.lowercased()) && !wrappers.contains($0.lowercased())
        }
        let names = Set(content.filter { $0.contains(where: \.isUppercase) })
        guard names.isSubset(of: candidateTokens) else { return false }

        // The leading subject is essential; trailing scene/occasion details are
        // optional. Names and numbers in those details are still protected.
        let detail = text.range(of: #"(?i)\b(?:above|below|during|behind|beneath|against)\b"#, options: .regularExpression)
        let subject = String(text[..<(detail?.lowerBound ?? text.endIndex)])
        let subjectWords = tokens(subject).filter {
            !connectors.contains($0.lowercased()) && !wrappers.contains($0.lowercased()) &&
                !names.contains($0) && !$0.contains(where: \.isNumber)
        }
        var required = Set(subjectWords.prefix(2).map { $0.lowercased() })
        // Lower-case names cannot be recognized by case. Preserve explicit
        // subject qualifiers too ("ownership in rust", "writing by anna delvey").
        if let qualifier = subject.range(of: #"(?i)\b(?:in|with|using|by|from|for)\b"#, options: .regularExpression) {
            required.formUnion(tokens(String(subject[qualifier.upperBound...])).filter {
                !connectors.contains($0.lowercased()) && !wrappers.contains($0.lowercased())
            }.map { $0.lowercased() })
        }
        required.formUnion(content.filter { $0.contains(where: \.isNumber) }.map { $0.lowercased() })
        // Keep date/version context next to a number, including lower-case month
        // names, rather than retaining a bare year and dropping its meaning.
        for index in sourceWords.indices where index > 0 && sourceWords[index].contains(where: \.isNumber) {
            let previous = sourceWords[index - 1].lowercased()
            if !connectors.contains(previous), !wrappers.contains(previous) { required.insert(previous) }
        }
        let polarity: Set<String> = ["not", "no", "without", "never"]
        required.formUnion(sourceWords.map { $0.lowercased() }.filter { polarity.contains($0) })
        guard !names.isEmpty || !required.isEmpty, required.isSubset(of: candidateWords) else { return false }
        // Token sets alone cannot distinguish 2.4 from 4.2 or reordered dates.
        let numericPattern = #"\b[vV]?\d+(?:[.-]\d+)+\b"#
        guard let regex = try? NSRegularExpression(pattern: numericPattern) else { return false }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).allSatisfy {
            guard let range = Range($0.range, in: text) else { return false }
            return candidate.contains(text[range])
        }
    }
}
