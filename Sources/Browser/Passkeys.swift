import AppKit
import AuthenticationServices
import Observation
import Security

/// WebKit handles WebAuthn and origin validation; the browser requests access to system credential providers.
@MainActor
@Observable
final class PasskeyAccess {
    static let shared = PasskeyAccess()
    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private(set) var isRequesting = false
    private(set) var status: Status = .unavailable

    enum Status {
        case unavailable, notDetermined, authorized, denied

        var description: String {
            switch self {
            case .unavailable:
                "This build needs Apple’s approved browser passkey entitlement and a matching signing profile."
            case .notDetermined:
                "Allow Browser to use passkeys from iCloud Keychain and your system credential providers."
            case .authorized:
                "Passkey access is enabled. Websites can use the system passkey sheet, including configured credential providers."
            case .denied:
                "Passkey access is denied. In System Settings, search for “Passkeys Access for Web Browsers” to change Browser’s access."
            }
        }
    }

    init() { refresh() }

    func refresh() {
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
                as? Bool == true else {
            status = .unavailable
            return
        }
        switch manager.authorizationStateForPlatformCredentials {
        case .authorized: status = .authorized
        case .notDetermined: status = .notDetermined
        case .denied: status = .denied
        @unknown default: status = .unavailable
        }
    }

    func requestAccess() async {
        refresh()
        guard status == .notDetermined, !isRequesting else { return }
        isRequesting = true
        _ = await manager.requestAuthorizationForPublicKeyCredentials()
        isRequesting = false
        refresh()
    }
}
