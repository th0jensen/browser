import XCTest
@testable import Browser

final class AddressSuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func page(_ address: String, title: String = "", visits: Int, daysAgo: Double = 0) -> HistoryPage {
        HistoryPage(url: URL(string: address)!, title: title, visitCount: visits,
                    lastVisit: now - daysAgo * 24 * 60 * 60)
    }

    private func suggestion(_ address: String) -> AddressSuggestion {
        AddressSuggestion(url: URL(string: address)!, title: "", isBookmarked: false)
    }

    func testAddressPrefixMatchesComeFirstThenMoreFrequentAndRecentVisits() {
        let pages = [
            page("https://example.com/digital", title: "A digital garden", visits: 50),
            page("https://gitlab.com/", visits: 3),
            page("https://github.com/", visits: 3, daysAgo: 20),
            page("https://www.github.com/athasdev", visits: 9),
            page("https://swift.org/", title: "Git tutorial", visits: 1),
        ]

        let ranked = AddressSuggestions.rank("git", pages: pages, bookmarks: [], now: now)

        XCTAssertEqual(ranked.map(\.url.absoluteString), [
            "https://www.github.com/athasdev", "https://gitlab.com/", "https://github.com/",
            "https://swift.org/", "https://example.com/digital",
        ])
    }

    func testBookmarksAreSuggestedAndMarked() {
        let bookmark = Bookmark(title: "Athas", url: URL(string: "https://athas.dev")!)
        let pages = [page("https://athas.dev", visits: 1), page("https://atlassian.com", visits: 2)]

        let ranked = AddressSuggestions.rank("at", pages: pages, bookmarks: [bookmark], now: now)

        XCTAssertEqual(ranked.map { $0.url.host() }, ["athas.dev", "atlassian.com"])
        XCTAssertEqual(ranked.first?.title, "Athas")
        XCTAssertEqual(ranked.map(\.isBookmarked), [true, false])
    }

    func testEveryWordTypedMustMatch() {
        let pages = [page("https://swift.org/blog", title: "Swift Blog", visits: 1),
                     page("https://swift.org/", title: "Swift", visits: 5)]

        let ranked = AddressSuggestions.rank("swift blog", pages: pages, bookmarks: [], now: now)

        XCTAssertEqual(ranked.map(\.url.absoluteString), ["https://swift.org/blog"])
        XCTAssertTrue(AddressSuggestions.rank("  ", pages: pages, bookmarks: [], now: now).isEmpty)
    }

    func testBoundedTopKMatchesFullSortWithStableTiesAndBookmarkMerging() {
        let pages = (0..<180).map { index in
            let host = index % 3 == 0 ? "git\(index).example" : "site\(index).example"
            let title = index % 3 == 1 ? "Git guide" : "A digital garden"
            return page("https://\(host)/", title: title, visits: index % 7, daysAgo: Double(index % 100))
        }
        let bookmarks = pages.enumerated().compactMap { index, page in
            index % 5 == 0 ? Bookmark(title: page.title, url: page.url) : nil
        }
        let bookmarked = Set(bookmarks.map(\.url))
        func tier(_ page: HistoryPage) -> Int {
            if AddressSuggestions.strippedAddress(page.url).hasPrefix("git") { return 3 }
            if page.title.hasPrefix("Git") { return 2 }
            return 1
        }
        func weight(_ page: HistoryPage) -> Double {
            AddressSuggestions.frecency(visitCount: page.visitCount, lastVisit: page.lastVisit, now: now)
                + (bookmarked.contains(page.url) ? 2 : 0)
        }
        let sorted = pages.sorted { a, b in
            if tier(a) != tier(b) { return tier(a) > tier(b) }
            if weight(a) != weight(b) { return weight(a) > weight(b) }
            let aLength = AddressSuggestions.strippedAddress(a.url).count
            let bLength = AddressSuggestions.strippedAddress(b.url).count
            if aLength != bLength { return aLength < bLength }
            return a.url.absoluteString < b.url.absoluteString
        }
        for limit in [0, 1, 2, 6, 17, 180, 200] {
            let expected = sorted.prefix(limit).map {
                AddressSuggestion(url: $0.url, title: $0.title, isBookmarked: bookmarked.contains($0.url))
            }
            XCTAssertEqual(AddressSuggestions.rank("git", pages: pages, bookmarks: bookmarks, now: now, limit: limit), expected)
            XCTAssertEqual(AddressSuggestions.rank("git", pages: pages.reversed(), bookmarks: bookmarks.reversed(), now: now, limit: limit), expected)
        }
        XCTAssertTrue(AddressSuggestions.rank("git", pages: pages, bookmarks: bookmarks, limit: -1).isEmpty)
    }

    func testOlderVisitsCountForLess() {
        XCTAssertGreaterThan(AddressSuggestions.frecency(visitCount: 2, lastVisit: now, now: now),
                             AddressSuggestions.frecency(visitCount: 2, lastVisit: now - 10 * 24 * 60 * 60, now: now))
    }

    func testStrippedAddress() {
        XCTAssertEqual(AddressSuggestions.strippedAddress(URL(string: "https://www.github.com/")!), "github.com")
        XCTAssertEqual(AddressSuggestions.strippedAddress(URL(string: "http://swift.org/blog/")!), "swift.org/blog/")
    }

    func testInlineCompletionCompletesTheSiteUntilAPathIsTyped() {
        let athas = suggestion("https://www.github.com/athasdev")

        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "git", with: athas), "github.com")
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "Git", with: athas), "Github.com")
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "www.gi", with: athas), "www.github.com")
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "github.com/a", with: athas), "github.com/athasdev")
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "github.com", with: athas))
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "hub", with: athas))
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "git hub", with: athas))
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "git", with: nil))
    }
}


