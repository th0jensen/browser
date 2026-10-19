import AppIntents
import AppKit
import CoreTransferable
import SwiftUI

/// The system resolves the annotated card to the same readable text used by Copy
/// and Share, including the source URL. No custom Siri launcher or private API.
struct PreviewNoteEntity: AppEntity, Transferable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Preview Note")
    static let defaultQuery = PreviewNoteQuery()
    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Text") var text: String
    @Property(title: "Source URL") var url: URL
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static var transferRepresentation: some TransferRepresentation { ProxyRepresentation(exporting: \.text) }

    @MainActor init(_ state: LinkPreviewState) {
        id = state.id
        title = state.result?.title ?? state.url.host() ?? "Preview Note"
        text = state.contextText
        url = state.url
    }
}

struct PreviewNoteQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PreviewNoteEntity] {
        await MainActor.run { identifiers.compactMap { LinkPreviewContextStore.shared.entity(for: $0) } }
    }
}

/// Resolve live notes, plus a bounded memory-only snapshot after a hover closes,
/// so a system action can finish reading the context it was invoked with.
@MainActor
final class LinkPreviewContextStore {
    static let shared = LinkPreviewContextStore()
    private struct WeakState { weak var state: LinkPreviewState? }
    private var live: [UUID: WeakState] = [:]
    private var recent: [(UUID, PreviewNoteEntity)] = []
    func register(_ state: LinkPreviewState) {
        live = live.filter { $0.value.state != nil }
        live[state.id] = WeakState(state: state)
    }
    func remember(_ state: LinkPreviewState) {
        live[state.id] = nil
        recent.removeAll { $0.0 == state.id }
        recent.append((state.id, PreviewNoteEntity(state)))
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
    }
    func entity(for id: UUID) -> PreviewNoteEntity? {
        if let state = live[id]?.state { return PreviewNoteEntity(state) }
        return recent.first { $0.0 == id }?.1
    }
}

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

/// The annotated content host is also the native menu's text requestor. An
/// entity annotation on a bare button alone supplies no AppKit text selection.
final class PreviewContentView: NSHostingView<LinkPreviewCard>, @MainActor NSServicesMenuRequestor {
    private weak var preview: LinkPreviewPresentation?
    init(preview: LinkPreviewPresentation) {
        self.preview = preview
        super.init(rootView: LinkPreviewCard(preview: preview))
        focusRingType = .none
        appEntityIdentifier = EntityIdentifier(for: PreviewNoteEntity.self, identifier: preview.state.id)
    }
    @MainActor required init(rootView: LinkPreviewCard) { fatalError("Use init(preview:)") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == .string && returnType == nil && preview != nil { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let preview else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(preview.state.contextText, forType: .string)
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
        appEntityIdentifier = EntityIdentifier(for: PreviewNoteEntity.self, identifier: preview.state.id)
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
        let window = view.window
        let previousResponder = window?.firstResponder
        window?.makeFirstResponder(view)
        defer {
            if window?.firstResponder === view { window?.makeFirstResponder(previousResponder) }
            preview.endInteraction()
        }
        NSMenu.popUpContextMenu(actionsMenu(), with: event, for: view)
    }

    func actionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Preview actions")
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
