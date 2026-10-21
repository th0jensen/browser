import Foundation

/// Frees memory by suspending background tabs that haven't been selected for a while,
/// and right away when the system runs low on memory.
@MainActor
final class TabSuspender {
    static let idleInterval: Duration = .seconds(10 * 60)
    private static let checkInterval: Duration = .seconds(60)

    private var idleCheck: Task<Void, Never>?
    private let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                                         queue: .main)

    init(browser: BrowserModel) {
        idleCheck = Task { [weak browser] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.checkInterval) }
                catch { return }
                guard let browser else { return }
                let cutoff = ContinuousClock.now - Self.idleInterval
                await browser.suspendTabs(browser.suspendableTabs.filter { $0.lastActive < cutoff })
            }
        }
        memoryPressure.setEventHandler { [weak self, weak browser] in
            MainActor.assumeIsolated {
                guard let self, let browser else { return }
                // A warning frees the least recently used half of the background tabs, critical pressure all of them.
                let tabs = browser.suspendableTabs
                let count = self.memoryPressure.data.contains(.critical) ? tabs.count : (tabs.count + 1) / 2
                Task { await browser.suspendTabs(Array(tabs.prefix(count))) }
            }
        }
        memoryPressure.activate()
    }

    isolated deinit {
        idleCheck?.cancel()
        memoryPressure.cancel()
    }
}
