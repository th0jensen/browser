import AppKit
import SwiftUI

/// Passive geometry anchor for native chrome presentation checks. It has no intrinsic size,
/// event handling or drawing; the surrounding SwiftUI view owns its layout.
struct ChromePresentationMarker: NSViewRepresentable {
    let identifier: String
    var onViewAvailable: ((ChromeRegionGeometryView) -> Void)? = nil
    func makeNSView(context: Context) -> ChromeRegionGeometryView {
        let view = ChromeRegionGeometryView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.wantsLayer = true
        onViewAvailable?(view)
        return view
    }
    func updateNSView(_ view: ChromeRegionGeometryView, context: Context) {
        onViewAvailable?(view)
    }
}

final class ChromeRegionGeometryView: NSView {
    var regionBounds: CGRect? {
        guard let window else { return nil }
        let rect = convert(bounds, to: nil)
        return CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
