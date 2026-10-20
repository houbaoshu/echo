import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                Picker("提供商", selection: Binding(get: { settings.selectedProvider }, set: { settings.selectProvider($0) })) {
                    ForEach(ModelProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }.accessibilityLabel("提供商").accessibilityIdentifier("settings.provider")
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

/// Volcengine Ark: one key for voice and image generation whichever service chats, and for chat and
/// web_search while it chats. Its address and protocol are fixed, so the group shows only what the
/// person chooses.
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
            Toggle("用于聊天", isOn: $settings.arkDraft.useForChat).toggleStyle(.switch)
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
                Text("模型不完整：\(reason)").settingsNotice().accessibilityIdentifier("settings.localModel.problem")
            }
            HStack(spacing: 12) {
                Button("导入模型…") { importing = true }.disabled(settings.importingLocalModel)
                    .accessibilityIdentifier("settings.localModel.import")
                Button("在访达中显示", action: reveal).accessibilityIdentifier("settings.localModel.reveal")
                if settings.importingLocalModel { ProgressView().controlSize(.small) }
            }
            if let notice = settings.localModelNotice {
                Text(notice).settingsNotice().accessibilityIdentifier("settings.localModel.notice")
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
