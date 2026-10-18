import AppKit
import SwiftUI

/// Keep the field's natural measurement independent of its last allocated toolbar width.
struct AddressToolbarHost<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> AddressToolbarView<Content> { AddressToolbarView(content: content) }
    func updateNSView(_ view: AddressToolbarView<Content>, context: Context) { view.host.rootView = content }
}

final class AddressToolbarView<Content: View>: NSView {
    let host: NSHostingView<Content>
    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: BrowserChrome.toolbarHeight) }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
    }
}
