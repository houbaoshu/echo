import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var pets: PetCatalog
    var workspace: WorkspaceStore? = nil
    /// Owned by the window controller, so showing the page can hand the first
    /// responder to this list instead of to the hosting container.
    let sectionFocus: SidebarListFocus
    var onBack: () -> Void
    var onReturnToVoice: (() -> Void)? = nil
    /// The section order the sidebar and its keyboard traversal both follow.
    static let sections = ["模型", "语音", "精灵"]
    private var section: String { settings.selectedSection }
    /// The sidebar is a system source list, so it hands back an optional selection.
    /// Clearing it (⌘-click on the selected row) keeps the current section.
    private var sectionSelection: Binding<String?> {
        Binding(get: { settings.selectedSection },
                set: { if let value = $0 { settings.selectedSection = value } })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                // The page sits under a full-size transparent titlebar. Neighbouring
                // backgrounds bleed into that top safe area by default while plain
                // content does not, so the rule has to opt in or it starts 32pt down.
                Divider().ignoresSafeArea(.container, edges: .top)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(section).font(WorkspaceStyle.pageTitle)
                        if section == "模型" { ModelSettingsView(settings: settings).id(settings.presentationRevision) }
                        else if section == "语音" { VoiceSettingsView(settings: settings, voice: voice) }
                        else { PetSettingsView(pets: pets, settings: settings) }
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
    /// A system source list owns section selection: it supplies the standard
    /// selection fill, hover, focus ring, arrow-key traversal and selected trait.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) { Label("返回应用", systemImage: "arrow.left").fontWeight(.medium) }
                .buttonStyle(.accessoryBar).controlSize(.large)
                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 14)
                .accessibilityIdentifier("settings.back")
            List(selection: sectionSelection) {
                ForEach(Self.sections, id: \.self) { name in
                    Label { Text(name) } icon: { icon(name).accessibilityHidden(true) }
                        // Fill the row so the blank space beside the label selects too.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("settings.section.\(name)")
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .accessibilityLabel("设置分区").accessibilityIdentifier("settings.sections")
            SidebarListFocusAnchor(focus: sectionFocus).frame(height: 0).accessibilityHidden(true)
        }.padding(.vertical, 6).frame(width: 200, alignment: .leading)
            .frame(maxHeight: .infinity).background(Color.primary.opacity(0.035))
            .background(Color(nsColor: .windowBackgroundColor))
    }
    @ViewBuilder private func icon(_ name: String) -> some View {
        switch name {
        case "模型": Image(systemName: "slider.horizontal.3")
        case "语音": Image(systemName: "waveform")
        default: SpiritCapsuleIcon().frame(width: 20, height: 20)
        }
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

/// One labelled settings row. Every section uses it so labels, control width and
/// row padding match, and so a narrow pane stacks each row the same way.
struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                Text(title).font(WorkspaceStyle.body).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                content.frame(width: 270)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(WorkspaceStyle.body)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16)
    }
}

/// The grouping box the settings rows sit in.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .textFieldStyle(.roundedBorder)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor).opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.09)))
    }
}

struct ModelSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var revealsKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard {
                SettingsRow(title: "Provider") {
                    Picker("Provider", selection: Binding(get: { settings.selectedProvider }, set: { settings.selectProvider($0) })) {
                        ForEach(ModelProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }.pickerStyle(.menu).labelsHidden()
                        .accessibilityLabel("Provider").accessibilityIdentifier("settings.provider")
                }
                Divider()
                SettingsRow(title: "协议") {
                    Picker("协议", selection: $settings.draft.apiProtocol) {
                        ForEach(ModelAPIProtocol.allCases, id: \.self) { apiProtocol in
                            Text(apiProtocol.title).tag(apiProtocol)
                        }
                    }.pickerStyle(.menu).labelsHidden()
                        .accessibilityLabel("协议").accessibilityIdentifier("settings.protocol")
                }
                Divider()
                SettingsRow(title: "Base URL") {
                    TextField("https://api.openai.com/v1", text: $settings.draft.baseURL)
                        .accessibilityLabel("Base URL").accessibilityIdentifier("settings.baseURL")
                }
                Divider()
                SettingsRow(title: "API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if revealsKey { TextField("输入 API Key", text: $settings.apiKey) }
                            else { SecureField("输入 API Key", text: $settings.apiKey) }
                        }.accessibilityLabel("API Key").accessibilityIdentifier("settings.apiKey")
                        Button { revealsKey.toggle() } label: { Image(systemName: revealsKey ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).help(revealsKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityLabel(revealsKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityIdentifier("settings.apiKey.reveal")
                        Button { settings.apiKey = "" } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).disabled(settings.apiKey.isEmpty).help("清除 API Key，保存后生效")
                            .accessibilityLabel("清除 API Key")
                            .accessibilityIdentifier("settings.apiKey.clear")
                    }.disabled(!settings.selectedProvider.requiresKey)
                }
                Divider()
                SettingsRow(title: "默认模型") {
                    TextField("输入 Model ID", text: $settings.draft.model)
                        .accessibilityLabel("默认模型").accessibilityIdentifier("settings.model")
                }
            }
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
                    .accessibilityIdentifier("settings.notice")
            }
        }
        .onDisappear { revealsKey = false }
        .onChange(of: settings.selectedProvider) { _, _ in revealsKey = false }
    }
    private var saveActions: some View {
        HStack(spacing: 12) {
            Button("保存") { settings.save() }.buttonStyle(.borderedProminent).disabled(!settings.isDirty)
                .accessibilityIdentifier("settings.save")
            Button("还原修改") { settings.restore() }.disabled(!settings.canRestoreModel)
                .accessibilityIdentifier("settings.restore")
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
}

struct PetSettingsView: View {
    @ObservedObject var pets: PetCatalog
    @ObservedObject var settings: SettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("使用 \(GlobalHotKey.Shortcut.quickComposer.title) 呼出桌宠输入框",
                       isOn: Binding(get: { settings.snapshot.quickComposerHotKey }, set: { settings.setQuickComposerHotKey($0) }))
                    .toggleStyle(.switch).accessibilityIdentifier("settings.quickComposerHotKey")
                if let notice = settings.hotKeyNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(WorkspaceStyle.caption)
                        .foregroundStyle(.orange).accessibilityIdentifier("settings.quickComposerHotKey.notice")
                }
            }
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
                        let selected = pets.selectedID == pet.id
                        Button { pets.activate(pet.id) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(decorative: pet.preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                                    .frame(height: 130).frame(maxWidth: .infinity).padding(.top, 8)
                                HStack {
                                    Text(pet.name).font(WorkspaceStyle.medium).lineLimit(1)
                                    Spacer()
                                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(PetCardButtonStyle(selected: selected)).id(pet.id)
                            // Keep the system focus ring on the card's own shape.
                            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 16))
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                            .accessibilityLabel("\(pet.name)，\(selected ? "当前精灵" : "点击切换")")
                            .accessibilityIdentifier("settings.pet.\(pet.id)")
                    }
                }.onChange(of: pets.highlightedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

/// The pet card is a selectable tile, so it carries the states a system row does:
/// hover, pressed, selected and disabled.
private struct PetCardButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        Card(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }
    private struct Card<Content: View>: View {
        let selected: Bool
        let pressed: Bool
        @ViewBuilder let content: Content
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            let highlighted = enabled && (pressed || hovered)
            content
                .background(Color.primary.opacity(pressed ? 0.08 : hovered ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(highlighted ? 0.2 : 0.1),
                                  lineWidth: selected ? 2 : 1))
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}
