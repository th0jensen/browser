import SwiftUI

enum ChromeRevealRegionKind {
    case toolbar, sidebar
}

private struct ChromeRegionVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var chromeRegionIsVisible: Bool {
        get { self[ChromeRegionVisibilityKey.self] }
        set { self[ChromeRegionVisibilityKey.self] = newValue }
    }
}

/// Retain the glass and tab views between reveals. Only this small subtree
/// observes hover visibility; pointer movement need not rebuild the browser.
struct ChromeRevealRegion<Content: View>: View {
    let controller: ChromeHoverController
    let region: ChromeRevealRegionKind
    @ViewBuilder var content: () -> Content

    private var isVisible: Bool {
        switch region {
        case .toolbar: controller.toolbarIsRevealed && !controller.customizationIsRunning
        case .sidebar: controller.sidebarIsRevealed
        }
    }

    var body: some View {
        content()
            .environment(\.chromeRegionIsVisible, isVisible)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
    }
}

/// Floating sidebars leave room below overlay chrome. Docked sidebars use the
/// native toolbar safe area and do not need an additional inset.
struct SidebarToolbarInset: ViewModifier {
    let controller: ChromeHoverController
    var outerInset: CGFloat = 0

    func body(content: Content) -> some View {
        let toolbarInset = controller.compactToolbar && controller.toolbarIsRevealed
            ? controller.headerHeight + BrowserChrome.edgeInset : 0
        content.padding(.top, toolbarInset > 0 ? toolbarInset + BrowserChrome.edgeInset : outerInset)
    }
}
