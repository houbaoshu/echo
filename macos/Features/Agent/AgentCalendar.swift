import EventKit
import Foundation
import FoundationModels

// Reminders and Calendar for the native Agent, through EventKit directly. The tools here read
// their arguments and say what the call asks for; the harness runs each call in its turn, asks for
// access, saves the call before anything changes, and keeps what an undo needs. `AgentCalendarStore`
// is the only part that touches EventKit, so tests give the harness a store of their own.
//
// Times cross the tool boundary as ISO 8601 with a UTC offset, or a date alone for a whole day,
// and come back in the person's time zone with the weekday, so the model can check its own
// arithmetic for "tomorrow" or "next Wednesday".

enum AgentCalendarKind: String, Codable, Sendable {
    case reminders, events
}

/// Whether Echo may use the person's reminders or events. Only full access lets a tool work.
enum AgentCalendarPermission: Sendable, Equatable {
    case granted, denied, restricted
    /// Calendar only: events can be added but not read.
    case writeOnly
}

struct AgentReminderList: Sendable, Equatable {
    var id: String
    var title: String
}

struct AgentReminder: Sendable, Equatable {
    var id: String
    var title: String
    /// As EventKit keeps it: a date alone for a reminder without a time; a time zone, or none for a floating time.
    var due: DateComponents?
    var listID: String
    var listTitle: String
    var isCompleted: Bool
    var modified: Date?
}

struct AgentCalendarEvent: Sendable, Equatable {
    var id: String
    var title: String
    var start: Date
    /// For an all-day event, any time on its last day.
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String
    var modified: Date?
}

/// A new event. An all-day event starts at the start of its first day and ends at the start of its last day.
struct AgentEventDraft: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
}

enum AgentCalendarFailure: Error, Equatable {
    case notFound
    /// The list or calendar cannot be changed.
    case readOnly(String)
    case noDefault
    case failed(String)

    /// What a card says of an error an undo met.
    static func reason(_ error: any Error) -> String {
        switch error as? AgentCalendarFailure {
        case .readOnly(let name)?: String(localized: "“\(name)”不能修改")
        case .failed(let reason)?: reason
        case .notFound?, .noDefault?, nil: error.localizedDescription
        }
    }
}

/// The person's reminders and events. Every call may ask the person for access first.
protocol AgentCalendarStore: Sendable {
    /// Asks the person when they have not decided yet, and waits for their answer.
    func permission(for kind: AgentCalendarKind) async -> AgentCalendarPermission
    /// Every reminder list, and the one new reminders go to.
    func reminderLists() async throws -> (lists: [AgentReminderList], defaultID: String?)
    /// Reminders not completed in `lists` (every list when nil), due within the range when one is given.
    func incompleteReminders(in lists: [String]?, dueFrom: Date?, dueTo: Date?) async throws -> [AgentReminder]
    /// `list` nil puts it in the default list. `alarm` notifies the person at that moment.
    func createReminder(title: String, due: DateComponents?, alarm: Date?, list: String?) async throws -> AgentReminder
    /// The reminder as it is now; nil when it no longer exists.
    func reminder(id: String) async throws -> AgentReminder?
    func setCompleted(_ completed: Bool, reminder id: String) async throws -> AgentReminder
    func removeReminder(id: String) async throws
    /// Events overlapping the range, every calendar.
    func events(from: Date, to: Date) async throws -> [AgentCalendarEvent]
    /// In the default calendar.
    func createEvent(_ draft: AgentEventDraft) async throws -> AgentCalendarEvent
    func event(id: String) async throws -> AgentCalendarEvent?
    func removeEvent(id: String) async throws
}

/// The person's clock: what "now" is and the time zone times are read and written in.
struct AgentClock: Sendable {
    var now: @Sendable () -> Date
    var timeZone: TimeZone
    static let system = AgentClock(now: { Date() }, timeZone: .autoupdatingCurrent)

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

// MARK: Times

/// A time as a tool argument gives it.
enum AgentTime: Sendable, Equatable {
    case instant(Date)
    /// A whole day, in no time zone.
    case day(year: Int, month: Int, day: Int)

