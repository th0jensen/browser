import Security
import WebKit
import XCTest
@testable import Browser

/// Keeps passwords in memory, so tests never touch the keychain.
@MainActor
private final class MemoryPasswordStorage: PasswordStorage {
    var items: [SavedPassword: String] = [:]
    var listError: Error?
    var readError: Error?
    var writeError: Error?
    var removalError: Error?

    func savedPasswords() throws -> [SavedPassword] {
        if let listError { throw listError }
        return Array(items.keys)
    }
    func password(for account: SavedPassword) throws -> String? {
        if let readError { throw readError }
        return items[account]
    }
    func save(_ password: String, for account: SavedPassword) throws {
        if let writeError { throw writeError }
        items[account] = password
    }
    func remove(_ account: SavedPassword) throws {
        if let removalError { throw removalError }
        items[account] = nil
    }
}

@MainActor
private final class MessageRecorder: NSObject, WKScriptMessageHandler {
    var captures: [PasswordCapture] = []
    var sawPasswordFields = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? [String: Any])?["type"] as? String == "fields" { sawPasswordFields = true }
        if let capture = PasswordCapture(body: message.body, isMainFrame: message.frameInfo.isMainFrame,
                                         origin: PasswordOrigin(message.frameInfo.securityOrigin)) {
            captures.append(capture)
        }
    }
}

@MainActor
final class PasswordTests: XCTestCase {
    private let example = PasswordOrigin(host: "example.com")!

    private func submission(username: String = "alice", password: String = "secret") -> [String: Any] {
        ["type": "submit", "username": username, "password": password]
    }

    func testOriginsMatchExactly() throws {
        let accounts = try XCTUnwrap(PasswordOrigin(url: URL(string: "https://Accounts.Example.com/login?next=/")))
        XCTAssertEqual(accounts, PasswordOrigin(host: "accounts.example.com"))
        XCTAssertEqual(accounts.description, "https://accounts.example.com")
        XCTAssertNotEqual(accounts, example)
        XCTAssertNotEqual(PasswordOrigin(url: URL(string: "https://example.com:8443")), example)
        XCTAssertEqual(PasswordOrigin(url: URL(string: "https://example.com:8443"))?.description, "https://example.com:8443")
        XCTAssertEqual(PasswordOrigin(url: URL(string: "https://example.com:443/a")), example)

        XCTAssertNil(PasswordOrigin(url: URL(string: "http://example.com")))
        XCTAssertNil(PasswordOrigin(url: URL(string: "file:///tmp/login.html")))
        XCTAssertNil(PasswordOrigin(url: nil))
    }

    func testOnlyTopFrameHTTPSSubmissionsAreCaptured() throws {
        let capture = try XCTUnwrap(PasswordCapture(body: submission(username: " alice "), isMainFrame: true,
                                                    origin: example))
        XCTAssertEqual(capture.account, SavedPassword(origin: example, username: "alice"))
        XCTAssertEqual(capture.password, "secret")

        XCTAssertNil(PasswordCapture(body: submission(), isMainFrame: false, origin: example))
        XCTAssertNil(PasswordCapture(body: submission(), isMainFrame: true, origin: nil))
        XCTAssertNil(PasswordCapture(body: submission(password: ""), isMainFrame: true, origin: example))
        XCTAssertNil(PasswordCapture(body: ["type": "fields"], isMainFrame: true, origin: example))
        XCTAssertNil(PasswordCapture(body: "alice:secret", isMainFrame: true, origin: example))
        XCTAssertNil(PasswordCapture(body: submission(password: String(repeating: "x", count: 2000)),
                                     isMainFrame: true, origin: example))
    }

    func testOffersToSaveNewAndChangedPasswordsOnly() throws {
        let storage = MemoryPasswordStorage()
        let passwords = PasswordManager(storage: storage)
        let capture = try XCTUnwrap(PasswordCapture(body: submission(), isMainFrame: true, origin: example))

        XCTAssertEqual(passwords.offer(for: capture), .save)
        try passwords.save(capture)
        XCTAssertNil(passwords.offer(for: capture))
        XCTAssertEqual(passwords.passwords(for: example).map(\.username), ["alice"])
        XCTAssertTrue(passwords.passwords(for: PasswordOrigin(host: "accounts.example.com")).isEmpty)
        XCTAssertTrue(passwords.passwords(for: nil).isEmpty)

        let changed = try XCTUnwrap(PasswordCapture(body: submission(password: "new secret"), isMainFrame: true,
                                                    origin: example))
        XCTAssertEqual(passwords.offer(for: changed), .update)

        passwords.offersToSave = false
        XCTAssertNil(passwords.offer(for: changed))
        passwords.offersToSave = true

        let other = PasswordOrigin(host: "other.example")!
        let otherCapture = try XCTUnwrap(PasswordCapture(body: submission(), isMainFrame: true, origin: other))
        passwords.neverSave(on: other)
        XCTAssertNil(passwords.offer(for: otherCapture))
        passwords.allowSaving(on: other.description)
        XCTAssertEqual(passwords.offer(for: otherCapture), .save)

        passwords.remove(capture.account)
        XCTAssertTrue(storage.items.isEmpty)
    }

