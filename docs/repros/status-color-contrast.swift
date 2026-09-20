// Increase Contrast, system colours, and what a dynamic NSColor provider is handed.
//
// Background: `WorkspaceStyle` derives its secondary and tertiary text colours by
// checking `appearance.bestMatch(from:)` for a high-contrast appearance and raising
// labelColor's alpha. Phase 3's P2-11 adds status colours (warning / success / running)
// and had to answer three questions before copying that shape:
//
//   [C1] Can a high-contrast appearance be synthesized by name, so this is testable
//        offline the way a light/dark difference is?
//   [C2] Do the system status colours already carry an Increase Contrast variant, which
//        would make the whole derivation unnecessary?
//   [C3] Inside `NSColor(name:) { appearance in … }`, is a *nested* system colour
//        resolved against the appearance being asked about, or against whatever the
//        current drawing appearance happens to be?
//
// Build and run:
//   SDKROOT=$(xcrun --show-sdk-path) swiftc -swift-version 6 \
//       -target arm64-apple-macosx27.0 docs/repros/status-color-contrast.swift \
//       -framework AppKit -o build/status-color-contrast && build/status-color-contrast
//
// Measured on macOS 27.0 / Xcode 27.0 (27A266a), 2026-09-20.

import AppKit

let requested: [NSAppearance.Name] = [.aqua, .accessibilityHighContrastAqua,
                                      .darkAqua, .accessibilityHighContrastDarkAqua]

// [C1] A high-contrast appearance cannot be conjured by name. Increase Contrast is a
// system-wide accessibility setting (NSWorkspace.accessibilityDisplayShouldIncreaseContrast),
// and with it off, NSAppearance(named: .accessibilityHighContrastAqua) hands back plain
// aqua — `actual` below is NSAppearanceNameAqua, not the name that was asked for.
//
// Consequence: the Increase Contrast branch of a dynamic colour CANNOT be exercised from
// a test process on a machine that has the setting off. Nothing in the suite asserts those
// numbers; turn the setting on in System Settings › Accessibility › Display to see them.
//
//   requested=NSAppearanceNameAqua                    actual=NSAppearanceNameAqua      best=NSAppearanceNameAqua
//   requested=NSAppearanceNameAccessibilityAqua       actual=NSAppearanceNameAqua      best=NSAppearanceNameAqua
//   requested=NSAppearanceNameDarkAqua                actual=NSAppearanceNameDarkAqua  best=NSAppearanceNameDarkAqua
//   requested=NSAppearanceNameAccessibilityDarkAqua   actual=NSAppearanceNameDarkAqua  best=NSAppearanceNameDarkAqua
func c1() {
    print("[C1] appearance synthesis")
    for name in requested {
        let appearance = NSAppearance(named: name)!
        print("  requested=\(name.rawValue.padding(toLength: 34, withPad: " ", startingAt: 0))"
              + "actual=\(appearance.name.rawValue.padding(toLength: 26, withPad: " ", startingAt: 0))"
              + "best=\(appearance.bestMatch(from: requested)?.rawValue ?? "nil")")
    }
}

// [C2] INCONCLUSIVE, and [C1] is why. A system status colour's two dark columns differ
// from its two light ones, but within each pair the plain and the "high-contrast" column
// are identical — which proves nothing, because [C1] showed both columns of a pair are
// the same appearance object. labelColor behaves the same way here, and labelColor is
// known to go fully opaque under real Increase Contrast, so this table is measuring the
// setting being off, not the absence of a variant.
//
// Consequence for WorkspaceStyle: the status *ink* defers to the system hue and adds no
// contrast branch of its own, because deepening a colour the system may already be
// deepening would correct it twice. Only the fill alpha — a number this app invented,
// with no system counterpart — is raised. Re-run this with Increase Contrast ON to
// settle [C2]; if the system does supply variants, nothing in WorkspaceStyle changes.
//
//   systemOrange        1.000/0.553/0.157  1.000/0.553/0.157  1.000/0.573/0.188  1.000/0.573/0.188
//   systemGreen         0.204/0.780/0.349  0.204/0.780/0.349  0.188/0.820/0.345  0.188/0.820/0.345
//   systemBlue          0.000/0.533/1.000  0.000/0.533/1.000  0.000/0.569/1.000  0.000/0.569/1.000
//   labelColor          0.000/0.000/0.000  0.000/0.000/0.000  1.000/1.000/1.000  1.000/1.000/1.000   (alpha 0.85 throughout)
//   controlAccentColor  0.000/0.478/1.000  0.000/0.478/1.000  0.000/0.478/1.000  0.000/0.478/1.000
func c2() {
    print("[C2] system colours across appearances (aqua, hcAqua, dark, hcDark)")
    let colors: [(String, NSColor)] = [("systemOrange", .systemOrange), ("systemGreen", .systemGreen),
                                       ("systemBlue", .systemBlue), ("labelColor", .labelColor),
                                       ("controlAccentColor", .controlAccentColor)]
    for (label, color) in colors {
        var line = "  " + label.padding(toLength: 20, withPad: " ", startingAt: 0)
        for name in requested {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let rgb = color.usingColorSpace(.sRGB)!
                line += String(format: "%.3f/%.3f/%.3f@%.2f  ", rgb.redComponent, rgb.greenComponent,
                               rgb.blueComponent, rgb.alphaComponent)
            }
        }
        print(line)
    }
}

// [C3] Inside a dynamic colour's provider, the appearance being resolved for is ALREADY
// the current drawing appearance. A nested system colour therefore resolves correctly
// with a plain `usingColorSpace(_:)`, and `performAsCurrentDrawingAppearance` must NOT be
// re-entered there — the provider is called on whatever thread draws, and re-entering it
// would be both unnecessary and unsafe.
//
// The proof is that `derived` (which reads NSColor.systemOrange inside its own provider)
// tracks the system colour's dark variant without ever setting an appearance itself:
//
//   aqua    system=1.000/0.553/0.157  derived=1.000/0.553/0.157
//   dark    system=1.000/0.573/0.188  derived=1.000/0.573/0.188
//
// This is what `WorkspaceStyle.statusFill(_:)` relies on.
func c3() {
    print("[C3] nested resolution inside a colour provider")
    let derived = NSColor(name: nil) { _ in NSColor.systemOrange.usingColorSpace(.sRGB)! }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let system = NSColor.systemOrange.usingColorSpace(.sRGB)!
            let made = derived.usingColorSpace(.sRGB)!
            print(String(format: "  %@ system=%.3f/%.3f/%.3f  derived=%.3f/%.3f/%.3f",
                         name.rawValue.padding(toLength: 26, withPad: " ", startingAt: 0),
                         system.redComponent, system.greenComponent, system.blueComponent,
                         made.redComponent, made.greenComponent, made.blueComponent))
        }
    }
}

c1(); c2(); c3()
