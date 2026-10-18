import AppKit
import SwiftUI

/// Row gestures and menu commands all activate the title's inline editor.
struct SavedTabRename: ViewModifier {
    let browser: BrowserModel
    let page: TabFolderItem
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture(count: 2).onEnded(request))
            .background(ForceClickRenameAnchor(action: request))
    }
    private func request() {
        guard browser.tabDrag.payload == nil else { return }
        browser.renamingSavedPageID = page.id
    }
}

struct SavedTabTitle: View {
    let browser: BrowserModel
    let page: TabFolderItem
    let isActive: Bool
    var fades = false
    private var editing: Bool { browser.renamingSavedPageID == page.id }
    private var layout: TabLayout { browser.chromePreferences.tabLayout }
    @Environment(\.chromeHoverController) private var chromeHover

    var body: some View {
        ZStack(alignment: .leading) {
            if editing {
                InlineTabNameField(text: browser.folders.item(page.id)?.title ?? page.title,
                                   weight: isActive ? .medium : .regular, commit: save, cancel: finish)
                    .frame(height: 20)
            } else if fades {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .leading) { Text(page.title).lineLimit(1).fixedSize() }
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        }
                    }.clipped()
                    .accessibilityLabel(page.title)
            } else {
                Text(page.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
        .modifier(IntelligenceShimmer(active: !editing && browser.namingSavedPageIDs.contains(page.id)))
        .accessibilityValue(browser.namingSavedPageIDs.contains(page.id) ? "Generating title" : "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromePresentation(isPresented: editing && layout == .horizontal, controller: chromeHover)
        .onChange(of: editing) { _, value in
            if layout == .vertical { chromeHover?.folderEditorIsPresented = value }
        }
        .onChange(of: layout) { _, value in
            if editing { chromeHover?.folderEditorIsPresented = value == .vertical }
        }
        .onDisappear {
            if editing {
                if layout == .vertical { chromeHover?.folderEditorIsPresented = false }
                finish()
            }
        }
    }

    private func finish() { if browser.renamingSavedPageID == page.id { browser.renamingSavedPageID = nil } }
    private func save(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { finish(); return }
        do { try browser.renameSavedPage(page.id, to: name) }
        catch { browser.intelligenceError = "Couldn’t rename the tab. " + error.localizedDescription }
        finish()
    }
}

/// A native field keeps selection, text navigation and Escape handling inside the
/// row. It commits once on Return or focus loss and restores the title on Escape.
struct InlineTabNameField: NSViewRepresentable {
    let text: String
    var weight: NSFont.Weight = .regular
    let commit: (String) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(commit: commit, cancel: cancel) }
    func makeNSView(context: Context) -> NameField {
        let field = NameField(string: text)
        field.font = .systemFont(ofSize: 12.5, weight: weight)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Tab name")
        field.identifier = NSUserInterfaceItemIdentifier("BrowserInlineTabName")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ view: NameField, context: Context) {
        context.coordinator.commit = commit
        context.coordinator.cancel = cancel
        // Do not replace text being edited when the webpage changes its title.
    }

    final class NameField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var commit: (String) -> Void
        var cancel: () -> Void
        private var finished = false
        init(commit: @escaping (String) -> Void, cancel: @escaping () -> Void) { self.commit = commit; self.cancel = cancel }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(control, cancelled: true); return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(control, cancelled: false, editedValue: textView.string); return true
            }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { finish(field, cancelled: false) }
        }
        private func finish(_ control: NSControl, cancelled: Bool, editedValue: String? = nil) {
            guard !finished else { return }
            finished = true
            let value = editedValue ?? (control as? NSTextField)?.stringValue ?? ""
            control.window?.makeFirstResponder(nil)
            if cancelled { cancel() } else { commit(value) }
        }
    }
}

/// One window-scoped pressure monitor serves all saved rows. The anchors never
/// intercept mouse clicks, scrolling, dragging, or the row’s close button.
private struct ForceClickRenameAnchor: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> AnchorView { AnchorView(action: action) }
    func updateNSView(_ view: AnchorView, context: Context) { view.action = action }

    final class AnchorView: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); ForceClickRows.shared.register(self) }
    }
    @MainActor private final class ForceClickRows {
        static let shared = ForceClickRows()
        let anchors = NSHashTable<AnchorView>.weakObjects()
        var monitor: Any?
        var fired = false
        func register(_ anchor: AnchorView) {
            anchors.add(anchor)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure, .leftMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if event.type == .leftMouseUp || event.stage < 2 { self.fired = false; return false }
                    guard !self.fired, event.type == .pressure, event.stage == 2,
                          let anchor = self.anchors.allObjects.first(where: {
                              $0.window === event.window && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor &&
                              $0.bounds.insetBy(dx: 0, dy: 0).contains($0.convert(event.locationInWindow, from: nil))
                          }) else { return false }
                    self.fired = true
                    anchor.action()
                    return true
                }
                return consumed ? nil : event
            }
        }
    }
}