extension AddressSuggestionsTests {
    func testCompletionPreservesCaseSensitivePathsQueriesAndTrailingSlashes() {
        let page = suggestion("https://example.com/Docs/Guide/?token=AbC#Section")
        XCTAssertEqual(AddressSuggestions.strippedAddress(page.url), "example.com/Docs/Guide/?token=AbC#Section")
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "example.com/D", with: page),
                       "example.com/Docs/Guide/?token=AbC#Section")
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "example.com/d", with: page))
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "EXAMPLE.com/Docs/G", with: page),
                       "EXAMPLE.com/Docs/Guide/?token=AbC#Section")
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "example.com/Docs/Guide/?token=A", with: page),
                       "example.com/Docs/Guide/?token=AbC#Section")
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "example.com/Docs/Guide/?token=a", with: page))
        XCTAssertEqual(AddressSuggestions.inlineCompletion(of: "example.com/D", with: suggestion("https://example.com/Docs/")),
                       "example.com/Docs/")
    }

    func testRankingMatchesCaseSensitiveAddressesWithoutRewritingThem() {
        let url = URL(string: "https://example.com/Docs/Guide?token=AbC")!
        let matches = AddressSuggestions.rank("example.com/docs", pages: [], bookmarks: [Bookmark(title: "Guide", url: url)])
        XCTAssertEqual(matches.first?.url, url)
    }
}


extension AddressSuggestionsTests {
    func testAcceptedCompletionPreservesHTTPPortAndCaseSensitiveResource() throws {
        let page = suggestion("http://localhost:8765/Docs/Guide?token=AbC#Section")
        let completion = try XCTUnwrap(AddressSuggestions.inlineCompletion(of: "localhost:8765/D", with: page))
        XCTAssertEqual(AddressSuggestions.completedURL(for: completion, with: page), page.url)
        XCTAssertEqual(AddressSuggestions.completedURL(for: "localhost:8765", with: page)?.absoluteString,
                       "http://localhost:8765")
        XCTAssertNil(AddressSuggestions.completedURL(for: "localhost:8765/docs/Guide?token=AbC#Section", with: page))
        XCTAssertNil(AddressSuggestions.completedURL(for: "localhost:9999/Docs/Guide?token=AbC#Section", with: page))
    }

    func testAcceptedCompletionPreservesHTTPSAndOriginalWWWHost() throws {
        let page = suggestion("https://www.example.com/Docs/")
        let site = try XCTUnwrap(AddressSuggestions.inlineCompletion(of: "exa", with: page))
        XCTAssertEqual(site, "example.com")
        XCTAssertEqual(AddressSuggestions.completedURL(for: site, with: page)?.absoluteString,
                       "https://www.example.com")
        let resource = try XCTUnwrap(AddressSuggestions.inlineCompletion(of: "example.com/D", with: page))
        XCTAssertEqual(AddressSuggestions.completedURL(for: resource, with: page), page.url)
        XCTAssertEqual(AddressSuggestions.completedURL(for: "www.example.com/Docs/", with: page), page.url)
        XCTAssertNil(AddressSuggestions.completedURL(for: "other.example/Docs/", with: page))
        XCTAssertNil(AddressSuggestions.completedURL(for: "example.com", with: nil))
    }
}
