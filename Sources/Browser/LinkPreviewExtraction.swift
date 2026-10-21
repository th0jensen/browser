import Foundation

/// Static fetch/extraction outcomes are separate from model and schema failures.
enum LinkPreviewFailure: Error, Sendable, Equatable {
    case blocked, loginRequired, insufficientText, unsupportedContent, fetchFailed, summaryFailed, timedOut

    var message: String {
        switch self {
        case .blocked: "This page requires a security check or JavaScript. Open the page to read it."
        case .loginRequired: "This page requires sign-in. Open the page to read it."
        case .insufficientText: "There is not enough readable text. Open the page to read it."
        case .unsupportedContent: "This content type cannot be previewed. Open the page to view it."
        case .fetchFailed: "The page could not be fetched. Open the page to read it."
        case .summaryFailed: "A summary could not be generated. Open the page to read it."
        case .timedOut: "The preview timed out. Open the page to read it."
        }
    }
}

/// A bounded, non-rendering selector, not a DOM or a browser HTML parser. Malformed
/// tags, deep nesting and raw-text elements fail closed. No subresources execute.
enum LinkPreviewExtractor {
    static let byteLimit = 128 * 1024
    static let textLimit = 6500
    static let supportedMIMETypes: Set<String> = ["text/html", "application/xhtml+xml", "text/plain"]
    private static let minimumText = 100
    private static let blockTags: Set<String> = [
        "html", "head", "body", "p", "div", "section", "article", "main", "li", "br", "ul", "ol",
        "h1", "h2", "h3", "h4", "h5", "h6", "title", "nav", "header", "footer", "form", "aside",
        "noscript", "blockquote", "pre", "table", "tr", "td", "figure", "figcaption"
    ]

    struct Extraction: Sendable {
        let text: String
        let metadata: [String: String]
        let failure: LinkPreviewFailure?
    }

