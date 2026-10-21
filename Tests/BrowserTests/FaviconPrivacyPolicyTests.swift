import Foundation
import XCTest
@testable import Browser

@MainActor
final class FaviconPrivacyPolicyTests: XCTestCase {
    func testRedirectRemovesCookieAndAuthenticationHeadersAndRejectsUnsafeDestinations() async throws {
        let session = URLSession(configuration: FaviconRequests.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let policy = FaviconRedirectPolicy()
        let source = URL(string: "https://icons.invalid/favicon.ico")!
        let task = session.dataTask(with: source) // Never resumed; exercise only the delegate policy.
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        var request = URLRequest(url: URL(string: "https://other-icons.invalid/icon.png")!)
        request.setValue("account=source-profile", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        let redirected = await withCheckedContinuation { continuation in
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                continuation.resume(returning: $0)
            }
        }
        let anonymous = try XCTUnwrap(redirected)
        XCTAssertEqual(anonymous.url, request.url)
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertEqual(anonymous.value(forHTTPHeaderField: "Accept"), "image/png")
        for destination in ["http://127.0.0.1:9/callback", "https://user:secret@icons.invalid/favicon.ico"] {
            let rejected = await withCheckedContinuation { continuation in
                policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: URL(string: destination)!)) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertNil(rejected)
        }
    }

    func testAuthenticationNeverOffersCredentialsAndLeavesOnlyTLSTrustToTheSystem() async {
        let session = URLSession(configuration: FaviconRequests.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://icons.invalid/favicon.ico")!)
        let policy = FaviconRedirectPolicy()
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodClientCertificate,
                       NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "icons.invalid", port: 443, protocol: "https", realm: nil,
                                           authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space,
                                                       proposedCredential: URLCredential(user: "source-profile", password: "secret", persistence: .forSession),
                                                       previousFailureCount: 0, failureResponse: nil, error: nil,
                                                       sender: FaviconChallengeSender())
            let result = await withCheckedContinuation { continuation in
                policy.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                    continuation.resume(returning: (disposition, credential == nil))
                }
            }
            XCTAssertEqual(result.0, method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge)
            XCTAssertTrue(result.1)
        }
    }
}

private final class FaviconChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { }
}
