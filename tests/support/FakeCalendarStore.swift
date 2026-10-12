import Foundation
import Synchronization

/// Stands in for Reminders and Calendar, so no test reads or changes the person's own. Every
/// save moves the item's modification date on by a second, as EventKit moves it on every change.
final class FakeCalendarStore: AgentCalendarStore, Sendable {
    struct Contents {
        var permissions: [AgentCalendarKind: AgentCalendarPermission]
        var lists: [AgentReminderList]
        var defaultList: String?
        var reminders: [AgentReminder] = []
        var alarms: [String: Date] = [:]
        var events: [AgentCalendarEvent] = []
        var defaultCalendar: String? = "日历"
        /// Every permission asked for, in order.
        var asked: [AgentCalendarKind] = []
        var nextID = 1
        var tick = 0
    }
    private let contents: Mutex<Contents>
    /// Holds each permission request until opened, as the system's access prompt does.
    private let prompt: (@Sendable () async -> Void)?
    /// When the first save happened; later ones count up from it.
    static let firstModified = Date(timeIntervalSinceReferenceDate: 813_500_000.123)

    init(permissions: [AgentCalendarKind: AgentCalendarPermission] = [.reminders: .granted, .events: .granted],
         lists: [String] = ["提醒", "工作"], prompt: (@Sendable () async -> Void)? = nil) {
        let lists = lists.enumerated().map { AgentReminderList(id: "list-\($0.offset)", title: $0.element) }
        contents = Mutex(Contents(permissions: permissions, lists: lists, defaultList: lists.first?.id))
        self.prompt = prompt
    }

    func read<T>(_ body: (Contents) -> T) -> T { contents.withLock { body($0) } }
    func change(_ body: (inout Contents) -> Void) { contents.withLock { body(&$0) } }
    var reminders: [AgentReminder] { read(\.reminders) }
    var events: [AgentCalendarEvent] { read(\.events) }
    var asked: [AgentCalendarKind] { read(\.asked) }

    /// Someone else edits a reminder or event: its modification date moves on.
    func touch(_ id: String) {
        change { c in
            let stamp = Self.stamp(&c)
            if let i = c.reminders.firstIndex(where: { $0.id == id }) { c.reminders[i].modified = stamp; c.reminders[i].title += "（改）" }
            if let i = c.events.firstIndex(where: { $0.id == id }) { c.events[i].modified = stamp; c.events[i].title += "（改）" }
        }
    }
    func delete(_ id: String) {
        change { c in c.reminders.removeAll { $0.id == id }; c.events.removeAll { $0.id == id } }
    }
    /// Adds a reminder as if the person made it in Reminders. Returns its id.
    @discardableResult func add(reminder title: String, due: DateComponents? = nil, list: Int = 0, completed: Bool = false) -> String {
        var id = ""
        change { c in
            id = Self.id(&c, "reminder")
            c.reminders.append(.init(id: id, title: title, due: due, listID: c.lists[list].id, listTitle: c.lists[list].title,
                                     isCompleted: completed, modified: Self.stamp(&c)))
        }
        return id
    }
    @discardableResult func add(event title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil,
                                calendar: String = "家庭") -> String {
        var id = ""
        change { c in
            id = Self.id(&c, "event")
            c.events.append(.init(id: id, title: title, start: start, end: end, isAllDay: allDay, location: location,
                                  calendarTitle: calendar, modified: Self.stamp(&c)))
        }
        return id
    }

    private static func stamp(_ c: inout Contents) -> Date {
        defer { c.tick += 1 }
        return firstModified.addingTimeInterval(TimeInterval(c.tick))
    }
    private static func id(_ c: inout Contents, _ kind: String) -> String {
        defer { c.nextID += 1 }
        return "\(kind)-\(c.nextID)"
    }

    func permission(for kind: AgentCalendarKind) async -> AgentCalendarPermission {
        change { $0.asked.append(kind) }
        if let prompt { await prompt() }
        return read { $0.permissions[kind] ?? .denied }
    }

    func reminderLists() async throws -> (lists: [AgentReminderList], defaultID: String?) {
        read { ($0.lists, $0.defaultList) }
    }

    func incompleteReminders(in lists: [String]?, dueFrom: Date?, dueTo: Date?) async throws -> [AgentReminder] {
        read { c in
            c.reminders.filter { reminder in
                guard !reminder.isCompleted, lists?.contains(reminder.listID) ?? true else { return false }
                guard dueFrom != nil || dueTo != nil else { return true }
                guard let due = reminder.due else { return false }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = due.timeZone ?? TimeZone(identifier: "Asia/Shanghai")!
                let date = calendar.date(from: DateComponents(year: due.year, month: due.month, day: due.day, hour: due.hour ?? 0, minute: due.minute ?? 0))!
                return (dueFrom.map { date >= $0 } ?? true) && (dueTo.map { date < $0 } ?? true)
            }
        }
    }

    func createReminder(title: String, due: DateComponents?, alarm: Date?, list: String?) async throws -> AgentReminder {
        try contents.withLock { c in
            guard let listID = list ?? c.defaultList, let found = c.lists.first(where: { $0.id == listID }) else { throw AgentCalendarFailure.noDefault }
            let reminder = AgentReminder(id: Self.id(&c, "reminder"), title: title, due: due, listID: found.id, listTitle: found.title,
                                         isCompleted: false, modified: Self.stamp(&c))
            c.reminders.append(reminder)
            if let alarm { c.alarms[reminder.id] = alarm }
            return reminder
        }
    }

    func reminder(id: String) async throws -> AgentReminder? {
        read { $0.reminders.first { $0.id == id } }
    }

    func setCompleted(_ completed: Bool, reminder id: String) async throws -> AgentReminder {
        try contents.withLock { c in
            guard let index = c.reminders.firstIndex(where: { $0.id == id }) else { throw AgentCalendarFailure.notFound }
            c.reminders[index].isCompleted = completed
            c.reminders[index].modified = Self.stamp(&c)
            return c.reminders[index]
        }
    }

    func removeReminder(id: String) async throws {
        try contents.withLock { c in
            guard c.reminders.contains(where: { $0.id == id }) else { throw AgentCalendarFailure.notFound }
            c.reminders.removeAll { $0.id == id }
        }
    }

    func events(from: Date, to: Date) async throws -> [AgentCalendarEvent] {
        read { c in c.events.filter { $0.start < to && $0.end > from } }
    }

    func createEvent(_ draft: AgentEventDraft) async throws -> AgentCalendarEvent {
        try contents.withLock { c in
            guard let calendar = c.defaultCalendar else { throw AgentCalendarFailure.noDefault }
            // As EventKit keeps an all-day event: to the last second of its last day.
            let end = draft.isAllDay ? draft.end.addingTimeInterval(86_399) : draft.end
            let event = AgentCalendarEvent(id: Self.id(&c, "event"), title: draft.title, start: draft.start, end: end, isAllDay: draft.isAllDay,
                                           location: draft.location, calendarTitle: calendar, modified: Self.stamp(&c))
            c.events.append(event)
            return event
        }
    }

    func event(id: String) async throws -> AgentCalendarEvent? {
        read { $0.events.first { $0.id == id } }
    }

    func removeEvent(id: String) async throws {
        try contents.withLock { c in
            guard c.events.contains(where: { $0.id == id }) else { throw AgentCalendarFailure.notFound }
            c.events.removeAll { $0.id == id }
        }
    }
}
