import AppKit
import SwiftUI

struct WindowGlassBackground: NSViewRepresentable {
    /// Keeps the glass dark whatever the system appearance, for a private window.
    var isDark = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentWindowMaterialView()
        view.material = .titlebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = isDark ? NSAppearance(named: .darkAqua) : nil
    }
}

private final class TransparentWindowMaterialView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
    }
}
