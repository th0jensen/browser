import XCTest
@testable import Browser

@MainActor
final class LinkPreviewExtractionTests: XCTestCase {
    private let article = "Tomato seedlings need warm soil and regular watering. Plant after the last frost, leave room between plants, and support the stems as they grow."
    private let page = URL(string: "https://example.com/garden")!

    func testPrefersArticleInsideMainOverNavigationAndSurroundingText() throws {
        let html = """
        <head><title>Growing tomatoes</title></head>
        <nav>\(String(repeating: "Home Categories Account ", count: 200))</nav>
        <div>\(String(repeating: "Unrelated recommendations. ", count: 100))</div>
        <main><p>Introduction to the site.</p><article>
        <header><h1>Planting guide</h1></header><p>\(article)</p><p>Water the soil, not the leaves.</p>
        </article><p>Related articles and promotions.</p></main>
        <footer>Contact and legal terms.</footer>
        """
        let result = try LinkPreviewExtractor.extract(html)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.text.hasPrefix("Growing tomatoes\n\nPlanting guide"))
        XCTAssertTrue(result.text.contains(article))
        XCTAssertTrue(result.text.contains("\n\nWater the soil"))
        for unwanted in ["Categories", "Unrelated", "promotions", "legal terms"] {
            XCTAssertFalse(result.text.contains(unwanted), unwanted)
        }
    }

    func testPrefersUsableMainButFallsBackWhenArticleIsTooShort() throws {
        let main = try LinkPreviewExtractor.extract("<div>Unrelated recommendations.</div><main><article>Teaser.</article><p>\(article)</p></main>")
        XCTAssertNil(main.failure)
        XCTAssertTrue(main.text.contains(article))
        XCTAssertFalse(main.text.contains("Unrelated"))
        let fallback = try LinkPreviewExtractor.extract("<main>Short.</main><div>\(article)</div>")
        XCTAssertNil(fallback.failure)
        XCTAssertTrue(fallback.text.contains(article))
    }

    func testChoosesOneArticleWithoutCombiningUnrelatedArticles() throws {
        let result = try LinkPreviewExtractor.extract("<article>\(article)</article><article>\(String(repeating: "Second story. ", count: 9))</article>")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.text, article)
        XCTAssertFalse(result.text.contains("Second story"))
    }

    func testChallengeAndJavaScriptGatesNeverBecomeSummaries() throws {
        let challenges = [
            "<title>Just a moment...</title><main>\(String(repeating: "Waiting for verification. ", count: 80))</main>",
            "<h1>Verify you are human</h1><p>Complete the security check before accessing the content.</p>",
            "<noscript>Please enable JavaScript</noscript>",
            "<h1>Checking your browser</h1><form>Security check</form>",
            "<h1>Verify <strong>you</strong> are human</h1><p>\(String(repeating: "Waiting for verification. ", count: 80))</p>",
            "<h1>Sorry, you have been blocked</h1><p>\(String(repeating: "Request details. ", count: 80))</p>",
            "<noscript>Please enable JavaScript to view this page.</noscript>",
            "<p>Enable JavaScript and cookies to continue.</p>"
        ]
        for html in challenges {
            XCTAssertEqual(try LinkPreviewExtractor.extract(html).failure, .blocked, html)
            XCTAssertThrowsError(try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)) {
                XCTAssertEqual($0 as? LinkPreviewFailure, .blocked)
            }
        }
    }

    func testLoginShortAndNavigationOnlyPagesHaveDistinctOutcomes() throws {
        for html in ["<h1>Sign in to continue</h1><p>Use your account to read this page.</p>",
                     "<form><label>Email</label><input type='password'><button>Sign in</button></form>"] {
            XCTAssertEqual(try LinkPreviewExtractor.extract(html).failure, .loginRequired)
        }
        XCTAssertEqual(try LinkPreviewExtractor.extract("<h1>A short page</h1><p>Hello.</p>").failure, .insufficientText)
        XCTAssertEqual(try LinkPreviewExtractor.extract("<title>\(String(repeating: "Title only ", count: 20))</title>").failure, .insufficientText)
        XCTAssertEqual(try LinkPreviewExtractor.extract("<nav>\(String(repeating: "Home News Contact ", count: 500))</nav>").failure, .insufficientText)
    }

    func testOrdinaryArticleCanDiscussSecurityAndContainLoginWidget() throws {
        let text = "Security checks protect accounts. Websites may ask visitors to verify you are human, enable JavaScript to continue, or sign in to continue. This article explains these checks."
        let result = try LinkPreviewExtractor.extract("<title>How security checks work</title><nav><h2>Sign in</h2><h2>Verify you are human</h2></nav><article><h1>Browser security</h1><p>\(text)</p></article><form><h2>Sign in</h2><input type=password><button>Sign in</button></form>")
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.text.contains(text))
    }

    func testPlainTextIsNotParsedAsHTMLAndUnsupportedTypesAreRejected() throws {
        let text = "Literal <script> and <article> strings are source text, not markup. " + article
        let plain = try LinkPreviewExtractor.extract(text, mimeType: "text/plain")
        XCTAssertNil(plain.failure)
        XCTAssertEqual(plain.text, text)
        for type in ["application/pdf", "image/png", "application/json", ""] {
            XCTAssertEqual(try LinkPreviewExtractor.extract(article, mimeType: type).failure, .unsupportedContent)
        }
    }

    func testHTTPFailuresDoNotEstablishBlockedStatus() throws {
        for code in [403, 404, 429, 500, 503] {
            XCTAssertThrowsError(try LinkPreviewFetcher.document(from: "<p>\(article)</p>", mimeType: "text/html", statusCode: code, at: page)) {
                XCTAssertEqual($0 as? LinkPreviewFailure, .fetchFailed)
            }
        }
        XCTAssertThrowsError(try LinkPreviewFetcher.document(from: "<h1>Verify you are human</h1>", mimeType: "text/html", statusCode: 403, at: page)) {
            XCTAssertEqual($0 as? LinkPreviewFailure, .blocked)
        }
        XCTAssertThrowsError(try LinkPreviewFetcher.document(from: "", mimeType: "text/html", statusCode: 401, at: page)) {
            XCTAssertEqual($0 as? LinkPreviewFailure, .loginRequired)
        }
        XCTAssertThrowsError(try LinkPreviewFetcher.document(from: article, mimeType: "application/pdf", statusCode: 200, at: page)) {
            XCTAssertEqual($0 as? LinkPreviewFailure, .unsupportedContent)
        }
    }

    func testMalformedMarkupHasBoundedSafeRecovery() throws {
        let malformed = "<main><p>\(article)<p>Second paragraph without closing tags.<!-- unfinished comment <script>evil"
        let result = try LinkPreviewExtractor.extract(malformed)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.text.contains(article))
        XCTAssertTrue(result.text.contains("\n\nSecond paragraph"))
        XCTAssertFalse(result.text.contains("evil"))
        for suffix in ["<script>never closed <article>injected", "<div title='unterminated > injected", "<style>never closed",
                       "<div data-long='" + String(repeating: "x", count: 5000) + "'>injected</div>"] {
            let safe = try LinkPreviewExtractor.extract("<article><p>\(article)</p></article>" + suffix)
            XCTAssertEqual(safe.text, article)
        }
        let deep = try LinkPreviewExtractor.extract(String(repeating: "<div>", count: 200) + article)
        XCTAssertEqual(deep.failure, .insufficientText)
    }

    func testByteTextAndTokenLimitsExcludeLateContent() throws {
        let oversized = "<article><p>" + String(repeating: "Bounded content. ", count: 12000) + "</p></article><h1>Verify you are human</h1>"
        let result = try LinkPreviewExtractor.extract(oversized)
        XCTAssertLessThanOrEqual(result.text.count, LinkPreviewExtractor.textLimit)
        XCTAssertFalse(result.text.contains("Verify"))
        let tokenHeavy = String(repeating: "<br>", count: 17000) + article
        XCTAssertEqual(try LinkPreviewExtractor.extract(tokenHeavy).failure, .insufficientText)
    }

    func testExecutableHiddenAndMetadataLookingTextNeverBecomeContentOrImages() throws {
        let html = """
        <script>const x = '</scripture><meta property="og:image" content="https://evil.example.com/x">';</script>
        <style>bad css</style><template><p>Template content</p></template>
        <textarea><meta property=og:image content=https://evil.example.com/textarea></textarea>
        <div hidden>Hidden content</div><div aria-hidden=true>Invisible content</div>
        <article><p>\(article)</p><p>&#x1F345; &amp; &#39; &lt;script&gt;</p></article>
        <meta content='/hero.jpg?a=1&amp;b=2' property='og:image'>
        """
        let result = try LinkPreviewExtractor.extract(html)
        XCTAssertNil(result.failure)
        for unwanted in ["const", "bad css", "Template", "Hidden", "Invisible"] { XCTAssertFalse(result.text.contains(unwanted)) }
        XCTAssertTrue(result.text.contains("🍅 & ' <script>"))
        let document = try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)
        XCTAssertEqual(document.imageURL?.absoluteString, "https://example.com/hero.jpg?a=1&b=2")
    }

    func testBrandedNonHeadingSecurityInterstitialIsRejectedAtDocumentBoundary() throws {
        let html = """
        <title>Example</title><main>
        <div>example.com</div><div>Verify you are human</div>
        <p>Complete the security check before accessing this website. This process is automatic. Your browser will redirect once verification is complete.</p>
        </main>
        """
        XCTAssertEqual(try LinkPreviewExtractor.extract(html).failure, .blocked)
        XCTAssertThrowsError(try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)) {
            XCTAssertEqual($0 as? LinkPreviewFailure, .blocked)
        }
    }

    func testOptionalNoscriptNoticeDoesNotBlockReadableArticle() throws {
        let notice = "<noscript>Please enable JavaScript to view this page.</noscript>"
        for html in [notice + "<article><h1>Growing tomatoes</h1><p>\(String(repeating: article, count: 12))</p></article>",
                     "<article><h1>Growing tomatoes</h1>\(notice)<p>\(String(repeating: article, count: 12))</p></article>"] {
            let extraction = try LinkPreviewExtractor.extract(html)
            XCTAssertNil(extraction.failure)
            XCTAssertFalse(extraction.text.contains("Please enable JavaScript"))
            let document = try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)
            XCTAssertEqual(document.text, extraction.text)
            XCTAssertTrue(document.text.contains(article))
        }
    }

    func testArticleSecuritySubsectionAndQuotedGateCopyAreNotPageLevelEvidence() throws {
        let html = """
        <title>Browser security explained</title><article><h1>Browser security</h1>
        <p>\(String(repeating: article, count: 12))</p><h2>Security check</h2>
        <p>Sites use security checks to protect their users.</p>
        <blockquote><div>Verify you are human</div><p>Complete the security check before accessing this website. Your browser will redirect once verification is complete.</p></blockquote>
        </article>
        """
        let extraction = try LinkPreviewExtractor.extract(html)
        XCTAssertNil(extraction.failure)
        let document = try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)
        XCTAssertEqual(document.text, extraction.text)
        XCTAssertTrue(document.text.contains("Security check"))
    }

    func testNestedInertContainersCannotSupplyArticleTextOrPublisherImages() throws {
        for tag in ["template", "svg"] {
            let inert = """
            <\(tag)><\(tag)></\(tag)>
            <article>\(String(repeating: "Inert article text must never reach inference. ", count: 40))</article>
            <meta property="og:image" content="https://cdn.example.com/inert.jpg">
            </\(tag)>
            """
            let empty = try LinkPreviewExtractor.extract(inert)
            XCTAssertEqual(empty.failure, .insufficientText)
            XCTAssertTrue(empty.text.isEmpty)
            XCTAssertTrue(empty.metadata.isEmpty)
            XCTAssertThrowsError(try LinkPreviewFetcher.document(from: inert, mimeType: "text/html", statusCode: 200, at: page)) {
                XCTAssertEqual($0 as? LinkPreviewFailure, .insufficientText)
            }
            for html in [inert + "<article>\(article)</article>", "<article>\(article)</article>" + inert] {
                let extraction = try LinkPreviewExtractor.extract(html)
                XCTAssertNil(extraction.failure)
                XCTAssertEqual(extraction.text, article)
                XCTAssertTrue(extraction.metadata.isEmpty)
                let document = try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)
                XCTAssertEqual(document.text, article)
                XCTAssertNil(document.imageURL)
            }
            let liveImage = try LinkPreviewFetcher.document(
                from: inert + "<article>\(article)</article><meta property='og:image' content='/live.jpg'>",
                mimeType: "text/html", statusCode: 200, at: page)
            XCTAssertEqual(liveImage.imageURL?.absoluteString, "https://example.com/live.jpg")
        }
    }

    func testMixedInertNestingAndRawTextCannotCloseOuterContainer() throws {
        let html = """
        <template><svg><svg/><![CDATA[<g></svg><meta property=og:image content=https://cdn.example.com/cdata.jpg>]]></svg>
        <template><title></template><meta property=og:image content=https://cdn.example.com/title.jpg></title>
        <script>const close = '</template>';</script>
        <!-- </template> --></template><meta property=og:image content=https://cdn.example.com/inert.jpg>
        <article>\(String(repeating: "Inert text. ", count: 2000))</article></template>
        <article>\(article)</article>
        """
        let extraction = try LinkPreviewExtractor.extract(html)
        XCTAssertNil(extraction.failure)
        XCTAssertEqual(extraction.text, article)
        XCTAssertTrue(extraction.metadata.isEmpty)
        let document = try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)
        XCTAssertEqual(document.text, article)
        XCTAssertNil(document.imageURL)
    }

    func testInertDepthLimitAndMissingCloseDiscardRemainingInput() throws {
        for tag in ["template", "svg"] {
            for inert in ["<\(tag)><\(tag)></\(tag)>", String(repeating: "<\(tag)>", count: 130)] {
                let html = inert + "<article>\(article)</article><meta property=og:image content=https://cdn.example.com/inert.jpg>"
                let extraction = try LinkPreviewExtractor.extract(html)
                XCTAssertEqual(extraction.failure, .insufficientText)
                XCTAssertTrue(extraction.text.isEmpty)
                XCTAssertTrue(extraction.metadata.isEmpty)
                XCTAssertThrowsError(try LinkPreviewFetcher.document(from: html, mimeType: "text/html", statusCode: 200, at: page)) {
                    XCTAssertEqual($0 as? LinkPreviewFailure, .insufficientText)
                }
            }
        }
    }

    func testCancelledExtractionDoesNotReturnContent() async {
        let source = "<article>\(article)</article>"
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try LinkPreviewExtractor.extract(source)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
    }

    func testFailureCopyAndShareTextContainOutcomeAndSource() {
        let state = LinkPreviewState(url: page)
        state.failure = .blocked
        state.isLoading = false
        XCTAssertEqual(state.contextText, LinkPreviewFailure.blocked.message + "\n\n" + page.absoluteString)
    }
}
