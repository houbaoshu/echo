import Foundation
import FoundationModels

extension AgentToolRecord {
    /// Whether the call could have changed anything left to check: bash calls from earlier builds,
    /// and every change tool but open_app and open_url, whose change is what the screen shows. A
    /// read cut off before its result left nothing to check for.
    var mayHaveChanged: Bool {
        switch tool {
        case nil: true
        case let name?: AgentHarness.changeTools.contains(name) && !AgentHarness.openTools.contains(name)
        }
    }

    /// What a card shows for a call: the path for the read and write tools, nothing for finder_location,
    /// which takes no arguments, and the command for bash calls in chats saved by earlier builds.
    /// Otherwise the arguments as the model wrote them, so a call it got wrong shows what it
    /// actually sent.
    static func display(_ call: Transcript.ToolCall) -> String {
        let text = AgentCallArguments.text(call)
        let object = AgentToolResult.jsonObject(text)
        switch call.toolName {
        case "bash": return object?["command"] as? String ?? text
        case "list_files", "read_file", "write_file", "edit_file":
            let path = object?["path"] as? String ?? text
            if let pages = (object?["pages"] as? String)?.trimmingCharacters(in: .whitespaces), !pages.isEmpty { return "\(path) · \(pages)" }
            if let line = object?["start_line"] as? Int, line > 1 { return "\(path):\(line)" }
            return path
        case "finder_location": return ""
        // What the reminders and calendar cards show of the arguments: the title, or the list.
        case "create_reminder", "create_event": return object?["title"] as? String ?? text
        case "list_reminders": return object?["list"] as? String ?? ""
        case "complete_reminder", "list_events": return ""
        case "open_app": return object?["name"] as? String ?? text
        case "open_url": return object?["url"] as? String ?? text
        case "web_search": return object?["query"] as? String ?? text
        case "web_fetch": return object?["url"] as? String ?? text
        case "generate_image": return object?["prompt"] as? String ?? text
        // What the memory card names: the line remembered, the passage's new text, or the passage removed.
        case "remember": return (object?["text"] as? String).map(AgentMemoryEdit.line) ?? text
        case "update_memory":
            let new = object?["new_text"] as? String ?? ""
            return new.isEmpty ? object?["old_text"] as? String ?? text : new
        default: return text
        }
    }
    static func summary(_ call: Transcript.ToolCall) -> String { summary(tool: call.toolName, display: display(call)) }
    /// What a running call is doing, from what its card shows of it.
    var summary: String { Self.summary(tool: tool ?? "bash", display: command) }
    private static func summary(tool: String, display: String) -> String {
        let shown = String(display.prefix(60))
        return switch tool {
        case "list_files": String(localized: "正在列出文件 · \(shown)")
        case "read_file": String(localized: "正在读取文件 · \(shown)")
        case "finder_location": String(localized: "正在查看访达位置")
        case "write_file": String(localized: "正在写入文件 · \(shown)")
        case "edit_file": String(localized: "正在修改文件 · \(shown)")
        case "list_reminders": String(localized: "正在查看提醒事项")
        case "create_reminder": String(localized: "正在新建提醒 · \(shown)")
        case "complete_reminder": String(localized: "正在完成提醒")
        case "list_events": String(localized: "正在查看日程")
        case "create_event": String(localized: "正在新建日程 · \(shown)")
        case "open_app": String(localized: "正在打开应用 · \(shown)")
        case "open_url": String(localized: "正在打开网址 · \(shown)")
        case "web_search": String(localized: "正在搜索 · \(shown)")
        case "web_fetch": String(localized: "正在读取网页 · \(shown)")
        case "generate_image": String(localized: "正在生成图片 · \(shown)")
        case "remember": String(localized: "正在记住 · \(shown)")
        case "update_memory": String(localized: "正在更新记忆 · \(shown)")
        default: String(localized: "正在调用工具 · \(tool)")
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
        switch decoded?.status {
        case "not_executed": return .notExecuted
        case "unknown": return .unknown
        case "failed" where AgentHarness.calendarTools.contains(tool ?? "") && AgentCalendarResult.missingAccess(result) != nil:
            return .failed
        // A search that found nothing to return failed, whatever kept it from searching, and so
        // did a page that could not be read.
        case "failed" where tool == "web_search" || tool == "web_fetch":
            return .failed
        default:
            guard decoded?.action == nil, let tool else { return .finished }
            if AgentHarness.writeTools.contains(tool) { return .notWritten }
            return AgentHarness.changeTools.contains(tool) ? .failed : .finished
        }
    }

    /// The time range a web_search call asked for, when it asked for one the tool knows.
    static func timeRange(_ call: Transcript.ToolCall) -> String? {
        guard call.toolName == "web_search", let object = AgentToolResult.jsonObject(AgentCallArguments.text(call)),
              let range = object["time_range"] as? String, AgentWebSearchRequest.TimeRange(rawValue: range) != nil else { return nil }
        return range
    }

    /// Longest passage an edit card keeps of each side.
    static let editPreviewLimit = 500

    /// What an edit_file or update_memory call replaces and with what, cut to `editPreviewLimit`
    /// characters each; for a remember call, nothing and the line it adds.
    static func edit(_ call: Transcript.ToolCall) -> Edit? {
        guard ["edit_file", "update_memory", "remember"].contains(call.toolName),
              let object = AgentToolResult.jsonObject(AgentCallArguments.text(call)) else { return nil }
        func cut(_ text: String) -> String { text.count > editPreviewLimit ? String(text.prefix(editPreviewLimit)) + "…" : text }
        if call.toolName == "remember" { return (object["text"] as? String).map { Edit(old: "", new: cut("- " + AgentMemoryEdit.line($0))) } }
        guard let old = object["old_text"] as? String, let new = object["new_text"] as? String else { return nil }
        return Edit(old: cut(old), new: cut(new))
    }
}
