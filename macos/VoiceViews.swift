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
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Text("音色 ID").font(.headline).fixedSize().padding(.trailing, 16)
                TextField("输入音色 ID", text: $settings.voiceDraft.speaker)
                    .accessibilityLabel("音色 ID")
                    .accessibilityIdentifier("voiceSettings.speaker")
            }
            HStack {
                Button("保存") { settings.saveVoice() }.buttonStyle(.borderedProminent)
                    .disabled(!settings.isVoiceDirty).accessibilityIdentifier("voiceSettings.save")
                Button("还原修改") { settings.restoreVoice() }.disabled(!settings.isVoiceDirty)
            }
            if let notice = settings.voiceNotice { Text(notice).font(.callout).textSelection(.enabled) }
            Divider()
            HStack {
                Button("检查连接") { test(preview: false) }
                    .accessibilityIdentifier("voiceSettings.test")
                Button("试听音色") { test(preview: true) }
                    .accessibilityIdentifier("voiceSettings.preview")
            }.disabled(voice.testing || voice.isActive || voice.isDictating || !settings.canTestVoice)
            if voice.testing {
                HStack { ProgressView().controlSize(.small); Text("正在测试…"); Button("取消") { voice.cancelTest() } }
            }
            if let result = voice.testResult { Text(result).font(.callout).textSelection(.enabled) }
            DisclosureGroup("诊断日志") {
                HStack {
                    Spacer()
                    Button("复制日志") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.text, forType: .string)
                    }.disabled(diagnostics.lines.isEmpty)
                }
                ScrollView {
                    Text(diagnostics.text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 220)
            }
        }.textFieldStyle(.roundedBorder)
            .onChange(of: settings.voiceAPIKey) { _, _ in voice.invalidateTest() }
            .onChange(of: settings.voiceDraft) { _, _ in voice.invalidateTest() }
            .onDisappear { voice.cancelTest() }
    }
    private func test(preview: Bool) {
        guard let key = try? settings.voiceTestKey() else { return }
        voice.test(configuration: settings.voiceDraft, key: key, preview: preview)
    }
}