    func testPrivateWindowsNeverLoadTheAutofillScript() {
        let passwords = PasswordManager(storage: MemoryPasswordStorage())

        let browser = BrowserModel(websiteDataStore: .default(), passwords: passwords)
        XCTAssertEqual(browser.makeConfiguration().userContentController.userScripts.filter {
            $0.source == PasswordAutofill.script
        }.count, 1)

        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        XCTAssertNil(privateWindow.passwords)
        XCTAssertFalse(privateWindow.makeConfiguration().userContentController.userScripts.contains {
            $0.source == PasswordAutofill.script
        })
        XCTAssertNil(BrowserModel(websiteDataStore: .nonPersistent(), passwords: passwords).passwords)
    }

    func testTestsUseEphemeralSharedPasswordStorage() {
        XCTAssertTrue(PasswordManager.shared.usesEphemeralStorage)
    }

    func testKeychainFailuresAreReportedAndDoNotOfferToOverwriteUnreadablePasswords() throws {
        let storage = MemoryPasswordStorage()
        let passwords = PasswordManager(storage: storage)
        let capture = try XCTUnwrap(PasswordCapture(body: submission(), isMainFrame: true, origin: example))
        try passwords.save(capture)

        storage.readError = PasswordStorageError.keychain(errSecAuthFailed)
        XCTAssertNil(passwords.offer(for: capture))
        XCTAssertNotNil(passwords.lastError)
        passwords.dismissError()
        XCTAssertNil(passwords.lastError)
        storage.readError = nil

        storage.listError = PasswordStorageError.keychain(errSecNotAvailable)
        passwords.reload()
        XCTAssertEqual(passwords.passwords, [capture.account])
        XCTAssertNil(passwords.offer(for: capture))
        XCTAssertNotNil(passwords.lastError)
        storage.listError = nil

        storage.writeError = PasswordStorageError.keychain(errSecAuthFailed)
        XCTAssertThrowsError(try passwords.save(capture))
        XCTAssertTrue(passwords.lastError?.contains("save this password") == true)

        storage.removalError = PasswordStorageError.keychain(errSecAuthFailed)
        passwords.remove(capture.account)
        XCTAssertEqual(storage.items[capture.account], capture.password)
        XCTAssertEqual(passwords.passwords, [capture.account])
        XCTAssertTrue(passwords.lastError?.contains("remove this password") == true)
    }

    func testSharedPopupControllersInstallThePasswordHandlerOnlyOnce() {
        let controller = WKUserContentController()
        let recorder = MessageRecorder()
        PasswordAutofill.install(in: controller, handler: recorder)
        PasswordAutofill.install(in: controller, handler: recorder)
        XCTAssertEqual(controller.userScripts.count, 1)
    }

    func testPasswordConfigurationSurvivesRestoreAndIncludesPeekAndSuppliedPopups() throws {
        let passwords = PasswordManager(storage: MemoryPasswordStorage())
        let browser = BrowserModel(websiteDataStore: .default(), passwords: passwords)
        let tab = try XCTUnwrap(browser.activeTab)
        tab.isNewTab = false
        tab.suspend()
        tab.restore()
        XCTAssertTrue(try XCTUnwrap(tab.webView).configuration.userContentController.userScripts.contains {
            $0.source == PasswordAutofill.script
        })

        let peek = browser.openPeek(from: tab)
        XCTAssertTrue(browser.tab(for: try XCTUnwrap(peek.webView)) === peek)
        XCTAssertTrue(try XCTUnwrap(peek.webView).configuration.userContentController.userScripts.contains {
            $0.source == PasswordAutofill.script
        })
        browser.dismissPeek()
        let popup = browser.openChildTab(of: tab, configuration: WKWebViewConfiguration(), select: false)
        XCTAssertTrue(try XCTUnwrap(popup.webView).configuration.userContentController.userScripts.contains {
            $0.source == PasswordAutofill.script
        })
    }

