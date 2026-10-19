import AppKit
import SwiftUI

@MainActor
enum PreviewNoteActions {
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