    /// ISO 8601: `2026-10-13T10:00:00+08:00` (seconds and fractions optional, `Z` for UTC), or
    /// `2026-10-13` alone. A time without an offset is refused: whose 10:00 it is must be said.
    static func parse(_ raw: String) -> Result<AgentTime, AgentInvalidArguments> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?(Z|z|[+-]\d{2}(?::?\d{2})?)?)?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let invalid = AgentInvalidArguments(result: AgentToolResult.failed(
            "\(raw) is not a time; use ISO 8601 with a UTC offset, such as 2026-10-13T10:00:00+08:00, or a date alone, such as 2026-10-13"))
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return .failure(invalid) }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        let year = Int(group(1)!)!, month = Int(group(2)!)!, day = Int(group(3)!)!
        guard let hourText = group(4) else {
            guard Self.isDay(year: year, month: month, day: day) else { return .failure(invalid) }
            return .success(.day(year: year, month: month, day: day))
        }
        guard let zone = group(8) else {
            return .failure(AgentInvalidArguments(result: AgentToolResult.failed(
                "\(raw) has no UTC offset; add the person's offset, such as 2026-10-13T10:00:00+08:00")))
        }
        let offset: Int
        if zone == "Z" || zone == "z" {
            offset = 0
        } else {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().filter(\.isNumber)
            let hours = Int(digits.prefix(2))!, minutes = digits.count > 2 ? Int(digits.suffix(2))! : 0
            guard hours <= 18, minutes < 60 else { return .failure(invalid) }
            offset = sign * (hours * 3600 + minutes * 60)
        }
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { return .failure(invalid) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: Int(hourText)!, minute: Int(group(5)!)!,
                                        second: group(6).flatMap { Int($0) } ?? 0,
                                        nanosecond: group(7).map { Int(($0.dropFirst() + String(repeating: "0", count: 9)).prefix(9))! } ?? 0)
        guard let hour = components.hour, hour < 24, components.minute! < 60, components.second! < 60,
              Self.isDay(year: year, month: month, day: day), let date = calendar.date(from: components) else { return .failure(invalid) }
        return .success(.instant(date))
    }

    private static func isDay(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    /// The day this time falls on for the person.
    func day(in clock: AgentClock) -> DateComponents {
        switch self {
        case .day(let year, let month, let day): DateComponents(year: year, month: month, day: day)
        case .instant(let date): clock.calendar.dateComponents([.year, .month, .day], from: date)
        }
    }

    /// The moment it names; a day alone starts at the person's midnight.
    func start(in clock: AgentClock) -> Date {
        switch self {
        case .instant(let date): date
        case .day: clock.calendar.date(from: day(in: clock))!
        }
    }
}

/// How results write times: in the person's time zone, with the weekday.
enum AgentTimeText {
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// `2026-10-13T10:00:00+08:00`.
    static func stamp(_ date: Date, in clock: AgentClock) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = clock.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func weekday(_ date: Date, in clock: AgentClock) -> String {
        weekdays[clock.calendar.component(.weekday, from: date) - 1]
    }

    /// `2026-10-13`.
    static func date(_ day: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    static func weekday(of day: DateComponents, in clock: AgentClock) -> String {
        let noon = clock.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return weekday(noon, in: clock)
    }

    /// The time and its weekday for a reminder's due date: a date alone for one without a time; a
    /// floating time is read in the person's time zone.
    static func due(_ due: DateComponents, in clock: AgentClock) -> (text: String, weekday: String) {
        guard due.hour != nil else { return (date(due), weekday(of: due, in: clock)) }
        let date = dueDate(due, in: clock)
        return (stamp(date, in: clock), weekday(date, in: clock))
    }

    /// The moment a reminder is due; a date alone is due at the start of its day.
    static func dueDate(_ due: DateComponents, in clock: AgentClock) -> Date {
        var calendar = clock.calendar
        if let zone = due.timeZone { calendar.timeZone = zone }
        let parts = DateComponents(year: due.year, month: due.month, day: due.day, hour: due.hour ?? 0, minute: due.minute ?? 0, second: due.second ?? 0)
        return calendar.date(from: parts) ?? clock.now()
    }

    /// "Monday 2026-10-12 20:15 (Asia/Shanghai, UTC+08:00)".
    static func now(_ clock: AgentClock) -> String {
        let date = clock.now()
        let parts = clock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let seconds = clock.timeZone.secondsFromGMT(for: date)
        let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        return "\(weekday(date, in: clock)) \(Self.date(parts)) " + String(format: "%02d:%02d", parts.hour!, parts.minute!)
            + " (\(clock.timeZone.identifier), \(offset))"
    }
}

// MARK: Results

enum AgentCalendarResult {
    static let maxItems = 100

