import XCTest
@testable import Browser

@MainActor
final class SitePermissionsTests: XCTestCase {
    func testRemembersTheAnswerForTheSite() async {
        let permissions = SitePermissions()
        var prompts = 0

        let first = await permissions.decide([.downloads], on: "example.com") { prompts += 1; return true }
        let second = await permissions.decide([.downloads], on: "example.com") { prompts += 1; return false }
        let otherSite = await permissions.decide([.downloads], on: "example.org") { prompts += 1; return false }

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(otherSite)
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(permissions.decision(for: [.downloads], on: "example.org"), false)
        XCTAssertNil(permissions.decision(for: [.camera], on: "example.com"))
    }

    func testCameraAndMicrophoneNeedBothAllowed() async {
        let permissions = SitePermissions()
        _ = await permissions.decide([.camera], on: "https://meet.example") { true }

        XCTAssertNil(permissions.decision(for: [.camera, .microphone], on: "https://meet.example"))
        _ = await permissions.decide([.microphone], on: "https://meet.example") { false }
        XCTAssertEqual(permissions.decision(for: [.camera, .microphone], on: "https://meet.example"), false)
        let isAllowed = await permissions.decide([.camera, .microphone], on: "https://meet.example") {
            XCTFail("Asked again after the microphone was refused")
            return true
        }
        XCTAssertFalse(isAllowed)
    }

    func testRequestsThatArriveTogetherShareOnePrompt() async {
        let permissions = SitePermissions()
        var prompts = 0
        let ask: @MainActor () async -> Bool? = {
            prompts += 1
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }

        async let first = permissions.decide([.downloads], on: "example.com", ask: ask)
        async let second = permissions.decide([.downloads], on: "example.com", ask: ask)
        let answers = await [first, second]

        XCTAssertEqual(answers, [true, true])
        XCTAssertEqual(prompts, 1)
    }

    func testUnansweredPromptsRefuseWithoutRemembering() async {
        let permissions = SitePermissions()

        let isAllowed = await permissions.decide([.downloads], on: "example.com") { nil }

        XCTAssertFalse(isAllowed)
        XCTAssertNil(permissions.decision(for: [.downloads], on: "example.com"))
    }

    func testCameraAndMicrophoneAnswersAreSavedButDownloadsArent() async {
        let suiteName = "dev.athas.browser.tests.permissions"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let permissions = SitePermissions(defaults: defaults)
        _ = await permissions.decide([.camera, .microphone], on: "https://meet.example") { true }
        _ = await permissions.decide([.downloads], on: "example.com") { true }
        permissions.setDecision(false, for: .microphone, on: "https://meet.example")
        _ = await permissions.decide([.camera], on: "https://video.example") { false }

        let relaunched = SitePermissions(defaults: defaults)

        XCTAssertEqual(relaunched.mediaDecisions, [
            SitePermissions.SiteDecisions(site: "https://meet.example", camera: true, microphone: false),
            SitePermissions.SiteDecisions(site: "https://video.example", camera: false, microphone: nil),
        ])
        XCTAssertNil(relaunched.decision(for: [.downloads], on: "example.com"))

        relaunched.removeDecisions(on: "https://meet.example")
        XCTAssertEqual(SitePermissions(defaults: defaults).mediaDecisions.map(\.site), ["https://video.example"])
        relaunched.removeAllMediaDecisions()
        XCTAssertTrue(SitePermissions(defaults: defaults).mediaDecisions.isEmpty)
    }

    func testSettingsDenialOverridesAnAlreadyOpenPermissionPromptForAllWaiters() async {
        let permissions = SitePermissions()
        let opened = expectation(description: "Permission sheet opened")
        var answer: CheckedContinuation<Bool?, Never>?
        let ask: @MainActor () async -> Bool? = {
            await withCheckedContinuation {
                answer = $0
                opened.fulfill()
            }
        }
        let first = Task { await permissions.decide([.camera], on: "https://meet.example", ask: ask) }
        await fulfillment(of: [opened], timeout: 2)
        let secondStarted = expectation(description: "Second request shares the sheet")
        let second = Task {
            secondStarted.fulfill()
            return await permissions.decide([.camera], on: "https://meet.example", ask: ask)
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        permissions.setDecision(false, for: .camera, on: "https://meet.example")
        answer?.resume(returning: true)

        let answers = await [first.value, second.value]
        XCTAssertEqual(answers, [false, false])
        XCTAssertEqual(permissions.decision(for: [.camera], on: "https://meet.example"), false)
    }

    func testResetInvalidatesPendingPromptAndAllowsANewQuestion() async {
        let permissions = SitePermissions()
        let opened = expectation(description: "Old permission sheet opened")
        var answer: CheckedContinuation<Bool?, Never>?
        let old = Task {
            await permissions.decide([.camera, .microphone], on: "https://meet.example") {
                await withCheckedContinuation {
                    answer = $0
                    opened.fulfill()
                }
            }
        }
        await fulfillment(of: [opened], timeout: 2)
        permissions.removeAllMediaDecisions()
        let new = await permissions.decide([.camera], on: "https://meet.example") { false }
        answer?.resume(returning: true)
        let oldResult = await old.value

        XCTAssertFalse(new)
        XCTAssertFalse(oldResult)
        XCTAssertEqual(permissions.decision(for: [.camera], on: "https://meet.example"), false)
        XCTAssertNil(permissions.decision(for: [.microphone], on: "https://meet.example"))
    }

    func testDialogsCanBeBlockedAfterTheFirst() {
        var dialogs = DialogLimiter()
        XCTAssertFalse(dialogs.offersBlocking)

        dialogs.didShow(blockingMore: false)
        XCTAssertTrue(dialogs.offersBlocking)
        XCTAssertFalse(dialogs.isBlocked)

        dialogs.didShow(blockingMore: true)
        XCTAssertTrue(dialogs.isBlocked)
    }
}
