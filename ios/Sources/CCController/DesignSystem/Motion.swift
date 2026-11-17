import SwiftUI

/// How the app moves. One spring with no bounce for everything that changes place or size, a quicker one for
/// small things arriving and leaving, and a pressed state for everything that can be tapped.
enum CCMotion {
    /// Layout moves: a card growing, a row moving, a panel sliding. Springs keep a gesture's speed and can be
    /// redirected mid-move, which timed curves can't.
    static let spring = Animation.spring(duration: 0.35, bounce: 0)
    /// Small things: a button appearing, a pressed state letting go.
    static let quick = Animation.spring(duration: 0.22, bounce: 0)

    /// The spring, or no animation when the person asked the system to reduce motion.
    static func spring(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : spring }
    static func quick(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : quick }
}

/// A button drawn as text, an icon or a small label, with no glass of its own. It dims the moment it is
/// touched and comes back on release, so a tap is never unanswered.
struct CCPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            // Down is instant; only the release eases back.
            .animation(configuration.isPressed ? nil : CCMotion.quick, value: configuration.isPressed)
    }
}

/// A whole row that opens something. A plate shows behind it while it is touched, as the system's list rows do.
struct CCRowButtonStyle: ButtonStyle {
    /// How far the plate reaches past the label, into the row's own padding.
    var outset: CGFloat = 8
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.ccLabel.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(-outset)
            }
            .animation(configuration.isPressed ? nil : CCMotion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CCPressableButtonStyle {
    static var ccPressable: CCPressableButtonStyle { CCPressableButtonStyle() }
}

extension ButtonStyle where Self == CCRowButtonStyle {
    static var ccRow: CCRowButtonStyle { CCRowButtonStyle() }
}

/// A rectangle larger than the view it's given. As a content shape it lets a small control take taps over at
/// least 44 pt without growing on screen.
struct OutsetRectangle: Shape {
    var horizontal: CGFloat
    var vertical: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -horizontal, dy: -vertical))
    }
}

extension View {
    /// Widens what counts as a tap on this view by the given amounts on each side. Use it on a button's label.
    func tapOutset(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        contentShape(OutsetRectangle(horizontal: horizontal, vertical: vertical))
    }
}