    static func reminder(_ reminder: AgentReminder, clock: AgentClock) -> [String: Any] {
        var value: [String: Any] = ["id": reminder.id, "title": reminder.title, "list": reminder.listTitle]
        if let due = reminder.due {
            let (text, weekday) = AgentTimeText.due(due, in: clock)
            value["due"] = text; value["due_weekday"] = weekday
        }
        return value
    }

    static func event(_ event: AgentCalendarEvent, clock: AgentClock, id: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["title": event.title, "all_day": event.isAllDay, "calendar": event.calendarTitle]
        if event.isAllDay {
            let first = clock.calendar.dateComponents([.year, .month, .day], from: event.start)
            let last = clock.calendar.dateComponents([.year, .month, .day], from: max(event.start, event.end.addingTimeInterval(-1)))
            value["start"] = AgentTimeText.date(first); value["start_weekday"] = AgentTimeText.weekday(of: first, in: clock)
            value["end"] = AgentTimeText.date(last); value["end_weekday"] = AgentTimeText.weekday(of: last, in: clock)
        } else {
            value["start"] = AgentTimeText.stamp(event.start, in: clock); value["start_weekday"] = AgentTimeText.weekday(event.start, in: clock)
            value["end"] = AgentTimeText.stamp(event.end, in: clock); value["end_weekday"] = AgentTimeText.weekday(event.end, in: clock)
        }
        if let location = event.location, !location.isEmpty { value["location"] = location }
        if id { value["id"] = event.id }
        return value
    }

    static func denied(_ kind: AgentCalendarKind, _ permission: AgentCalendarPermission) -> String {
        let (name, pane) = kind == .reminders
            ? ("Reminders", "System Settings > Privacy & Security > Reminders (系统设置 > 隐私与安全性 > 提醒事项)")
            : ("Calendars", "System Settings > Privacy & Security > Calendars (系统设置 > 隐私与安全性 > 日历)")
        return switch permission {
        case .restricted:
            AgentToolResult.failed("Access to \(name) is restricted on this Mac, for example by a configuration profile, so nothing was read or changed.")
        case .writeOnly:
            AgentToolResult.failed("Echo may only add events, not read them, so nothing was read or changed. The person can give Echo full access in \(pane).")
        case .granted, .denied:
            AgentToolResult.failed("Echo has no access to \(name), so nothing was read or changed. The person can turn it on in \(pane).")
        }
    }

    /// Which access a result says Echo lacks, when it is the result of a call made without it.
    static func missingAccess(_ result: String) -> (kind: AgentCalendarKind, permission: AgentCalendarPermission)? {
        for kind in [AgentCalendarKind.reminders, .events] {
            for permission in [AgentCalendarPermission.denied, .restricted, .writeOnly] where result == denied(kind, permission) {
                return (kind, permission)
            }
        }
        return nil
    }

    static func failure(_ error: any Error, what: String) -> String {
        switch error as? AgentCalendarFailure {
        case .notFound: AgentToolResult.failed("\(what) was not found")
        case .readOnly(let name)?: AgentToolResult.failed("\(name) cannot be changed, so nothing was changed")
        case .noDefault?: AgentToolResult.failed("there is no default calendar for new events, so nothing was added")
        case .failed(let reason)?: AgentToolResult.failed(reason)
        case nil: AgentToolResult.failed(error.localizedDescription)
        }
    }
}

/// What Echo changed with one call, kept with the chat so the change can be undone.
struct AgentCalendarChange: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case createdReminder, completedReminder, createdEvent
    }
    var action: Action
    /// The reminder's or event's identifier.
    var item: String
    var title: String
    /// When the item was last modified before the change, and right after it, as seconds since
    /// the reference date: an encoder's date format must not round them. Nil before for a new item.
    var before: TimeInterval?
    var after: TimeInterval
    var kind: AgentCalendarKind { action == .createdEvent ? .events : .reminders }

    /// Whether `modified` is the time Echo's change left.
    static func same(_ modified: Date?, _ recorded: TimeInterval?) -> Bool {
        guard let modified, let recorded else { return false }
        return abs(modified.timeIntervalSinceReferenceDate - recorded) < 0.001
    }
}

// MARK: Requests and tools

