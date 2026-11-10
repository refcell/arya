import SwiftUI

/// A thin determinate progress bar: a `rule` track with an `ink` fill, or the accent while
/// it is the live, primary work. 3 pt tall, fluid width.
public struct AryaProgressBar: View {
    let fraction: Double
    let isLive: Bool

    /// `fraction` is clamped to 0...1.
    public init(_ fraction: Double, isLive: Bool = false) {
        self.fraction = min(max(fraction, 0), 1)
        self.isLive = isLive
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AryaColor.rule)
                Capsule().fill(isLive ? AryaColor.accentFill : AryaColor.inkMuted)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: AryaSize.progressHeight)
        .animation(AryaMotion.panel, value: fraction)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// A small indeterminate spinner: a three-quarter arc that turns once per 0.9 s, or a still
/// arc under Reduce Motion. 10 pt by default.
public struct AryaSpinner: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 10) { self.size = size }

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / AryaMotion.spinSeconds
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(AryaColor.inkMuted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(
                    .degrees(reduceMotion ? 0 : turns.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Working")
    }
}

/// The live dot: a filled positive dot with a ring that grows and fades once per pulse, for
/// a steward that is running right now. Still under Reduce Motion.
public struct AryaLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase =
                reduceMotion
                ? 0.35
                : context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: AryaMotion.pulseSeconds)
                    / AryaMotion.pulseSeconds
            ZStack {
                Circle().stroke(AryaColor.positive, lineWidth: 1)
                    .scaleEffect(1 + phase * 1.2)
                    .opacity(1 - phase)
                Circle().fill(AryaColor.positive)
            }
        }
        .frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
        .accessibilityLabel("Running")
    }
}

extension View {
    /// Highlights a row that just arrived: a `selection` wash that fades over 1.2 s. `isNew`
    /// is true on the first render of a row the person has not seen.
    public func aryaArrival(_ isNew: Bool) -> some View {
        modifier(ArrivalHighlight(isNew: isNew))
    }
}

struct ArrivalHighlight: ViewModifier {
    let isNew: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AryaState private var lit = true

    func body(content: Content) -> some View {
        content
            .background(isNew && lit ? AryaColor.selection : .clear)
            .onAppear {
                guard isNew else { return }
                if reduceMotion {
                    lit = false
                    return
                }
                withAnimation(.easeOut(duration: AryaMotion.arrivalSeconds)) { lit = false }
            }
    }
}
