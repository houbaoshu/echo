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

struct VoiceAttributionBar: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var voice: VoiceSessionController
    let owner: VoiceSessionSnapshot.Owner
    var onReturn: () -> Void
    private var conversationTitle: String {
        workspace.conversations.first { $0.id == owner.conversationID }?.title ?? "会话"
    }
    var body: some View {
        HStack(spacing: 10) {
            VoiceWaveform().frame(width: 14, height: 14)
                .foregroundStyle(voice.isMuted ? .orange : Color.accentColor)
            Button(action: onReturn) {
                HStack(spacing: 4) {
                    Text("\(conversationTitle) 的 Live Voice")
                        .font(WorkspaceStyle.caption).fontWeight(.medium)
                        .foregroundStyle(WorkspaceStyle.primary)
                    Image(systemName: "arrow.right").font(.system(size: 9))
                        .foregroundStyle(WorkspaceStyle.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("返回 \(conversationTitle)")
            .accessibilityLabel("返回 \(conversationTitle)")
            .accessibilityIdentifier("voice.reveal")
            if !voice.status.isEmpty {
                Text("· \(voice.status)")
                    .font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .accessibilityIdentifier("voice.status")
            }
            Spacer()
            Button {
                workspace.toggleVoiceMute(owner: owner)
            } label: {
                Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(voice.isMuted ? .orange : WorkspaceStyle.secondary)
            .help(voice.isMuted ? "取消静音" : "静音麦克风")
            .accessibilityLabel(voice.isMuted ? "取消静音" : "静音麦克风")
            .accessibilityIdentifier("voice.mute")
            Button {
                workspace.endVoice(owner: owner)
            } label: {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(WorkspaceStyle.secondary)
            .help("结束语音")
            .accessibilityLabel("结束语音")
            .accessibilityIdentifier("voice.end")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("voice.attributionBar")
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject private var diagnostics = VoiceDiagnostics.shared
    private var testsDisabled: Bool { voice.testing || voice.isActive || voice.isDictating || !settings.canTestVoice }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard {
                SettingsRow(title: "音色 ID") {
                    TextField("输入音色 ID", text: $settings.voiceDraft.speaker)
                        .accessibilityLabel("音色 ID")
                        .accessibilityIdentifier("voiceSettings.speaker")
                }
            }
            HStack(spacing: 12) {
                Button("保存") { settings.saveVoice() }.buttonStyle(.borderedProminent)
                    .disabled(!settings.isVoiceDirty).accessibilityIdentifier("voiceSettings.save")
                Button("还原修改") { settings.restoreVoice() }.disabled(!settings.isVoiceDirty)
                    .accessibilityIdentifier("voiceSettings.restore")
            }
            if let notice = settings.voiceNotice {
                Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("voiceSettings.notice")
            }
            Divider()
            HStack(spacing: 12) {
                Button("检查连接") { test(preview: false) }
                    .accessibilityIdentifier("voiceSettings.test")
                Button("试听音色") { test(preview: true) }
                    .accessibilityIdentifier("voiceSettings.preview")
            }.disabled(testsDisabled)
            if voice.testing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在测试…").font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    Button("取消") { voice.cancelTest() }.accessibilityIdentifier("voiceSettings.cancelTest")
                }
            }
            if let result = voice.testResult {
                Text(result).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("voiceSettings.testResult")
            }
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
        }.onChange(of: settings.voiceAPIKey) { _, _ in voice.invalidateTest() }
            .onChange(of: settings.voiceDraft) { _, _ in voice.invalidateTest() }
            .onDisappear { voice.cancelTest() }
    }
    private func test(preview: Bool) {
        guard let key = try? settings.voiceTestKey() else { return }
        voice.test(configuration: settings.voiceDraft, key: key, preview: preview)
    }
}

/// Live Voice is connecting: a small solid dot, without motion.
struct VoiceConnectingIndicator: View {
    var body: some View {
        Circle().fill(.primary).frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// The pet's voice indicator. State-driven motion only; it does not read audio levels.
struct VoiceOrb: View {
    let indicator: PetSurfacePresentation.VoiceIndicator
    var muted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let colors = [Color(red: 0.56, green: 0.64, blue: 1), Color(red: 0.32, green: 0.42, blue: 0.96),
                                 Color(red: 0.8, green: 0.84, blue: 1), Color(red: 0.56, green: 0.64, blue: 1)]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || indicator == .inactive || indicator == .ending)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle(time))))
                .overlay {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.8), .clear], center: UnitPoint(x: 0.35, y: 0.3),
                                                 startRadius: 0, endRadius: 10))
                }
                .scaleEffect(reduceMotion ? 0.92 : scale(time))
                .opacity(indicator == .connecting || indicator == .ending ? 0.55 : 1)
                .saturation(muted ? 0.15 : 1)
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("voice.orb")
    }
    private func scale(_ time: Double) -> CGFloat {
        switch indicator {
        case .inactive, .ending: 0.9
        case .connecting: 0.82 + 0.08 * sin(time * 3)
        case .listening: 0.94 + 0.04 * sin(time * 2)
        case .thinking: 0.9
        case .speaking: 0.88 + 0.12 * abs(sin(time * 7))
        }
    }
    private func angle(_ time: Double) -> Double {
        indicator == .thinking ? time.truncatingRemainder(dividingBy: 3) * 120 : 0
    }
    private var accessibilityText: String {
        switch indicator {
        case .inactive: "语音未开始"
        case .connecting: "正在连接"
        case .listening: muted ? "麦克风已静音" : "正在聆听"
        case .thinking: "正在思考"
        case .speaking: "正在播报"
        case .ending: "正在结束"
        }
    }
}