    private func loadForm(_ html: String, recorder: MessageRecorder) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        PasswordAutofill.install(in: configuration.userContentController, handler: recorder)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/login"))
        try await waitUntil { recorder.sawPasswordFields }
        return webView
    }

    func testSubmittedSignInFormsAreReported() async throws {
        let recorder = MessageRecorder()
        let webView = try await loadForm("""
        <form onsubmit="event.preventDefault()">
          <input name="search" type="search">
          <input name="email" type="email" autocomplete="username">
          <input name="password" type="password">
          <button>Sign In</button>
        </form>
        """, recorder: recorder)

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[name=email]').value = 'alice@example.com';
        document.querySelector('[name=password]').value = 'secret';
        document.querySelector('form').requestSubmit(); 0
        """)

        try await waitUntil { !recorder.captures.isEmpty }
        XCTAssertEqual(recorder.captures, [PasswordCapture(body: submission(username: "alice@example.com"),
                                                           isMainFrame: true, origin: example)])
    }

    func testSignUpFormsReportTheNewPassword() async throws {
        let recorder = MessageRecorder()
        let webView = try await loadForm("""
        <form onsubmit="event.preventDefault()">
          <input name="user" type="text">
          <input name="current" type="password" autocomplete="current-password">
          <input name="new" type="password" autocomplete="new-password">
        </form>
        """, recorder: recorder)

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[name=user]').value = 'bob';
        document.querySelector('[name=current]').value = 'old';
        document.querySelector('[name=new]').value = 'brand new';
        document.querySelector('form').requestSubmit(); 0
        """)

        try await waitUntil { !recorder.captures.isEmpty }
        XCTAssertEqual(recorder.captures.first?.username, "bob")
        XCTAssertEqual(recorder.captures.first?.password, "brand new")
    }

    func testUnrelatedButtonsAndReturnOutsideAFormNeverCaptureCredentials() async throws {
        let recorder = MessageRecorder()
        let webView = try await loadForm("""
        <form>
          <input name=user value=alice>
          <input name=password type=password value=secret>
          <button type=button id=show>Show Password</button>
        </form>
        <button id=unrelated>Cookie Settings</button>
        <div role=button id=role>Open Settings</div>
        <input id=search type=search>
        """, recorder: recorder)

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('#unrelated').click();
        document.querySelector('#role').click();
        document.querySelector('#show').click();
        document.querySelector('#search').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
        0
        """)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(recorder.captures.isEmpty)
    }

    func testFillSkipsHiddenReadonlyAndNewPasswordFields() async throws {
        let recorder = MessageRecorder()
        let webView = try await loadForm("""
        <form>
          <input name=user>
          <input name=hidden type=password style="display:none">
          <input name=readonly type=password readonly>
          <input name=new type=password autocomplete=new-password>
          <input name=current type=password autocomplete=current-password>
        </form>
        """, recorder: recorder)

        let filled = try await webView.callAsyncJavaScript(PasswordAutofill.fillScript, arguments: [
            "origin": example.description, "username": "alice", "secret": "secret",
        ], in: nil, contentWorld: PasswordAutofill.world)
        XCTAssertEqual(filled as? Bool, true)
        let values = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('input[type=password]')].map(field => field.value)
        """)
        XCTAssertEqual(values as? [String], ["", "", "", "secret"])
    }

    func testPasswordsOnlyFillOnTheirOrigin() async throws {
        let recorder = MessageRecorder()
        let webView = try await loadForm("""
        <form><input name="user" type="text"><input name="password" type="password"></form>
        """, recorder: recorder)
        let values = "[document.querySelector('[name=user]').value, document.querySelector('[name=password]').value]"

        let refused = try await webView.callAsyncJavaScript(PasswordAutofill.fillScript, arguments: [
            "origin": "https://evil.example", "username": "alice", "secret": "secret",
        ], in: nil, contentWorld: PasswordAutofill.world)
        XCTAssertEqual(refused as? Bool, false)
        let refusedValues = try await webView.evaluateJavaScript(values) as? [String]
        XCTAssertEqual(refusedValues, ["", ""])

        let filled = try await webView.callAsyncJavaScript(PasswordAutofill.fillScript, arguments: [
            "origin": example.description, "username": "alice", "secret": "secret",
        ], in: nil, contentWorld: PasswordAutofill.world)
        XCTAssertEqual(filled as? Bool, true)
        let filledValues = try await webView.evaluateJavaScript(values) as? [String]
        XCTAssertEqual(filledValues, ["alice", "secret"])
    }

    func testPageScriptsCantReachTheAutofillHandler() async throws {
        let recorder = MessageRecorder()
        let webView = try await loadForm("<form><input type=password></form>", recorder: recorder)

        let reachable = try await webView.evaluateJavaScript(
            "typeof window.webkit?.messageHandlers?.\(PasswordAutofill.handlerName)")
        XCTAssertEqual(reachable as? String, "undefined")
    }
}
