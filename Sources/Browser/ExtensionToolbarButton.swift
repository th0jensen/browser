import SwiftUI
import WebKit

struct ExtensionButton: View {
    let item: InstalledExtension
    let browser: BrowserModel
    @State private var extensions = BrowserExtensions.shared

    var body: some View {
        let _ = extensions.actionRevision
        if item.kind == .contentBlocker {
            ContentBlockerButton(item: item, browser: browser)
        } else {
            let context = extensions.context(for: item)
            let action = context?.action(for: browser.focusedPage)
            Button {
                guard browser.supportsExtensions, let tab = browser.focusedPage else { return }
                Task { @MainActor in
                    await extensions.restore()
                    guard browser.supportsExtensions, tab.supportsExtensions, browser.tab(withID: tab.id) != nil, let readyContext = extensions.context(for: item),
                          readyContext.action(for: tab)?.isEnabled == true else { return }
                    extensions.focus(browser)
                    readyContext.userGesturePerformed(in: tab)
                    readyContext.performAction(for: tab)
                }
            } label: {
                Label {
                    Text(item.name)
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? extensions.toolbarIcon(for: item) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else { Image(systemName: "puzzlepiece.extension") }
                        }
                        .frame(width: 16, height: 16)
                        if let badge = action?.badgeText, !badge.isEmpty {
                            Text(badge).font(.system(size: 8, weight: .bold))
                                .padding(2).background(.tint, in: Capsule()).offset(x: 7, y: -7)
                        }
                    }
                }
            }
            .labelStyle(ChromeToolbarLabelStyle())
            .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
        .chromeToolbarButtonStyle()
        .controlSize(.regular)
            .disabled(!browser.supportsExtensions || !item.isEnabled || action?.isEnabled == false || extensions.errors[item.id] != nil || browser.focusedPage == nil)
            .help(action?.label.isEmpty == false ? action!.label : item.toolbarActionLabel ?? item.name)
            .accessibilityLabel(item.name)
        }
    }
}
