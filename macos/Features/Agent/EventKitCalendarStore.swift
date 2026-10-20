import EventKit
import Foundation

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
        try committing { try store.save(reminder, commit: true) }
        return Self.value(reminder)
    }

    func reminder(id: String) async throws -> AgentReminder? {
        current(id, as: EKReminder.self).map(Self.value)
    }

    func setCompleted(_ completed: Bool, reminder id: String) async throws -> AgentReminder {
        guard let reminder = current(id, as: EKReminder.self) else { throw AgentCalendarFailure.notFound }
        guard reminder.calendar.allowsContentModifications else { throw AgentCalendarFailure.readOnly(reminder.calendar.title) }
        reminder.isCompleted = completed
        try committing { try store.save(reminder, commit: true) }
        return Self.value(reminder)
    }

    func removeReminder(id: String) async throws {
        guard let reminder = current(id, as: EKReminder.self) else { throw AgentCalendarFailure.notFound }
        try committing { try store.remove(reminder, commit: true) }
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
        try committing { try store.save(event, span: .thisEvent, commit: true) }
        return Self.value(event)
    }

    func event(id: String) async throws -> AgentCalendarEvent? {
        current(id, as: EKEvent.self).map(Self.value)
    }

    func removeEvent(id: String) async throws {
        guard let event = current(id, as: EKEvent.self) else { throw AgentCalendarFailure.notFound }
        try committing { try store.remove(event, span: .thisEvent, commit: true) }
    }

    /// The item as it is now; nil when it is gone or is not of `type`.
    private func current<Item: EKCalendarItem>(_ id: String, as type: Item.Type) -> Item? {
        guard let item = store.calendarItem(withIdentifier: id) as? Item, item.refresh() else { return nil }
        return item
    }

    /// Makes one change and commits it. A change that fails stays pending in the store; reset drops it.
    private func committing(_ change: () throws -> Void) throws {
        do { try change() } catch { store.reset(); throw AgentCalendarFailure.failed(error.localizedDescription) }
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
