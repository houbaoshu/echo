import AppKit
import SwiftUI

/// The shared surface behind the activity cards and the voice bubble: regular Liquid Glass, the
/// same surface as the controls below the pet. The panels are borderless, fully transparent and
/// almost never key, so the glass draws as it does in any window without an active appearance,
/// as flat frost that blurs the desktop well past legibility and refracts nothing. Glass samples
/// whatever the panel draws beneath it like the desktop, so in dark appearance a black fill under
/// it darkens the card: dark glass over a bright desktop is otherwise a light grey that leaves
/// white text near 2:1. Tinting the glass instead lightens it further.
struct CompanionBackground<SurfaceShape: Shape>: View {
    var shape: SurfaceShape
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Color.clear.glassEffect(.regular, in: shape)
            .background {
                if colorScheme == .dark { shape.fill(.black.opacity(0.3)) }
            }
    }
}

extension View {
    /// A bordered system style drawn as a circle. The companion panels are borderless floating
    /// panels that are almost never the key window, so the style would draw its inactive,
    /// washed-out variant there even though the control is live. The controls are always live, so
    /// they appear active whatever their window's state.
    func companionCircleButton(_ style: some PrimitiveButtonStyle) -> some View {
        buttonStyle(style).buttonBorderShape(.circle).environment(\.appearsActive, true)
    }
}

/// The symbol of a 28 pt `companionCircleButton`. The bordered system styles inset their label by
/// 4 pt on every side; taking that back out of the label keeps the control's outer size exactly
/// what the companion layout reserves for it.
struct CompanionButtonSymbol: View {
    let name: String
    var weight: Font.Weight = .medium
    private static let systemButtonInset: CGFloat = 8
    var body: some View {
        Image(systemName: name).font(.system(.body, weight: weight))
            .frame(width: 28 - Self.systemButtonInset, height: 28 - Self.systemButtonInset)
    }
}

/// A round control drawn on top of a companion card. The fill is one grey step away from the
/// card's glass in both appearances, so the half that overlaps the card stays visible; the
/// style exists to give the control the hover and pressed states that `.plain` does not provide.
private struct CompanionRoundButtonStyle: ButtonStyle {
    let size: CGFloat
    let textStyle: Font.TextStyle
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(textStyle, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                Circle().fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .overlay {
                        if configuration.isPressed || hovered {
                            Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
                        }
                    }
            }
            .contentShape(Circle())
    }
}

struct RoundControl: View {
    let symbol: String
    let label: String
    let size: CGFloat
    /// The symbol's text style, chosen by the caller to suit the diameter.
    let textStyle: Font.TextStyle
    let identifier: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CompanionRoundButtonStyle(size: size, textStyle: textStyle, hovered: hovered))
            .onHover { hovered = $0 }
            .help(label).accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