    static func extract(_ source: String, mimeType: String = "text/html") throws -> Extraction {
        try Task.checkCancellation()
        guard supportedMIMETypes.contains(mimeType.lowercased()) else {
            return Extraction(text: "", metadata: [:], failure: .unsupportedContent)
        }
        if mimeType.lowercased() == "text/plain" {
            let text = String(bounded(source).prefix(textLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
            return Extraction(text: text, metadata: [:], failure: failure(text: text,
                evidence: [Evidence(text: text, role: .body, article: nil)], hasReadableArticle: false, loginFormWithoutContent: false))
        }
        var parser = Parser(source)
        return try parser.parse()
    }

    private static func bounded(_ source: String) -> String {
        String(decoding: source.utf8.prefix(byteLimit), as: UTF8.self)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func failure(text: String, evidence: [Evidence], hasReadableArticle: Bool,
                                loginFormWithoutContent: Bool) -> LinkPreviewFailure? {
        let gates = ["verify you are human", "checking your browser", "just a moment", "access denied",
                     "complete the security check", "checking if the site connection is secure",
                     "enable javascript to continue", "please enable javascript", "javascript is required",
                     "enable javascript and cookies to continue", "you need to enable javascript to run this app",
                     "sorry, you have been blocked", "access to this page has been denied",
                     "verify that you are human", "please verify you are a human", "performing security verification"]
        let gateTitles = gates + ["security check", "javascript required", "enable javascript", "attention required"]
        let canonical: (String) -> String = {
            normalized($0).lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let isGate: (String) -> Bool = {
            let value = canonical($0)
            return gateTitles.contains(value) || value.hasPrefix("please enable javascript to ")
        }
        // Keep source roles: a page-level interstitial is not an article subsection,
        // quotation, login widget, or optional no-script notice beside readable text.
        let pageHeadings = evidence.filter { $0.role == .title || $0.role == .pageHeading }
        if pageHeadings.contains(where: { isGate($0.text) }) { return .blocked }
        if text.count < minimumText && evidence.contains(where: { $0.role == .notice && isGate($0.text) }) { return .blocked }
        let body = evidence.filter { $0.role == .body && $0.article == nil }
        if !hasReadableArticle {
            let instruction = body.contains { isGate($0.text) }
            let supportingCopy = body.contains { block in
                let value = canonical(block.text)
                return value.contains("complete the security check before accessing")
                    || value.contains("redirect once verification is complete")
                    || value.contains("enable javascript and cookies to continue")
            }
            // Standalone blocks allow branding before the challenge instruction.
            let shortGate = text.count < 1200 && body.contains { block in
                let value = canonical(block.text)
                return gates.contains { value.hasPrefix($0) }
            }
            if (instruction && supportingCopy) || shortGate { return .blocked }
        }
        let loginHeadings = ["sign in", "log in", "login", "sign in to continue", "log in to continue"]
        let loginHeading = pageHeadings.contains { loginHeadings.contains(canonical($0.text)) }
        let shortLogin = !hasReadableArticle && text.count < 1200 && body.contains { block in
            let value = canonical(block.text)
            return ["sign in to continue", "log in to continue", "please sign in to read", "sign in to read"]
                .contains { value.hasPrefix($0) }
        }
        if loginFormWithoutContent || shortLogin || (loginHeading && text.count < 1200) { return .loginRequired }
        if text.count < minimumText { return .insufficientText }
        return nil
    }

    private struct Block {
        let text: String
        let article: Int?
        let main: Int?
    }

    private enum EvidenceRole {
        case body, title, pageHeading, subsection, notice, form, quotation
    }

    private struct Evidence {
        let text: String
        let role: EvidenceRole
        let article: Int?
    }

    private struct Frame {
        let name: String
        let article: Int?
        let main: Int?
        let hidden: Bool
        let excluded: Bool
    }

    private struct Parser {
        let bytes: [UInt8]
        var cursor = 0
        var stack: [Frame] = []
        var blocks: [Block] = []
        var pending = ""
        var sourceText = ""
        var evidence: [Evidence] = []
        var pageTitle = ""
        var metadata: [String: String] = [:]
        var password = false
        var candidateCount = 0
        var tokenCount = 0

        init(_ source: String) { bytes = Array(source.utf8.prefix(byteLimit)) }

        mutating func parse() throws -> Extraction {
            while cursor < bytes.count && tokenCount < 16000 {
                tokenCount += 1
                if tokenCount % 128 == 0 { try Task.checkCancellation() }
                if bytes[cursor] != 60 { // <
                    let start = cursor
                    while cursor < bytes.count && bytes[cursor] != 60 { cursor += 1 }
                    append(String(decoding: bytes[start..<cursor], as: UTF8.self))
                    continue
                }
                if matches([60, 33, 45, 45], at: cursor) {
                    cursor += 4
                    while cursor < bytes.count && !matches([45, 45, 62], at: cursor) { cursor += 1 }
                    cursor = min(cursor + 3, bytes.count)
                    continue
                }
                guard let tag = readTag() else { break }
                if tag.name.isEmpty { continue }
                if tag.closing {
                    if let index = stack.lastIndex(where: { $0.name == tag.name }) {
                        if stack[index...].contains(where: { blockTags.contains($0.name) }) { flush() }
                        stack.removeSubrange(index...)
                    } else if blockTags.contains(tag.name) { flush() }
                    continue
                }
                if ["script", "style", "textarea", "iframe"].contains(tag.name) {
                    flush()
                    skipRaw(tag.name)
                    continue
                }
                if ["template", "svg"].contains(tag.name) {
                    flush()
                    if tag.name != "svg" || !tag.selfClosing { try skipInert(tag.name) }
                    continue
                }
                if tag.name == "meta", metadata.count < 32,
                   let key = tag.attributes["property"] ?? tag.attributes["name"], let value = tag.attributes["content"] {
                    metadata[key.lowercased()] = decode(value)
                }
                if tag.name == "input", tag.attributes["type"]?.lowercased() == "password" { password = true }
                if blockTags.contains(tag.name) { flush() }
                // Recover common omitted end tags without retaining an unbounded stack.
                if ["p", "li", "h1", "h2", "h3"].contains(tag.name), stack.last?.name == tag.name { stack.removeLast() }
                let parent = stack.last
                var article = parent?.article, main = parent?.main
                if candidateCount < 32 && ["article", "main"].contains(tag.name) {
                    candidateCount += 1
                    if tag.name == "article" { article = candidateCount } else { main = candidateCount }
                }
                let hidden = parent?.hidden == true || tag.attributes["hidden"] != nil || tag.attributes["aria-hidden"]?.lowercased() == "true"
                let excluded = parent?.excluded == true || ["head", "title", "nav", "footer", "aside", "form", "noscript"].contains(tag.name)
                    || (tag.name == "header" && article == nil && main == nil)
                if !tag.selfClosing && !["meta", "input", "img", "br", "hr", "link", "source", "wbr", "area", "base", "embed"].contains(tag.name) {
                    guard stack.count < 128 else { break }
                    stack.append(Frame(name: tag.name, article: article, main: main, hidden: hidden, excluded: excluded))
                }
            }
            flush()
            try Task.checkCancellation()
            let article = bestCandidate(\.article)
            let main = bestCandidate(\.main)
            let selected = blocks.filter { block in
                if let article { return block.article == article }
                if let main { return block.main == main }
                return true
            }.map(\.text).joined(separator: "\n\n")
            let selectedText = String(selected.prefix(textLimit))
            let titled = pageTitle.isEmpty || selectedText.hasPrefix(pageTitle) ? selectedText : pageTitle + "\n\n" + selectedText
            let text = String(titled.prefix(textLimit))
            let status = failure(text: selectedText, evidence: evidence, hasReadableArticle: article != nil,
                                 loginFormWithoutContent: password && selectedText.count < minimumText)
            return Extraction(text: text, metadata: metadata, failure: status)
        }

        func bestCandidate(_ key: KeyPath<Block, Int?>) -> Int? {
            var scores: [Int: Int] = [:]
            for block in blocks {
                if let id = block[keyPath: key] { scores[id, default: 0] += block.text.count }
            }
            return scores.filter { $0.value >= minimumText }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.first?.key
        }

        mutating func append(_ raw: String) {
            guard stack.last?.hidden != true,
                  !stack.contains(where: { ["nav", "footer", "aside"].contains($0.name) }) else { return }
            let text = decode(raw)
            sourceText += text
            if stack.last?.excluded != true { pending += text }
        }

        mutating func flush() {
            let source = normalized(sourceText)
            if !source.isEmpty && evidence.count < 2048 {
                let role = evidenceRole
                evidence.append(Evidence(text: source, role: role, article: stack.last?.article))
                if role == .title && pageTitle.isEmpty { pageTitle = String(source.prefix(200)) }
            }
            sourceText = ""
            let text = normalized(pending)
            if !text.isEmpty && blocks.count < 2048 { blocks.append(Block(text: text, article: stack.last?.article, main: stack.last?.main)) }
            pending = ""
        }

        var evidenceRole: EvidenceRole {
            if stack.contains(where: { ["blockquote", "q", "pre", "code"].contains($0.name) }) { return .quotation }
            if stack.contains(where: { $0.name == "noscript" }) { return .notice }
            if stack.contains(where: { $0.name == "form" }) { return .form }
            if stack.contains(where: { $0.name == "title" }) { return .title }
            if stack.contains(where: { ["h1", "h2", "h3", "h4", "h5", "h6"].contains($0.name) }) {
                return stack.last?.article == nil && stack.contains(where: { $0.name == "h1" }) ? .pageHeading : .subsection
            }
            return .body
        }

        /// Raw-text elements cannot nest. Never interpret markup in their content.
        mutating func skipRaw(_ name: String) {
            let closingTag = Array(("</" + name).utf8)
            while cursor < bytes.count {
                let end = cursor + closingTag.count
                if matches(closingTag, at: cursor), end < bytes.count,
                   space(bytes[end]) || bytes[end] == 62 || bytes[end] == 47 {
                    if readTag() == nil { cursor = bytes.count }
                    return
                }
                cursor += 1
            }
        }

        /// Template/SVG containers can nest. A missing close, malformed tag, or
        /// exhausted budget discards the remaining input, never exposing inert data.
        mutating func skipInert(_ root: String) throws {
            var containers = [root]
            while cursor < bytes.count && tokenCount < 16000 {
                tokenCount += 1
                if tokenCount % 128 == 0 { try Task.checkCancellation() }
                if bytes[cursor] != 60 {
                    while cursor < bytes.count && bytes[cursor] != 60 { cursor += 1 }
                    continue
                }
                if matches([60, 33, 45, 45], at: cursor) {
                    cursor += 4
                    while cursor < bytes.count && !matches([45, 45, 62], at: cursor) { cursor += 1 }
                    cursor = min(cursor + 3, bytes.count)
                    continue
                }
                if matches(Array("<![cdata[".utf8), at: cursor) {
                    cursor += 9
                    while cursor < bytes.count && !matches([93, 93, 62], at: cursor) { cursor += 1 }
                    cursor = min(cursor + 3, bytes.count)
                    continue
                }
                guard let tag = readTag() else { break }
                if !tag.closing && ["script", "style", "textarea", "iframe", "title", "xmp", "noembed", "noframes"].contains(tag.name) {
                    skipRaw(tag.name)
                } else if ["template", "svg"].contains(tag.name) {
                    if tag.closing {
                        if containers.last == tag.name {
                            containers.removeLast()
                            if containers.isEmpty { return }
                        }
                    } else if tag.name != "svg" || !tag.selfClosing {
                        guard containers.count < 128 else { break }
                        containers.append(tag.name)
                    }
                }
            }
            cursor = bytes.count
        }

        func matches(_ target: [UInt8], at index: Int) -> Bool {
            guard index + target.count <= bytes.count else { return false }
            return target.indices.allSatisfy { lower(bytes[index + $0]) == target[$0] }
        }

        func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
        func space(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }

        struct Tag {
            let name: String
            let closing: Bool
            let selfClosing: Bool
            let attributes: [String: String]
        }

        mutating func readTag() -> Tag? {
            let start = cursor
            cursor += 1
            var quote: UInt8?
            while cursor < bytes.count && cursor - start <= 4096 {
                let byte = bytes[cursor]
                if let current = quote { if byte == current { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                cursor += 1
            }
            guard cursor < bytes.count, bytes[cursor] == 62 else { return nil }
            let end = cursor
            cursor += 1
            var i = start + 1
            let closing = i < end && bytes[i] == 47
            if closing { i += 1 }
            let nameStart = i
            while i < end && ((65...90).contains(bytes[i]) || (97...122).contains(bytes[i]) || (48...57).contains(bytes[i])) { i += 1 }
            let name = String(decoding: bytes[nameStart..<i].map(lower), as: UTF8.self)
            var attributes: [String: String] = [:]
            while i < end && attributes.count < 32 {
                while i < end && (space(bytes[i]) || bytes[i] == 47) { i += 1 }
                let keyStart = i
                while i < end && !space(bytes[i]) && ![61, 47].contains(bytes[i]) { i += 1 }
                guard i > keyStart else { break }
                let key = String(decoding: bytes[keyStart..<i].map(lower), as: UTF8.self)
                while i < end && space(bytes[i]) { i += 1 }
                var value = ""
                if i < end && bytes[i] == 61 {
                    i += 1
                    while i < end && space(bytes[i]) { i += 1 }
                    let quote = i < end && [34, 39].contains(bytes[i]) ? bytes[i] : nil
                    if quote != nil { i += 1 }
                    let valueStart = i
                    while i < end && (quote.map { bytes[i] != $0 } ?? !space(bytes[i])) { i += 1 }
                    value = String(decoding: bytes[valueStart..<i].prefix(2048), as: UTF8.self)
                    if quote != nil && i < end { i += 1 }
                }
                attributes[key] = value
            }
            return Tag(name: name, closing: closing, selfClosing: end > start && bytes[end - 1] == 47, attributes: attributes)
        }
    }

    /// Decode only bounded character references. Do not parse HTML again after decoding.
    private static func decode(_ text: String) -> String {
        let named = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "ndash": "–", "mdash": "—", "rsquo": "’"]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&" {
                let end = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
                if let semicolon = text[index..<end].firstIndex(of: ";") {
                    let entity = String(text[text.index(after: index)..<semicolon])
                    var replacement = named[entity]
                    if entity.hasPrefix("#") {
                        let hex = entity.lowercased().hasPrefix("#x")
                        if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                           let scalar = UnicodeScalar(number), !CharacterSet.controlCharacters.contains(scalar) {
                            replacement = String(scalar)
                        }
                    }
                    if let replacement {
                        result += replacement
                        index = text.index(after: semicolon)
                        continue
                    }
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }
}
