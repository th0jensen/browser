import Foundation
import Observation
#if !APP_STORE
import Sparkle
#endif

/// Whether this build can update itself. The Mac App Store build is updated by the store and leaves Sparkle out,
/// and a build without Sparkle's public key couldn't verify the updates it downloads.
enum UpdateFeature {
    /// What project.yml ships with until the real key is set. See RELEASING.md.
    static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    static var isAppStoreBuild: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }

    static func isEnabled(info: [String: Any]?, isAppStoreBuild: Bool = isAppStoreBuild) -> Bool {
        guard !isAppStoreBuild, let info,
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https",
              feed.host?.isEmpty == false,
              let key = info["SUPublicEDKey"] as? String, key != publicKeyPlaceholder,
              // An Ed25519 public key is 32 bytes.
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }
}

/// Checks for, downloads, and installs updates with Sparkle, from the appcast published with each GitHub release.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    let isAvailable: Bool
    private(set) var canCheckForUpdates = false
    var checksAutomatically = false {
        didSet {
            #if !APP_STORE
            controller?.updater.automaticallyChecksForUpdates = checksAutomatically
            #endif
        }
    }
    var downloadsAutomatically = false {
        didSet {
            #if !APP_STORE
            controller?.updater.automaticallyDownloadsUpdates = downloadsAutomatically
            #endif
        }
    }

    #if !APP_STORE
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    #endif

    init(bundle: Bundle = .main) {
        #if DEBUG
        // Debug shares the release bundle identity and profile, but must never replace itself during QA.
        isAvailable = false
        #else
        isAvailable = !BrowserProfile.isTesting && BrowserProfile.qaDirectory == nil
            && UpdateFeature.isEnabled(info: bundle.infoDictionary)
        #endif
        #if !APP_STORE
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        downloadsAutomatically = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        #endif
    }

    func checkForUpdates() {
        #if !APP_STORE
        controller?.checkForUpdates(nil)
        #endif
    }
}
