import SwiftUI

struct IntelligenceShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    GeometryReader { geometry in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                        LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(40, geometry.size.width * 0.5))
                            .offset(x: (geometry.size.width * 1.5) * phase - geometry.size.width * 0.5)
                    }
                }.mask(content).allowsHitTesting(false)
            }
        } else { content }
    }
}

struct TidyActivityDivider: View {
    let isLoading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func waveOffset(at x: CGFloat, width: CGFloat, phase: Double) -> CGFloat {
        // Every point inside the tips can move. Amplitude eases continuously
        // to zero at the tips, without a flat stub or a cut-off moving segment.
        let edge = min(1, max(0, min(x, width - x) / 24))
        let anchor = edge * edge * edge * (edge * (edge * 6 - 15) + 10)
        return sin(x * .pi / 16 - phase) * 3.5 * anchor
    }

    var body: some View {
        Group {
            if isLoading && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { context, size in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * .pi * 2
                        var path = Path()
                        let strokeInset: CGFloat = 2
                        let waveWidth = max(0, size.width - strokeInset * 2)
                        let samples = max(1, Int(ceil(waveWidth * 2)))
                        for sample in 0...samples {
                            let progress = CGFloat(sample) / CGFloat(samples)
                            let x = strokeInset + progress * waveWidth
                            // The wave settles progressively toward each anchored tip.
                            let y = size.height / 2 + Self.waveOffset(at: x - strokeInset, width: waveWidth, phase: phase)
                            if sample == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(path, with: .color(.primary.opacity(0.3)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
            } else {
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: 2, y: size.height / 2))
                    path.addLine(to: CGPoint(x: max(2, size.width - 2), y: size.height / 2))
                    context.stroke(path, with: .color(.primary.opacity(0.16)), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 12)
        .accessibilityHidden(true)
    }
}
