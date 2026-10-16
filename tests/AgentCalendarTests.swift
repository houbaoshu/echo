import Foundation
import FoundationModels
import Synchronization
import Testing

/// Reminders and Calendar through the native Agent, on a fake store: no test reads or changes the
/// person's own reminders or events. The clock is fixed, in a time zone of the test's choosing, so
/// no result depends on where or when the tests run.
@MainActor @Suite(.serialized) struct AgentCalendarTests {
    typealias Chat = AgentHarnessTests.Chat

    /// Monday 2026-10-12 20:00 in Shanghai.
    nonisolated static let monday = Date(timeIntervalSince1970: 1_791_806_400)
    nonisolated static let clock = AgentClock(now: { monday }, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    nonisolated static let newYork = AgentClock(now: { monday }, timeZone: TimeZone(identifier: "America/New_York")!)

    static func run(_ chat: Chat, _ text: String = "帮我办") async throws {
        #expect(chat.store.send(text))
        try await chat.idle()
    }

    static func chat(_ calls: [(String, String)], calendar: FakeCalendarStore = FakeCalendarStore(),
                     clock: AgentClock = clock) -> Chat {
        Chat(FinderRootTests.oneByOne(calls), calendar: calendar, clock: clock)
    }

    static func json(_ text: String?) -> [String: Any] {
        (text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
    }

    @discardableResult static func undo(_ chat: Chat, _ index: Int) async throws -> AgentToolRecord.Undo? {
        try await WriteUndoTests.undo(chat, index)
    }

    // MARK: Create, list, complete

    @Test func createListAndCompleteAReminder() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_reminder", #"{"title":"交报告","due":"2026-10-13T10:00:00+08:00","list":"工作"}"#),
            ("list_reminders", #"{"list":"工作"}"#),
            ("complete_reminder", #"{"id":"reminder-1"}"#),
        ], calendar: calendar)
        try await Self.run(chat)

        let created = Self.json(chat.store.tools[0].result)
        #expect(created["action"] as? String == "created")
        let reminder = try #require(created["reminder"] as? [String: Any])
        #expect(reminder["id"] as? String == "reminder-1" && reminder["title"] as? String == "交报告" && reminder["list"] as? String == "工作")
        #expect(reminder["due"] as? String == "2026-10-13T10:00:00+08:00" && reminder["due_weekday"] as? String == "Tuesday")
        let stored = try #require(calendar.reminders.first)
        #expect(stored.due == DateComponents(timeZone: Self.clock.timeZone, year: 2026, month: 10, day: 13, hour: 10, minute: 0))
        #expect(calendar.read(\.alarms)["reminder-1"] == Date(timeIntervalSince1970: 1_791_856_800), "It alerts at the due time")

        let listed = Self.json(chat.store.tools[1].result)
        #expect((listed["reminders"] as? [[String: Any]])?.map { $0["title"] as? String } == ["交报告"])
        #expect(listed["lists"] as? [String] == ["提醒", "工作"] && listed["truncated"] as? Bool == false)

        let completed = Self.json(chat.store.tools[2].result)
        #expect(completed["action"] as? String == "completed" && calendar.reminders.first?.isCompleted == true)
        #expect(chat.store.tools.map(\.state) == [.finished, .finished, .finished])
        #expect(chat.store.tools.map(\.undo) == [.available, nil, .available], "Only changes can be undone")
        #expect(chat.native.calendarChanges.count == 2)
        #expect(calendar.asked == [.reminders, .reminders, .reminders])
        #expect(chat.store.tools.map(\.command) == ["交报告", "工作", ""])
    }

    @Test func remindersWithoutADueDateAndInTheDefaultList() async throws {
        let calendar = FakeCalendarStore()
        calendar.add(reminder: "买牛奶")
        calendar.add(reminder: "旧的", completed: true)
        calendar.add(reminder: "周三交", due: DateComponents(timeZone: Self.clock.timeZone, year: 2026, month: 10, day: 14, hour: 9, minute: 0), list: 1)
        let chat = Self.chat([
            ("create_reminder", #"{"title":"浇花","due":"2026-10-15"}"#),
            ("list_reminders", #"{}"#),
            ("list_reminders", #"{"due_from":"2026-10-14","due_to":"2026-10-14"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        let created = try #require(Self.json(chat.store.tools[0].result)["reminder"] as? [String: Any])
        #expect(created["list"] as? String == "提醒", "The default list")
        #expect(created["due"] as? String == "2026-10-15" && created["due_weekday"] as? String == "Thursday", "A day without a time")
        #expect(calendar.read(\.alarms).isEmpty)
        let all = (Self.json(chat.store.tools[1].result)["reminders"] as? [[String: Any]])?.map { $0["title"] as? String }
        #expect(all == ["周三交", "浇花", "买牛奶"], "Due first, by date; completed ones are left out")
        let wednesday = (Self.json(chat.store.tools[2].result)["reminders"] as? [[String: Any]])?.map { $0["title"] as? String }
        #expect(wednesday == ["周三交"], "A day as the end of the range takes in that whole day")
    }

    @Test func aListThatDoesNotExistSaysWhichDo() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_reminder", #"{"title":"买菜","list":"购物"}"#),
            ("list_reminders", #"{"list":" 工作 "}"#),
            ("list_reminders", #"{"list":"购物"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        let expected = AgentToolResult.failed(#"there is no reminder list named 购物, so nothing was done; the lists are "提醒", "工作""#)
        #expect(chat.store.tools[0].result == expected && chat.store.tools[2].result == expected)
        #expect(calendar.reminders.isEmpty)
        #expect(chat.store.tools.map(\.state) == [.failed, .finished, .finished], "A change that did nothing says so; a read shows as read")
        #expect(chat.store.tools[0].undo == nil)
        #expect(Self.json(chat.store.tools[1].result)["reminders"] != nil, "Names match without surrounding spaces")
    }

    /// A spoken list name rarely spaces words as the list does: spaces anywhere, full-width ones
    /// included, and case do not matter. Names that become the same are not guessed between.
    @Test func listNamesMatchWithoutTheirSpaces() async throws {
        let calendar = FakeCalendarStore(lists: ["提醒", "Echo 测试", "购物 清单"])
        let chat = Self.chat([
            ("create_reminder", #"{"title":"少空格","list":"Echo测试"}"#),
            ("create_reminder", #"{"title":"多空格","list":" echo　 测 试 "}"#),
            ("list_reminders", #"{"list":"购物清单"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        #expect(calendar.reminders.map(\.listTitle) == ["Echo 测试", "Echo 测试"], "Fewer spaces and more, full-width among them")
        #expect(chat.store.tools.map(\.state) == [.finished, .finished, .finished])

        let lists = ["Echo 测试", "echo测试", "工作"].enumerated().map { AgentReminderList(id: "\($0.offset)", title: $0.element) }
        #expect(AgentCalendarRunner.list(named: "Echo  测试", in: lists) == nil, "Two lists are named so without spaces: neither is picked")
        #expect(AgentCalendarRunner.list(named: "Echo 测试", in: lists)?.id == "0", "Unless one is named exactly so")
        let twins = [AgentReminderList(id: "a", title: "工作"), AgentReminderList(id: "b", title: "工作")]
        #expect(AgentCalendarRunner.list(named: "工作", in: twins) == nil, "Two lists with the same name: neither is picked")
        #expect(AgentCalendarRunner.list(named: "工 作", in: [twins[0]])?.id == "a")

        let tied = FakeCalendarStore(lists: ["提醒", "Echo 测试", "echo测试"])
        let refused = Self.chat([("create_reminder", #"{"title":"交报告","list":"ECHO 测 试"}"#)], calendar: tied)
        try await Self.run(refused)
        #expect(refused.store.tools[0].result == AgentToolResult.failed(
            #"there is no reminder list named ECHO 测 试, so nothing was done; the lists are "提醒", "Echo 测试", "echo测试""#))
        #expect(refused.store.tools[0].state == .failed && tied.reminders.isEmpty)
    }

    @Test func completingAReminderThatIsGoneOrDone() async throws {
        let calendar = FakeCalendarStore()
        calendar.add(reminder: "已完成", completed: true)
        let chat = Self.chat([
            ("complete_reminder", #"{"id":"nope"}"#),
            ("complete_reminder", #"{"id":"reminder-1"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        #expect(chat.store.tools[0].result == AgentToolResult.failed("no reminder has the id nope; list_reminders gives the ids of reminders not completed"))
        #expect(chat.store.tools[1].result == AgentToolResult.failed("已完成 is already completed, so nothing was changed"))
        #expect(chat.store.tools.map(\.state) == [.failed, .failed] && chat.native.calendarChanges.isEmpty)
    }

    @Test func createAndListEvents() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_event", #"{"title":"组会","start":"2026-10-14T14:00:00+08:00","location":"三楼会议室"}"#),
            ("create_event", #"{"title":"秋游","start":"2026-10-17","end":"2026-10-18"}"#),
            ("list_events", #"{"from":"2026-10-14","to":"2026-10-18"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        let meeting = try #require(Self.json(chat.store.tools[0].result)["event"] as? [String: Any])
        #expect(meeting["start"] as? String == "2026-10-14T14:00:00+08:00" && meeting["end"] as? String == "2026-10-14T15:00:00+08:00",
                "Without an end it lasts an hour")
        #expect(meeting["start_weekday"] as? String == "Wednesday" && meeting["location"] as? String == "三楼会议室")
        #expect(meeting["calendar"] as? String == "日历" && meeting["all_day"] as? Bool == false && meeting["id"] as? String == "event-1")
        let trip = try #require(Self.json(chat.store.tools[1].result)["event"] as? [String: Any])
        #expect(trip["all_day"] as? Bool == true, "A date alone makes an all-day event")
        #expect(trip["start"] as? String == "2026-10-17" && trip["end"] as? String == "2026-10-18")
        #expect(trip["start_weekday"] as? String == "Saturday" && trip["end_weekday"] as? String == "Sunday")
        let stored = try #require(calendar.events.last)
        #expect(stored.start == Date(timeIntervalSince1970: 1_792_166_400) && stored.isAllDay, "Midnight in Shanghai")
        let listed = Self.json(chat.store.tools[2].result)
        #expect(listed["from"] as? String == "2026-10-14T00:00:00+08:00" && listed["to"] as? String == "2026-10-19T00:00:00+08:00",
                "A day as the end of the range takes in the whole day")
        #expect((listed["events"] as? [[String: Any]])?.map { $0["title"] as? String } == ["组会", "秋游"])
        #expect(chat.store.tools.map(\.undo) == [.available, .available, nil])
    }

    @Test func badTimesAndRangesSayWhatIsWrong() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_reminder", #"{"title":"交报告","due":"2026-10-13T10:00:00"}"#),
            ("create_event", #"{"title":"组会","start":"明天下午"}"#),
            ("create_event", #"{"title":"组会","start":"2026-10-14T14:00:00+08:00","end":"2026-10-14T13:00:00+08:00"}"#),
            ("create_event", #"{"title":"组会","start":"2026-10-14","all_day":false}"#),
            ("list_events", #"{"from":"2026-10-15","to":"2026-10-14T00:00:00+08:00"}"#),
            ("create_reminder", #"{"title":"  "}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        let details = chat.store.tools.map { Self.json($0.result)["detail"] as? String ?? "" }
        #expect(details[0] == "2026-10-13T10:00:00 has no UTC offset; add the person's offset, such as 2026-10-13T10:00:00+08:00")
        #expect(details[1].hasPrefix("明天下午 is not a time; use ISO 8601 with a UTC offset"))
        #expect(details[2] == "end must be after start" && details[3] == "start needs a time unless all_day is true")
        #expect(details[4] == "to must be after from" && details[5] == "title must not be empty")
        #expect(calendar.reminders.isEmpty && calendar.events.isEmpty)
        #expect(calendar.asked == [.events, .events, .events], "Arguments that cannot be read never ask for access")
    }

    // MARK: Time

    /// Times come in with any offset and go out in the person's time zone, with the weekday, also
    /// when the conversion crosses midnight.
    @Test func timesAreConvertedToThePersonsTimeZone() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_reminder", #"{"title":"跨天","due":"2026-10-13T23:30:00-07:00"}"#),
            ("create_event", #"{"title":"UTC","start":"2026-10-12T20:00:00Z","end":"2026-10-12T21:30:00Z"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        let reminder = try #require(Self.json(chat.store.tools[0].result)["reminder"] as? [String: Any])
        #expect(reminder["due"] as? String == "2026-10-14T14:30:00+08:00" && reminder["due_weekday"] as? String == "Wednesday")
        #expect(calendar.reminders.first?.due == DateComponents(timeZone: Self.clock.timeZone, year: 2026, month: 10, day: 14, hour: 14, minute: 30))
        let event = try #require(Self.json(chat.store.tools[1].result)["event"] as? [String: Any])
        #expect(event["start"] as? String == "2026-10-13T04:00:00+08:00" && event["start_weekday"] as? String == "Tuesday")
        #expect(event["end"] as? String == "2026-10-13T05:30:00+08:00")

        // The same moments for someone in New York, where it is still Monday morning.
        let other = FakeCalendarStore()
        let york = Self.chat([("create_event", #"{"title":"UTC","start":"2026-10-12T20:00:00Z"}"#)], calendar: other, clock: Self.newYork)
        try await Self.run(york)
        let there = try #require(Self.json(york.store.tools[0].result)["event"] as? [String: Any])
        #expect(there["start"] as? String == "2026-10-12T16:00:00-04:00" && there["start_weekday"] as? String == "Monday")
    }

    /// An all-day event belongs to its days, not to moments: it reads the same in any time zone,
    /// and a range that touches any of its days finds it.
    @Test func allDayEventsKeepTheirDays() async throws {
        let calendar = FakeCalendarStore()
        let york = AgentClock.newYorkCalendar
        // As EventKit returns one: from the start of its first day to the last second of its last.
        calendar.add(event: "国庆", start: york.date(from: DateComponents(year: 2026, month: 10, day: 12))!,
                     end: york.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 23, minute: 59, second: 59))!, allDay: true)
        let chat = Self.chat([("list_events", #"{"from":"2026-10-13T20:00:00-04:00","to":"2026-10-14"}"#)], calendar: calendar, clock: Self.newYork)
        try await Self.run(chat)
        let event = try #require((Self.json(chat.store.tools[0].result)["events"] as? [[String: Any]])?.first)
        #expect(event["all_day"] as? Bool == true)
        #expect(event["start"] as? String == "2026-10-12" && event["end"] as? String == "2026-10-13" && event["end_weekday"] as? String == "Tuesday")
    }

    @Test func parsingTimes() {
        let ten = AgentTime.instant(Date(timeIntervalSince1970: 1_791_856_800))
        #expect((try? AgentTime.parse("2026-10-13").get()) == .day(year: 2026, month: 10, day: 13))
        #expect((try? AgentTime.parse("2026-10-13T10:00+08:00").get()) == ten)
        #expect((try? AgentTime.parse(" 2026-10-13T02:00:00Z ").get()) == ten)
        #expect((try? AgentTime.parse("2026-10-13T10:00:00+0800").get()) == ten)
        #expect((try? AgentTime.parse("2026-10-13T02:00:00.500Z").get()) == .instant(Date(timeIntervalSince1970: 1_791_856_800.5)))
        // Digits of other scripts are refused, not read: fullwidth in each part, and Arabic-Indic.
        for bad in ["2026-02-30", "2026-10-13T25:00:00+08:00", "2026-13-01", "tomorrow", "2026-10-13T10:00:00+19:00",
                    "２０２６-１０-１３", "2026-10-13T１０:00:00+08:00", "2026-10-13T10:00:00+０８:００",
                    "2026-10-13T10:00:00.５００+08:00", "٢٠٢٦-١٠-١٣"] {
            #expect(throws: AgentInvalidArguments.self, "\(bad)") { try AgentTime.parse(bad).get() }
        }
        #expect(AgentTimeText.now(Self.clock) == "Monday 2026-10-12 20:00 (Asia/Shanghai, UTC+08:00)")
        #expect(AgentTimeText.now(Self.newYork) == "Monday 2026-10-12 08:00 (America/New_York, UTC-04:00)")
    }

    static func instructions(_ request: LanguageModelExecutorGenerationRequest) -> String? {
        guard case .instructions(let instructions)? = request.transcript.first else { return nil }
        return AgentHarness.text(instructions.segments)
    }

    /// The instructions say what the time line on each message is, and describe the tools.
    @Test func instructionsExplainTheTimeLineAndTheTools() async throws {
        let chat = Self.chat([])
        try await Self.run(chat, "现在几点")
        let request = try #require(chat.model.requests.first)
        let text = try #require(Self.instructions(request))
        #expect(text.contains(#"Each message from the person starts with a line from Echo, "[Echo: sent …]", giving the person's local date, weekday, time and time zone"#))
        #expect(!text.contains(AgentTimeText.now(Self.clock)) && !text.contains("Monday"), "No time in the instructions")
        let paragraph = try #require(text.components(separatedBy: "\n\n").first { $0.contains("create_reminder") })
        #expect(paragraph.hasPrefix("list_reminders, create_reminder and complete_reminder work with the person's Reminders"))
        #expect(paragraph.contains("A title names the thing to do or the event alone; its date, time, place and list each have their own argument."))
        for word in ["must", "never", "always", "Never", "Always", "Do not", "do not", "should", "only when", "reply", "answer"] {
            #expect(!paragraph.contains(word), "The paragraph states facts, not orders: \(word)")
        }
        let tools = request.enabledToolDefinitions.map(\.name)
        #expect(Set(["list_reminders", "create_reminder", "complete_reminder", "list_events", "create_event"]).isSubset(of: tools))
    }

    // MARK: Time on each message

    /// Each message carries the time it reached the model, saved with it: the instructions are
    /// the same in every request, and the history is resent exactly as it was first sent, so a
    /// service's prompt cache keeps matching. The chat shows what the person wrote.
    @Test func eachMessageCarriesItsTimeAndTheHistoryNeverChanges() async throws {
        // A clock that moves on a minute every time it is read: a time worked out again would differ.
        let minutes = Mutex(0)
        let clock = AgentClock(now: { Self.monday.addingTimeInterval(60 * Double(minutes.withLock { $0 += 1; return $0 - 1 })) },
                               timeZone: Self.clock.timeZone)
        let chat = Chat({ _, emit, index in
            if index == 1 { await emit.call("list_reminders", #"{}"#, id: "r") } else { try await emit.text("好的 \(index)") }
        }, calendar: FakeCalendarStore(), clock: clock)
        try await Self.run(chat, "第一句")
        try await Self.run(chat, "第二句")
        try await Self.run(chat, "第三句")
        let requests = chat.model.requests
        #expect(requests.count == 4)
        let instructions = requests.map(Self.instructions)
        #expect(Set(instructions).count == 1 && instructions[0] != nil, "The instructions are the same in every request")
        let first = try #require(requests[0].promptTexts.first)
        #expect(first == "[Echo: sent Monday 2026-10-12 20:00 (Asia/Shanghai, UTC+08:00)]\n\n第一句")
        for (index, request) in requests.enumerated() {
            let earlier = requests[..<index].last.map { Array($0.transcript.dropFirst()) } ?? []
            let now = Array(request.transcript.dropFirst())
            #expect(Array(now.prefix(earlier.count)) == earlier, "Request \(index) resends the history exactly as before")
        }
        #expect(requests[3].promptTexts == [first, "[Echo: sent Monday 2026-10-12 20:01 (Asia/Shanghai, UTC+08:00)]\n\n第二句",
                                            "[Echo: sent Monday 2026-10-12 20:02 (Asia/Shanghai, UTC+08:00)]\n\n第三句"])
        #expect(chat.userTexts == ["第一句", "第二句", "第三句"], "The chat shows what the person wrote")
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        #expect(saved.native?.entries.compactMap { entry -> String? in
            if case .prompt(let prompt) = entry { AgentHarness.text(prompt.segments) } else { nil }
        } == requests[3].promptTexts, "The time line is saved with the message")
    }

    /// A follow-up sent while a turn runs carries its own time, before any notice.
    @Test func aFollowUpCarriesItsTimeToo() async throws {
        let gate = AsyncGate()
        let chat = Chat({ _, emit, index in
            if index == 0 { await gate.wait(); try await emit.text("先回一句") } else { try await emit.text("好的") }
        }, calendar: FakeCalendarStore(), clock: Self.clock)
        #expect(chat.store.send("第一句"))
        try await eventually("first request") { chat.model.requests.count == 1 }
        #expect(chat.store.send("插一句"))
        gate.open()
        try await chat.idle()
        let texts = try #require(chat.model.requests.last).promptTexts
        #expect(texts.last == "[Echo: sent Monday 2026-10-12 20:00 (Asia/Shanghai, UTC+08:00)]\n\n插一句")
        #expect(chat.userTexts == ["第一句", "插一句"])
    }

    // MARK: Access

    @Test func deniedAccessSaysWhereToTurnItOn() async throws {
        let calendar = FakeCalendarStore(permissions: [.reminders: .denied, .events: .restricted])
        let chat = Self.chat([
            ("create_reminder", #"{"title":"交报告"}"#),
            ("list_reminders", #"{}"#),
            ("create_event", #"{"title":"组会","start":"2026-10-14T14:00:00+08:00"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        let reminders = AgentToolResult.failed("Echo has no access to Reminders, so nothing was read or changed. The person can turn it on in System Settings > Privacy & Security > Reminders (系统设置 > 隐私与安全性 > 提醒事项).")
        #expect(chat.store.tools[0].result == reminders && chat.store.tools[1].result == reminders)
        #expect(chat.store.tools[2].result == AgentToolResult.failed("Access to Calendars is restricted on this Mac, for example by a configuration profile, so nothing was read or changed."))
        #expect(chat.store.tools.map(\.state) == [.failed, .failed, .failed], "Reads without access failed too")
        #expect(calendar.reminders.isEmpty && calendar.events.isEmpty)
        // The card says it in the person's language; the model keeps its own words.
        let cards = chat.store.tools.map { AgentCalendarCard(tool: $0).lines }
        #expect(cards[0] == ["Echo 没有提醒事项的访问权限。可以在“系统设置 > 隐私与安全性 > 提醒事项”里打开。"] && cards[1] == cards[0])
        #expect(cards[2] == ["这台 Mac 限制了对日历的访问，例如由配置描述文件限制。"])
        #expect(AgentCalendarCard(tool: chat.store.tools[1]).title == "失败 · 查看提醒事项")
        #expect(AgentCalendarCard.missingAccess(.events, .writeOnly) == "Echo 只能添加日程，不能读取。可以在“系统设置 > 隐私与安全性 > 日历”里改为完全访问。")
        #expect(AgentCalendarCard.missingAccess(.events, .denied) == "Echo 没有日历的访问权限。可以在“系统设置 > 隐私与安全性 > 日历”里打开。")
        // Other failures are not mistaken for missing access.
        #expect(AgentCalendarResult.missingAccess(AgentToolResult.failed("title must not be empty")) == nil)
        #expect(AgentToolRecord.state(forResult: AgentToolResult.failed("to must be after from"), tool: "list_events") == .finished)
        #expect(AgentCalendarResult.denied(.events, .writeOnly).contains("System Settings > Privacy & Security > Calendars (系统设置 > 隐私与安全性 > 日历)"))
    }

    /// While the system's access prompt waits for the person, Stop ends the call at once and
    /// nothing is made, even when the person allows access afterwards.
    @Test func stopWhileTheAccessPromptWaits() async throws {
        let gate = AsyncGate()
        let calendar = FakeCalendarStore(prompt: { await gate.wait() })
        let chat = Self.chat([("create_reminder", #"{"title":"交报告"}"#)], calendar: calendar)
        #expect(chat.store.send("提醒我"))
        try await eventually("asks for access") { calendar.asked == [.reminders] }
        chat.store.stopTask()
        try await chat.idle()
        #expect(chat.store.task?.status == .stopped)
        #expect(chat.store.tools.first?.state == .notExecuted && chat.store.tools.first?.result == AgentToolResult.cancelledBefore)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calendar.reminders.isEmpty, "An answer after the Stop makes nothing")
    }

    /// Input sent while the prompt waits supersedes the call, which returns at once; the turn goes on.
    @Test func followUpWhileTheAccessPromptWaits() async throws {
        let gate = AsyncGate()
        let calendar = FakeCalendarStore(prompt: { await gate.wait() })
        let chat = Chat({ _, emit, index in
            if index == 0 { await emit.call("create_reminder", #"{"title":"交报告"}"#, id: "c") } else { try await emit.text("好的") }
        }, calendar: calendar, clock: Self.clock)
        #expect(chat.store.send("提醒我"))
        try await eventually("asks for access") { calendar.asked == [.reminders] }
        #expect(chat.store.send("算了"))
        try await chat.idle()
        #expect(chat.store.tools.first?.result == AgentToolResult.superseded)
        #expect(chat.assistantTexts.last == "好的")
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calendar.reminders.isEmpty)
    }

    // MARK: Undo

    @Test func undoRemovesWhatWasMadeAndReopensWhatWasCompleted() async throws {
        let calendar = FakeCalendarStore()
        let mine = calendar.add(reminder: "已有的")
        let chat = Self.chat([
            ("create_reminder", #"{"title":"交报告","due":"2026-10-13T10:00:00+08:00"}"#),
            ("complete_reminder", #"{"id":"\#(mine)"}"#),
            ("create_event", #"{"title":"组会","start":"2026-10-14T14:00:00+08:00"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        var refreshes = 0
        chat.store.onFilesChanged = { refreshes += 1 }
        #expect(chat.store.tools.allSatisfy { chat.store.offersUndo($0) && chat.store.canUndo($0) })
        let before = chat.store.tools.compactMap(\.result)

        #expect(try await Self.undo(chat, 0) == .undone && calendar.reminders.map(\.title) == ["已有的"])
        #expect(try await Self.undo(chat, 1) == .undone && calendar.reminders.first?.isCompleted == false)
        #expect(try await Self.undo(chat, 2) == .undone && calendar.events.isEmpty)
        #expect(refreshes == 0, "No file changed")
        #expect(chat.store.tools.allSatisfy { !chat.store.offersUndo($0) })
        #expect(chat.native.calendarChanges.isEmpty)

        try await FinderRootTests.run(chat, "现在呢？")
        let outputs = try #require(chat.model.requests.last).toolOutputs
        #expect(outputs == zip(before, ["create_reminder", "complete_reminder", "create_event"]).map { AgentToolResult.undone($0, tool: $1) })
        let notes = outputs.map { Self.json($0)["undone"] as? String ?? "" }
        #expect(notes[0].contains("the reminder it created was deleted") && notes[1].contains("no longer marked as completed")
                && notes[2].contains("the event it created was deleted"))
        let notice = AgentToolResult.undoNotice([
            #"Reminder "交报告": the reminder your create_reminder call created was deleted."#,
            #"Reminder "已有的": no longer marked as completed by your complete_reminder call."#,
            #"Event "组会": the event your create_event call created was deleted."#,
        ])
        #expect(try #require(chat.model.requests.last).userTexts.last == notice + "现在呢？")
    }

    /// A reminder or event changed or removed since Echo's change is left as it is; the card says why.
    @Test func somethingChangedSinceIsLeftAlone() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_reminder", #"{"title":"改过的"}"#),
            ("create_reminder", #"{"title":"删掉的"}"#),
            ("create_event", #"{"title":"改过的日程","start":"2026-10-14T14:00:00+08:00"}"#),
            ("create_event", #"{"title":"删掉的日程","start":"2026-10-15T14:00:00+08:00"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        calendar.touch("reminder-1"); calendar.delete("reminder-2"); calendar.touch("event-3"); calendar.delete("event-4")
        var outcomes: [AgentToolRecord.Undo?] = []
        for index in chat.store.tools.indices { outcomes.append(try await Self.undo(chat, index)) }
        #expect(outcomes == [.refused(.reminderChanged), .refused(.reminderMissing), .refused(.eventChanged), .refused(.eventMissing)])
        #expect(calendar.reminders.map(\.title) == ["改过的（改）"] && calendar.events.map(\.title) == ["改过的日程（改）"])
        #expect(chat.store.tools.allSatisfy { chat.store.offersUndo($0) && $0.result.map(AgentToolResult.isUndone) == false },
                "The button stays, and the model is told nothing")
        #expect(chat.native.undoNotices.isEmpty)
        #expect(AgentUndoRefusal.reminderChanged.message == "这条提醒事项后来又被改过，没有撤销。")
        #expect(AgentUndoRefusal.eventMissing.message == "这个日程已经不在了，没有撤销。")
    }

    /// A reminder completed again by the person after Echo completed it is left as it is.
    @Test func aCompletionTouchedSinceIsLeftAlone() async throws {
        let calendar = FakeCalendarStore()
        let mine = calendar.add(reminder: "交报告")
        let chat = Self.chat([("complete_reminder", #"{"id":"\#(mine)"}"#)], calendar: calendar)
        try await Self.run(chat)
        _ = try await calendar.setCompleted(false, reminder: mine)
        _ = try await calendar.setCompleted(true, reminder: mine)
        #expect(try await Self.undo(chat, 0) == .refused(.reminderChanged) && calendar.reminders.first?.isCompleted == true)
    }

    /// Echo's own changes to one reminder come off from the latest back.
    @Test func onlyTheLatestChangeComesOff() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([
            ("create_reminder", #"{"title":"交报告"}"#),
            ("complete_reminder", #"{"id":"reminder-1"}"#),
        ], calendar: calendar)
        try await Self.run(chat)
        #expect(try await Self.undo(chat, 0) == .refused(.reminderChanged) && calendar.reminders.count == 1)
        #expect(try await Self.undo(chat, 1) == .undone && calendar.reminders.first?.isCompleted == false)
        #expect(try await Self.undo(chat, 0) == .undone && calendar.reminders.isEmpty)
    }

    /// Without access any more, nothing is undone, and the card says why.
    @Test func undoWithoutAccess() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([("create_event", #"{"title":"组会","start":"2026-10-14T14:00:00+08:00"}"#)], calendar: calendar)
        try await Self.run(chat)
        calendar.change { $0.permissions[.events] = .denied }
        #expect(try await Self.undo(chat, 0) == .refused(.noCalendarAccess) && calendar.events.count == 1)
        #expect(AgentUndoRefusal.noCalendarAccess.message == "Echo 没有日历的访问权限，没有撤销。")
    }

    /// What an undo needs is saved with the chat: a reopened chat undoes the change.
    @Test func undoAfterReopening() async throws {
        let calendar = FakeCalendarStore()
        let chat = Self.chat([("create_reminder", #"{"title":"交报告"}"#)], calendar: calendar)
        try await Self.run(chat)
        let saved = try JSONDecoder().decode(TaskStore.Snapshot.self, from: JSONEncoder().encode(chat.store.snapshot))
        #expect(saved.native?.calendarChanges.values.first?.after == FakeCalendarStore.firstModified.timeIntervalSinceReferenceDate,
                "The modification date survives to the millisecond and below")
        let reopened = Chat({ _, emit, _ in try await emit.text("ok") }, snapshot: saved, calendar: calendar, clock: Self.clock)
        #expect(reopened.store.tools.map(\.undo) == [.available])
        #expect(try await Self.undo(reopened, 0) == .undone && calendar.reminders.isEmpty)
        #expect(reopened.native.undoNotices.count == 1)
    }

    /// A reminder call that runs after a change in its batch sees the change.
    @Test func callsInABatchRunInTheirOrder() async throws {
        let calendar = FakeCalendarStore()
        let chat = Chat({ _, emit, index in
            if index == 0 {
                await emit.calls([("create_reminder", #"{"title":"一"}"#, "a"), ("list_reminders", #"{}"#, "b"),
                                  ("create_reminder", #"{"title":"二"}"#, "c"), ("list_reminders", #"{}"#, "d")])
            } else { try await emit.text("done") }
        }, calendar: calendar, clock: Self.clock)
        try await Self.run(chat)
        let counts = [1, 3].map { (Self.json(chat.store.tools[$0].result)["reminders"] as? [Any])?.count }
        #expect(counts == [1, 2])
    }
}

extension AgentClock {
    static var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
}
