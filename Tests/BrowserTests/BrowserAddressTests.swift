import XCTest
@testable import Browser

final class BrowserAddressTests: XCTestCase {
    func testHTTPSAddressIsPreserved() {
        XCTAssertEqual(BrowserAddress.url(for: " https://example.com/path ")?.absoluteString,
                       "https://example.com/path")
    }

    func testDomainGainsHTTPS() {
        XCTAssertEqual(BrowserAddress.url(for: "example.com/docs")?.absoluteString,
                       "https://example.com/docs")
    }

    func testWordsBecomeEncodedSearch() {
        let url = BrowserAddress.url(for: "swift webkit", searchEngine: .google)
        XCTAssertEqual(url?.host(), "www.google.com")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value, "swift webkit")
    }

    func testEachSearchEngineSearchesForTheWords() {
        let expected: [SearchEngine: String] = [
            .google: "https://www.google.com/search?q=swift%20%26%20webkit",
            .duckDuckGo: "https://duckduckgo.com/?q=swift%20%26%20webkit",
            .bing: "https://www.bing.com/search?q=swift%20%26%20webkit",
            .kagi: "https://kagi.com/search?q=swift%20%26%20webkit",
            .ecosia: "https://www.ecosia.org/search?q=swift%20%26%20webkit",
        ]
        for engine in SearchEngine.allCases {
            XCTAssertEqual(BrowserAddress.url(for: " swift & webkit ", searchEngine: engine)?.absoluteString,
                           expected[engine], engine.title)
        }
    }

    func testPlusSignsAreSearchedFor() {
        XCTAssertEqual(SearchEngine.duckDuckGo.searchURL(for: "c++")?.absoluteString, "https://duckduckgo.com/?q=c%2B%2B")
    }

    func testAddressesIgnoreTheSearchEngine() {
        XCTAssertEqual(BrowserAddress.url(for: "swift.org", searchEngine: .kagi)?.absoluteString, "https://swift.org")
    }

    func testEmptyInputDoesNothing() {
        XCTAssertNil(BrowserAddress.url(for: "  "))
    }
}
