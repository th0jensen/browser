import AppKit
import SwiftUI

@MainActor
enum PreviewNoteActions {
    @discardableResult
    static func openPage(_ url: URL, from tab: BrowserTab?,
                         activateApplication: () -> Void = { NSApp.activate() },
                         openElsewhere: (URL) -> Void = { ExternalURLRouter.shared.open([$0]) }) -> Task<Void, Never>? {
        guard let tab, let browser = tab.browser, !browser.isClosed,
              (browser.tabAcrossSpaces(withID: tab.id) === tab || browser.peek?.tab === tab),
              let window = browser.window else {
            openElsewhere(url)
            activateApplication()
            return nil
        }
        // A kept note can outlive the source tab's selection. A live peek has no
        // entry in the normal tab list and must not be assigned to activeTabID.
        if browser.peek?.tab !== tab {
            if tab.spaceID != browser.activeSpaceID, !browser.selectSpace(tab.spaceID) {
                openElsewhere(url)
                activateApplication()
                return nil
            }
            browser.dismissPeek()
            browser.activeTabID = tab.id
        }
        // Start navigation before bringing the browser forward, without waiting
        // for the destination or its resources to finish loading.
        tab.load(url)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApplication()
        let target = browser.focusedPage
        if target?.webView?.window === window {
            target?.focusPage()
            return nil
        } else {
            // A structurally different tab may join its native host on the next
            // SwiftUI update. Never override a subsequent user focus request.
            let focusResponder = window.firstResponder
            let addressRequest = browser.addressFocusRequest
            let findRequest = browser.findFocusRequest
            let findVisible = target?.isFindBarVisible ?? false
            return Task { @MainActor [weak browser, weak target, weak window, weak focusResponder] in
                for _ in 0..<20 {
                    guard !Task.isCancelled, let browser, let target, let window, !browser.isClosed,
                          browser.focusedPage === target, browser.window === window,
                          window.isKeyWindow, window.firstResponder === focusResponder,
                          browser.addressFocusRequest == addressRequest,
                          browser.findFocusRequest == findRequest,
                          target.isFindBarVisible == findVisible else { return }
                    if target.webView?.window === window { target.focusPage(); return }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
    }

    static func copyText(_ state: LinkPreviewState, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(state.contextText, forType: .string)
    }
    static func copyLink(_ state: LinkPreviewState, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([state.url as NSURL])
    }
}

struct PreviewActionsControl: NSViewRepresentable {
    let preview: LinkPreviewPresentation
    func makeNSView(context: Context) -> PreviewActionsButton { PreviewActionsButton(preview: preview) }
    func updateNSView(_ button: PreviewActionsButton, context: Context) { button.preview = preview }
}

final class PreviewActionsButton: NSButton {
    weak var preview: LinkPreviewPresentation?
    init(preview: LinkPreviewPresentation) {
        self.preview = preview
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Preview actions")
        symbolConfiguration = .init(pointSize: 12, weight: .medium)
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel("Preview actions")
        target = self
        action = #selector(showActions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func showActions() {
        guard let preview, let event = NSApp.currentEvent else { return }
        preview.actions.present(with: event)
    }
}

@MainActor
final class PreviewNoteMenuPresenter: NSObject {
    private weak var preview: LinkPreviewPresentation?
    private var sharePicker: NSSharingServicePicker?
    init(preview: LinkPreviewPresentation) { self.preview = preview }

    func present(with event: NSEvent) {
        guard let preview, let view = preview.content else { return }
        preview.beginInteraction()
        defer { preview.endInteraction() }
        // This is an explicit actions popup, including when invoked by a right
        // click. Context-menu augmentation would add unsupported system actions.
        let location = view.convert(event.locationInWindow, from: nil)
        actionsMenu().popUp(positioning: nil, at: location, in: view)
    }

    func actionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Preview actions")
        menu.allowsContextMenuPlugIns = false
        menu.automaticallyInsertsWritingToolsItems = false
        menu.addItem(item("Open Page", #selector(openPage)))
        if preview?.state.isKept == false { menu.addItem(item("Keep as Note", #selector(keepNote))) }
        menu.addItem(.separator())
        menu.addItem(item("Copy Text", #selector(copyText)))
        menu.addItem(item("Copy Link", #selector(copyLink)))
        if let preview {
            let picker = NSSharingServicePicker(items: [preview.state.contextText])
            sharePicker = picker
            menu.addItem(picker.standardShareMenuItem)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func openPage() { preview?.open() }
    @objc private func keepNote() { preview?.keep() }
    @objc private func copyText() { if let state = preview?.state { PreviewNoteActions.copyText(state) } }
    @objc private func copyLink() { if let state = preview?.state { PreviewNoteActions.copyLink(state) } }
}
