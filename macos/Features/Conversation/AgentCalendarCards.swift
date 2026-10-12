import Foundation

/// What a reminders or calendar card says: its title and the lines it shows when opened, from the
/// call's arguments until a result says what was done. Times read relative to now in the person's
/// time zone: "明天 10:00", "周三 14:00–15:00", later ones by date.
struct AgentCalendarCard {
    let tool: AgentToolRecord
    var now = Date()
    var timeZone = TimeZone.current
    var locale = Locale.current

    static func applies(to tool: AgentToolRecord) -> Bool {
        tool.tool.map(AgentHarness.calendarTools.contains) ?? false
    }

    var icon: String {
        switch tool.tool {
        case "list_reminders": "checklist"
        case "create_reminder": "bell"
        case "complete_reminder": "checkmark.circle"
        case "list_events": "calendar"
        default: "calendar.badge.plus"
        }
    }

    /// "新建提醒：交报告 · 明天 10:00"; a call that did not finish says how it ended first.
    var title: String {
        let prefix: String
        if tool.undo == .undone { prefix = String(localized: "已撤销") + " · " }
        else if tool.state == .finished && AgentHarness.calendarChangeTools.contains(tool.tool ?? "") { prefix = "" }
        else { prefix = tool.state.label + " · " }
        return prefix + action
    }

    private var result: [String: Any]? {
        tool.result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    }

    private var action: String {
        let result = result
        switch tool.tool {
        case "create_reminder":
            let reminder = result?["reminder"] as? [String: Any]
            let name = reminder?["title"] as? String ?? tool.command
            let due = (reminder?["due"] as? String).flatMap(when)
            return String(localized: "新建提醒：\(name)") + (due.map { " · " + $0 } ?? "")
        case "complete_reminder":
            let name = (result?["reminder"] as? [String: Any])?["title"] as? String
            return name.map { String(localized: "完成提醒：\($0)") } ?? String(localized: "完成提醒")
        case "create_event":
            let event = result?["event"] as? [String: Any]
            let name = event?["title"] as? String ?? tool.command
            return String(localized: "新建日程：\(name)") + (event.flatMap(span).map { " · " + $0 } ?? "")
        case "list_reminders":
            return String(localized: "查看提醒事项") + (tool.command.isEmpty ? "" : " · " + tool.command)
        default:
            let from = (result?["from"] as? String).flatMap(Self.instant)
            let to = (result?["to"] as? String).flatMap(Self.instant)
            guard let from, let to else { return String(localized: "查看日程") }
            // The range ends where the next day starts; the card names the last day it covers.
            let last = to.addingTimeInterval(-1)
            let days = calendar.isDate(from, inSameDayAs: last) ? day(from) : day(from) + "–" + day(last)
            return String(localized: "查看日程") + " · " + days
        }
    }

    /// The lines an opened card shows; nil leaves the card to show the result as other tools do.
    var lines: [String]? {
        if let missing = tool.result.flatMap(AgentCalendarResult.missingAccess) { return [Self.missingAccess(missing.kind, missing.permission)] }
        guard let result, result["status"] == nil else { return nil }
        switch tool.tool {
        case "list_reminders":
            let reminders = result["reminders"] as? [[String: Any]] ?? []
            if reminders.isEmpty { return [String(localized: "（没有提醒事项）")] }
            return reminders.map { reminder in
                ([reminder["title"] as? String ?? ""] + [(reminder["due"] as? String).flatMap(when), reminder["list"] as? String].compactMap { $0 })
                    .joined(separator: " · ")
            } + (result["truncated"] as? Bool == true ? [String(localized: "已截断")] : [])
        case "list_events":
            let events = result["events"] as? [[String: Any]] ?? []
            if events.isEmpty { return [String(localized: "（没有日程）")] }
            return events.map { event in
                ([event["title"] as? String ?? "", span(event), event["location"] as? String].compactMap { $0 }).joined(separator: " · ")
            } + (result["truncated"] as? Bool == true ? [String(localized: "已截断")] : [])
        case "create_reminder", "complete_reminder":
            guard let reminder = result["reminder"] as? [String: Any] else { return nil }
            return [(reminder["list"] as? String).map { String(localized: "列表：\($0)") }].compactMap { $0 }
        case "create_event":
            guard let event = result["event"] as? [String: Any] else { return nil }
            return [(event["calendar"] as? String).map { String(localized: "日历：\($0)") },
                    (event["location"] as? String).map { String(localized: "地点：\($0)") }].compactMap { $0 }
        default: return nil
        }
    }

    /// What the person reads when Echo had no access: the model gets its own words for it.
    static func missingAccess(_ kind: AgentCalendarKind, _ permission: AgentCalendarPermission) -> String {
        switch (kind, permission) {
        case (.reminders, .restricted): String(localized: "这台 Mac 限制了对提醒事项的访问，例如由配置描述文件限制。")
        case (.events, .restricted): String(localized: "这台 Mac 限制了对日历的访问，例如由配置描述文件限制。")
        case (.events, .writeOnly): String(localized: "Echo 只能添加日程，不能读取。可以在“系统设置 > 隐私与安全性 > 日历”里改为完全访问。")
        case (.reminders, _): String(localized: "Echo 没有提醒事项的访问权限。可以在“系统设置 > 隐私与安全性 > 提醒事项”里打开。")
        case (.events, _): String(localized: "Echo 没有日历的访问权限。可以在“系统设置 > 隐私与安全性 > 日历”里打开。")
        }
    }

    // MARK: Times

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// "明天 10:00" for a time, "明天" for a date alone.
    private func when(_ text: String) -> String? {
        if let date = Self.instant(text) { return day(date) + " " + time(date) }
        return Self.date(text, in: calendar).map(day)
    }

    /// "周三 14:00–15:00", "周六 全天", or across days "周三 22:00 – 周四 01:00".
    private func span(_ event: [String: Any]) -> String? {
        if event["all_day"] as? Bool == true {
            guard let first = (event["start"] as? String).flatMap({ Self.date($0, in: calendar) }),
                  let last = (event["end"] as? String).flatMap({ Self.date($0, in: calendar) }) else { return nil }
            let days = calendar.isDate(first, inSameDayAs: last) ? day(first) : day(first) + "–" + day(last)
            return days + " " + String(localized: "全天")
        }
        guard let start = (event["start"] as? String).flatMap(Self.instant) else { return nil }
        guard let end = (event["end"] as? String).flatMap(Self.instant) else { return day(start) + " " + time(start) }
        if calendar.isDate(start, inSameDayAs: end) {
            // The interval formatter says the period once: "下午2:00–3:00", "2:00–3:00 PM".
            let formatter = DateIntervalFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateTemplate = "jmm"
            return day(start) + " " + formatter.string(from: start, to: end)
        }
        return day(start) + " " + time(start) + " – " + day(end) + " " + time(end)
    }

    /// Today, tomorrow and yesterday by name, the coming week by weekday, other days by date.
    private func day(_ date: Date) -> String {
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch offset {
        case -1...1:
            formatter.dateStyle = .medium
            formatter.doesRelativeDateFormatting = true
        case 2...6:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        default:
            formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMd" : "yMMMd")
        }
        return formatter.string(from: date)
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    /// A time as results write it, with its offset.
    static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A date alone, as the start of that day.
    static func date(_ text: String, in calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, !text.contains("T") else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
