import XCTest
@testable import Browser

@MainActor
final class HistoryStoreTests: XCTestCase {
    private let swift = URL(string: "https://swift.org")!
    private let apple = URL(string: "https://www.apple.com")!

    private func makeFile() -> StoreFile {
        StoreFile(url: FileManager.default.temporaryDirectory
            .appending(path: "BrowserTests-\(UUID().uuidString)")
            .appending(path: "History.plist"))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testVisitsFollowThePageTitle() {
        let history = HistoryStore(file: nil)
        let id = history.recordVisit(to: swift, title: "")

        history.updateTitle(of: id, to: "Swift.org")

        XCTAssertEqual(history.visits.map(\.title), ["Swift.org"])
        XCTAssertEqual(history.visits.first?.displayTitle, "Swift.org")
    }

    func testRecentVisitsAreNewestFirstWithoutRepeats() {
        let history = HistoryStore(file: nil)
        let now = Date.now
        history.recordVisit(to: swift, title: "Swift", at: now - 30)
        history.recordVisit(to: apple, title: "Apple", at: now - 20)
        history.recordVisit(to: swift, title: "Swift", at: now - 10)

        XCTAssertEqual(history.recentVisits(limit: 15).map(\.url), [swift, apple])
        XCTAssertEqual(history.recentVisits(limit: 1).map(\.url), [swift])
    }

    func testPagesCombineVisitsToAnAddress() throws {
        let history = HistoryStore(file: nil)
        let now = Date.now
        history.recordVisit(to: swift, title: "Swift", at: now - 30)
        history.recordVisit(to: swift, title: "", at: now - 10)
        history.recordVisit(to: apple, title: "Apple", at: now - 20)

        let page = try XCTUnwrap(history.pages.first { $0.url == swift })
        XCTAssertEqual(page.visitCount, 2)
        XCTAssertEqual(page.title, "Swift")
        XCTAssertEqual(page.lastVisit, now - 10)
        XCTAssertEqual(history.pages.count, 2)
    }

    func testDaysAreNewestFirstWithEachAddressOncePerDay() {
        let history = HistoryStore(file: nil)
        history.recordVisit(to: swift, title: "Swift", at: date(14, 9))
        history.recordVisit(to: apple, title: "Apple", at: date(15, 9))
        history.recordVisit(to: swift, title: "Swift", at: date(15, 10))
        history.recordVisit(to: apple, title: "Apple", at: date(15, 11))

        let days = history.days(calendar: calendar)

        XCTAssertEqual(days.map(\.date), [date(15, 0), date(14, 0)])
        XCTAssertEqual(days[0].entries.map(\.url), [apple, swift])
        XCTAssertEqual(days[0].entries.map(\.date), [date(15, 11), date(15, 10)])
        XCTAssertEqual(days[1].entries.map(\.url), [swift])
        XCTAssertEqual(history.days(matching: "APPLE", calendar: calendar).map(\.entries.count), [1])
    }

    func testRemovingAnEntryOnlyRemovesThatDaysVisits() {
        let history = HistoryStore(file: nil)
        history.recordVisit(to: swift, title: "Swift", at: date(14, 9))
        history.recordVisit(to: swift, title: "Swift", at: date(15, 9))
        history.recordVisit(to: swift, title: "Swift", at: date(15, 10))

        history.removeVisits(to: swift, onDayOf: date(15, 12), calendar: calendar)

        XCTAssertEqual(history.visits.map(\.date), [date(14, 9)])
    }

    func testClearRanges() {
        let now = date(15, 12)
        let history = HistoryStore(file: nil)
        history.recordVisit(to: swift, title: "", at: date(14, 9))
        history.recordVisit(to: swift, title: "", at: date(15, 9))
        history.recordVisit(to: swift, title: "", at: now - 10 * 60)

        history.clear(.lastHour, now: now, calendar: calendar)
        XCTAssertEqual(history.visits.map(\.date), [date(14, 9), date(15, 9)])

        history.clear(.today, now: now, calendar: calendar)
        XCTAssertEqual(history.visits.map(\.date), [date(14, 9)])

        history.clear(.all, now: now, calendar: calendar)
        XCTAssertTrue(history.visits.isEmpty)
    }

    func testTodayAndYesterdayStartsAtTheStartOfYesterday() {
        let now = date(15, 12)
        XCTAssertEqual(HistoryClearRange.todayAndYesterday.start(now: now, calendar: calendar), date(14, 0))
        XCTAssertEqual(HistoryClearRange.lastHour.start(now: now, calendar: calendar), date(15, 11))
        XCTAssertEqual(HistoryClearRange.all.start(now: now, calendar: calendar), .distantPast)

        let history = HistoryStore(file: nil)
        history.recordVisit(to: swift, title: "", at: date(13, 23))
        history.recordVisit(to: swift, title: "", at: date(14, 1))
        history.clear(.todayAndYesterday, now: now, calendar: calendar)
        XCTAssertEqual(history.visits.map(\.date), [date(13, 23)])
    }

    func testPruneDropsExpiredVisitsAndTheOldestBeyondTheLimit() {
        let now = Date.now
        var visits = [HistoryVisit(url: swift, title: "", date: now - HistoryStore.maxAge - 60)]
        visits += (0..<HistoryStore.maxVisits + 2).map {
            HistoryVisit(url: apple, title: "", date: now - 60 + Double($0) / 1000)
        }

        HistoryStore.prune(&visits, now: now)

        XCTAssertEqual(visits.count, HistoryStore.maxVisits)
        XCTAssertTrue(visits.allSatisfy { $0.url == apple })
        XCTAssertEqual(visits.first?.date, now - 60 + 2.0 / 1000)
    }

    func testHistoryPersistsAcrossStores() async {
        let file = makeFile()
        let history = HistoryStore(file: file)
        await history.waitUntilLoaded()
        history.recordVisit(to: swift, title: "Swift", at: .now - 60)
        history.recordVisit(to: apple, title: "Apple", at: .now - 30)
        history.saveNow()

        let reloaded = HistoryStore(file: file)
        await reloaded.waitUntilLoaded()

        XCTAssertEqual(reloaded.visits, history.visits)
    }

    func testVisitsAndClearingBeforeTheSavedHistoryLoadsAreKept() async {
        let file = makeFile()
        let saved = HistoryStore(file: file)
        await saved.waitUntilLoaded()
        saved.recordVisit(to: swift, title: "Swift", at: .now - 60)
        saved.saveNow()

        let history = HistoryStore(file: file)
        history.clear(.all)
        history.recordVisit(to: apple, title: "Apple")
        await history.waitUntilLoaded()

        XCTAssertEqual(history.visits.map(\.url), [apple])
    }
}
