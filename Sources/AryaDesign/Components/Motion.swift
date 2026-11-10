import SwiftUI

extension AryaMotion {
    /// True in snapshot and test processes (any `ARYA_SNAPSHOT*` variable, or an `.xctest`
    /// bundle): motion renders one still frame there so offscreen renders settle.
    public static let frozenByProcess: Bool = {
        let info = ProcessInfo.processInfo
        if info.environment.keys.contains(where: { $0.hasPrefix("ARYA_SNAPSHOT") }) { return true }
        if info.environment["XCTestConfigurationFilePath"] != nil { return true }
        return info.arguments.contains { $0.contains(".xctest") }
    }()

    /// Whether motion is still: frozen by the process, or Reduce Motion is on.
    public static func isStill(reduceMotion: Bool) -> Bool { frozenByProcess || reduceMotion }
}

/// A thin determinate progress bar: a `rule` track with an `ink` fill, `positive` once the
/// work finished well. Never the accent (that is the primary action's). 3 pt tall, fluid width.
public struct AryaProgressBar: View {
    let fraction: Double
    let succeeded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `fraction` is clamped to 0...1; `succeeded` tints a finished bar green. `isLive` is
    /// accepted for callers that mark running work; it no longer changes the tint (VC26).
    public init(_ fraction: Double, isLive: Bool = false, succeeded: Bool = false) {
        self.fraction = min(max(fraction, 0), 1)
        self.succeeded = succeeded
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AryaColor.rule)
                Capsule().fill(succeeded && fraction >= 1 ? AryaColor.positive : AryaColor.ink)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: AryaSize.progressHeight)
        .animation(
            AryaMotion.isStill(reduceMotion: reduceMotion) ? nil : AryaMotion.panel, value: fraction
        )
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
        Group {
            if AryaMotion.isStill(reduceMotion: reduceMotion) {
                arc(degrees: 0)
            } else {
                TimelineView(.animation) { context in
                    let turns = context.date.timeIntervalSinceReferenceDate / AryaMotion.spinSeconds
                    arc(degrees: turns.truncatingRemainder(dividingBy: 1) * 360)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Working")
    }

    private func arc(degrees: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(AryaColor.inkMuted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(degrees))
    }
}

/// The live dot: a filled positive dot with a ring that grows and fades once per pulse, for
/// a steward that is running right now. Still under Reduce Motion.
public struct AryaLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if AryaMotion.isStill(reduceMotion: reduceMotion) {
                dot(phase: 0.35)
            } else {
                TimelineView(.animation) { context in
                    dot(
                        phase: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: AryaMotion.pulseSeconds)
                            / AryaMotion.pulseSeconds)
                }
            }
        }
        .frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
        .accessibilityLabel("Running")
    }

    /// One frame of the pulse; `phase` runs 0...1 per cycle.
    private func dot(phase: Double) -> some View {
        ZStack {
            Circle().stroke(AryaColor.positive, lineWidth: 1)
                .scaleEffect(1 + phase * 1.2)
                .opacity(1 - phase)
            Circle().fill(AryaColor.positive)
        }
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
                if AryaMotion.isStill(reduceMotion: reduceMotion) {
                    // Snapshots show the wash at its start; Reduce Motion drops it.
                    if reduceMotion { lit = false }
                    return
                }
                withAnimation(.easeOut(duration: AryaMotion.arrivalSeconds)) { lit = false }
            }
    }
}
