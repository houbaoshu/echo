import SwiftUI

// Shared by the desktop control and chat so both use the same four-bar mark.
struct VoiceWaveform: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let barWidth = rect.width / 7
        for (index, fraction) in [0.5, 1.0, 0.75, 0.4].enumerated() {
            let height = rect.height * fraction
            let bar = CGRect(x: rect.minX + CGFloat(index) * barWidth * 2,
                             y: rect.midY - height / 2, width: barWidth, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}

struct RecordingWaveform: View {
    let levels: [Double]
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let count = min(80, max(1, Int(geometry.size.width / 7)))
            let visible = Array(levels.suffix(80))
            let spacing = count > 1 ? max(0, (geometry.size.width - CGFloat(count) * 3) / CGFloat(count - 1)) : 0
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    // Fit the bounded history to the row instead of leaving a wide
                    // window mostly empty. Keep quiet speech visible on a dB scale.
                    let start = index * 80 / count
                    let end = (index + 1) * 80 / count
                    let padding = 80 - visible.count
                    let samples = visible[max(0, start - padding)..<max(0, end - padding)]
                    let level = samples.max() ?? 0
                    let height = level > 0 ? max(0, min(1, (log10(level) + 2.4) / 2.4)) : 0
                    Capsule().fill(active ? WorkspaceStyle.primary : WorkspaceStyle.secondary)
                        .frame(width: 3, height: 4 + max(0, geometry.size.height - 4) * height)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion || !active ? nil : .linear(duration: 0.12), value: levels)
        }.accessibilityLabel(active ? "录音音量" : "录音已暂停")
            .accessibilityIdentifier("dictation.waveform")
    }
}

struct VoiceSettingsView: View {
    @Bindable var settings: SettingsStore
    var voice: VoiceSessionController
    @FocusState private var editingSpeaker: Bool
    private var diagnostics: VoiceDiagnostics { .shared }
    /// Voice has no key of its own: without the model page's Volcengine Ark key the tests stay grey.
    private var testsDisabled: Bool { voice.testing || voice.isActive || voice.isDictating || !settings.canTestVoice }
    /// A voice ID that could not be saved says why below the group; otherwise the test's own result,
    /// which no longer applies once the Volcengine Ark key is gone (it may go while the page is away).
    private var status: SettingsTestLine? {
        settings.voiceNotice.map { SettingsTestLine(text: $0, succeeded: false) }
            ?? (settings.canTestVoice ? voice.testResult : nil)
    }
    var body: some View {
        // Each group of the section is a `Section`, so the separator between them is the
        // form's own rather than a hand-placed `Divider()`.
        Form {
            Section {
                // Saved on Return, when the field is left, or when the page goes; there is no save button.
                TextField("音色 ID", text: $settings.voiceDraft.speaker, prompt: Text("输入音色 ID"))
                    .focused($editingSpeaker)
                    .onSubmit { settings.commitVoice() }
                    .accessibilityLabel("音色 ID")
                    .accessibilityIdentifier("voiceSettings.speaker")
                // The test and the preview use the voice ID as typed, saved or not.
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button("测试连接") { test(preview: false) }.disabled(testsDisabled)
                        .accessibilityIdentifier("voiceSettings.test")
                    Button("试听音色") { test(preview: true) }.disabled(testsDisabled)
                        .accessibilityIdentifier("voiceSettings.preview")
                }
            } header: {
                Text("豆包语音")
            } footer: {
                SettingsGroupStatus(testing: voice.testing, line: status, identifier: "voiceSettings",
                                    cancel: { voice.cancelTest() })
            }
            Section {
                DisclosureGroup("诊断日志") {
                    HStack {
                        Spacer()
                        Button("复制日志") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostics.text, forType: .string)
                        }.disabled(diagnostics.lines.isEmpty).accessibilityIdentifier("voiceSettings.copyLog")
                    }
                    ScrollView {
                        Text(diagnostics.text)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 220)
                }.accessibilityIdentifier("voiceSettings.diagnostics")
            }
        }.textFieldStyle(.roundedBorder)
            .onChange(of: editingSpeaker) { _, editing in if !editing { settings.commitVoice() } }
            .onChange(of: settings.savedArkKey) { _, _ in voice.invalidateTest() }
            .onChange(of: settings.voiceDraft) { _, _ in voice.invalidateTest(); settings.voiceNotice = nil }
            .onDisappear { settings.commitVoice(); voice.cancelTest() }
    }
    private func test(preview: Bool) {
        guard let key = try? settings.voiceTestKey() else { return }
        settings.voiceNotice = nil
        voice.test(configuration: settings.voiceDraft, key: key, preview: preview)
    }
}

/// Live Voice is connecting: a small solid dot, without motion.
struct VoiceConnectingIndicator: View {
    var body: some View {
        Circle().fill(.primary).frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

/// Live Voice's mark: the selected planet's current frame, drawn at whatever size the surface
/// asks for. The pet strip and the chat overlay share one `PetStore`, so both always show the
/// same frame of the same planet.
struct VoicePlanet: View {
    /// `PlanetStore.active`, which is nil while Live Voice is idle or the sprite failed to load.
    let store: PetStore?
    let indicator: PetSurfacePresentation.VoiceIndicator
    var muted = false
    let size: CGFloat
    var body: some View {
        Group {
            if let store {
                PlanetFrame(store: store)
            } else {
                // Without a planet the surface still has to say Live Voice is on, and the
                // composer's own mark is what that looks like everywhere else in the app.
                VoiceWaveform().frame(width: size * 0.5, height: size * 0.5)
                    .foregroundStyle(muted ? WorkspaceStyle.warning : Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .saturation(muted ? 0.3 : 1)
        .accessibilityLabel(Self.label(indicator, muted: muted))
        .accessibilityIdentifier("voice.planet")
    }
    static func label(_ indicator: PetSurfacePresentation.VoiceIndicator, muted: Bool) -> String {
        switch indicator {
        case .inactive: String(localized: "语音未开始")
        case .connecting: String(localized: "正在连接")
        case .listening: muted ? String(localized: "麦克风已静音") : String(localized: "正在聆听")
        case .thinking: String(localized: "正在思考")
        case .speaking: String(localized: "正在播报")
        case .ending: String(localized: "正在结束")
        }
    }
}

/// The observing leaf. Frames change on the `PetStore`, not on the shared `PlanetStore`, so the
/// view that redraws every frame has to be the one holding the sprite.
private struct PlanetFrame: View {
    let store: PetStore
    var body: some View {
        Image(decorative: store.image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

#Preview("语音状态") {
    VStack(spacing: 20) {
        VoicePlanet(store: nil, indicator: .listening, size: 80)
        RecordingWaveform(
            levels: [-60, -42, -25, -18, -32, -48, -22, -36, -55],
            active: true
        )
        .frame(width: 240, height: 40)
    }
    .padding(24)
}
