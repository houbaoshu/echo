import AppKit
import SwiftUI

/// The settings page's section list, hosted in a real system sidebar column.
///
/// NSSplitViewItem's sidebar owns the column: the material, its inactive-window
/// appearance, the hairline divider to the detail pane and the titlebar region all
/// come from AppKit, the same way the workspace sidebar gets them. Nothing here
/// paints a background or fixes a width, or that material would be covered up.
struct SettingsSidebar: View {
    @ObservedObject var settings: SettingsStore
    /// Owned by the window controller, so showing the page can hand the first
    /// responder to this list instead of to the hosting container.
    let sectionFocus: SidebarListFocus
    /// The sidebar is a system source list, so it hands back an optional selection.
    /// Clearing it (⌘-click on the selected row) keeps the current section.
    private var sectionSelection: Binding<String?> {
        Binding(get: { settings.selectedSection },
                set: { if let value = $0 { settings.selectedSection = value } })
    }
    /// A system source list owns section selection: it supplies the standard
    /// selection fill, hover, focus ring, arrow-key traversal and selected trait.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: sectionSelection) {
                ForEach(SettingsView.sections, id: \.self) { name in
                    Label { Text(name) } icon: { icon(name).accessibilityHidden(true) }
                        // Fill the row so the blank space beside the label selects too.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("settings.section.\(name)")
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .modifier(SidebarListFocusBinding(focus: sectionFocus))
                .accessibilityLabel("设置分区").accessibilityIdentifier("settings.sections")
        }.padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.primary)
    }
    @ViewBuilder private func icon(_ name: String) -> some View {
        switch name {
        case "模型": Image(systemName: "slider.horizontal.3")
        case "语音": Image(systemName: "waveform")
        case "星球": Image("custom.spaceship")
        default: Image("custom.capsule").frame(width: 20, height: 20)
        }
    }
}

/// The settings page's detail pane: the selected section, and nothing else. Live Voice
/// keeps its controls in the chat window and on the pet strip, so settings never
/// carries them. The sidebar is its own column, so this is only the right-hand side.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var pets: PetCatalog
    @ObservedObject var planets: PlanetStore
    /// The section order the sidebar and its keyboard traversal both follow.
    static let sections = ["模型", "语音", "星球", "精灵"]
    private var section: String { settings.selectedSection }
    var body: some View {
        VStack(spacing: 0) {
            // Each section is its own `Form`, so the card grouping, the label column and
            // its width, the control column, the row separators and the narrow-pane
            // stacking all come from `.formStyle(.grouped)`. The form scrolls itself,
            // which is why there is no ScrollView here any more; the page title sits
            // above it and stays put, the way a System Settings pane's title does.
            VStack(alignment: .leading, spacing: 0) {
                Text(section).font(WorkspaceStyle.pageTitle)
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 4)
                Group {
                    // Closing a retained settings window does not unmount its views.
                    // Reset revealed credentials and field focus on close/reopen while
                    // leaving the store's unsaved form values intact.
                    if section == "模型" { ModelSettingsView(settings: settings).id(settings.presentationRevision) }
                    else if section == "语音" { VoiceSettingsView(settings: settings, voice: voice) }
                    else if section == "星球" { PlanetSettingsView(planets: planets) }
                    else { PetSettingsView(pets: pets, settings: settings) }
                }.formStyle(.grouped)
            }.frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .font(WorkspaceStyle.body).foregroundStyle(WorkspaceStyle.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// While a section's connection test runs: what is happening, and the one way to
/// stop it. Both sections show this instead of each inventing its own cancel.
struct SettingsTestProgress: View {
    let identifier: String
    var cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在测试…").font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
            Button("取消", action: cancel).accessibilityIdentifier(identifier)
        }
    }
}

/// A finished connection test, shown in the same place with the same mark and colours on both
/// sections, so a result reads the same wherever it came from.
struct SettingsTestResult: View {
    let text: String
    let succeeded: Bool
    let identifier: String
    var body: some View {
        Label(text, systemImage: succeeded ? "checkmark.circle" : "info.circle")
            .font(WorkspaceStyle.caption).foregroundStyle(succeeded ? WorkspaceStyle.success : WorkspaceStyle.secondary)
            .textSelection(.enabled).accessibilityIdentifier(identifier)
    }
}

