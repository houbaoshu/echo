// Voice orb visual prototype — macOS 27.0 / Xcode 27.0
//
// A standalone look-and-feel probe for the Siri-style Live Voice orb, before any of it
// reaches production code. Nothing here imports Echo: no VoiceOrb, no VoiceSessionSnapshot,
// no PetSurfacePresentation. It draws the orb from an animated MeshGradient and exposes the
// five things being judged as live sliders, so the numbers that look right can be read off
// the window and written into the real view later.
//
// What this answers:
//  [O1] Does an animated MeshGradient read as internal FLOW at ~64pt, or does it smear into
//       one flat colour? The four corners are pinned, the boundary points slide along their
//       own edge and the four interior points drift freely, all on slow incommensurate
//       periods (12–30s) so the motion never visibly loops.
//  [O2] What breathing amplitude and period stay QUIET? The default is ±3% on a ~4.5s
//       period, which is roughly a resting human breath.
//  [O3] How bright may the specular and rim sit before the orb starts to shout, on a dark
//       and on a light background.
//  [O4] Does the effect survive the 56–72pt band the chat window would use? The reference
//       row draws 48 / 64 / 80pt from the same parameters for that comparison.
//  [O5] Is 30fps enough for motion this slow? The frame rate toggle switches 30 ⇄ 60.
//
// Build & run:
//   source scripts/swift-env.sh
//   swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx27.0 \
//       docs/repros/voice-orb-prototype.swift -o build/orb-prototype && build/orb-prototype
//
// The palette is Echo's existing orb palette from VoiceViews.swift:194-195, so what is being
// judged is the motion and the shading, not a new brand colour.

import AppKit
import SwiftUI

// MARK: - Colour

/// Colour mixing that `Color` does not offer. The mesh needs to interpolate between two
/// tints per vertex every frame, which has to happen in components.
private struct RGB {
    var r: Double, g: Double, b: Double

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func color(brightness: Double) -> Color {
        Color(red: min(1, r * brightness), green: min(1, g * brightness), blue: min(1, b * brightness))
    }
}

private enum Palette {
    /// VoiceViews.swift:194-195, unchanged.
    static let deep = RGB(r: 0.32, g: 0.42, b: 0.96)
    static let mid = RGB(r: 0.56, g: 0.64, b: 1.0)
    static let pale = RGB(r: 0.80, g: 0.84, b: 1.0)
    /// Two small hue excursions, so the flow has something to be seen with. Neither is far
    /// enough from the blue to read as a second colour at rest.
    static let cyan = RGB(r: 0.45, g: 0.76, b: 1.0)
    static let violet = RGB(r: 0.62, g: 0.55, b: 1.0)
}

// MARK: - Mesh geometry

private enum Mesh {
    static let side = 4
    static let count = side * side
    private static let step = Float(side - 1)

    /// Row-major base grid over the unit square.
    static let base: [SIMD2<Float>] = (0..<side).flatMap { row in
        (0..<side).map { column in SIMD2<Float>(Float(column) / step, Float(row) / step) }
    }

    /// Deterministic per-vertex phases and rates. Written out rather than seeded from a
    /// generator so two runs of the probe are comparable.
    private static func phase(_ index: Int, _ salt: Double) -> Double {
        (Double(index) * 2.399963 + salt).truncatingRemainder(dividingBy: 2 * .pi)
    }

    private static func rate(_ index: Int, _ salt: Double) -> Double {
        // 12–30 second periods, never a whole multiple of one another.
        0.21 + 0.0407 * Double((index * 7 + Int(salt * 10)) % 7)
    }

    /// The drifting grid at `time`. Corners are pinned — a corner that moves tears the
    /// gradient — boundary vertices slide only along their own edge, interior vertices are
    /// free. `flow` is 0…1 and scales every excursion.
    static func points(time: Double, flow: Double) -> [SIMD2<Float>] {
        base.enumerated().map { index, point in
            let row = index / side, column = index % side
            let onLeftOrRight = column == 0 || column == side - 1
            let onTopOrBottom = row == 0 || row == side - 1
            if onLeftOrRight && onTopOrBottom { return point }

            let along = Float(0.055 * flow * sin(time * rate(index, 1.3) + phase(index, 0.7)))
            let free = SIMD2<Float>(Float(0.085 * flow * sin(time * rate(index, 2.1) + phase(index, 1.9))),
                                    Float(0.085 * flow * cos(time * rate(index, 3.7) + phase(index, 4.1))))
            if onLeftOrRight { return SIMD2(point.x, point.y + along) }
            if onTopOrBottom { return SIMD2(point.x + along, point.y) }
            return point + free
        }
    }

