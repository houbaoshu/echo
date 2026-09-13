import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var pets: PetCatalog
    var workspace: WorkspaceStore? = nil
    var onBack: () -> Void
    var onReturnToVoice: (() -> Void)? = nil
    private var section: String { settings.selectedSection }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: onBack) { Label("返回应用", systemImage: "arrow.left").fontWeight(.medium) }
                        .buttonStyle(.plain).padding(.bottom, 30).accessibilityIdentifier("settings.back")
                    navigation("模型", icon: "slider.horizontal.3")
                    navigation("语音", icon: "waveform")
                    navigation("精灵") { SpiritCapsuleIcon().frame(width: 20, height: 20) }
                    Spacer()
                }.padding(20).frame(width: 200, alignment: .leading)
                    .frame(maxHeight: .infinity).background(Color.primary.opacity(0.035))
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(section).font(WorkspaceStyle.pageTitle)
                        if section == "模型" { ModelSettingsView(settings: settings).id(settings.presentationRevision) }
                        else if section == "语音" { VoiceSettingsView(settings: settings, voice: voice) }
                        else { PetSettingsView(pets: pets) }
                    }.frame(maxWidth: 820, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
                }.background(Color(nsColor: .textBackgroundColor))
            }
            if let owner = voice.snapshot.session.owner, let ws = workspace {
                Divider()
                VoiceAttributionBar(workspace: ws, voice: voice, owner: owner) {
                    if let onReturnToVoice {
                        onReturnToVoice()
                    } else {
                        onBack()
                        ws.revealVoice(owner: owner)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func navigation(_ name: String, icon: String) -> some View {
        navigation(name) { Image(systemName: icon) }
    }
    private func navigation<Icon: View>(_ name: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button { settings.selectedSection = name } label: {
            Label { Text(name) } icon: { icon().accessibilityHidden(true) }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(section == name ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(section == name ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).accessibilityIdentifier("settings.section.\(name)")
    }
}

/// A compact capsule outline that inherits the settings sidebar's foreground style.
struct SpiritCapsuleIcon: View {
    var body: some View {
        CapsuleOutline()
            .stroke(style: StrokeStyle(lineWidth: 0.95, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
    }

    private struct CapsuleOutline: Shape {
        func path(in rect: CGRect) -> Path {
            // A regular cylinder: equal elliptical end caps, parallel sides,
            // and matching cap seams. Project it to the reference's proportions.
            let k: CGFloat = 0.5522847498
            var shell = Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addCurve(to: CGPoint(x: 12, y: -10),
                              control1: CGPoint(x: 0, y: -10 * k),
                              control2: CGPoint(x: 12 - 12 * k, y: -10))
                path.addCurve(to: CGPoint(x: 24, y: 0),
                              control1: CGPoint(x: 12 + 12 * k, y: -10),
                              control2: CGPoint(x: 24, y: -10 * k))
                path.addLine(to: CGPoint(x: 24, y: 28))
                path.addCurve(to: CGPoint(x: 12, y: 38),
                              control1: CGPoint(x: 24, y: 28 + 10 * k),
                              control2: CGPoint(x: 12 + 12 * k, y: 38))
                path.addCurve(to: CGPoint(x: 0, y: 28),
                              control1: CGPoint(x: 12 - 12 * k, y: 38),
                              control2: CGPoint(x: 0, y: 28 + 10 * k))
                path.closeSubpath()
                for y: CGFloat in [0, 28] {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 24, y: y))
                }
            }
            shell = shell.applying(CGAffineTransform(a: 20.0 / 24, b: 13.0 / 24,
                                                     c: -18.0 / 28, d: 21.0 / 28,
                                                     tx: 28, ty: 10))
            // Trace the split independently: both ends meet the side walls
            // inside the casing, leaving the reference's narrow rim at each end.
            shell.move(to: CGPoint(x: 25.43, y: 13))
            shell.addLine(to: CGPoint(x: 31.5, y: 17))
            shell.addLine(to: CGPoint(x: 26, y: 36.5))
            shell.addLine(to: CGPoint(x: 32.57, y: 41))
            let scale = min(rect.width, rect.height) / 50
            let placement = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -29, y: -27)
            return shell.applying(placement)
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var revealsKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                row("协议") {
                    Picker("协议", selection: $settings.draft.apiProtocol) {
                        ForEach(ModelAPIProtocol.allCases, id: \.self) { apiProtocol in
                            Text(apiProtocol.title).tag(apiProtocol)
                        }
                    }.pickerStyle(.menu).labelsHidden()
                        .accessibilityLabel("协议").accessibilityIdentifier("settings.protocol")
                }
                Divider()
                row("Base URL") {
                    TextField("https://api.openai.com/v1", text: $settings.draft.baseURL)
                        .accessibilityLabel("Base URL").accessibilityIdentifier("settings.baseURL")
                }
                Divider()
                row("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if revealsKey { TextField("输入 API Key", text: $settings.apiKey) }
                            else { SecureField("输入 API Key", text: $settings.apiKey) }
                        }.accessibilityLabel("API Key").accessibilityIdentifier("settings.apiKey")
                        Button { revealsKey.toggle() } label: { Image(systemName: revealsKey ? "eye.slash" : "eye") }
                            .buttonStyle(.plain).help(revealsKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityLabel(revealsKey ? "隐藏 API Key" : "显示 API Key")
                        Button { settings.apiKey = "" } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).disabled(settings.apiKey.isEmpty).help("清除 API Key，保存后生效")
                            .accessibilityLabel("清除 API Key")
                    }
                }
                Divider()
                row("默认模型") {
                    TextField("输入 Model ID", text: $settings.draft.model)
                        .accessibilityLabel("默认模型").accessibilityIdentifier("settings.model")
                }
            }.textFieldStyle(.roundedBorder)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor).opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.09)))
            ViewThatFits(in: .horizontal) {
                HStack { saveActions; Spacer(); testAction }
                VStack(alignment: .leading, spacing: 12) { saveActions; testAction }
            }
            if let result = settings.testResult {
                Label(result, systemImage: settings.testSucceeded ? "checkmark.circle" : "info.circle")
                    .font(WorkspaceStyle.caption).foregroundStyle(settings.testSucceeded ? Color.green : .secondary)
                    .textSelection(.enabled).accessibilityIdentifier("settings.testResult")
            }
            if let notice = settings.notice {
                Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
            }
        }
        .onDisappear { revealsKey = false }
    }
    private var saveActions: some View {
        HStack(spacing: 12) {
            Button("保存") { settings.save() }.buttonStyle(.borderedProminent).disabled(!settings.isDirty)
                .accessibilityIdentifier("settings.save")
            Button("还原修改") { settings.restore() }.disabled(!settings.isDirty)
        }
    }
    private var testAction: some View {
        HStack(spacing: 8) {
            if settings.testing { ProgressView().controlSize(.small) }
            Button(settings.testing ? "取消测试" : "测试连接") {
                if settings.testing { settings.cancelTest() } else { settings.testConnection() }
            }.help("验证当前协议的工具调用能力，不执行命令，也不自动保存")
                .accessibilityIdentifier("settings.test")
        }
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                Text(title).font(WorkspaceStyle.body).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                content().frame(width: 270)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(WorkspaceStyle.body)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16)
    }

}

struct PetSettingsView: View {
    @ObservedObject var pets: PetCatalog
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("我的精灵").font(WorkspaceStyle.medium)
                Spacer()
                Button("导入精灵…", systemImage: "plus") {
                    WorkspaceActions.chooseFolder { pets.importPet(from: $0) }
                }.accessibilityIdentifier("settings.importPet")
            }
            if let notice = pets.notice { Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled) }
            ScrollViewReader { proxy in
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                    ForEach(pets.entries) { pet in
                        Button { pets.activate(pet.id) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(decorative: pet.preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                                    .frame(height: 130).frame(maxWidth: .infinity).padding(.top, 8)
                                HStack {
                                    Text(pet.name).font(WorkspaceStyle.medium).lineLimit(1)
                                    Spacer()
                                    if pets.selectedID == pet.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(pets.selectedID == pet.id ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: pets.selectedID == pet.id ? 2 : 1))
                        }.buttonStyle(.plain).id(pet.id)
                            .accessibilityLabel("\(pet.name)，\(pets.selectedID == pet.id ? "当前精灵" : "点击切换")")
                            .accessibilityIdentifier("settings.pet.\(pet.id)")
                    }
                }.onChange(of: pets.highlightedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}