struct ModelSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var revealsKey = false
    /// Revealing swaps the secure field for a plain one — a different view, which
    /// takes the first responder with it when it goes. Hand it back to whichever
    /// field replaced it, so the caret does not vanish mid-edit.
    @FocusState private var keyFieldFocused: Bool
    var body: some View {
        // A control that takes its own label keeps it, so the form — not this view —
        // decides where the label column ends and how a narrow pane stacks the row.
        // `LabeledContent` is only for the one row whose control is a composite.
        Form {
            Section {
                Picker("Provider", selection: Binding(get: { settings.selectedProvider }, set: { settings.selectProvider($0) })) {
                    ForEach(ModelProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }.accessibilityLabel("Provider").accessibilityIdentifier("settings.provider")
                Picker("协议", selection: $settings.draft.apiProtocol) {
                    ForEach(ModelAPIProtocol.allCases, id: \.self) { apiProtocol in
                        Text(apiProtocol.title).tag(apiProtocol)
                    }
                }.accessibilityLabel("协议").accessibilityIdentifier("settings.protocol")
                TextField("Base URL", text: $settings.draft.baseURL, prompt: Text("https://api.openai.com/v1"))
                    .accessibilityLabel("Base URL").accessibilityIdentifier("settings.baseURL")
                LabeledContent("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if revealsKey { TextField("API Key", text: $settings.apiKey, prompt: Text("输入 API Key")) }
                            else { SecureField("API Key", text: $settings.apiKey, prompt: Text("输入 API Key")) }
                        }.labelsHidden().focused($keyFieldFocused)
                            .accessibilityLabel("API Key").accessibilityIdentifier("settings.apiKey")
                        Button {
                            let editing = keyFieldFocused
                            revealsKey.toggle()
                            // The replacement exists only after this update; asking any
                            // earlier focuses the field that is on its way out.
                            if editing { DispatchQueue.main.async { keyFieldFocused = true } }
                        } label: { Image(systemName: revealsKey ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).help(revealsKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityLabel(revealsKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityIdentifier("settings.apiKey.reveal")
                        Button { settings.apiKey = "" } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).disabled(settings.apiKey.isEmpty).help("清除 API Key，保存后生效")
                            .accessibilityLabel("清除 API Key")
                            .accessibilityIdentifier("settings.apiKey.clear")
                    }.disabled(!settings.selectedProvider.requiresKey)
                }
                TextField("默认模型", text: $settings.draft.model, prompt: Text("输入 Model ID"))
                    .accessibilityLabel("默认模型").accessibilityIdentifier("settings.model")
            }
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack { saveActions; Spacer(); testAction }
                    VStack(alignment: .leading, spacing: 12) { saveActions; testAction }
                }
                if settings.testing {
                    SettingsTestProgress(identifier: "settings.cancelTest") { settings.cancelTest() }
                }
                if let result = settings.testResult {
                    SettingsTestResult(text: result, succeeded: settings.testSucceeded, identifier: "settings.testResult")
                }
                if let notice = settings.notice {
                    Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("settings.notice")
                }
            }
        }
        // A grouped form draws a text field as plain trailing-aligned text, which reads
        // as a value rather than something editable. These are all credentials and
        // endpoints the user types into, so they keep the bordered field the card used.
        .textFieldStyle(.roundedBorder)
        .onDisappear { revealsKey = false }
        .onChange(of: settings.selectedProvider) { _, _ in revealsKey = false }
    }
    private var saveActions: some View {
        HStack(spacing: 12) {
            Button("保存") { settings.save() }.buttonStyle(.borderedProminent).disabled(!settings.isDirty)
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("settings.save")
            Button("还原修改") { settings.restore() }.disabled(!settings.canRestoreModel)
                .accessibilityIdentifier("settings.restore")
        }
    }
    private var testAction: some View {
        Button("测试连接") { settings.testConnection() }
            .disabled(settings.testing)
            .help("验证当前协议的工具调用能力，不执行命令，也不自动保存")
            .accessibilityIdentifier("settings.test")
    }
}