    /// One tint per vertex: saturated at the rim, pale toward the upper left where the
    /// specular sits, with a slow excursion through cyan and violet that is what makes the
    /// drift legible as flow rather than as a wobble.
    static func colors(time: Double, flow: Double, brightness: Double) -> [Color] {
        (0..<count).map { index in
            let row = index / side, column = index % side
            let u = Double(column) / Double(side - 1), v = Double(row) / Double(side - 1)
            let radius = min(1, hypot(u - 0.5, v - 0.5) / 0.7071)

            // Base shading: deep at the edge, mid through the body, pale toward (0.35, 0.3).
            var tint = Palette.deep.mix(Palette.mid, max(0, 1 - radius * 1.25))
            let toSpecular = max(0, 1 - hypot(u - 0.35, v - 0.30) / 0.75)
            tint = tint.mix(Palette.pale, toSpecular * 0.55)

            // The excursion, strongest in the interior so the rim stays a steady blue.
            let interior = max(0, 1 - radius * 1.1)
            let swing = 0.5 + 0.5 * sin(time * rate(index, 0.5) * 1.6 + phase(index, 2.6))
            let accent = Palette.cyan.mix(Palette.violet, swing)
            tint = tint.mix(accent, 0.30 * flow * interior)

            return tint.color(brightness: brightness)
        }
    }
}

// MARK: - The orb

private struct OrbSettings {
    var size: Double = 64
    var speed: Double = 1.0
    var flow: Double = 0.6
    var breath: Double = 0.030
    var brightness: Double = 1.0
    var glow: Double = 0.35
    var reduceMotion = false
    var smooth = false

    var interval: Double { smooth ? 1.0 / 60 : 1.0 / 30 }
}

private struct OrbView: View {
    let settings: OrbSettings
    let size: Double
    /// Seconds since the probe started; shared by every orb on screen so the reference row
    /// stays in step with the subject.
    let time: Double

    private var t: Double { settings.reduceMotion ? 0 : time * settings.speed }

    /// ~4.5s at speed 1. Slower than a resting breath reads as sleepy; faster reads as eager.
    private var breathScale: Double {
        settings.reduceMotion ? 1 : 1 + settings.breath * sin(t * 1.4)
    }

    var body: some View {
        let flow = settings.reduceMotion ? 0.35 : settings.flow
        ZStack {
            MeshGradient(width: Mesh.side, height: Mesh.side,
                         points: Mesh.points(time: t, flow: flow),
                         colors: Mesh.colors(time: t, flow: flow, brightness: settings.brightness),
                         smoothsColors: true)

            // Volume: the body falls off into shadow at the rim, which is most of what makes
            // a flat disc read as a sphere.
            Circle().fill(RadialGradient(colors: [.clear, Color(red: 0.04, green: 0.05, blue: 0.20).opacity(0.50)],
                                         center: .center, startRadius: size * 0.16, endRadius: size * 0.52))

            // Fresnel: a thin rim light, brightest away from the specular.
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.40 * settings.brightness),
                                                          .white.opacity(0.04),
                                                          .white.opacity(0.26 * settings.brightness)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: max(0.6, size * 0.024))
                .blendMode(.plusLighter)

            // Specular, scaled from the size — the production view hardcodes endRadius 10,
            // which is exactly why it cannot grow past the pet strip.
            Circle().fill(RadialGradient(colors: [.white.opacity(0.50 * settings.brightness), .clear],
                                         center: UnitPoint(x: 0.35, y: 0.30),
                                         startRadius: 0, endRadius: size * 0.45))
                .blendMode(.plusLighter)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Grouped before the shadow so plusLighter blends inside the orb, not against
        // whatever the orb happens to be sitting on.
        .compositingGroup()
        .shadow(color: Palette.mid.color(brightness: 1).opacity(settings.glow), radius: size * 0.14)
        .scaleEffect(breathScale)
        .frame(width: size * 1.12, height: size * 1.12)
    }
}

// MARK: - Probe window

private struct ProbeView: View {
    @State private var settings = OrbSettings()
    @State private var darkStage = true

    var body: some View {
        HStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: settings.interval, paused: false)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                VStack(spacing: 36) {
                    Spacer()
                    OrbView(settings: settings, size: settings.size, time: time)
                    Text("\(Int(settings.size))pt")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    // The 56–72pt band the chat window would live in, plus the pet strip's
                    // own scale for contrast, all from the same parameters.
                    HStack(alignment: .center, spacing: 28) {
                        ForEach([22.0, 48.0, 64.0, 80.0], id: \.self) { size in
                            VStack(spacing: 8) {
                                OrbView(settings: settings, size: size, time: time)
                                Text("\(Int(size))").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(darkStage ? Color(red: 0.09, green: 0.09, blue: 0.11)
                                      : Color(red: 0.96, green: 0.96, blue: 0.97))
            }

            Divider()

            Form {
                Section("尺寸与节奏") {
                    slider("尺寸", $settings.size, 32...96, "%.0f pt")
                    slider("速度", $settings.speed, 0.2...2.0, "%.2f×")
                    slider("呼吸幅度", $settings.breath, 0...0.08, "±%.1f%%", scale: 100)
                }
                Section("质感") {
                    slider("内部流动", $settings.flow, 0...1, "%.2f")
                    slider("亮度", $settings.brightness, 0.5...1.4, "%.2f")
                    slider("外辉光", $settings.glow, 0...0.8, "%.2f")
                }
                Section("对照") {
                    Toggle("深色背景", isOn: $darkStage)
                    Toggle("60fps（关闭为 30fps）", isOn: $settings.smooth)
                    Toggle("模拟“减弱动态效果”", isOn: $settings.reduceMotion)
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Host

private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Voice Orb 视觉原型"
        window.contentView = NSHostingView(rootView: ProbeView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum VoiceOrbPrototype {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
