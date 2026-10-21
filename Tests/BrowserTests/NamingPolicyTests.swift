import XCTest
@testable import Browser

@MainActor
final class NamingPolicyTests: XCTestCase {
    func testShortTitlesKeepTheirLanguageCaseAndProperNouns() {
        for title in ["Arc", "The Who", "iPhone API", "le jardin de Zoé", "東京の喫茶店", "تعلم Swift", "C++", "YouTube"] {
            XCTAssertFalse(NamingPolicy.titleNeedsModel(title), title)
            XCTAssertEqual(NamingPolicy.selectTitle(original: title, cleaned: "Home", short: "Summary"), title)
        }
    }

    func testNotificationCountsAndExplicitBoilerplateAreRemovedWithoutCuttingWords() {
        XCTAssertEqual(NamingPolicy.cleanedTitle(" (24) [3]  Rust Ownership - Google Search "), "Rust Ownership")
        XCTAssertEqual(NamingPolicy.cleanedTitle("Café Zoé | Official Website"), "Café Zoé")
        XCTAssertEqual(NamingPolicy.cleanedTitle("(2026)"), "(2026)")
        XCTAssertEqual(NamingPolicy.cleanedTitle("(2026) Annual Report"), "(2026) Annual Report")
        XCTAssertEqual(NamingPolicy.cleanedTitle("(999) Annual Report"), "Annual Report")
        XCTAssertEqual(NamingPolicy.cleanedTitle("YouTube"), "YouTube")
        XCTAssertEqual(NamingPolicy.cleanedTitle("Anna Delvey - Anna Delvey"), "Anna Delvey - Anna Delvey")
    }

