import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings page's section list, hosted in a real system sidebar column.
///
/// NSSplitViewItem's sidebar owns the column: the material, its inactive-window
/// appearance, the hairline divider to the detail pane and the titlebar region all
/// come from AppKit, the same way the workspace sidebar gets them. Nothing here
/// paints a background or fixes a width, or that material would be covered up.
struct SettingsSidebar: View {
    var settings: SettingsStore
    /// Owned by the window controller, so showing the page can hand the first
    /// responder to this list instead of to the hosting container.
    let sectionFocus: SidebarListFocus
    /// The sidebar is a system source list, so it hands back an optional selection.
    /// Clearing it (⌘-click on the selected row) keeps the current section.
    private var sectionSelection: Binding<SettingsSection?> {
        Binding(get: { settings.selectedSection },
                set: { if let value = $0 { settings.selectedSection = value } })
    }
    /// A system source list owns section selection: it supplies the standard
    /// selection fill, hover, focus ring, arrow-key traversal and selected trait.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: sectionSelection) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Label { Text(section.title) } icon: { icon(section).accessibilityHidden(true) }
                        // Fill the row so the blank space beside the label selects too.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("settings.section.\(section.rawValue)")
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .modifier(SidebarListFocusBinding(focus: sectionFocus))
                .accessibilityLabel("设置分区").accessibilityIdentifier("settings.sections")
        }.padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    @ViewBuilder private func icon(_ section: SettingsSection) -> some View {
        switch section {
        case .model: Image(systemName: "slider.horizontal.3")
        case .voice: Image(systemName: "waveform")
        case .planet: Image("custom.spaceship")
        case .pet: Image("custom.capsule").frame(width: 20, height: 20)
        }
    }
}

