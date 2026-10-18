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
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var labelStyle = ToolbarLabelStyle.iconOnly
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
                                                .frame(minWidth: 28)
                                                .frame(width: labelStyle == .iconOnly ? 28 : nil, height: labelStyle.chromeControlHeight)
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
                        .frame(width: labelStyle == .iconOnly ? max(geometry.size.width, minimumWidth) : nil)
                        .frame(minWidth: max(geometry.size.width, minimumWidth))
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
        .frame(height: labelStyle.chromeControlHeight)
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
private struct ChromeToolbarButtonPresentation: ViewModifier {
    @Environment(\.fullscreenToolbarOverlay) private var fullscreenOverlay
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var labelStyle = ToolbarLabelStyle.iconOnly

    @ViewBuilder
    func body(content: Content) -> some View {
        if fullscreenOverlay {
            content
                .buttonStyle(.plain)
                .padding(.horizontal, labelStyle == .iconOnly ? 0 : 6)
                .frame(minWidth: 28)
                .frame(width: labelStyle == .iconOnly ? 28 : nil, height: labelStyle.chromeControlHeight)
                .contentShape(Rectangle())
        } else {
            content.buttonStyle(.automatic)
        }
    }
}

extension View {
    /// Apply the native style directly to the original control, preserving its action and identity.
    func chromeToolbarButtonStyle() -> some View {
        modifier(ChromeToolbarButtonPresentation())
    }
}

/// Public AppKit factories give the fullscreen overlay the same native window controls
/// without detaching the original buttons from AppKit's titlebar.
struct FullscreenWindowControls: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    weak var window: NSWindow?

    func makeNSView(context: Context) -> FullscreenWindowControlsView {
        let view = FullscreenWindowControlsView()
        view.configure(targetWindow: window, isEnabled: isEnabled)
        return view
    }

    func updateNSView(_ view: FullscreenWindowControlsView, context: Context) {
        view.configure(targetWindow: window, isEnabled: isEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullscreenWindowControlsView, context: Context) -> CGSize? {
        let height = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? BrowserChrome.tabRowHeight
        return CGSize(width: nsView.controlsWidth, height: height)
    }
}

final class FullscreenWindowControlsView: NSView {
    private weak var targetWindow: NSWindow?
    private var controlsAreEnabled = true
    private(set) var controlButtons: [NSWindow.ButtonType: NSButton] = [:]
    private var buttonOffsets: [NSWindow.ButtonType: CGFloat] = [:]
    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    var controlsWidth: CGFloat {
        controlButtons.reduce(0) { max($0, leadingInset + (buttonOffsets[$1.key] ?? 0) + $1.value.frame.width) }
    }

    private var leadingInset: CGFloat {
        (BrowserChrome.toolbarHeight - (controlButtons[.closeButton]?.frame.height ?? 14)) / 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullScreen]
        for (index, type) in buttonTypes.enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: style) else { continue }
            controlButtons[type] = button
            buttonOffsets[type] = CGFloat(index) * 20
            switch type {
            case .closeButton: button.setAccessibilityLabel("Close Window")
            case .miniaturizeButton: button.setAccessibilityLabel("Minimize Window")
            case .zoomButton: button.setAccessibilityLabel("Exit Full Screen")
            default: break
            }
            addSubview(button)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: controlsWidth, height: BrowserChrome.tabRowHeight)
    }

    func configure(targetWindow: NSWindow?, isEnabled: Bool = true) {
        self.targetWindow = targetWindow
        controlsAreEnabled = isEnabled
        updateButtons()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateButtons()
    }

    private func updateButtons() {
        guard let target = targetWindow ?? window else { return }
        let oldWidth = controlsWidth
        let isFullscreen = target.styleMask.contains(.fullScreen)
        var geometryChanged = false
        // Fullscreen AppKit can park its original hidden controls. Keep the native
        // pitch captured in windowed mode, or the standard 20-point factory pitch.
        if !isFullscreen, let sourceClose = target.standardWindowButton(.closeButton) {
            let closeOrigin = sourceClose.convert(sourceClose.bounds, to: nil).minX
            let offsets = buttonTypes.compactMap { type -> (NSWindow.ButtonType, CGFloat)? in
                guard let source = target.standardWindowButton(type) else { return nil }
                return (type, source.convert(source.bounds, to: nil).minX - closeOrigin)
            }
            if offsets.count == 3, offsets[1].1 >= sourceClose.frame.width,
               offsets[2].1 - offsets[1].1 >= (target.standardWindowButton(.miniaturizeButton)?.frame.width ?? 14) {
                for (type, offset) in offsets where buttonOffsets[type] != offset {
                    buttonOffsets[type] = offset
                    geometryChanged = true
                }
            }
        }
        for type in buttonTypes {
            guard let button = controlButtons[type] else { continue }
            if (button.target as? NSWindow) !== target { button.target = target }
            let action: Selector
            let enabled: Bool
            switch type {
            case .closeButton:
                action = #selector(NSWindow.performClose(_:))
                enabled = controlsAreEnabled && target.styleMask.contains(.closable)
            case .miniaturizeButton:
                action = #selector(NSWindow.performMiniaturize(_:))
                enabled = controlsAreEnabled && !isFullscreen && target.styleMask.contains(.miniaturizable)
            case .zoomButton:
                action = #selector(NSWindow.toggleFullScreen(_:))
                enabled = controlsAreEnabled && target.styleMask.contains(.resizable)
            default: continue
            }
            if button.action != action { button.action = action }
            // AppKit disables the parked fullscreen originals along with its hidden
            // titlebar. The in-window close and exit controls still own valid actions.
            let nativeEnabled = enabled && (isFullscreen || (target.standardWindowButton(type)?.isEnabled ?? true))
            if button.isEnabled != nativeEnabled { button.isEnabled = nativeEnabled }
        }
        if controlsWidth != oldWidth { invalidateIntrinsicContentSize() }
        if geometryChanged { needsLayout = true }
    }

    override func layout() {
        super.layout()
        for (type, button) in controlButtons {
            var frame = button.frame
            frame.origin = NSPoint(x: leadingInset + (buttonOffsets[type] ?? 0),
                                   y: (bounds.height - frame.height) / 2)
            if button.frame != frame { button.frame = frame }
        }
    }
}
