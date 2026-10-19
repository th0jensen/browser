import AppKit
import SwiftUI

@MainActor
enum PreviewNoteActions {
    @discardableResult
    static func openPage(_ url: URL, from tab: BrowserTab?,
                         activateApplication: @escaping () -> Void = { NSApp.activate() },
                         openElsewhere: (URL) -> Void = { ExternalURLRouter.shared.open([$0]) }) -> Task<Void, Never>? {
        guard let tab, let browser = tab.browser, !browser.isClosed,
              browser.tab(withID: tab.id) === tab, let window = browser.window else {
            openElsewhere(url)
            activateApplication()
            return nil
        }
        // A kept note can outlive the source tab's selection. A live peek has no
        // entry in the normal tab list and must not be assigned to activeTabID.
        if browser.peek?.tab !== tab {
            browser.dismissPeek()
            browser.activeTabID = tab.id
        }
        tab.load(url)
        guard let webView = tab.webView else { return nil }
        // Clear the background window's old responder so swapping its page host
        // cannot look like a later user focus change. This does not activate it.
        _ = window.makeFirstResponder(nil)
        let focusResponder = window.firstResponder
        let addressRequest = browser.addressFocusRequest
        let findRequest = browser.findFocusRequest
        let findVisible = tab.isFindBarVisible
        return Task { @MainActor [weak browser, weak tab, weak webView, weak window, weak focusResponder] in
            @MainActor func requestIsCurrent() -> Bool {
                guard !Task.isCancelled, let browser, let tab, let webView, let window else { return false }
                return !browser.isClosed && browser.tab(withID: tab.id) === tab
                    && browser.focusedPage === tab && tab.webView === webView && browser.window === window
                    && window.firstResponder === focusResponder
                    && browser.addressFocusRequest == addressRequest && browser.findFocusRequest == findRequest
                    && tab.isFindBarVisible == findVisible
            }
            // Keep the note usable and the browser in the background until the
            // destination finishes, including a terminal load error.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while webView?.isLoading == true {
                guard requestIsCurrent(), ContinuousClock.now < deadline else { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard requestIsCurrent(), let browser, let tab, let webView, let window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            activateApplication()
            if webView.window === window { tab.focusPage(); return }
            // SwiftUI may attach a structurally different tab after activation.
            // Stop if the user makes a later selection or focus request.
            let activatedResponder = window.firstResponder
            for _ in 0..<20 {
                guard !Task.isCancelled, !browser.isClosed, browser.focusedPage === tab,
                      browser.window === window, window.isKeyWindow,
                      window.firstResponder === activatedResponder,
                      browser.addressFocusRequest == addressRequest,
                      browser.findFocusRequest == findRequest,
                      tab.isFindBarVisible == findVisible else { return }
                if webView.window === window { tab.focusPage(); return }
                try? await Task.sleep(for: .milliseconds(25))
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
