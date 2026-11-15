import Foundation
import FoundationModels

extension AgentToolRecord {
    /// Whether the call could have changed anything left to check: bash calls from earlier builds,
    /// and every change tool but open_app and open_url, whose change is what the screen shows. A
    /// read cut off before its result left nothing to check for.
    var mayHaveChanged: Bool {
        guard let tool else { return true }
        guard let name = AgentToolName(rawValue: tool) else { return false }
        return name.isChange && name.effect != .opens
    }

    /// `tool` as one of Echo's tools; nil for bash calls from earlier builds and for a name Echo
    /// does not know.
    var toolName: AgentToolName? { tool.flatMap(AgentToolName.init(rawValue:)) }

    /// What a card shows for a call: the path for the read and write tools, nothing for finder_location,
    /// which takes no arguments, and the command for bash calls in chats saved by earlier builds.
    /// Otherwise the arguments as the model wrote them, so a call it got wrong shows what it
    /// actually sent.
    static func display(_ call: Transcript.ToolCall) -> String {
        let text = AgentCallArguments.text(call)
        let object = AgentToolResult.jsonObject(text)
        guard let name = AgentToolName(rawValue: call.toolName) else {
            return call.toolName == AgentToolName.legacyBash ? object?["command"] as? String ?? text : text
        }
        switch name {
        case .listFiles, .readFile, .writeFile, .editFile:
            let path = object?["path"] as? String ?? text
            if let pages = (object?["pages"] as? String)?.trimmingCharacters(in: .whitespaces), !pages.isEmpty { return "\(path) · \(pages)" }
            if let line = object?["start_line"] as? Int, line > 1 { return "\(path):\(line)" }
            return path
        case .finderLocation: return ""
        // What the reminders and calendar cards show of the arguments: the title, or the list.
        case .createReminder, .createEvent: return object?["title"] as? String ?? text
        case .listReminders: return object?["list"] as? String ?? ""
        case .completeReminder, .listEvents: return ""
        case .openApp: return object?["name"] as? String ?? text
        case .openURL: return object?["url"] as? String ?? text
        case .webSearch: return object?["query"] as? String ?? text
        case .webFetch: return object?["url"] as? String ?? text
        case .generateImage: return object?["prompt"] as? String ?? text
        // What the memory card names: the line remembered, the passage's new text, or the passage removed.
        case .remember: return (object?["text"] as? String).map(AgentMemoryEdit.line) ?? text
        case .updateMemory:
            let new = object?["new_text"] as? String ?? ""
            return new.isEmpty ? object?["old_text"] as? String ?? text : new
        }
    }
    static func summary(_ call: Transcript.ToolCall) -> String { summary(tool: call.toolName, display: display(call)) }
    /// What a running call is doing, from what its card shows of it.
    var summary: String { Self.summary(tool: tool ?? AgentToolName.legacyBash, display: command) }
    private static func summary(tool: String, display: String) -> String {
        let shown = String(display.prefix(60))
        guard let name = AgentToolName(rawValue: tool) else { return String(localized: "正在调用工具 · \(tool)") }
        return switch name {
        case .listFiles: String(localized: "正在列出文件 · \(shown)")
        case .readFile: String(localized: "正在读取文件 · \(shown)")
        case .finderLocation: String(localized: "正在查看访达位置")
        case .writeFile: String(localized: "正在写入文件 · \(shown)")
        case .editFile: String(localized: "正在修改文件 · \(shown)")
        case .listReminders: String(localized: "正在查看提醒事项")
        case .createReminder: String(localized: "正在新建提醒 · \(shown)")
        case .completeReminder: String(localized: "正在完成提醒")
        case .listEvents: String(localized: "正在查看日程")
        case .createEvent: String(localized: "正在新建日程 · \(shown)")
        case .openApp: String(localized: "正在打开应用 · \(shown)")
        case .openURL: String(localized: "正在打开网址 · \(shown)")
        case .webSearch: String(localized: "正在搜索 · \(shown)")
        case .webFetch: String(localized: "正在读取网页 · \(shown)")
        case .generateImage: String(localized: "正在生成图片 · \(shown)")
        case .remember: String(localized: "正在记住 · \(shown)")
        case .updateMemory: String(localized: "正在更新记忆 · \(shown)")
        }
    }
    /// A change tool's result that says what it did is finished; any other that ran ended with
    /// nothing changed, so its card says so even folded: a write as not written, a reminder or event
    /// change, or an app or page not opened, as failed. A reminders or calendar call that had no
    /// access failed too, a read as well, and so did a search that could not search and a page
    /// that could not be read. Other tools' failures show as finished.
    static func state(forResult result: String, tool: String?) -> State {
        struct ResultStatus: Decodable { var status: String?; var action: String? }
        let decoded = try? JSONDecoder().decode(ResultStatus.self, from: Data(result.utf8))
        let name = tool.flatMap(AgentToolName.init(rawValue:))
        switch decoded?.status {
        case "not_executed": return .notExecuted
        case "unknown": return .unknown
        case "failed" where name?.isCalendar == true && AgentCalendarResult.missingAccess(result) != nil:
            return .failed
        // A search that found nothing to return failed, whatever kept it from searching, and so
        // did a page that could not be read.
        case "failed" where name?.effect == .readsWeb:
            return .failed
        default:
            guard decoded?.action == nil, let name else { return .finished }
            if name.effect == .writesFile { return .notWritten }
            return name.isChange ? .failed : .finished
        }
    }

    /// The time range a web_search call asked for, when it asked for one the tool knows.
    static func timeRange(_ call: Transcript.ToolCall) -> String? {
        guard AgentToolName(rawValue: call.toolName) == .webSearch, let object = AgentToolResult.jsonObject(AgentCallArguments.text(call)),
              let range = object["time_range"] as? String, AgentWebSearchRequest.TimeRange(rawValue: range) != nil else { return nil }
        return range
    }

    /// Longest passage an edit card keeps of each side.
    static let editPreviewLimit = 500

    /// What an edit_file or update_memory call replaces and with what, cut to `editPreviewLimit`
    /// characters each; for a remember call, nothing and the line it adds.
    static func edit(_ call: Transcript.ToolCall) -> Edit? {
        let name = AgentToolName(rawValue: call.toolName)
        guard name == .editFile || name == .updateMemory || name == .remember,
              let object = AgentToolResult.jsonObject(AgentCallArguments.text(call)) else { return nil }
        func cut(_ text: String) -> String { text.count > editPreviewLimit ? String(text.prefix(editPreviewLimit)) + "…" : text }
        if name == .remember { return (object["text"] as? String).map { Edit(old: "", new: cut("- " + AgentMemoryEdit.line($0))) } }
        guard let old = object["old_text"] as? String, let new = object["new_text"] as? String else { return nil }
        return Edit(old: cut(old), new: cut(new))
    }
}
