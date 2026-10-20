import AppKit
import SwiftUI

// Type comes from the system's text styles; the secondary and tertiary tones are the system's label colours.
// Keep AppKit and SwiftUI typography in sync, including the native text editor.
enum WorkspaceStyle {
    /// The point size of the system `.body` style, for AppKit text — the composer and
    /// code — that has to match SwiftUI's `.body`.
    static let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
    static let body = Font.body
    static let medium = Font.body.weight(.medium)
    static let caption = Font.callout
    static let primary = Color(nsColor: .labelColor)
    /// For surfaces without a material of their own. On the sidebar, the project file
    /// inspector and the search palette, call sites use the hierarchical `.secondary`
    /// instead: measured on macOS 27, it does not draw the same as this fixed colour there.
    /// In the sidebar-style lists it is lighter (light: 136 vs 119 on 238; dark: 120 vs 149
    /// on 44); on the palette's material it is stronger (light: 112 vs 120; dark: 173 vs 152).
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: Status colours
    //
    // Warning, success and running are states, not decoration, so they name a meaning
    // instead of a hue at each call site. The hue itself stays the system's —
    // `NSColor.systemOrange` / `.systemGreen` / `.systemBlue` already track light and
    // dark, which is why nothing below spells out components.
    //
    // The ink deliberately does NOT get an Increase Contrast branch of its own — like the
    // text colours above, it is a system colour — and that is a measurement, not an oversight. Increase Contrast is a
    // system-wide accessibility setting, not an appearance a view can be handed: with it
    // off, `NSAppearance(named: .accessibilityHighContrastAqua)` hands back plain aqua
    // on a machine with that setting off. Such a run cannot tell whether a system
    // colour carries its own high-contrast variant — and if it does, deepening
    // the hue here as well would correct it twice. Adjusting a colour the system already
    // adjusts is the worse failure, so this defers to the system for the hue.
    //
    // The fill below is the opposite case: its alpha is a number this app invented, with
    // no system counterpart that could double up, so it is raised here.

    /// The mark itself: an icon, a piece of status text, a badge fill.
    static let warning = Color(nsColor: .systemOrange)
    static let success = Color(nsColor: .systemGreen)
    static let running = Color(nsColor: .systemBlue)
    /// The tint a status message sits on. Derived from the same hue rather than written
    /// out as `Color.orange.opacity(0.12)`, so ink and ground cannot drift apart, and
    /// deepened under Increase Contrast so a 12% wash does not vanish there.
    static let warningFill = Color(nsColor: statusFill(.systemOrange))

    private static func increasesContrast(_ appearance: NSAppearance) -> Bool {
        let contrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        return contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
    }
    private static func statusFill(_ base: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            // A nested system colour resolves against the appearance being asked about:
            // the provider already runs with it current for drawing, so this picks
            // up the light or dark variant without setting an appearance itself — and
            // must not, since the provider is called on whatever thread draws.
            let resolved = base.usingColorSpace(.sRGB) ?? base
            return resolved.withAlphaComponent(increasesContrast(appearance) ? 0.2 : 0.12)
        }
    }
}

extension NSFont {
    /// TextKit 2 has no `defaultLineHeight(for:)`, and reaching for `NSLayoutManager`
    /// only to read one would migrate a text view back to TextKit 1. Measured against
    /// `NSLayoutManager.defaultLineHeight(for:)` on macOS 27.0: identical for the
    /// 11-14 pt system fonts this app draws with. Every composer measures at 13 pt
    /// (`WorkspaceStyle.bodySize`, and the pet's fields); check the font size before adding a caller
    /// outside that range.
    var defaultLineHeight: CGFloat { ceil(ascender - descender + leading) }
}