struct PetSettingsView: View {
    @ObservedObject var pets: PetCatalog
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            // The switch keeps its own label, so the form aligns it with every other
            // section's control column instead of this view padding it into place.
            Section {
                Toggle("使用 \(GlobalHotKey.Shortcut.quickComposer.title) 呼出桌宠输入框",
                       isOn: Binding(get: { settings.snapshot.quickComposerHotKey }, set: { settings.setQuickComposerHotKey($0) }))
                    .toggleStyle(.switch)
                    .accessibilityLabel("使用 \(GlobalHotKey.Shortcut.quickComposer.title) 呼出桌宠输入框")
                    .accessibilityIdentifier("settings.quickComposerHotKey")
            } footer: {
                if let notice = settings.hotKeyNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(WorkspaceStyle.caption)
                        .foregroundStyle(WorkspaceStyle.warning).accessibilityIdentifier("settings.quickComposerHotKey.notice")
                }
            }
            Section {
                if let notice = pets.notice { Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled) }
                ScrollViewReader { proxy in
                    LazyVGrid(columns: SpriteCard.columns, spacing: 16) {
                        ForEach(pets.entries) { pet in
                            SpriteCard(name: pet.name, preview: pet.preview, selected: pets.selectedID == pet.id,
                                       currentLabel: "当前精灵", identifier: "settings.pet.\(pet.id)") { pets.activate(pet.id) }
                                .id(pet.id)
                        }
                    }.onChange(of: pets.highlightedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            } header: {
                HStack {
                    Text("我的精灵")
                    Spacer()
                    Button("导入精灵…", systemImage: "plus") {
                        WorkspaceActions.chooseFolder { pets.importPet(from: $0) }
                    }.accessibilityIdentifier("settings.importPet")
                }
            }
        }
    }
}

/// Live Voice's planet picker. Same card grid as the pets, from a different folder: a planet is
/// the voice mark, not a second pet, so it gets its own section rather than a row in 精灵.
struct PlanetSettingsView: View {
    @ObservedObject var planets: PlanetStore
    var body: some View {
        Form {
            Section {
                if let notice = planets.notice {
                    Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                        .textSelection(.enabled).accessibilityIdentifier("settings.planet.notice")
                }
                LazyVGrid(columns: SpriteCard.columns, spacing: 16) {
                    ForEach(planets.entries) { planet in
                        SpriteCard(name: planet.name, preview: planet.preview, selected: planets.selectedID == planet.id,
                                   currentLabel: "当前星球", identifier: "settings.planet.\(planet.id)") { planets.select(planet.id) }
                            .id(planet.id)
                    }
                }
            } header: {
                Text("我的星球")
            }
        }
        // The settings window is retained rather than unmounted, so this runs once and the
        // sprite sheets are never decoded for a page nobody opened.
        .task { planets.loadEntries() }
    }
}

/// One pet or planet in its settings grid. Both grids draw this one card, so they cannot drift.
struct SpriteCard: View {
    static let columns = [GridItem(.adaptive(minimum: 170), spacing: 16)]
    let name: String
    let preview: CGImage
    let selected: Bool
    /// How VoiceOver names the selected card: 当前精灵 or 当前星球.
    let currentLabel: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(decorative: preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .frame(height: 130).frame(maxWidth: .infinity).padding(.top, 8)
                HStack {
                    Text(name).font(WorkspaceStyle.medium).lineLimit(1)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(PetCardButtonStyle(selected: selected))
            // Keep the system focus ring on the card's own shape.
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 16))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityLabel("\(name)，\(selected ? currentLabel : "点击切换")")
            .accessibilityIdentifier(identifier)
    }
}

/// The pet card is a selectable tile, so it carries the states a system row does:
/// hover, pressed, selected and disabled.
struct PetCardButtonStyle: ButtonStyle {
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
