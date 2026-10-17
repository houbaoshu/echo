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
        // Nor does it set a foreground colour: given a concrete colour, the form derives its
        // row separators and button fills from it and draws them a step darker than System
        // Settings (measured on macOS 27: separators 209 vs 235 on a 247 card).
        // The grouped form's own background is wallpaper-tinted in dark mode and covers
        // anything behind it, so it is hidden for the neutral fill System Settings shows
        // (measured on macOS 27, dark: 30 vs the form's 42,39,38).
        Group {
            // Closing a retained settings window does not unmount its views.
            // Reset revealed credentials and field focus on close/reopen while
            // leaving the store's unsaved form values intact.
            // Keep the if/else chain: written as a switch, a swapped-in pane no longer
            // rejoins the key view loop (NativeAppKitEventTests.testSettingsKeyboardAndFocus).
            if section == .model { ModelSettingsView(settings: settings).id(settings.presentationRevision) }
            else if section == .voice { VoiceSettingsView(settings: settings, voice: voice).id(settings.presentationRevision) }
            else if section == .planet { PlanetSettingsView(planets: planets, settings: settings) }
            else { PetSettingsView(pets: pets, settings: settings) }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A group's footer, in the gap below its box: a running test and the way to stop it, or the
/// group's last report — a test's result, or why it could not be saved. Always one line; a long
/// report is cut short and shows whole on hover. Every group with a test uses this, so a result
/// reads the same wherever it came from.
struct SettingsGroupStatus: View {
    let testing: Bool
    let line: SettingsTestLine?
    /// Prefixes the identifiers of the cancel button and the report.
    let identifier: String
    var cancel: @MainActor () -> Void
    var body: some View {
        // The form already leaves a gap below a group's box; the line is drawn in it rather than
        // added to it, so a report coming or going never moves the groups below.
        Color.clear.frame(height: 0).overlay(alignment: .topLeading) { content.fixedSize(horizontal: false, vertical: true) }
    }
    private var content: some View {
        Group {
            if testing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在测试…").foregroundStyle(WorkspaceStyle.secondary)
                    // No colour around the button: a concrete foreground greys its title and
                    // darkens its fill.
                    Button("取消", action: cancel).controlSize(.small).accessibilityIdentifier("\(identifier).cancelTest")
                }
            } else if let line {
                Label(line.text, systemImage: line.succeeded ? "checkmark.circle" : "info.circle")
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(line.succeeded ? WorkspaceStyle.success : WorkspaceStyle.secondary)
                    .help(line.text).accessibilityIdentifier("\(identifier).status")
            }
        }.font(WorkspaceStyle.caption)
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
    /// Whether the form around the row lets it be edited.
    @Environment(\.isEnabled) private var formEnabled
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
                } label: { Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(iconColor(formEnabled && enabled)) }
                    .buttonStyle(.borderless).help(revealed ? "隐藏 API Key" : "显示 API Key")
                    .accessibilityLabel(revealed ? "隐藏 API Key" : "显示 API Key")
                    .accessibilityIdentifier("\(identifier).reveal")
                Button { key = "" } label: { Image(systemName: "xmark.circle").foregroundStyle(iconColor(formEnabled && enabled && !key.isEmpty)) }
                    .buttonStyle(.borderless).disabled(key.isEmpty).help("清除 API Key，保存后生效")
                    .accessibilityLabel("清除 API Key")
                    .accessibilityIdentifier("\(identifier).clear")
            }.disabled(!enabled)
        }
    }
    /// A borderless icon button keeps its full colour when disabled (measured on macOS 27), so it
    /// takes the disabled text colour itself, the way the field beside it greys out.
    private func iconColor(_ active: Bool) -> Color { active ? .primary : Color(nsColor: .disabledControlTextColor) }
}

struct ModelSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var revealsKey = false
    @State private var revealsArkKey = false
    var body: some View {
        // A control that takes its own label keeps it, so the form — not this view —
        // decides where the label column ends and how a narrow pane stacks the row.
        // `LabeledContent` is only for the one row whose control is a composite.
        // Each group saves, reverts and tests only itself, in its last row; Return saves
        // the group whose field has the caret.
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
                SettingsGroupActions(save: settings.save, canSave: settings.isDirty,
                                     restore: settings.restore, canRestore: settings.canRestoreModel,
                                     identifier: "settings") {
                    Button("测试连接") { settings.testConnection() }
                        .disabled(settings.testing || !settings.canTestModelService)
                        .accessibilityIdentifier("settings.test")
                }
            } header: {
                Text("模型服务")
            } footer: {
                SettingsGroupStatus(testing: settings.testing, line: settings.modelServiceStatus, identifier: "settings",
                                    cancel: settings.cancelModelServiceTest)
            }
            .onSubmit { if settings.isDirty { settings.save() } }
            ArkSettingsSection(settings: settings, revealsKey: $revealsArkKey)
            LocalModelSection(settings: settings)
            MemorySection(settings: settings)
        }
        // A grouped form draws a text field as plain trailing-aligned text, which reads
        // as a value rather than something editable. These are all credentials and
        // endpoints the user types into, so they keep the bordered field the card used.
        .textFieldStyle(.roundedBorder)
        .onDisappear { revealsKey = false; revealsArkKey = false }
        .onChange(of: settings.selectedProvider) { _, _ in revealsKey = false }
    }
}

