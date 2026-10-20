import AppKit
import SwiftUI

/// What the person asked the Agent to remember: whether turns use it, and what it holds, read-only.
/// The file is theirs to edit in their own editor; the page only opens it or moves it to the Trash.
struct MemorySettingsView: View {
    var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                Toggle("使用记忆", isOn: Binding(get: { settings.snapshot.memoryEnabled }, set: { settings.setMemoryEnabled($0) }))
                    .toggleStyle(.switch).accessibilityIdentifier("settings.memory.enabled")
            }
            Section {
                if let contents = settings.memoryContents {
                    if let modified = contents.modified {
                        LabeledContent("上次更新") { Text(modified.formatted(date: .abbreviated, time: .shortened)) }
                            .accessibilityIdentifier("settings.memory.modified")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(contents.lines.enumerated()), id: \.offset) { _, line in
                            switch line {
                            case .item(let text):
                                // A list item's marker is drawn as a bullet hanging beside its text.
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(verbatim: "•").accessibilityHidden(true)
                                    Text(verbatim: text)
                                }
                            case .text(let text): Text(verbatim: text)
                            }
                        }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine).accessibilityIdentifier("settings.memory.contents")
                } else {
                    Text("还没有记忆。在聊天里说“记住……”即可添加。").foregroundStyle(WorkspaceStyle.secondary)
                        .accessibilityIdentifier("settings.memory.empty")
                }
                HStack(spacing: 12) {
                    Button("在编辑器中打开", action: open).disabled(settings.memoryFile == nil)
                        .accessibilityIdentifier("settings.memory.open")
                    Button("清空记忆", action: settings.clearMemory).disabled(settings.memoryContents == nil)
                        .accessibilityIdentifier("settings.memory.clear")
                }
                if let notice = settings.memoryNotice {
                    Text(notice).settingsNotice().accessibilityIdentifier("settings.memory.notice")
                }
            } header: {
                Text("记忆内容")
            }
        }
        // Read again each time the window opens or the page is switched to, so what the person
        // wrote in their editor, or the Agent remembered since, shows up.
        .task(id: settings.presentationRevision) { settings.reloadMemory() }
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

#Preview("设置 · 记忆") {
    // A store beside a settings.json that does not exist, with a memory written for it.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("echo-preview-settings")
    let _ = try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let _ = try? Data("- 喜欢喝美式，不加糖\n- 回答尽量简短（“说重点就行”）\n常用项目是 Echo\n".utf8)
        .write(to: AgentMemoryFile(folder: folder).url)
    let settings = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    MemorySettingsView(settings: settings).formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(width: 520, height: 420)
}
