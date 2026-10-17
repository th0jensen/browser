import AppKit
import SwiftUI

/// The attached NSToolbar remains the persisted source of truth in fullscreen.
/// Separators and spaces end a glass group exactly where native customization put them.
struct FullscreenToolbarPart: Equatable, Identifiable {
    enum Content: Equatable {
        case controls([String])
        case address
        case space
        case flexibleSpace
        case divider
    }

    let id: Int
    let content: Content

    var minimumWidth: CGFloat {
        switch content {
        case .controls(let identifiers): CGFloat(identifiers.count) * 28 + 8
        case .address: 160
        case .space, .flexibleSpace: 20
        case .divider: 12
        }
    }

    static func parts(for identifiers: [String]) -> [Self] {
        var result: [Self] = []
        var controls: [String] = []
        var groupStart = 0
        func flushControls() {
            guard !controls.isEmpty else { return }
            result.append(Self(id: groupStart, content: .controls(controls)))
            controls.removeAll()
        }
        for (index, identifier) in identifiers.enumerated() {
            let separator: Content?
            switch identifier {
            case "address": separator = .address
            case NSToolbarItem.Identifier.space.rawValue: separator = .space
            case NSToolbarItem.Identifier.flexibleSpace.rawValue: separator = .flexibleSpace
            default: separator = identifier.hasPrefix("divider") ? .divider : nil
            }
            if let separator {
                flushControls()
                result.append(Self(id: index, content: separator))
            } else {
                if controls.isEmpty { groupStart = index }
                controls.append(identifier)
            }
        }
        flushControls()
        return result
    }
}

/// Only glass surfaces are drawn; the page stays visible between the button groups.
struct FullscreenToolbarRow<Control: View, Address: View>: View {
    let identifiers: [String]
    var focusRequest = 0
    var control: (String) -> Control
    var address: () -> Address

    init(identifiers: [String], focusRequest: Int = 0, @ViewBuilder control: @escaping (String) -> Control,
         @ViewBuilder address: @escaping () -> Address) {
        self.identifiers = identifiers
        self.focusRequest = focusRequest
        self.control = control
        self.address = address
    }

    var body: some View {
        let parts = FullscreenToolbarPart.parts(for: identifiers)
        let minimumWidth = parts.reduce(0) { $0 + $1.minimumWidth }
            + CGFloat(max(0, parts.count - 1)) * BrowserChrome.edgeInset
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: BrowserChrome.edgeInset) {
                        HStack(spacing: BrowserChrome.edgeInset) {
                            ForEach(parts) { part in
                                switch part.content {
                                case .controls(let identifiers):
                                    HStack(spacing: 0) {
                                        ForEach(Array(identifiers.enumerated()), id: \.offset) { _, identifier in
                                            control(identifier)
                                                .frame(width: 28, height: BrowserChrome.toolbarHeight)
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .glassEffect(.regular.interactive(), in: Capsule())
                                case .address:
                                    address()
                                        .frame(minWidth: 160, maxWidth: .infinity)
                                        .id("address")
                                case .space:
                                    Color.clear.frame(width: 20, height: 1)
                                        .allowsHitTesting(false)
                                case .flexibleSpace:
                                    Spacer(minLength: 20)
                                case .divider:
                                    Rectangle().fill(.separator)
                                        .frame(width: 1, height: 20)
                                        .frame(width: 12)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        .frame(width: max(geometry.size.width, minimumWidth))
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .onChange(of: focusRequest) { _, request in
                    if request > 0 { proxy.scrollTo("address", anchor: .center) }
                }
                .onAppear {
                    if focusRequest > 0 { proxy.scrollTo("address", anchor: .center) }
                }
            }
        }
        .frame(height: BrowserChrome.toolbarHeight)
    }
}

private struct FullscreenToolbarOverlayKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var fullscreenToolbarOverlay: Bool {
        get { self[FullscreenToolbarOverlayKey.self] }
        set { self[FullscreenToolbarOverlayKey.self] = newValue }
    }
}

/// Native toolbar buttons use AppKit's automatic presentation; overlay groups own their glass.
struct ChromeToolbarButtonStyle: PrimitiveButtonStyle {
    @Environment(\.fullscreenToolbarOverlay) private var fullscreenOverlay

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if fullscreenOverlay {
            Button(configuration)
                .buttonStyle(.plain)
                .frame(width: 28, height: BrowserChrome.toolbarHeight)
                .contentShape(Rectangle())
        } else {
            Button(configuration).buttonStyle(.automatic)
        }
    }
}