/// A group's last row, and only buttons: save and revert, for this group alone, on the left;
/// the group's own tests on the right.
struct SettingsGroupActions<Tests: View>: View {
    var save: @MainActor () -> Void
    let canSave: Bool
    var restore: @MainActor () -> Void
    let canRestore: Bool
    /// Prefixes the save and revert buttons' identifiers.
    let identifier: String
    @ViewBuilder let tests: Tests
    var body: some View {
        HStack(spacing: 12) {
            Button("保存", action: save).disabled(!canSave).accessibilityIdentifier("\(identifier).save")
            Button("还原修改", action: restore).disabled(!canRestore).accessibilityIdentifier("\(identifier).restore")
            Spacer(minLength: 0)
            tests
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Volcengine Ark: one key for chat, voice, web_search and image generation, whichever service
/// chats. Its address and protocol are fixed, so the group shows only what the person chooses.
struct ArkSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Binding var revealsKey: Bool
    var body: some View {
        Section {
            SettingsAPIKeyField(key: $settings.arkAPIKey, revealed: $revealsKey, identifier: "settings.ark.apiKey")
            TextField("语言模型", text: $settings.arkDraft.languageModel, prompt: Text(ArkSettings.defaultLanguageModel))
                .accessibilityLabel("语言模型").accessibilityIdentifier("settings.ark.chatModel")
            TextField("视觉模型", text: $settings.arkDraft.visionModel, prompt: Text(ArkSettings.defaultVisionModel))
                .accessibilityLabel("视觉模型").accessibilityIdentifier("settings.ark.imageModel")
            Toggle("用于对话", isOn: $settings.arkDraft.useForChat).toggleStyle(.switch)
                .disabled(!settings.canUseArkForChat)
                .accessibilityIdentifier("settings.ark.useForChat")
            SettingsGroupActions(save: settings.saveArk, canSave: settings.isArkDirty,
                                 restore: settings.restoreArk, canRestore: settings.isArkDirty,
                                 identifier: "settings.ark") {
                Button("测试连接") { settings.testArk() }
                    .disabled(settings.arkTesting || !settings.canTestArk)
                    .accessibilityIdentifier("settings.ark.test")
            }
        } header: {
            Text("火山方舟")
        } footer: {
            SettingsGroupStatus(testing: settings.arkTesting, line: settings.arkStatus, identifier: "settings.ark",
                                cancel: settings.cancelArkTest)
        }
        .onSubmit { if settings.isArkDirty { settings.saveArk() } }
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
                Button("在访达中显示", action: reveal).accessibilityIdentifier("settings.localModel.reveal")
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
        } else if let folder = settings.localModels?.models {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

/// What the person asked the Agent to remember lives in a file they edit in their own editor;
/// settings only opens it.
struct MemorySection: View {
    var settings: SettingsStore
    var body: some View {
        Section {
            Button("打开记忆文件", action: open).disabled(settings.memoryFile == nil)
                .accessibilityIdentifier("settings.memory.open")
            if let notice = settings.memoryNotice {
                Text(notice).font(WorkspaceStyle.caption).foregroundStyle(WorkspaceStyle.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("settings.memory.notice")
            }
        } header: {
            Text("记忆")
        }
    }
    /// In the app that opens Markdown files, or the default text editor when none does.
    private func open() {
        guard let url = settings.memoryFileForEditing() else { return }
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(toOpen: url) ?? workspace.urlForApplication(toOpen: .plainText) else {
            settings.memoryNotice = String(localized: "没有能打开记忆文件的应用。")
            return
        }
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in settings.memoryNotice = String(localized: "无法打开记忆文件：\(error.localizedDescription)") }
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
                                       currentLabel: String(localized: "\(pet.name)，当前精灵"), identifier: "settings.pet.\(pet.id)",
                                       moveToTrash: pet.builtin ? nil : { pets.moveToTrash(pet.id) }) { pets.activate(pet.id) }
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
        // Listed again each time the window opens or the page is switched to, so a pet put back
        // from the Trash shows up; listed pets are not read again.
        .task(id: settings.presentationRevision) { pets.reload() }
    }
}

/// Live Voice's planet picker. Same card grid as the pets, from a different folder: a planet is
/// the voice mark, not a second pet, so it gets its own section rather than a row in 精灵.
struct PlanetSettingsView: View {
    var planets: PlanetStore
    var settings: SettingsStore
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
                                       currentLabel: String(localized: "\(planet.name)，当前星球"), identifier: "settings.planet.\(planet.id)",
                                       moveToTrash: planet.id.hasPrefix("imported:") ? { planets.moveToTrash(planet.id) } : nil) { planets.select(planet.id) }
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
        // Listed each time the window opens or the page is switched to, so a planet put back from
        // the Trash shows up, and never for a page nobody opened; listed planets are not decoded again.
        .task(id: settings.presentationRevision) { planets.loadEntries() }
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
    /// Only an imported card has a menu, and its one item moves the folder to the Trash.
    var moveToTrash: (() -> Void)?
    let action: () -> Void
    var body: some View {
        if let moveToTrash {
            card.contextMenu { Button("移到废纸篓", action: moveToTrash) }
        } else { card }
    }
    private var card: some View {
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

#Preview("设置 · 记忆") {
    // A store beside a settings.json that does not exist, so the button has a file to open.
    let settings = SettingsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("echo-preview-settings/settings.json"))
    Form { MemorySection(settings: settings) }.formStyle(.grouped)
        .frame(width: 520, height: 160)
}
