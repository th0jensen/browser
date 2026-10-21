import AppKit
import SwiftUI

enum ChromePresentationRegion: Equatable { case toolbar, sidebar }

@MainActor
protocol ChromePresentationControlling: AnyObject {
    func beginPresentation(in region: ChromePresentationRegion)
    func endPresentation(in region: ChromePresentationRegion)
}

extension ChromeHoverController: ChromePresentationControlling {
    func beginPresentation(in region: ChromePresentationRegion) {
        switch region {
        case .toolbar: beginPresentation()
        case .sidebar: beginSidebarPresentation()
        }
    }
    func endPresentation(in region: ChromePresentationRegion) {
        switch region {
        case .toolbar: endPresentation()
        case .sidebar: endSidebarPresentation()
        }
    }
}

/// One presentation owns one balanced hold, even when SwiftUI repeats lifecycle updates.
@MainActor
final class ChromePresentationHold {
    private weak var controller: (any ChromePresentationControlling)?
    private var region: ChromePresentationRegion = .toolbar

    func setPresented(_ isPresented: Bool, controller nextController: (any ChromePresentationControlling)?,
                      region nextRegion: ChromePresentationRegion = .toolbar) {
        let next = isPresented ? nextController : nil
        guard controller !== next || region != nextRegion else { return }
        end()
        region = nextRegion
        controller = next
        next?.beginPresentation(in: region)
    }

    func end() {
        let previous = controller
        controller = nil
        previous?.endPresentation(in: region)
    }

    isolated deinit { end() }
}

private struct ChromeHoverControllerKey: EnvironmentKey {
    static let defaultValue: ChromeHoverController? = nil
}

extension EnvironmentValues {
    var chromeHoverController: ChromeHoverController? {
        get { self[ChromeHoverControllerKey.self] }
        set { self[ChromeHoverControllerKey.self] = newValue }
    }
}

private struct ChromePresentationModifier: ViewModifier {
    let isPresented: Bool
    let controller: ChromeHoverController?
    let region: ChromePresentationRegion
    @State private var hold = ChromePresentationHold()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, value in
                hold.setPresented(value, controller: controller, region: region)
            }
            .onChange(of: controller.map(ObjectIdentifier.init)) { _, _ in
                hold.setPresented(isPresented, controller: controller, region: region)
            }
            .onChange(of: region) { _, _ in
                hold.setPresented(isPresented, controller: controller, region: region)
            }
            .onDisappear { hold.end() }
    }
}

extension View {
    func chromePresentation(isPresented: Bool, controller: ChromeHoverController?,
                            region: ChromePresentationRegion = .toolbar) -> some View {
        modifier(ChromePresentationModifier(isPresented: isPresented, controller: controller, region: region))
    }
}

/// WebKit owns its popover delegate. Object-scoped notifications preserve that ownership.
@MainActor
final class ChromePopoverPresentation {
    private let popover: NSPopover
    private let hold = ChromePresentationHold()
    private var observers: [NSObjectProtocol] = []
    private var onClose: (@MainActor (ChromePopoverPresentation) -> Void)?
    private var isFinished = false

    init(popover: NSPopover, owner: NSWindow?, controller: (any ChromePresentationControlling)?,
         onClose: @escaping @MainActor (ChromePopoverPresentation) -> Void) {
        self.popover = popover
        self.onClose = onClose
        observers.append(NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                                                                 object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
        if let owner {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                     object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        hold.setPresented(true, controller: controller)
    }

    func close() {
        guard !isFinished else { return }
        popover.close()
        finish()
    }

    /// Also releases a hold when AppKit declines to show the popover.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        hold.end()
        let callback = onClose
        onClose = nil
        callback?(self)
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        hold.end()
    }
}