/// The settings page's detail pane: the selected section, and nothing else. Live Voice
/// keeps its controls in the chat window and on the pet strip, so settings never
/// carries them. The sidebar is its own column, so this is only the right-hand side.
struct SettingsView: View {
    var settings: SettingsStore
    var voice: VoiceSessionController
    let pets: PetCatalog
    var planets: PlanetStore
    private var section: SettingsSection { settings.selectedSection }
    var body: some View {
        // Each section is its own `Form`, so the card grouping, the label column and
        // its width, the control column, the row separators and the narrow-pane
        // stacking all come from `.formStyle(.grouped)`. The form scrolls itself,
        // which is why there is no ScrollView here. The section's name is the window
        // title, so the pane carries no heading of its own. The pane sets no font: the
        // form's own body font is the same, and a font set here would also replace the
        // form's semibold group headings (measured on macOS 27: they turn regular).
        Group {
            // Closing a retained settings window does not unmount its views.
            // Reset revealed credentials and field focus on close/reopen while
            // leaving the store's unsaved form values intact.
            // Keep the if/else chain: written as a switch, a swapped-in pane no longer
            // rejoins the key view loop (NativeAppKitEventTests.testSettingsKeyboardAndFocus).
            if section == .model { ModelSettingsView(settings: settings).id(settings.presentationRevision) }
            else if section == .voice { VoiceSettingsView(settings: settings, voice: voice) }
            else if section == .planet { PlanetSettingsView(planets: planets) }
            else { PetSettingsView(pets: pets, settings: settings) }
        }.formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .foregroundStyle(WorkspaceStyle.primary)
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

/// The API Key row, the same on the model and voice sections: a secure field that can be
/// revealed, and a button that clears it until the section is saved.
struct SettingsAPIKeyField: View {
    @Binding var key: String
    @Binding var revealed: Bool
    let identifier: String
    /// Only the controls go grey, as the other rows' fields do; the label stays as it is.
    var enabled = true
    /// Revealing swaps the secure field for a plain one — a different view, which
    /// takes the first responder with it when it goes. Hand it back to whichever
    /// field replaced it, so the caret does not vanish mid-edit.
    @FocusState private var focused: Bool
    var body: some View {
        LabeledContent("API Key") {
            HStack(spacing: 8) {
                Group {
                    if revealed { TextField("API Key", text: $key, prompt: Text("输入 API Key")) }
                    else { SecureField("API Key", text: $key, prompt: Text("输入 API Key")) }
                }.labelsHidden().focused($focused)
                    .accessibilityLabel("API Key").accessibilityIdentifier(identifier)
                Button {
                    let editing = focused
                    revealed.toggle()
                    // The replacement exists only after this update; asking any
                    // earlier focuses the field that is on its way out.
                    if editing { DispatchQueue.main.async { focused = true } }
                } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(revealed ? "隐藏 API Key" : "显示 API Key")
                    .accessibilityLabel(revealed ? "隐藏 API Key" : "显示 API Key")
                    .accessibilityIdentifier("\(identifier).reveal")
                Button { key = "" } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).disabled(key.isEmpty).help("清除 API Key，保存后生效")
                    .accessibilityLabel("清除 API Key")
                    .accessibilityIdentifier("\(identifier).clear")
            }.disabled(!enabled)
        }
    }
}

struct ModelSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var revealsKey = false
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
                SettingsAPIKeyField(key: $settings.apiKey, revealed: $revealsKey, identifier: "settings.apiKey",
                                    enabled: settings.selectedProvider.requiresKey)
                TextField("默认模型", text: $settings.draft.model, prompt: Text("输入 Model ID"))
                    .accessibilityLabel("默认模型").accessibilityIdentifier("settings.model")
            } header: {
                Text("模型服务")
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
            LocalModelSection(settings: settings)
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

/// The offline model: which one is imported, bringing in an exported model folder, and where it is.
/// The path is one click away rather than always on screen.
struct LocalModelSection: View {
    var settings: SettingsStore
    @State private var importing = false
    var body: some View {
        Section {
            Toggle("使用本地模型", isOn: Binding(get: { settings.snapshot.localModelOnly }, set: { settings.setLocalModelOnly($0) }))
                .toggleStyle(.switch).accessibilityIdentifier("settings.localModel.only")
            // Only one model can be imported for now, so the menu lists exactly what is
            // there and choosing is a no-op; it is a picker so the row reads like the others.
            let title = settings.localModelName ?? String(localized: "未导入")
            Picker("模型", selection: .constant(title)) {
                Text(title).tag(title)
            }.disabled(settings.localModelName == nil).accessibilityIdentifier("settings.localModel.model")
            if case .invalid(let reason) = settings.localModel {
                Text("模型不完整：\(reason)").font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                    .textSelection(.enabled).accessibilityIdentifier("settings.localModel.problem")
            }
            HStack(spacing: 12) {
                Button("导入模型…") { importing = true }.disabled(settings.importingLocalModel)
                    .accessibilityIdentifier("settings.localModel.import")
                Button("在 Finder 中显示", action: reveal).accessibilityIdentifier("settings.localModel.reveal")
                if settings.importingLocalModel { ProgressView().controlSize(.small) }
            }
            if let notice = settings.localModelNotice {
                Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("settings.localModel.notice")
            }
        } header: {
            Text("本地模型")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.importLocalModel(from: url) }
        }
        .onAppear { settings.refreshLocalModel() }
    }
    private func reveal() {
        if case .ready(let url) = settings.localModel {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = LocalModelLocation.installURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

struct PetSettingsView: View {
    let pets: PetCatalog
    var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                if let notice = pets.notice { Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled) }
                ScrollViewReader { proxy in
                    LazyVGrid(columns: SpriteCard.columns, spacing: 16) {
                        ForEach(pets.entries) { pet in
                            SpriteCard(name: pet.name, preview: pet.preview, selected: pets.selectedID == pet.id,
                                       currentLabel: String(localized: "\(pet.name)，当前精灵"), identifier: "settings.pet.\(pet.id)") { pets.activate(pet.id) }
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
    var planets: PlanetStore
    var body: some View {
        Form {
            Section {
                if let notice = planets.notice {
                    Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary)
                        .textSelection(.enabled).accessibilityIdentifier("settings.planet.notice")
                }
                ScrollViewReader { proxy in
                    LazyVGrid(columns: SpriteCard.columns, spacing: 16) {
                        ForEach(planets.entries) { planet in
                            SpriteCard(name: planet.name, preview: planet.preview, selected: planets.selectedID == planet.id,
                                       currentLabel: String(localized: "\(planet.name)，当前星球"), identifier: "settings.planet.\(planet.id)") { planets.select(planet.id) }
                                .id(planet.id)
                        }
                    }.onChange(of: planets.highlightedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            } header: {
                HStack {
                    Text("我的星球")
                    Spacer()
                    Button("导入星球…", systemImage: "plus") {
                        WorkspaceActions.chooseFolder { planets.importPlanet(from: $0) }
                    }.accessibilityIdentifier("settings.importPlanet")
                }
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
    /// How VoiceOver names the card while it is selected — its name and 当前精灵 or 当前星球 —
    /// as one localized sentence, since the two halves do not join the same way in every language.
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
            .accessibilityLabel(selected ? currentLabel : String(localized: "\(name)，点击切换"))
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

#Preview("设置") {
    let settings = SettingsStore()
    let voice = VoiceSessionController()
    let pets = PetCatalog(
        settings: settings,
        builtinRoot: Bundle.main.resourceURL?.appendingPathComponent("pets")
    )
    let planets = PlanetStore(
        settings: settings,
        root: Bundle.main.resourceURL?.appendingPathComponent("planets"),
        voice: voice
    )
    return SettingsView(settings: settings, voice: voice, pets: pets, planets: planets)
        .frame(width: 720, height: 560)
}
