import CoreGraphics

/// The app's text sizes. Every type token scales by the current step together (STYLE.md Type).
enum TextScale {
    /// The user-defaults key holding the current scale.
    static let defaultsKey = "textScale"
    static let steps: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5]
    static let standard: CGFloat = 1
    /// The steps' names in Settings, in `steps` order.
    static let labels = ["Small", "Standard", "Large", "Larger", "Largest"]

    /// The nearest step to a stored value, so an edited default never yields an odd size.
    static func normalized(_ value: CGFloat) -> CGFloat {
        steps.min { abs($0 - value) < abs($1 - value) } ?? standard
    }

    static func bigger(_ value: CGFloat) -> CGFloat {
        steps.first { $0 > normalized(value) } ?? steps[steps.count - 1]
    }

    static func smaller(_ value: CGFloat) -> CGFloat {
        steps.last { $0 < normalized(value) } ?? steps[0]
    }
}