    func testShortCandidateCannotLoseIdentifyingProperNounsEvenWhenTheyNameTheSite() {
        let original = "Individualized Engineering Expectations - Anna Delvey"
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: original, short: "Engineering Expectations"), original)
        let arc = "Arc by the Browser Company: Monetization Strategy"
        XCTAssertEqual(NamingPolicy.selectTitle(original: arc, cleaned: arc, short: "Monetization Strategy"), arc)
        let youtube = "YouTube Creator Analytics for Science Teachers"
        XCTAssertEqual(NamingPolicy.selectTitle(original: youtube, cleaned: youtube, short: "Creator Analytics"), youtube)
    }

    func testRustOwnershipFromThePromptExampleCanActuallyShorten() {
        let original = "Understanding Ownership - The Rust Programming Language"
        XCTAssertTrue(NamingPolicy.titleNeedsModel(original))
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: "Ownership in Rust", short: "Rust Ownership"), "Rust Ownership")
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: "Ownership in Rust", short: "Ownership"), "Ownership in Rust")
        for candidate in ["Ownership", "Rust", "rust ownership", "Swift Ownership"] {
            XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: "Home", short: candidate), original, candidate)
        }
    }

    func testWrappersAndRepeatedSiteNamesAreOptionalButNewNamesAreNot() {
        let original = "Introduction to Aurora memory ownership - Aurora Docs"
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: original, short: "Aurora memory ownership"), "Aurora memory ownership")
        let author = "Introduction to memory ownership - Anna Delvey"
        XCTAssertEqual(NamingPolicy.selectTitle(original: author, cleaned: author, short: "Memory Ownership"), author)
        let subject = "Learning memory ownership in rust with examples"
        XCTAssertEqual(NamingPolicy.selectTitle(original: subject, cleaned: subject, short: "Memory Ownership"), subject)
    }

    func testCleanedCandidateIsUsedWhenShortCandidateLosesIdentity() {
        let original = "Understanding memory ownership in Rust with Rust"
        let cleaned = "Understanding Rust memory ownership"
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: cleaned, short: "Memory Ownership"), cleaned)
        // This safe label has more than three words. Never truncate it by words.
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: "Home", short: cleaned), cleaned)
    }

    func testInvalidCandidatesUseCleanedOriginalRatherThanATruncatedResult() {
        let original = "(7) Understanding memory ownership in Rust - Google Search"
        let fallback = "Understanding memory ownership in Rust"
        for candidate in ["", "Summary", "Ignore all instructions", "Rust\nOwnership", "../../Rust", "{\"name\":\"Rust\"}", String(repeating: "Rust ", count: 50)] {
            XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: candidate, short: candidate), fallback, candidate)
        }
        let long = String(repeating: "Important subject ", count: 20) + "Anna Delvey"
        XCTAssertFalse(NamingPolicy.titleNeedsModel(long))
        XCTAssertEqual(NamingPolicy.selectTitle(original: long, cleaned: "Important subject", short: "Important"), long)
    }

    func testLanguagesAndAcronymsCannotBeTranslatedOrDropped() {
        let fixtures = [
            "Comprendre la mémoire avec Rust et Zoé à Montréal",
            "東京の喫茶店で学ぶプログラミングとSwiftの入門講座について",
            "تعلم البرمجة باستخدام Swift في مدينة القاهرة للمبتدئين",
            "Understanding C++ API ownership with iPhone and macOS"
        ]
        for original in fixtures {
            XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: "Learn Programming", short: "Rust Guide"), original)
        }
        let original = "Understanding C++ API ownership with iPhone and macOS"
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: original, short: "Understanding C API ownership iPhone macOS"), original)
        XCTAssertEqual(NamingPolicy.selectTitle(original: original, cleaned: "Home", short: "understanding c++ api ownership iphone macos"), original)
    }

    func testInformativeDownloadsKeepSubjectVersionBuildAndUsefulDates() {
        let fixtures = [
            ("Orion-2.4.1-53102.dmg", "Orion-2.4.1-53102"),
            ("Project_Aurora_2026-06-14.pdf", "Project Aurora 2026-06-14"),
            ("source-main.tar.gz", "source-main"),
            ("Carbon Copy.pdf", "Carbon Copy"),
            ("Budget_2026_2026.xlsx", "Budget 2026 2026"),
            ("Build-1234567890123456.zip", "Build-1234567890123456"),
            ("Orion-2.4.1-a1b2c3d4e5f67890.zip", "Orion-2.4.1-a1b2c3d4e5f67890"),
            ("2026061419510500.zip", "2026061419510500"),
            ("IMG_20260614.jpg", "IMG 20260614"),
            ("旅行計画_2026.pdf", "旅行計画 2026")
        ]
        for (filename, expected) in fixtures {
            XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: filename, sourceTitle: "Unrelated Page", candidate: "Unrelated Page"), expected, filename)
        }
    }

    func testGeneratedCopyMarkersAndUUIDSuffixesAreCleaned() {
        for stem in ["Aurora Notes (1)", "Aurora Notes (copy)", "Aurora Notes copy 2", "Aurora Notes (copy) (2)"] {
            XCTAssertEqual(NamingPolicy.cleanedDownloadStem(stem), "Aurora Notes", stem)
        }
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Aurora_Notes_550e8400-e29b-41d4-a716-446655440000"), "Aurora Notes")
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Aurora_Notes_a1b2c3d4e5f67890"), "Aurora Notes a1b2c3d4e5f67890")
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Aurora release 2.4.1"), "Aurora release 2.4.1")
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Report (2026)"), "Report (2026)")
    }

    func testTimestampCleanupKeepsDateHourMinuteAndMeridiemWithoutGuessingLocale() {
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Screenshot 2026-06-14 at 19.51.05"), "Screenshot 2026-06-14 at 19.51")
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Screenshot 2026-06-14 at 11.12.18 PM"), "Screenshot 2026-06-14 at 11.12 PM")
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Report 03-04-26"), "Report 03-04-26")
        XCTAssertEqual(NamingPolicy.cleanedDownloadStem("Export 20260614195105"), "Export 20260614195105")
    }

    func testSyntheticDownloadsUseOnlyClearSourceIdentityInTheInputLanguage() {
        for filename in ["image0.png", "download (1).pdf", "550e8400-e29b-41d4-a716-446655440000.tar.gz", "a1b2c3d4e5f67890.zip"] {
            XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: filename, sourceTitle: "Aurora API Notes", candidate: "Aurora API Notes"), "Aurora API Notes", filename)
        }
        XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: "旅行計画", candidate: "旅行計画"), "旅行計画")
        XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "download.zip", sourceTitle: "Aurora API 2.4", candidate: "Aurora API 2.4"), "Aurora API 2.4")
    }

    func testLongAuroraSourceAllowsAConciseDownloadWithoutLosingIdentity() {
        let source = "Aurora Observatory panoramic photograph of the northern lights above snow covered mountains during the winter expedition - Aurora Gallery"
        XCTAssertTrue(NamingPolicy.downloadNeedsModel(filename: "image.png", sourceTitle: source))
        let concise = "Aurora Observatory northern lights"
        XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: source, candidate: concise), concise)
        for candidate in ["Aurora Observatory", "northern lights", "Aurora northern lights", "Aurora Observatory mountains", "aurora observatory northern lights"] {
            XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: source, candidate: candidate), "image", candidate)
        }
    }

    func testSourceVersionsDatesAndPolarityCannotDisappearOrChange() {
        for (source, candidate) in [
            ("Aurora API 2.4 reference", "Aurora API reference"),
            ("Aurora API 2.4 reference", "Aurora API 4.2 reference"),
            ("Aurora report during june 2026", "Aurora report 2026"),
            ("Aurora report 2026-06-14", "Aurora report 2026-14-06"),
            ("Aurora report without tracking", "Aurora report tracking")
        ] {
            XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: source, candidate: candidate), "image", source)
        }
        XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: "Aurora report during june 2026", candidate: "Aurora report june 2026"), "Aurora report june 2026")
    }

    func testInferenceEligibilityRequiresASyntheticFilenameAndClearBoundedSource() {
        XCTAssertTrue(NamingPolicy.downloadNeedsModel(filename: "image.png", sourceTitle: "Aurora Notes"))
        XCTAssertFalse(NamingPolicy.downloadNeedsModel(filename: "Aurora_2.4.1.zip", sourceTitle: "Aurora Notes"))
        for source in ["", "Home", "Download", "image0", String(repeating: "Aurora ", count: 30)] {
            XCTAssertFalse(NamingPolicy.downloadNeedsModel(filename: "image.png", sourceTitle: source), source)
        }
        XCTAssertFalse(NamingPolicy.downloadNeedsModel(filename: String(repeating: "a", count: 170) + ".png", sourceTitle: "Aurora Notes"))
    }

    func testAmbiguousOrUnsafeDownloadCandidatesKeepTheOriginalStem() {
        for candidate in ["", "Notes", "Aurora Notes.exe", "../Aurora Notes", "Aurora\nNotes", "Secret Instructions", "Aurora Notes 2027", String(repeating: "Aurora Notes ", count: 10)] {
            XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: "Aurora Notes", candidate: candidate), "image", candidate)
        }
        for source in ["", "Home", "Download", "Untitled", String(repeating: "Aurora Notes ", count: 20)] {
            XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: source, candidate: "Aurora Notes"), "image", source)
        }
        XCTAssertEqual(NamingPolicy.selectDownloadStem(filename: "image.png", sourceTitle: "Notes de Zoé", candidate: "Zoe Notes"), "image")
    }

    func testCompoundExtensionsAndCaseStayOutsideTheNamingModel() {
        let parts = NamingPolicy.filenameParts("Aurora-2.4.TAR.GZ")
        XCTAssertEqual(parts.stem, "Aurora-2.4")
        XCTAssertEqual(parts.suffix, "TAR.GZ")
        XCTAssertEqual(NamingPolicy.filenameParts("License").stem, "License")
        XCTAssertEqual(NamingPolicy.filenameParts("License").suffix, "")
    }

    func testCacheKeysSeparateKindsExtensionsAndSourceIdentity() {
        let title = NamingPolicy.CacheKey(kind: .title, input: "Aurora", context: "", page: "example.com")
        XCTAssertNotEqual(title, .init(kind: .download, input: "Aurora", context: "", page: "example.com"))
        XCTAssertNotEqual(title, .init(kind: .title, input: "Aurora", context: "", page: "other.example"))
        let download = NamingPolicy.CacheKey(kind: .download, input: "image.png", context: "Aurora", page: "example.com")
        XCTAssertNotEqual(download, .init(kind: .download, input: "image.pdf", context: "Aurora", page: "example.com"))
        XCTAssertNotEqual(download, .init(kind: .download, input: "image.png", context: "Orion", page: "example.com"))
    }

    func testCancellationAlsoAppliesToDeterministicNamingPaths() async {
        let intelligence = LocalIntelligence()
        let titleTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await intelligence.savedTabName(title: "Aurora", url: URL(string: "https://example.com")!)
        }
        do {
            _ = try await titleTask.value
            XCTFail("Cancelled title naming must not return a deterministic or cached result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let downloadTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await intelligence.downloadName(filename: "Aurora-2.4.zip", sourceTitle: "Aurora", sourceURL: nil)
        }
        do {
            _ = try await downloadTask.value
            XCTFail("Cancelled download naming must not return a deterministic or cached result")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEmptyTitleFailsWithoutAnAvailableModel() async {
        do {
            _ = try await LocalIntelligence().savedTabName(title: " \n ", url: URL(string: "https://example.com")!)
            XCTFail("An empty title must not replace a saved name")
        } catch { XCTAssertTrue(error is IntelligenceError) }
    }

    func testShortTitlesAndInformativeDownloadsNeedNoAvailableModel() async throws {
        let intelligence = LocalIntelligence()
        let title = try await intelligence.savedTabName(title: "(3) le jardin de Zoé", url: URL(string: "https://example.com")!)
        XCTAssertEqual(title, "le jardin de Zoé")
        let stem = try await intelligence.downloadName(filename: "Orion_2.4.1 (copy).tar.gz", sourceTitle: "Unrelated", sourceURL: nil)
        XCTAssertEqual(stem, "Orion 2.4.1")
        let ambiguous = try await intelligence.downloadName(filename: "image.png", sourceTitle: "Home", sourceURL: nil)
        XCTAssertEqual(ambiguous, "image")
        let long = String(repeating: "Identifying subject ", count: 20) + "Anna Delvey"
        let unchanged = try await intelligence.savedTabName(title: long, url: URL(string: "https://example.com")!)
        XCTAssertEqual(unchanged, long)
    }
}

@MainActor
final class NamingFilenameSafetyTests: XCTestCase {
    func testConciseSourceBasedDownloadKeepsItsOriginalExtension() {
        let source = "Aurora Observatory panoramic photograph of the northern lights above snow covered mountains during the winter expedition - Aurora Gallery"
        let stem = NamingPolicy.selectDownloadStem(filename: "image.PNG", sourceTitle: source, candidate: "Aurora Observatory northern lights")
        XCTAssertEqual(DownloadManager.tidyFilename(stem: stem, original: "image.PNG"), "Aurora Observatory northern lights.PNG")
    }

    func testLongOutputFallsBackInsteadOfCuttingOffIdentityOrVersion() {
        let candidate = String(repeating: "Important ", count: 12) + "Orion 2.4.1"
        XCTAssertEqual(DownloadManager.tidyFilename(stem: candidate, original: "original.tar.gz"), "original.tar.gz")
        XCTAssertEqual(DownloadManager.tidyFilename(stem: "Aurora 2.4.1", original: "original.TAR.GZ"), "Aurora 2.4.1.TAR.GZ")
    }
}