/// What a reminders or calendar call asks for.
enum AgentCalendarRequest: Sendable, Equatable {
    case listReminders(list: String?, from: AgentTime?, to: AgentTime?)
    case createReminder(title: String, due: AgentTime?, list: String?)
    case completeReminder(id: String)
    case listEvents(from: AgentTime, to: AgentTime)
    case createEvent(title: String, start: AgentTime, end: AgentTime?, allDay: Bool?, location: String?)

    var kind: AgentCalendarKind {
        switch self {
        case .listReminders, .createReminder, .completeReminder: .reminders
        case .listEvents, .createEvent: .events
        }
    }
}

/// Runs reminders and calendar calls for the conversation.
protocol AgentCalendarAccess: Sendable {
    /// `call` links the call to the one the harness saw dispatched, as for finder_location.
    /// `changes` says whether the tool changes anything, which decides its place in its batch.
    func run(call: GenerationID?, changes: Bool, _ request: Result<AgentCalendarRequest, AgentInvalidArguments>) async throws -> String
}

private func timeArgument(_ raw: String?) -> Result<AgentTime?, AgentInvalidArguments> {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return .success(nil) }
    return AgentTime.parse(raw).map(Optional.some)
}

private func nonEmpty(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

struct ListRemindersTool: Tool {
    let name = "list_reminders"
    let description = "List the person's reminders that are not completed"
    let access: any AgentCalendarAccess

    @Generable
    struct Input {
        @Guide(description: "Only this reminder list, by its name; omit for every list")
        var list: String?
        @Guide(description: "Only reminders due at or after this time, ISO 8601 with a UTC offset or a date")
        var due_from: String?
        @Guide(description: "Only reminders due before this time, ISO 8601 with a UTC offset or a date")
        var due_to: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentCalendarRequest, AgentInvalidArguments>
        if let input = try? Input(arguments) {
            request = timeArgument(input.due_from).flatMap { from in
                timeArgument(input.due_to).map { to in .listReminders(list: nonEmpty(input.list), from: from, to: to) }
            }
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for list_reminders; expected {\"list\"?: string, \"due_from\"?: string, \"due_to\"?: string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, changes: false, request)
    }
}

struct CreateReminderTool: Tool {
    let name = "create_reminder"
    let description = "Add a reminder to the person's Reminders"
    let access: any AgentCalendarAccess

    @Generable
    struct Input {
        @Guide(description: "The thing to do alone, without when it is due or which list it is in, which go in due and list: 交报告 for \"明天上午十点提醒我交报告\"")
        var title: String
        @Guide(description: "When it is due, ISO 8601 with a UTC offset, or a date alone for a day without a time; omit for no due date")
        var due: String?
        @Guide(description: "The reminder list's name; omit for the default list")
        var list: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentCalendarRequest, AgentInvalidArguments>
        if let input = try? Input(arguments) {
            if let title = nonEmpty(input.title) {
                request = timeArgument(input.due).map { .createReminder(title: title, due: $0, list: nonEmpty(input.list)) }
            } else {
                request = .failure(.init(result: AgentToolResult.failed("title must not be empty")))
            }
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for create_reminder; expected {\"title\": string, \"due\"?: string, \"list\"?: string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, changes: true, request)
    }
}

struct CompleteReminderTool: Tool {
    let name = "complete_reminder"
    let description = "Mark one of the person's reminders as completed"
    let access: any AgentCalendarAccess

    @Generable
    struct Input {
        @Guide(description: "The reminder's id, as list_reminders or create_reminder gave it")
        var id: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentCalendarRequest, AgentInvalidArguments>
        if let input = try? Input(arguments), let id = nonEmpty(input.id) {
            request = .success(.completeReminder(id: id))
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for complete_reminder; expected {\"id\": string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, changes: true, request)
    }
}

struct ListEventsTool: Tool {
    let name = "list_events"
    let description = "List the events in the person's calendars within a time range"
    let access: any AgentCalendarAccess

    @Generable
    struct Input {
        @Guide(description: "Start of the range, ISO 8601 with a UTC offset, or a date for the start of that day")
        var from: String
        @Guide(description: "End of the range, ISO 8601 with a UTC offset, or a date for the end of that day")
        var to: String
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentCalendarRequest, AgentInvalidArguments>
        if let input = try? Input(arguments) {
            request = AgentTime.parse(input.from).flatMap { from in AgentTime.parse(input.to).map { .listEvents(from: from, to: $0) } }
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for list_events; expected {\"from\": string, \"to\": string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, changes: false, request)
    }
}

struct CreateEventTool: Tool {
    let name = "create_event"
    let description = "Add an event to the person's default calendar"
    let access: any AgentCalendarAccess

    @Generable
    struct Input {
        @Guide(description: "What the event is alone, without its date, time or place, which go in start, end and location: 组会 for \"下周三下午两点在三楼开组会\"")
        var title: String
        @Guide(description: "When it starts, ISO 8601 with a UTC offset, or a date for an all-day event")
        var start: String
        @Guide(description: "When it ends, ISO 8601 with a UTC offset, or the last day of an all-day event; omit for one hour, or one day when all-day")
        var end: String?
        @Guide(description: "Whether it lasts all day")
        var all_day: Bool?
        var location: String?
    }

    var parameters: GenerationSchema { Input.generationSchema }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let request: Result<AgentCalendarRequest, AgentInvalidArguments>
        if let input = try? Input(arguments) {
            if let title = nonEmpty(input.title) {
                request = AgentTime.parse(input.start).flatMap { start in
                    timeArgument(input.end).map { .createEvent(title: title, start: start, end: $0, allDay: input.all_day, location: nonEmpty(input.location)) }
                }
            } else {
                request = .failure(.init(result: AgentToolResult.failed("title must not be empty")))
            }
        } else {
            request = .failure(.init(result: AgentToolResult.failed(
                "invalid arguments for create_event; expected {\"title\": string, \"start\": string, \"end\"?: string, \"all_day\"?: boolean, \"location\"?: string}. Received: \(arguments.jsonString)")))
        }
        return try await access.run(call: arguments.id, changes: true, request)
    }
}

// MARK: Running a call

/// A call worked out against the store with nothing changed yet, or its result.
enum AgentCalendarPlan: Sendable {
    case done(String)
    case createReminder(title: String, due: DateComponents?, alarm: Date?, list: String?)
    case completeReminder(id: String)
    case createEvent(AgentEventDraft)
}

/// The calls on a store, in the two steps the harness runs them in: `prepare` reads and checks and
/// changes nothing; `commit` makes the change and says what an undo needs.
enum AgentCalendarRunner {
    static func prepare(_ request: AgentCalendarRequest, store: any AgentCalendarStore, clock: AgentClock) async -> AgentCalendarPlan {
        do {
            switch request {
            case .listReminders(let name, let from, let to):
                var lists: [String]?
                var names: [String] = []
                if let name {
                    let all = try await store.reminderLists().lists
                    names = all.map(\.title)
                    guard let list = Self.list(named: name, in: all) else { return .done(Self.noList(name, all)) }
                    lists = [list.id]
                }
                // A day as the end of the range takes in the whole day.
                let end = to.map { time -> Date in
                    if case .day = time { clock.calendar.date(byAdding: .day, value: 1, to: time.start(in: clock))! } else { time.start(in: clock) }
                }
                let start = from?.start(in: clock)
                if let start, let end, end <= start { return .done(AgentToolResult.failed("due_to must be after due_from")) }
                // Without a range, reminders without a due date are listed too; with one, they are not.
                let found = try await store.incompleteReminders(in: lists, dueFrom: start, dueTo: end)
                let sorted = found.sorted { lhs, rhs in
                    switch (lhs.due.map { AgentTimeText.dueDate($0, in: clock) }, rhs.due.map { AgentTimeText.dueDate($0, in: clock) }) {
                    case let (l?, r?): l < r
                    case (.some, nil): true
                    default: false
                    }
                }
                var value: [String: Any] = ["reminders": sorted.prefix(AgentCalendarResult.maxItems).map { AgentCalendarResult.reminder($0, clock: clock) },
                                            "truncated": sorted.count > AgentCalendarResult.maxItems]
                if name != nil { value["lists"] = names }
                return .done(AgentToolResult.object(value))

            case .createReminder(let title, let due, let name):
                var list: String?
                if let name {
                    let all = try await store.reminderLists().lists
                    guard let found = Self.list(named: name, in: all) else { return .done(Self.noList(name, all)) }
                    list = found.id
                }
                switch due {
                case nil: return .createReminder(title: title, due: nil, alarm: nil, list: list)
                case .day?:
                    return .createReminder(title: title, due: due!.day(in: clock), alarm: nil, list: list)
                case .instant(let date)?:
                    var parts = clock.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    if parts.second == 0 { parts.second = nil }
                    parts.timeZone = clock.timeZone
                    return .createReminder(title: title, due: parts, alarm: date, list: list)
                }

            case .completeReminder(let id):
                guard let reminder = try await store.reminder(id: id) else {
                    return .done(AgentToolResult.failed("no reminder has the id \(id); list_reminders gives the ids of reminders not completed"))
                }
                if reminder.isCompleted { return .done(AgentToolResult.failed("\(reminder.title) is already completed, so nothing was changed")) }
                return .completeReminder(id: id)

            case .listEvents(let from, let to):
                let start = from.start(in: clock)
                let end: Date = if case .day = to { clock.calendar.date(byAdding: .day, value: 1, to: to.start(in: clock))! } else { to.start(in: clock) }
                guard end > start else { return .done(AgentToolResult.failed("to must be after from")) }
                let found = try await store.events(from: start, to: end).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
                return .done(AgentToolResult.object([
                    "from": AgentTimeText.stamp(start, in: clock), "to": AgentTimeText.stamp(end, in: clock),
                    "events": found.prefix(AgentCalendarResult.maxItems).map { AgentCalendarResult.event($0, clock: clock) },
                    "truncated": found.count > AgentCalendarResult.maxItems,
                ]))

            case .createEvent(let title, let start, let end, let allDay, let location):
                let wholeDay: Bool
                switch (allDay, start) {
                case (true?, _), (nil, .day): wholeDay = true
                case (false?, .day): return .done(AgentToolResult.failed("start needs a time unless all_day is true"))
                default: wholeDay = false
                }
                if wholeDay {
                    let first = clock.calendar.date(from: start.day(in: clock))!
                    let last = end.map { clock.calendar.date(from: $0.day(in: clock))! } ?? first
                    guard last >= first else { return .done(AgentToolResult.failed("end must not be before start")) }
                    return .createEvent(.init(title: title, start: first, end: last, isAllDay: true, location: location))
                }
                let begin = start.start(in: clock)
                let finish = end?.start(in: clock) ?? begin.addingTimeInterval(3600)
                guard finish > begin else { return .done(AgentToolResult.failed("end must be after start")) }
                return .createEvent(.init(title: title, start: begin, end: finish, isAllDay: false, location: location))
            }
        } catch {
            return .done(AgentCalendarResult.failure(error, what: "the item"))
        }
    }

    /// Makes the change. The record is nil when nothing changed.
    static func commit(_ plan: AgentCalendarPlan, store: any AgentCalendarStore, clock: AgentClock) async -> (result: String, change: AgentCalendarChange?) {
        do {
            switch plan {
            case .done(let result):
                return (result, nil)
            case .createReminder(let title, let due, let alarm, let list):
                let reminder = try await store.createReminder(title: title, due: due, alarm: alarm, list: list)
                return (AgentToolResult.object(["action": "created", "reminder": AgentCalendarResult.reminder(reminder, clock: clock)]),
                        reminder.modified.map { .init(action: .createdReminder, item: reminder.id, title: reminder.title, before: nil,
                                                      after: $0.timeIntervalSinceReferenceDate) })
            case .completeReminder(let id):
                guard let before = try await store.reminder(id: id) else { throw AgentCalendarFailure.notFound }
                let reminder = try await store.setCompleted(true, reminder: id)
                return (AgentToolResult.object(["action": "completed", "reminder": AgentCalendarResult.reminder(reminder, clock: clock)]),
                        reminder.modified.map { .init(action: .completedReminder, item: id, title: reminder.title,
                                                      before: before.modified?.timeIntervalSinceReferenceDate, after: $0.timeIntervalSinceReferenceDate) })
            case .createEvent(let draft):
                let event = try await store.createEvent(draft)
                return (AgentToolResult.object(["action": "created", "event": AgentCalendarResult.event(event, clock: clock, id: true)]),
                        event.modified.map { .init(action: .createdEvent, item: event.id, title: event.title, before: nil,
                                                   after: $0.timeIntervalSinceReferenceDate) })
            }
        } catch {
            let what = if case .createEvent = plan { "the event" } else { "the reminder" }
            return (AgentCalendarResult.failure(error, what: what), nil)
        }
    }

    /// A list by its name as the person sees it: case and spaces anywhere, full-width ones
    /// included, do not matter, since a spoken name rarely spaces words as the list does. When
    /// that leaves more than one list, the one named exactly so is taken, and without one none is:
    /// the call fails and names every list rather than pick one.
    static func list(named name: String, in lists: [AgentReminderList]) -> AgentReminderList? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = lists.filter { loose($0.title) == loose(wanted) }
        if matches.count == 1 { return matches[0] }
        let exact = matches.filter { $0.title == wanted }
        return exact.count == 1 ? exact[0] : nil
    }

    /// A name without its spaces, in one case.
    private static func loose(_ name: String) -> String {
        String(name.filter { !$0.isWhitespace }).lowercased()
    }

    static func noList(_ name: String, _ lists: [AgentReminderList]) -> String {
        AgentToolResult.failed("there is no reminder list named \(name), so nothing was done; the lists are "
            + lists.map { "\"\($0.title)\"" }.joined(separator: ", "))
    }

    enum UndoOutcome: Sendable, Equatable {
        /// When the item was last modified after the undo; nil for an item the undo removed.
        case undone(modified: TimeInterval?)
        case refused(AgentUndoRefusal)
    }

    /// Takes back one change while the item is still as the change left it.
    static func undo(_ change: AgentCalendarChange, store: any AgentCalendarStore) async -> UndoOutcome {
        switch await store.permission(for: change.kind) {
        case .granted: break
        default: return .refused(change.kind == .reminders ? .noRemindersAccess : .noCalendarAccess)
        }
        do {
            switch change.action {
            case .createdReminder, .completedReminder:
                guard let reminder = try await store.reminder(id: change.item) else { return .refused(.reminderMissing) }
                guard AgentCalendarChange.same(reminder.modified, change.after) else { return .refused(.reminderChanged) }
                if change.action == .createdReminder {
                    try await store.removeReminder(id: change.item)
                    return .undone(modified: nil)
                }
                let reopened = try await store.setCompleted(false, reminder: change.item)
                return .undone(modified: reopened.modified?.timeIntervalSinceReferenceDate)
            case .createdEvent:
                guard let event = try await store.event(id: change.item) else { return .refused(.eventMissing) }
                guard AgentCalendarChange.same(event.modified, change.after) else { return .refused(.eventChanged) }
                try await store.removeEvent(id: change.item)
                return .undone(modified: nil)
            }
        } catch AgentCalendarFailure.notFound {
            return .refused(change.kind == .reminders ? .reminderMissing : .eventMissing)
        } catch {
            return .refused(.failed(AgentCalendarFailure.reason(error)))
        }
    }
}

// MARK: EventKit

/// Lets EventKit objects cross from EventKit's queue to the store's actor, which alone uses them.
private struct Handed<Value>: @unchecked Sendable {
    let value: Value
}

/// The person's reminders and events through one long-lived event store, as Apple recommends: a
/// store made for each call can read an event saved by another store moments before with most of
/// its fields missing. Items are refreshed before they are read, since the store keeps what it read
/// before and another app may have changed it since.
actor EventKitCalendarStore: AgentCalendarStore {
    static let shared = EventKitCalendarStore()

    private var made: EKEventStore?
    /// Made on first use, so a harness that never reaches these tools never touches EventKit.
    private var store: EKEventStore {
        if let made { return made }
        let store = EKEventStore()
        made = store
        return store
    }

    func permission(for kind: AgentCalendarKind) async -> AgentCalendarPermission {
        let type: EKEntityType = kind == .reminders ? .reminder : .event
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        case .restricted: return .restricted
        case .notDetermined: break
        default: return .denied
        }
        let store = Handed(value: store)
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in continuation.resume(returning: granted) }
            if kind == .reminders { store.value.requestFullAccessToReminders(completion: answer) }
            else { store.value.requestFullAccessToEvents(completion: answer) }
        }
        if granted { return .granted }
        return EKEventStore.authorizationStatus(for: type) == .restricted ? .restricted : .denied
    }

    func reminderLists() async throws -> (lists: [AgentReminderList], defaultID: String?) {
        (store.calendars(for: .reminder).map { AgentReminderList(id: $0.calendarIdentifier, title: $0.title) },
         store.defaultCalendarForNewReminders()?.calendarIdentifier)
    }

    func incompleteReminders(in lists: [String]?, dueFrom: Date?, dueTo: Date?) async throws -> [AgentReminder] {
        let calendars = lists.map { ids in store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) } }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: dueFrom, ending: dueTo, calendars: calendars)
        let store = Handed(value: store)
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<Handed<[EKReminder]>, Never>) in
            store.value.fetchReminders(matching: predicate) { continuation.resume(returning: Handed(value: $0 ?? [])) }
        }
        return found.value.filter { $0.refresh() }.map(Self.value)
    }

    func createReminder(title: String, due: DateComponents?, alarm: Date?, list: String?) async throws -> AgentReminder {
        let calendar = try list.map { id in
            guard let calendar = store.calendar(withIdentifier: id) else { throw AgentCalendarFailure.notFound }
            return calendar
        } ?? store.defaultCalendarForNewReminders()
        guard let calendar else { throw AgentCalendarFailure.noDefault }
        guard calendar.allowsContentModifications else { throw AgentCalendarFailure.readOnly(calendar.title) }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        reminder.dueDateComponents = due
        if let alarm { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
        try save(reminder)
        return Self.value(reminder)
    }

    func reminder(id: String) async throws -> AgentReminder? {
        current(id, as: EKReminder.self).map(Self.value)
    }

    func setCompleted(_ completed: Bool, reminder id: String) async throws -> AgentReminder {
        guard let reminder = current(id, as: EKReminder.self) else { throw AgentCalendarFailure.notFound }
        guard reminder.calendar.allowsContentModifications else { throw AgentCalendarFailure.readOnly(reminder.calendar.title) }
        reminder.isCompleted = completed
        try save(reminder)
        return Self.value(reminder)
    }

    func removeReminder(id: String) async throws {
        guard let reminder = current(id, as: EKReminder.self) else { throw AgentCalendarFailure.notFound }
        do { try store.remove(reminder, commit: true) } catch { store.reset(); throw AgentCalendarFailure.failed(error.localizedDescription) }
    }

    func events(from: Date, to: Date) async throws -> [AgentCalendarEvent] {
        store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { $0.refresh() }.map(Self.value)
    }

    func createEvent(_ draft: AgentEventDraft) async throws -> AgentCalendarEvent {
        guard let calendar = store.defaultCalendarForNewEvents else { throw AgentCalendarFailure.noDefault }
        guard calendar.allowsContentModifications else { throw AgentCalendarFailure.readOnly(calendar.title) }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.calendar = calendar
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = draft.end
        event.location = draft.location
        do { try store.save(event, span: .thisEvent, commit: true) } catch { store.reset(); throw AgentCalendarFailure.failed(error.localizedDescription) }
        return Self.value(event)
    }

    func event(id: String) async throws -> AgentCalendarEvent? {
        current(id, as: EKEvent.self).map(Self.value)
    }

    func removeEvent(id: String) async throws {
        guard let event = current(id, as: EKEvent.self) else { throw AgentCalendarFailure.notFound }
        do { try store.remove(event, span: .thisEvent, commit: true) } catch { store.reset(); throw AgentCalendarFailure.failed(error.localizedDescription) }
    }

    /// The item as it is now; nil when it is gone or is not of `type`.
    private func current<Item: EKCalendarItem>(_ id: String, as type: Item.Type) -> Item? {
        guard let item = store.calendarItem(withIdentifier: id) as? Item, item.refresh() else { return nil }
        return item
    }

    private func save(_ reminder: EKReminder) throws {
        // A failed save leaves the change pending in the store; reset drops it.
        do { try store.save(reminder, commit: true) } catch { store.reset(); throw AgentCalendarFailure.failed(error.localizedDescription) }
    }

    private static func value(_ reminder: EKReminder) -> AgentReminder {
        AgentReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", due: reminder.dueDateComponents,
                      listID: reminder.calendar?.calendarIdentifier ?? "", listTitle: reminder.calendar?.title ?? "",
                      isCompleted: reminder.isCompleted, modified: reminder.lastModifiedDate)
    }

    private static func value(_ event: EKEvent) -> AgentCalendarEvent {
        AgentCalendarEvent(id: event.calendarItemIdentifier, title: event.title ?? "", start: event.startDate, end: event.endDate,
                           isAllDay: event.isAllDay, location: event.location, calendarTitle: event.calendar?.title ?? "",
                           modified: event.lastModifiedDate)
    }
}
