import SwiftUI

/// A card that says what its tool did in words of its own, rather than showing the call's result.
protocol AgentToolCard {
    var tool: AgentToolRecord { get }
    var title: String { get }
    var icon: String { get }
    /// The lines an opened card shows; nil leaves the card to show the result as other tools do.
    var lines: [String]? { get }
    /// The pages a search or page-reading card lists.
    var links: [AgentSearchCard.Link] { get }
}

extension AgentToolCard {
    var links: [AgentSearchCard.Link] { [] }
    var result: [String: Any]? { tool.resultObject }
    /// `action`, after how the call ended when it did not finish.
    func titled(_ action: String) -> String { (tool.state == .finished ? "" : tool.state.label + " · ") + action }
}

struct AgentToolView: View {
    let tool: AgentToolRecord
    /// Undo on a write card: shown when set, clickable when `canUndo`.
    let undo: (() -> Void)?
    let canUndo: Bool
    @State private var isExpanded: Bool
    @Environment(\.locale) private var locale
    init(tool: AgentToolRecord, expanded: Bool = false, undo: (() -> Void)? = nil, canUndo: Bool = false) {
        self.tool = tool
        self.undo = undo
        self.canUndo = canUndo
        _isExpanded = State(initialValue: expanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                disclosure
                if let undo {
                    Button("撤销", action: undo).controlSize(.small).disabled(!canUndo)
                        .accessibilityIdentifier("tool.undo")
                }
            }
            if case .refused(let reason) = tool.undo {
                Text(reason.message).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private var disclosure: some View {
        let card = ownCard
        return DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.command.isEmpty, card == nil {
                    Text(tool.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if let directory = tool.directory { Text(directory).font(.caption).foregroundStyle(.secondary) }
                if let edit = tool.edit, tool.tool == "remember" {
                    // A remember call has nothing before: the line it adds is all there is to show.
                    Text("新增").font(.caption).foregroundStyle(.secondary)
                    Text(edit.new).font(.system(.caption, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                } else if let edit = tool.edit {
                    Text("改前").font(.caption).foregroundStyle(.secondary)
                    Text(edit.old).font(.system(.caption, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                    Text("改后").font(.caption).foregroundStyle(.secondary)
                    Text(edit.new.isEmpty ? String(localized: "（删除）") : edit.new)
                        .font(.system(.caption, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                }
                // An unknown result is the model's note to itself; the person gets the card's own.
                if let card, let lines = card.lines, tool.state != .unknown {
                    if !lines.isEmpty { Text(lines.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                    ForEach(card.links) { link in
                        if let url = link.url {
                            Button {
                                Task { try? await WorkspaceOpener.shared.openInBrowser(url) }
                            } label: {
                                searchEntry(link, color: .link)
                            }.buttonStyle(.plain).help(url.absoluteString)
                        } else {
                            // A page without an address, such as a weather card: listed, not a link.
                            searchEntry(link, color: .primary)
                        }
                    }
                } else if let result = tool.result, tool.state != .unknown {
                    if let json = tool.resultObject {
                        // A failed card's title already says it failed.
                        if tool.state != .failed { Text(resultSummary(json)).font(.caption).foregroundStyle(.secondary) }
                        if let stdout = json["stdout"] as? String, !stdout.isEmpty {
                            Text(stdout).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let stderr = json["stderr"] as? String, !stderr.isEmpty {
                            Text(stderr).font(.system(.caption, design: .monospaced)).foregroundStyle(WorkspaceStyle.warning).textSelection(.enabled)
                        }
                        if let files = json["files"] as? [String] {
                            Text(files.isEmpty ? String(localized: "（空文件夹）") : files.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let content = json["content"] as? String, !content.isEmpty {
                            Text(content).font(.system(.caption, design: .monospaced)).lineLimit(40).textSelection(.enabled)
                        }
                        if let detail = json["detail"] as? String ?? json["message"] as? String {
                            Text(detail).font(.caption).textSelection(.enabled)
                        }
                    } else { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                } else if tool.state == .unknown, tool.mayHaveChanged {
                    Text("中断前可能已产生修改；继续处理时需先检查现场。").font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            Group {
                if let finderTitle { Label(finderTitle, systemImage: icon) }
                else if let card { Label(card.title, systemImage: card.icon) }
                else { Label("\(tool.stateLabel) · \(action)\(tool.command.prefix(90))", systemImage: icon) }
            }.font(.caption).lineLimit(AgentImageCard.applies(to: tool) ? 1 : 2)
        }
    }
    /// Reminders and calendar cards, the cards of the tools that open an app or a page, search
    /// and page-reading cards, memory cards and image cards say what was done in words of their own.
    /// A search card also lists the pages it found, and a page-reading card the page it read.
    private var ownCard: (any AgentToolCard)? {
        if AgentCalendarCard.applies(to: tool) { return AgentCalendarCard(tool: tool, locale: locale) }
        if AgentOpenCard.applies(to: tool) { return AgentOpenCard(tool: tool) }
        if AgentSearchCard.applies(to: tool) { return AgentSearchCard(tool: tool) }
        if AgentFetchCard.applies(to: tool) { return AgentFetchCard(tool: tool) }
        if AgentMemoryCard.applies(to: tool) { return AgentMemoryCard(tool: tool) }
        if AgentImageCard.applies(to: tool) { return AgentImageCard(tool: tool) }
        return nil
    }
    /// One page of a search card: its title, and its site beneath.
    private func searchEntry(_ link: AgentSearchCard.Link, color: some ShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(link.title).font(.caption).foregroundStyle(color).multilineTextAlignment(.leading)
            if !link.site.isEmpty { Text(link.site).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    /// finder_location has no arguments to show. The folder's name is in the result; a call that
    /// found none ends at what it looked at.
    private var finderTitle: String? {
        guard tool.tool == "finder_location" else { return nil }
        let folder = tool.resultObject?["folder"] as? String
        return ([tool.state.label, String(localized: "访达位置")] + (folder.map { [$0] } ?? [])).joined(separator: " · ")
    }
    /// Bash cards show the command alone, as they always have; other tools say what they did.
    private var action: String {
        switch tool.tool {
        case nil: ""
        case "list_files": String(localized: "列出") + " "
        case "read_file": String(localized: "读取") + " "
        case "write_file": String(localized: "写入") + " "
        case "edit_file": String(localized: "修改") + " "
        case let name?: "\(name) "
        }
    }
    private var icon: String {
        switch tool.tool {
        case nil: "terminal"
        case "list_files": "folder"
        // A PDF's pages or an image, by what the call read.
        case "read_file": switch tool.resultObject?["kind"] as? String {
            case "pdf": "doc.richtext"
            case "image": "photo"
            default: "doc.text"
            }
        case "finder_location": "macwindow"
        case "write_file": "square.and.pencil"
        case "edit_file": "pencil.line"
        default: "wrench.and.screwdriver"
        }
    }
    private func resultSummary(_ json: [String: Any]) -> String {
        var parts = [tool.stateLabel]
        switch json["action"] as? String {
        case "created": parts.append(String(localized: "新建"))
        case "overwritten": parts.append(String(localized: "覆盖"))
        case "edited": parts.append(String(localized: "已修改"))
        default: break
        }
        if json["action"] != nil, let bytes = json["bytes"] as? Int {
            parts.append(Int64(bytes).formatted(.byteCount(style: .file)))
        }
        if json["truncated"] as? Bool == true { parts.append(String(localized: "已截断")) }
        switch json["kind"] as? String {
        case "pdf":
            if let pages = json["pages"] as? String, let count = json["page_count"] as? Int {
                parts.append(String(localized: "第 \(pages) 页，共 \(count) 页"))
            }
        case "image":
            if let width = json["width"] as? Int, let height = json["height"] as? Int {
                parts.append(String(localized: "图片 · \(String(width))×\(String(height))"))
            }
        default: break
        }
        if let code = json["exit_code"] as? Int { parts.append(String(localized: "退出码 \(code)")) }
        if json["timed_out"] as? Bool == true { parts.append(String(localized: "超时")) }
        if json["stdout_truncated"] as? Bool == true { parts.append(String(localized: "stdout 已截断")) }
        if json["stderr_truncated"] as? Bool == true { parts.append(String(localized: "stderr 已截断")) }
        return parts.joined(separator: " · ")
    }
}

#Preview("工具卡片 · 写入") {
    let edit = AgentToolRecord.Edit(old: "- 周三下午三点开会", new: "- 周四上午十点开会\n- 会前把议程发给大家")
    let records: [AgentToolRecord] = [
        .init(callID: "1", entryID: 1, turnID: 1, command: "drafts/plan.md",
              result: #"{"action":"created","bytes":412,"path":"drafts/plan.md"}"#, state: .finished, tool: "write_file"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"overwritten","bytes":2048,"folder":"资料","path":"notes.txt"}"#, state: .finished,
              directory: "/Users/someone/Documents/资料", tool: "write_file"),
        .init(callID: "3", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"edited","bytes":2051,"path":"notes.txt"}"#, state: .finished, tool: "edit_file", edit: edit),
        .init(callID: "4", entryID: 1, turnID: 1, command: ".zshrc",
              result: AgentToolResult.failed("hidden files and folders are not written: .zshrc"), state: .notWritten, tool: "write_file"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "notes.txt",
              result: AgentToolResult.failed("old_text was not found in notes.txt, so nothing was changed; it must match the file exactly, including spaces and line breaks"),
              state: .notWritten, tool: "edit_file", edit: edit),
        .init(callID: "6", entryID: 1, turnID: 1, command: "notes.txt",
              result: AgentToolResult.unknownAfterInterruption, state: .unknown, tool: "edit_file", edit: edit),
        .init(callID: "7", entryID: 1, turnID: 1, command: "missing.txt",
              result: AgentToolResult.failed("no such file or directory: missing.txt"), state: .finished, tool: "read_file"),
    ]
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(records) { AgentToolView(tool: $0, expanded: true) }
        }.padding()
    }.frame(width: 520, height: 1120)
}

#Preview("工具卡片 · 撤销") {
    let edit = AgentToolRecord.Edit(old: "- 周三下午三点开会", new: "- 周四上午十点开会")
    let records: [AgentToolRecord] = [
        .init(callID: "1", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"edited","bytes":2051,"path":"notes.txt"}"#, state: .finished, tool: "edit_file", edit: edit, undo: .available),
        .init(callID: "2", entryID: 1, turnID: 1, command: "drafts/plan.md",
              result: AgentToolResult.undone(#"{"action":"created","bytes":412,"path":"drafts/plan.md"}"#), state: .finished,
              tool: "write_file", undo: .undone),
        .init(callID: "3", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"overwritten","bytes":2048,"path":"notes.txt"}"#, state: .finished, tool: "write_file",
              undo: .refused(.changed)),
    ]
    VStack(alignment: .leading, spacing: 8) {
        ForEach(records) { record in
            AgentToolView(tool: record, undo: record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}

/// Reminders and events as the tools return them, around now, so the cards read "明天" and "周三".
@MainActor private enum CalendarPreview {
    static let clock = AgentClock.system
    static func at(days: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = clock.calendar
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
    static func due(days: Int, hour: Int) -> DateComponents {
        var parts = clock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at(days: days, hour: hour))
        parts.timeZone = clock.timeZone
        return parts
    }
    static func reminder(_ title: String, days: Int?, hour: Int = 10, list: String = "工作") -> AgentReminder {
        AgentReminder(id: UUID().uuidString, title: title, due: days.map { due(days: $0, hour: hour) }, listID: list, listTitle: list,
                      isCompleted: false, modified: nil)
    }
    static func event(_ title: String, days: Int, hour: Int, hours: Int = 1, location: String? = nil, allDay: Bool = false) -> AgentCalendarEvent {
        let start = allDay ? at(days: days, hour: 0) : at(days: days, hour: hour)
        return AgentCalendarEvent(id: UUID().uuidString, title: title, start: start,
                                  end: allDay ? start.addingTimeInterval(86_399) : start.addingTimeInterval(TimeInterval(hours) * 3600),
                                  isAllDay: allDay, location: location, calendarTitle: "日历", modified: nil)
    }
    static func object(_ value: [String: Any]) -> String { AgentToolResult.object(value) }
    static var created: String { object(["action": "created", "reminder": AgentCalendarResult.reminder(reminder("交报告", days: 1), clock: clock)]) }
    static var completed: String { object(["action": "completed", "reminder": AgentCalendarResult.reminder(reminder("买牛奶", days: nil, list: "提醒"), clock: clock)]) }
    static var meeting: String {
        object(["action": "created", "event": AgentCalendarResult.event(event("组会", days: 2, hour: 14, location: "三楼会议室"), clock: clock, id: true)])
    }
    static var reminders: String {
        object(["reminders": [reminder("交报告", days: 1), reminder("续签合同", days: 9, hour: 9), reminder("买牛奶", days: nil, list: "提醒")]
            .map { AgentCalendarResult.reminder($0, clock: clock) }, "truncated": false])
    }
    static var events: String {
        let from = at(days: 0, hour: 0), to = at(days: 7, hour: 0)
        return object(["from": AgentTimeText.stamp(from, in: clock), "to": AgentTimeText.stamp(to, in: clock), "truncated": false,
                       "events": [event("组会", days: 2, hour: 14, location: "三楼会议室"), event("秋游", days: 5, hour: 0, allDay: true),
                                  event("牙医", days: 6, hour: 9, hours: 1)].map { AgentCalendarResult.event($0, clock: clock) }])
    }
    static var cards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "", result: reminders, state: .finished, tool: "list_reminders"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "交报告", result: created, state: .finished, tool: "create_reminder", undo: .available),
        .init(callID: "3", entryID: 1, turnID: 1, command: "", result: completed, state: .finished, tool: "complete_reminder", undo: .available),
        .init(callID: "4", entryID: 1, turnID: 1, command: "", result: events, state: .finished, tool: "list_events"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "组会", result: meeting, state: .finished, tool: "create_event", undo: .available),
    ]}
    static var undoCards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "交报告", result: AgentToolResult.undone(created, tool: "create_reminder"),
              state: .finished, tool: "create_reminder", undo: .undone),
        .init(callID: "2", entryID: 1, turnID: 1, command: "组会", result: meeting, state: .finished, tool: "create_event",
              undo: .refused(.eventChanged)),
        .init(callID: "3", entryID: 1, turnID: 1, command: "", result: completed, state: .finished, tool: "complete_reminder",
              undo: .refused(.reminderMissing)),
        .init(callID: "4", entryID: 1, turnID: 1, command: "买菜",
              result: AgentCalendarRunner.noList("购物", [.init(id: "a", title: "提醒"), .init(id: "b", title: "工作")]),
              state: .failed, tool: "create_reminder"),
    ]}
    static var deniedCards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "", result: AgentCalendarResult.denied(.reminders, .denied), state: .failed,
              tool: "list_reminders"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "交报告", result: AgentCalendarResult.denied(.reminders, .denied), state: .failed,
              tool: "create_reminder"),
        .init(callID: "3", entryID: 1, turnID: 1, command: "组会", result: AgentCalendarResult.denied(.events, .denied), state: .failed,
              tool: "create_event"),
        .init(callID: "4", entryID: 1, turnID: 1, command: "", result: AgentCalendarResult.denied(.events, .writeOnly), state: .failed,
              tool: "list_events"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "", result: AgentCalendarResult.denied(.reminders, .restricted), state: .failed,
              tool: "complete_reminder"),
    ]}
}

#Preview("工具卡片 · 提醒事项和日历") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CalendarPreview.cards) { record in
                AgentToolView(tool: record, expanded: true, undo: record.undo == nil ? nil : {}, canUndo: true)
            }
        }.padding()
    }.frame(width: 520, height: 640)
}

#Preview("工具卡片 · 提醒事项和日历 · 撤销") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CalendarPreview.undoCards) { record in
            AgentToolView(tool: record, expanded: record.state != .finished,
                          undo: record.undo == nil || record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 提醒事项和日历 · 没有权限") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CalendarPreview.deniedCards) { AgentToolView(tool: $0, expanded: true) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 提醒事项和日历 · 折叠") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CalendarPreview.cards) { record in
            AgentToolView(tool: record, undo: record.undo == nil ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}

/// open_app and open_url cards: opened, brought to the front, and each way nothing opened.
@MainActor private enum OpenPreview {
    static let reminders = AgentApp(path: "/System/Applications/Reminders.app", name: "提醒事项", names: [])
    static var cards: [AgentToolRecord] {[
        .init(callID: "1", entryID: 1, turnID: 1, command: "提醒事项", result: AgentOpenResult.opened(reminders, wasRunning: false),
              state: .finished, tool: "open_app"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "Finder",
              result: AgentOpenResult.opened(.init(path: "/System/Library/CoreServices/Finder.app", name: "访达", names: []), wasRunning: true),
              state: .finished, tool: "open_app"),
        .init(callID: "3", entryID: 1, turnID: 1, command: "https://developer.apple.com/documentation/appkit?language=objc",
              result: AgentOpenResult.opened(URL(string: "https://developer.apple.com/documentation/appkit?language=objc")!),
              state: .finished, tool: "open_url"),
        .init(callID: "4", entryID: 1, turnID: 1, command: "提醒", result: AgentOpenResult.noApp("提醒", closest: ["提醒事项", "备忘录", "日历"]),
              state: .failed, tool: "open_app"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "Siri",
              result: AgentOpenResult.sameName("Siri", apps: [.init(path: "/System/Applications/Siri.app", name: "Siri", names: []),
                                                               .init(path: "/System/Applications/Siri AI.app", name: "Siri AI", names: [])]),
              state: .failed, tool: "open_app"),
        .init(callID: "6", entryID: 1, turnID: 1, command: "shortcuts://run-shortcut?name=x", result: AgentOpenResult.scheme("shortcuts"),
              state: .failed, tool: "open_url"),
        .init(callID: "7", entryID: 1, turnID: 1, command: "example.com", result: AgentOpenResult.noScheme, state: .failed, tool: "open_url"),
    ]}
}

#Preview("工具卡片 · 打开应用和网址") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(OpenPreview.cards) { AgentToolView(tool: $0, expanded: true) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 打开应用和网址 · 折叠") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(OpenPreview.cards) { AgentToolView(tool: $0) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 写入 · 折叠") {
    let records: [AgentToolRecord] = [
        .init(callID: "1", entryID: 1, turnID: 1, command: "drafts/plan.md",
              result: #"{"action":"created","bytes":412,"path":"drafts/plan.md"}"#, state: .finished, tool: "write_file"),
        .init(callID: "2", entryID: 1, turnID: 1, command: "notes.txt",
              result: #"{"action":"edited","bytes":2051,"path":"notes.txt"}"#, state: .finished, tool: "edit_file"),
        .init(callID: "3", entryID: 1, turnID: 1, command: ".zshrc",
              result: AgentToolResult.failed("hidden files and folders are not written: .zshrc"), state: .notWritten, tool: "write_file"),
        .init(callID: "4", entryID: 1, turnID: 1, command: "notes.txt",
              result: AgentToolResult.failed("old_text was not found in notes.txt"), state: .notWritten, tool: "edit_file"),
        .init(callID: "5", entryID: 1, turnID: 1, command: "missing.txt",
              result: AgentToolResult.failed("no such file or directory: missing.txt"), state: .finished, tool: "read_file"),
    ]
    VStack(alignment: .leading, spacing: 8) {
        ForEach(records) { AgentToolView(tool: $0) }
    }.padding().frame(width: 520)
}

/// remember and update_memory cards: remembered, changed, removed, undone, refused, and each way nothing changed.
@MainActor private enum MemoryPreview {
    static func record(_ id: String, _ tool: String, _ command: String, edit: AgentToolRecord.Edit, result: String, state: AgentToolRecord.State,
                       undo: AgentToolRecord.Undo? = nil) -> AgentToolRecord {
        .init(callID: id, entryID: 1, turnID: 1, command: command, result: result, state: state, tool: tool, edit: edit, undo: undo)
    }
    static func failed(_ reason: AgentMemoryEdit.Reason, count: Int? = nil) -> String {
        var value: [String: Any] = ["status": "failed", "detail": "", "reason": reason.rawValue]
        if let count { value["count"] = count }
        return AgentToolResult.object(value)
    }
    static let remembered = AgentMemoryEdit.result(.remember("喜欢喝美式，不加糖"))
    static let updated = AgentMemoryEdit.result(.update(old: "住在杭州", new: "住在上海"))
    static let removed = AgentMemoryEdit.result(.update(old: "常用项目是 Echo", new: ""))
    static var cards: [AgentToolRecord] {[
        record("1", "remember", "喜欢喝美式，不加糖", edit: .init(old: "", new: "- 喜欢喝美式，不加糖"), result: remembered, state: .finished, undo: .available),
        record("2", "update_memory", "住在上海", edit: .init(old: "住在杭州", new: "住在上海"), result: updated, state: .finished, undo: .available),
        record("3", "update_memory", "常用项目是 Echo", edit: .init(old: "常用项目是 Echo", new: ""), result: removed, state: .finished, undo: .available),
    ]}
    static var otherCards: [AgentToolRecord] {[
        record("1", "remember", "喜欢喝美式，不加糖", edit: .init(old: "", new: "- 喜欢喝美式，不加糖"),
               result: AgentToolResult.undone(remembered, tool: "remember"), state: .finished, undo: .undone),
        record("2", "update_memory", "住在上海", edit: .init(old: "住在杭州", new: "住在上海"), result: updated, state: .finished,
               undo: .refused(.memoryChanged)),
        record("3", "remember", "生日是 5 月 3 日", edit: .init(old: "", new: "- 生日是 5 月 3 日"), result: failed(.full), state: .failed),
        record("4", "update_memory", "周末不看工作消息", edit: .init(old: "周末不回消息", new: "周末不看工作消息"), result: failed(.notFound), state: .failed),
        record("5", "update_memory", "- ", edit: .init(old: "- ", new: ""), result: failed(.ambiguous, count: 6), state: .failed),
        record("6", "remember", "手机号 138 0013 8000", edit: .init(old: "", new: "- 手机号 138 0013 8000"),
               result: refused(.remember("手机号 138 0013 8000")), state: .failed),
        record("7", "update_memory", "住在文三路 88 号", edit: .init(old: "住在杭州", new: "住在文三路 88 号"),
               result: refused(.update(old: "住在杭州", new: "住在文三路 88 号")), state: .failed),
    ]}
    /// What a call the memory does not accept gets back.
    static func refused(_ change: AgentMemoryChange) -> String {
        if case .failure(let failure) = AgentMemoryEdit.apply(change, to: nil) { failure.result } else { "" }
    }
}

#Preview("工具卡片 · 记忆") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(MemoryPreview.cards) { AgentToolView(tool: $0, expanded: true, undo: {}, canUndo: true) }
    }.padding().frame(width: 520)
}

#Preview("工具卡片 · 记忆 · 撤销和失败") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(MemoryPreview.otherCards) { record in
            AgentToolView(tool: record, expanded: record.state != .finished,
                          undo: record.undo == nil || record.undo == .undone ? nil : {}, canUndo: true)
        }
    }.padding().frame(width: 520)
}
