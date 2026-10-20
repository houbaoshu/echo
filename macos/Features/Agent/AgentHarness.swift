import Foundation
import FoundationModels
import Synchronization

// The native Agent engine. Foundation Models runs the model and the tool loop inside each
// `respond`; this harness coordinates turns around it: one `respond` at a time, Stop, continue,
// input that arrives while a turn runs, bounded recovery from invalid model output, the
// 30-request limit, persistence gates, and the projection into `TaskStore`'s messages and tools.
//
// A new `LanguageModelSession` is built for every `respond` from the history the harness holds
// (the transcript without instructions), so settings snapshotted at turn start stay fixed for
// the turn, and the harness can amend the transcript between calls without touching a session
// that is still unwinding.

/// How a turn ended, for the conversation that owns it.
enum AgentTurnEnding: Equatable {
    case completed(reply: UUID, text: String)
    /// `reply` is set when the final reply completed before the Stop took effect.
    case stopped(reply: UUID?)
    /// `notice` also shows the error beside the composer, as for settings that cannot start a turn.
    case failed(String, notice: Bool)
}

/// The conversation a harness works for. `TaskStore` implements it.
@MainActor protocol AgentHarnessHost: AnyObject {
    var harnessMessages: [ConversationMessage] { get }
    var harnessTools: [AgentToolRecord] { get }
    func harnessProject(messages: [ConversationMessage], tools: [AgentToolRecord])
    /// Streams into the conversation's `AssistantReplyStream`; `final` settles the operation.
    func harnessStream(operation: UInt64, text: String, toolCall: Bool, final: Bool)
    func harnessStatus(_ summary: String)
    func harnessProjectDirectory() -> AgentProjectRoot
    /// Where this conversation keeps copies of the files its write tools replace; nil keeps none,
    /// so no existing file is replaced.
    func harnessBackupDirectory() -> URL?
    var harnessChatID: UUID { get }
    /// Saves the whole conversation, the harness state included. Throws the user-facing failure.
    func harnessSave() throws
    func harnessFinish(_ ending: AgentTurnEnding)
}

/// Prompt metadata the harness writes. Adapters act only on `AgentPromptMarker.continueKey`.
enum AgentPromptKey {
    /// The user message a prompt came from.
    static let message = "echo.message"
    /// Feedback about invalid model output: sent to the model, never shown.
    static let feedback = "echo.feedback"
}

/// Resumes a continuation once, whichever of its callers comes first, even one that comes before
/// the continuation is set; later ones are ignored.
final class ResumeOnce<T: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<T, any Error>?, early: Result<T, any Error>?)>((nil, nil))
    func set(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state in
            if state.early == nil { state.continuation = continuation }
            return state.early
        }
        if let early { continuation.resume(with: early) }
    }
    func resume(returning value: T) { resume(with: .success(value)) }
    func resume(throwing error: any Error) { resume(with: .failure(error)) }
    func resume(with result: Result<T, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
            if let continuation = state.continuation { state.continuation = nil; state.early = result; return continuation }
            if state.early == nil { state.early = result }
            return nil
        }
        continuation?.resume(with: result)
    }
}

@MainActor final class AgentHarness {
    /// Builds the model for one `respond`. Every executor must call `budget.spend()` before a
    /// request and record finished entries in `ledger`; `EchoLanguageModel` does both.
    typealias ModelFactory = @Sendable (GenerationLedger, GenerationBudget) -> any LanguageModel

    static let generationLimit = 30
    static let formatErrorLimit = 3
    static var stepLimitMessage: String { String(localized: "已达到本轮 \(generationLimit) 次模型请求限制。") }
    static var formatErrorMessage: String { String(localized: "模型连续返回无效工具格式，已停止。") }
    static var offlineAfterOutputMessage: String { String(localized: "网络已断开，本轮已有输出或执行过工具，未自动改用本地模型。联网后点“继续处理”。") }

    weak var host: (any AgentHarnessHost)?
    private(set) var state = NativeAgentState()
    private let resolveModel: @MainActor () throws -> ModelFactory
    private let local: LocalChatService?
    /// Read when a turn starts: every new turn goes to the local model.
    private let localOnly: @MainActor () -> Bool

    private var turn: Task<Void, Never>?
    private var stopRequested = false
    private let steering = AgentSteeringSignal()
    /// The running `respond`'s prompt, which Foundation Models records only once it returns.
    private var runningPrompt: Transcript.Entry?
    /// Entries of the running `respond` after its prompt, as the latest stream snapshot shows them.
    private var live: [Transcript.Entry] = []
    /// What the running `respond` wrote up to its last saved tool result; a crash restores this.
    private var checkpointed: [Transcript.Entry] = []
    /// Calls are keyed "entry index:call ID": providers reuse call IDs across generations.
    /// Calls Foundation Models dispatched whose output is not in yet.
    private var dispatched: Set<String> = []
    /// Each call by the identity its arguments carry: tools are not told their call, and calls with
    /// identical arguments still carry different identities.
    private var callKeys: [GenerationID: String] = [:]
    /// The folder each call read or found, for its card.
    private var callDirectories: [String: String] = [:]
    /// Results of write calls that finished. Foundation Models writes a batch's results only once
    /// every call in it is done; until then, and after a Stop, these are the real results.
    private var finishedOutputs: [String: String] = [:]
    private let writePolicy: AgentWritePolicy
    private let writeHooks: AgentWriteHooks
    private let attachmentHooks: AgentAttachmentHooks
    private let trash: AgentTrash
    private let calendarStore: any AgentCalendarStore
    /// The person's clock: for the time each message carries, and the time zone of the calendar tools.
    private let clock: AgentClock
    private let opener: any AgentOpener
    /// Read when a turn starts: the searcher web_search uses, when whoever chats has one.
    private let webSearch: @MainActor () -> AgentWebSearcher?
    /// The running turn's searcher; nil offers no web_search.
    private var searcher: AgentWebSearcher?
    /// Reads pages for web_fetch, which every turn with tools offers.
    private let fetcher: any AgentWebFetching
    /// Read when a turn starts: the generator generate_image uses, when the Volcengine Ark key is saved.
    private let imageGeneration: @MainActor () -> ArkImageGenerator?
    /// The running turn's generator; nil offers no generate_image.
    private var imageGenerator: ArkImageGenerator?
    /// Where generated images go unless the person asks for the chat's folder.
    private let picturesFolder: URL
    /// The file of what the person asked the Agent to remember; nil offers no memory tools and gives
    /// no memory. Undo finds the memory's changes by it whether or not the memory is in use.
    private let memory: AgentMemoryFile?
    /// Read when a turn starts: whether the person has the memory in use.
    private let memoryEnabled: @MainActor () -> Bool
    /// The running turn's memory; nil offers no memory tools and gives no memory.
    private var turnMemory: AgentMemoryFile?
    /// Write calls this turn that left a record their card can undo from.
    private var undoableCalls: Set<String> = []
    /// Undos under way. A turn must not start meanwhile: an undo amends the transcript when it ends.
    private(set) var undoing = 0
    /// Writes whose change is under way, and the turn waiting for them to end before it settles.
    private var writesInFlight = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Calls waiting on work off the main actor, such as a write reading its original; a Stop or
    /// newer input ends their wait.
    private var pendingPrepares: [UUID: @Sendable (any Error) -> Void] = [:]
    /// Counts turns, so a call that outlived its turn does nothing in the next.
    private var turnSerial = 0
    private var operations: [String: UInt64] = [:]
    private var nextOperation: UInt64 = 0
    private let finder: any FinderLocating
    /// finder_location calls waiting for Finder. Nil answers a superseded call.
    private var finderWaiters: [UUID: CheckedContinuation<FinderLocation?, any Error>] = [:]
    /// The Finder lookup under way, which every caller asking at the same time shares.
    private var finderLookup: Task<FinderLocation, Never>?
    /// Each batch's calls in the order the model wrote them, and the calls that are done. A batch
    /// runs as if its calls ran in the order written; `waits(_:for:)` says which call waits for which.
    private var batchCalls: [Int: [(key: String, tool: String)]] = [:]
    private var doneCalls: Set<String> = []
    private var turnWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var storageFailure: String?

    init(resolveModel: @escaping @MainActor () throws -> ModelFactory, local: LocalChatService? = nil,
         localOnly: @escaping @MainActor () -> Bool = { false },
         finder: any FinderLocating = AppleEventFinderLocator.shared, writePolicy: AgentWritePolicy = AgentWritePolicy(),
         writeHooks: AgentWriteHooks = AgentWriteHooks(), attachmentHooks: AgentAttachmentHooks = AgentAttachmentHooks(),
         trash: AgentTrash = .system, calendar: any AgentCalendarStore = EventKitCalendarStore.shared, clock: AgentClock = .system,
         opener: any AgentOpener = WorkspaceOpener.shared, webSearch: @escaping @MainActor () -> AgentWebSearcher? = { nil },
         fetcher: any AgentWebFetching = WebPageFetcher(),
         imageGenerator: @escaping @MainActor () -> ArkImageGenerator? = { nil }, picturesFolder: URL = AgentImageFiles.picturesFolder,
         memory: AgentMemoryFile? = nil, memoryEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.resolveModel = resolveModel
        self.local = local
        self.localOnly = localOnly
        self.finder = finder
        self.writePolicy = writePolicy
        self.writeHooks = writeHooks
        self.attachmentHooks = attachmentHooks
        self.trash = trash
        self.calendarStore = calendar
        self.clock = clock
        self.opener = opener
        self.webSearch = webSearch
        self.fetcher = fetcher
        self.imageGeneration = imageGenerator
        self.picturesFolder = picturesFolder
        self.memory = memory
        self.memoryEnabled = memoryEnabled
    }

    /// Reads the model settings saved when each turn starts. `ECHO_LOCAL_CHAT=always` sends every
    /// turn to the local model as the saved switch does, for development.
    convenience init(settings: SettingsStore, local: LocalChatService? = nil) {
        let alwaysLocal = ProcessInfo.processInfo.environment["ECHO_LOCAL_CHAT"] == "always"
        self.init(resolveModel: {
            let (configuration, key) = try settings.savedModelCredentials()
            let endpoint = AgentEndpoint(configuration, key: key)
            let session = AgentTransport.make(for: endpoint)
            return { ledger, budget in EchoLanguageModel(endpoint: endpoint, transport: session, ledger: ledger, budget: budget) }
        }, local: local, localOnly: { alwaysLocal || settings.snapshot.localModelOnly },
                  webSearch: { AgentWebSearcher.searcher(for: settings) }, imageGenerator: { ArkImageGenerator.generator(for: settings) },
                  memory: settings.memoryFile, memoryEnabled: { settings.snapshot.memoryEnabled })
    }

    var isRunning: Bool { turn != nil }
    var continuable: Bool { state.continuable }
    /// What a save records: the running `respond` contributes its prompt and the entries up to its
    /// last saved tool result, never model output that may still be cut off. Write calls that
    /// already finished in a batch Foundation Models has not written back yet contribute their result.
    var persistentState: NativeAgentState {
        guard isRunning, let runningPrompt else { return state }
        var saved = state
        saved.entries = Self.closingDanglingCalls(saved.entries + [runningPrompt] + checkpointed) { [finishedOutputs] index, call in
            finishedOutputs["\(index):\(call.id)"]
        }
        return saved
    }

    // MARK: Commands from the conversation

    /// Adopts saved state. Calls that never got a result had unknown effects, and a turn with no
    /// outcome was interrupted.
    func restore(_ saved: NativeAgentState?) {
        guard let saved else { return }
        state = saved
        state.entries = Self.closingDanglingCalls(state.entries, with: AgentToolResult.unknownAfterInterruption)
        if let last = state.turns.indices.last, state.turns[last].outcome == nil { state.turns[last].outcome = .interrupted }
        project()
    }

    /// Queues user input for the next turn, or for the running one. `attachments` are the paths of
    /// the files sent with it; the chat keeps them once the input reaches the transcript.
    /// Returns the names the files go by in the chat.
    @discardableResult func enqueue(messageID: UUID, text: String, attachments: [String] = []) -> [String] {
        let names = state.names(for: attachments)
        state.pendingInputs.append(.init(messageID: messageID, text: text, attachments: attachments.isEmpty ? nil : attachments,
                                         names: attachments.isEmpty ? nil : names))
        guard isRunning else { return names }
        steering.set(true)
        resumeFinderWaiters(.success(nil))
        interruptPrepares(WriteSuperseded())
        return names
    }

    /// The names the files at `paths` would go by if they were sent now.
    func attachmentNames(for paths: [String]) -> [String] { state.names(for: paths) }

    /// Takes back pending input between turns, so no later turn sends it. Returns what was taken
    /// back, in the order it was queued.
    @discardableResult func withdraw(_ messageIDs: Set<UUID>) -> [NativeAgentState.Input] {
        guard !isRunning else { return [] }
        let withdrawn = state.pendingInputs.filter { messageIDs.contains($0.messageID) }
        state.pendingInputs.removeAll { messageIDs.contains($0.messageID) }
        return withdrawn
    }

    /// Starts a turn with the pending input, or continues the last turn when there is none.
    @discardableResult func begin() -> Bool {
        guard !isRunning, undoing == 0 else { return false }
        stopRequested = false; storageFailure = nil
        steering.set(false)
        turnSerial += 1
        turn = Task { [weak self] in await self?.runTurn() }
        return true
    }

    /// Cancels the running turn. The conversation learns the result from `harnessFinish`.
    func stop() {
        guard isRunning else { return }
        stopRequested = true
        resumeFinderWaiters(.failure(CancellationError()))
        resumeTurnWaiters(.failure(CancellationError()))
        interruptPrepares(CancellationError())
        turn?.cancel()
    }

    /// Undoes the change of the call whose card is `toolID`, between turns, off the main actor. A
    /// write comes off from the call's record only while the file still has what the call wrote; a
    /// reminder or event only while it was not modified since. Once it is undone, the call's result
    /// tells the model so in every later request. Nil when it was undone.
    func undo(toolID: String) async -> AgentUndoRefusal? {
        guard !isRunning, outputIndex(of: toolID) != nil else { return .backupMissing }
        if let change = state.calendarChanges[toolID] { return await undoCalendar(change, toolID: toolID) }
        guard let directory = host?.harnessBackupDirectory() else { return .backupMissing }
        undoing += 1
        defer { undoing -= 1 }
        let policy = writePolicy, trash = trash, memory = memory
        let refusal = await Task.detached { () -> AgentUndoRefusal? in
            guard let (record, folder) = AgentBackupStore(directory: directory).find(toolRecord: toolID) else { return .backupMissing }
            guard record.rootKind == AgentBackupStore.memoryRoot else { return AgentFileUndo.undo(record, copy: folder, policy: policy, trash: trash) }
            let root = memory.flatMap { ProjectPath.canonical($0.folder.path) }
            switch AgentFileUndo.undo(record, copy: folder, policy: policy, memory: root, trash: trash) {
            case nil: return nil
            // What the memory holds is all the person sees of it: whatever else changed, it changed.
            case .changed?, .missing?, .symbolicLink?, .notFile?: return .memoryChanged
            case let other?: return other
            }
        }.value
        guard refusal == nil else { return refusal }
        noteUndone(toolID: toolID)
        return nil
    }

    /// Undoes a reminder or event change while the item is still as the change left it. An
    /// earlier change Echo made to the same item, which left it as this one found it, can then be
    /// undone in turn.
    private func undoCalendar(_ change: AgentCalendarChange, toolID: String) async -> AgentUndoRefusal? {
        undoing += 1
        defer { undoing -= 1 }
        let store = calendarStore
        switch await Task.detached(operation: { await AgentCalendarRunner.undo(change, store: store) }).value {
        case .refused(let refusal): return refusal
        case .undone(let modified):
            state.calendarChanges[toolID] = nil
            for (id, earlier) in state.calendarChanges where earlier.item == change.item {
                if let modified, let before = change.before, abs(earlier.after - before) < 0.001 { state.calendarChanges[id]?.after = modified }
            }
            noteUndone(toolID: toolID)
            return nil
        }
    }

    /// Tells the model of an undone change.
    private func noteUndone(toolID: String) {
        // No turn starts while an undo runs, so the transcript is as it was. The call's result says
        // so where it stands, and the next message the model gets says so where the model is now:
        // a note in an earlier result alone does not outweigh the model's own later reply.
        if let index = outputIndex(of: toolID), case .toolOutput(var amended) = state.entries[index] {
            let result = Self.text(amended.segments)
            amended.segments = [.text(.init(content: AgentToolResult.undone(result, tool: amended.toolName)))]
            state.entries[index] = .toolOutput(amended)
            state.undoNotices.append(AgentToolResult.undoNoticeLine(tool: amended.toolName, result: result))
        }
        project()
        // A failed save leaves the note in memory; the conversation's next save writes it.
        try? host?.harnessSave()
    }

    /// Where the result of the call whose card is `toolID` ("turn:entry:call ID") is in the transcript.
    private func outputIndex(of toolID: String) -> Int? {
        let parts = toolID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let entry = Int(parts[1]), state.entries.indices.contains(entry),
              case .toolCalls(let calls) = state.entries[entry], calls.contains(where: { $0.id == parts[2] }) else { return nil }
        return state.entries.indices.dropFirst(entry + 1).first { index in
            if case .toolOutput(let output) = state.entries[index] { output.id == parts[2] } else { false }
        }
    }

    // MARK: Turn

    private enum Next {
        case inputs
        case resume
        case feedback(String)
    }

    /// The model a turn uses: the cloud model with Echo's tools, or the local model for chat alone.
    private enum Route {
        case cloud(ModelFactory)
        case local(LocalChatService)
        var isLocal: Bool { if case .local = self { true } else { false } }
    }

    private func runTurn() async {
        guard !stopRequested else { return finish(.stopped(reply: nil)) }
        var route: Route
        if let local, localOnly() {
            // Only the local model: when it cannot be used the turn says so and never goes to the cloud.
            switch local.backend.availability() {
            case .ready: route = .local(local)
            case .missing: return finish(.failed(LocalChatError.modelMissing.localizedDescription, notice: true))
            case .invalid(let reason): return finish(.failed(LocalChatError.modelInvalid(reason).localizedDescription, notice: true))
            }
        } else {
            do { route = .cloud(try resolveModel()) }
            catch let error as SettingsError where error == .modelNotConfigured && local != nil {
                // Without a cloud model the local one answers, when there is one.
                switch local!.backend.availability() {
                case .ready: route = .local(local!)
                case .missing:
                    return finish(.failed(String(localized: "尚未配置模型。请在设置中配置并保存默认模型，或导入本地模型。"), notice: true))
                case .invalid(let reason):
                    return finish(.failed(String(localized: "尚未配置默认模型，本地模型也不完整（\(reason)）。请在设置中配置默认模型，或重新导入本地模型。"), notice: true))
                }
            }
            catch { return finish(.failed(error.localizedDescription, notice: true)) }
        }
        // The local model has no tools, so no search, images or memory either.
        searcher = route.isLocal ? nil : webSearch()
        imageGenerator = route.isLocal ? nil : imageGeneration()
        turnMemory = route.isLocal || !memoryEnabled() ? nil : memory

        let budget = GenerationBudget(limit: Self.generationLimit, steering: steering)
        state.turns.append(.init(start: state.entries.count))
        var next: Next = state.pendingInputs.isEmpty ? .resume : .inputs
        var formatErrors = 0
        while true {
            // What this request starts from, restored if it goes to the local model instead.
            let before = (entries: state.entries, pendingInputs: state.pendingInputs, undoNotices: state.undoNotices,
                          attachments: state.attachments)
            let resuming = if case .resume = next { true } else { false }
            // Input that enters the transcript is no longer pending; the UI drops its "待处理".
            var history = state.entries
            let promptText: String, metadata: [String: any ConvertibleToGeneratedContent]
            var userPrompt: Transcript.Prompt?
            var marker: Transcript.Prompt?
            switch next {
            case .inputs:
                steering.set(false)
                let inputs = state.pendingInputs
                state.pendingInputs = []
                // Each message carries the time it reached the cloud model, saved with it, so the
                // history reads the same in every later request. The local model has no tools to
                // work out dates for, and is not told.
                let sent = route.isLocal ? "" : AgentToolResult.sentNotice(AgentTimeText.now(clock))
                for input in inputs.dropLast() { history.append(.prompt(Self.userPrompt(input, prefix: sent + attached(input, local: route.isLocal)))) }
                let last = inputs.last!
                // The cloud model hears of undone changes before the person's next words. The local
                // model has no tools, so it is not told.
                let notice = route.isLocal ? "" : AgentToolResult.undoNotice(state.undoNotices)
                if !route.isLocal { state.undoNotices = [] }
                let prefix = sent + notice + attached(last, local: route.isLocal)
                userPrompt = Self.userPrompt(last, prefix: prefix)
                promptText = prefix + last.text; metadata = [AgentPromptKey.message: last.messageID.uuidString]
            case .resume:
                promptText = ""; metadata = [AgentPromptMarker.continueKey: true]
                marker = Transcript.Prompt(metadata: metadata, segments: [])
            case .feedback(let text):
                promptText = text; metadata = [AgentPromptKey.feedback: true]
                marker = Transcript.Prompt(metadata: metadata, segments: [.text(.init(content: text))])
            }
            state.entries = history
            runningPrompt = (userPrompt ?? marker).map { .prompt($0) }
            live = []; checkpointed = []; dispatched = []; operations = [:]
            project()
            host?.harnessStatus(String(localized: "正在请求模型…"))

            let ledger = GenerationLedger()
            var modelHistory = history
            let session: LanguageModelSession?
            var inputError: (any Error)?
            switch route {
            case .cloud(let factory):
                session = LanguageModelSession(
                    profile: AgentProfile(model: factory(ledger, budget), tools: tools(), attachments: state.attachments.map(\.name),
                                          memory: turnMemory?.read(), harness: self),
                    history: history)
            case .local(let service):
                do {
                    // A continue is answered only for a message nothing was done for yet.
                    if resuming && !LocalChatContext.isUnanswered(history) { throw LocalChatError.cannotContinue }
                    modelHistory = try LocalChatContext.history(history, prompt: promptText)
                    session = LanguageModelSession(profile: LocalChatProfile(model: service.factory(ledger, budget)), history: modelHistory)
                } catch {
                    session = nil; inputError = error
                }
            }
            let result: Result<Void, any Error>
            var entries = history
            if let session {
                result = await Self.consume(session, prompt: Prompt(promptText), metadata: metadata) { [weak self] entries in
                    await self?.receive(entries)
                }
                // A stopped stream ends without waiting for its tools; a write under way ends first.
                await writesSettled()
                // The local model saw a filtered view; what it added follows the whole history.
                let written = Array(session.transcript).filter { if case .instructions = $0 { false } else { true } }
                entries = history + written.dropFirst(modelHistory.count)
            } else {
                result = .failure(inputError!)
            }
            // A Stop before Foundation Models recorded the prompt still leaves the input in the history.
            if let userPrompt, !entries[history.count...].contains(where: { Self.messageID(of: $0) == userPrompt.metadata[AgentPromptKey.message].flatMap(Self.string) }) {
                entries.insert(.prompt(userPrompt), at: history.count)
            }
            let added = entries[history.count...]
            let streamed = live.contains { if case .prompt = $0 { false } else { true } }
            runningPrompt = nil; live = []; checkpointed = []; dispatched = []

            if stopRequested { return finishStopped(entries, base: history.count, ledger: ledger) }
            if let storageFailure {
                state.entries = closingInterruptedCalls(entries)
                return finish(.failed(storageFailure, notice: true))
            }
            if added.contains(where: { if case .toolOutput = $0 { true } else { false } }) { formatErrors = 0 }

            switch result {
            case .success:
                state.entries = entries
                guard let response = Self.finalResponse(entries, after: history.count) else {
                    // The local model has no tools to be told about: its output is dropped, the input stays.
                    if route.isLocal { return finishLocalWithoutReply(entries, base: history.count) }
                    // Neither a reply nor a tool call.
                    formatErrors += 1
                    guard formatErrors < Self.formatErrorLimit else { return finish(.failed(Self.formatErrorMessage, notice: false), outcome: .formatErrorLimit) }
                    next = .feedback(AgentToolResult.status("not_executed",
                        "expected a reply or a tool call, received neither. Reply directly or call one of the available tools with valid arguments."))
                    continue
                }
                if !state.pendingInputs.isEmpty {
                    // Input queued while the model wrote this: the text is not the reply.
                    project()
                    host?.harnessStream(operation: operationID(response.id), text: "", toolCall: true, final: true)
                    next = .inputs
                    continue
                }
                let reply = deliver(response)
                // A Stop admitted while the reply was applied lands on a completed turn.
                if stopRequested { return finish(.stopped(reply: reply), outcome: .completed) }
                return finish(.completed(reply: reply, text: Self.text(response.segments)), outcome: .completed)

            case .failure(let error):
                switch Self.unwrap(error) {
                case is GenerationBudget.Superseded:
                    state.entries = entries
                    next = .inputs
                case is GenerationBudget.Exhausted:
                    state.entries = closingInterruptedCalls(entries)
                    return finish(.failed(Self.stepLimitMessage, notice: false), outcome: .stepLimit)
                case is GeneratedContent.ParsingError where route.isLocal:
                    return finishLocalWithoutReply(entries, base: history.count)
                case is GeneratedContent.ParsingError:
                    formatErrors += 1
                    let dangling = Self.danglingCalls(entries)
                    if dangling.isEmpty {
                        state.entries = entries
                        next = .feedback(AgentToolResult.status("not_executed",
                            "tool call arguments are not valid JSON. Reply directly or call one of the available tools with valid arguments."))
                    } else {
                        // An unknown tool: answered as the call's result, like any other tool result.
                        state.entries = Self.closingDanglingCalls(entries) { _, call in
                            AgentToolResult.status("not_executed",
                                "unknown tool \(call.toolName). Reply directly or call one of the available tools with valid arguments.")
                        }
                        next = .resume
                    }
                    guard formatErrors < Self.formatErrorLimit else {
                        return finish(.failed(Self.formatErrorMessage, notice: false), outcome: .formatErrorLimit)
                    }
                default:
                    if case .cloud = route, let local, (Self.unwrap(error) as? AgentModelError)?.isOffline == true {
                        // Offline before the turn produced anything: the same input goes to the local
                        // model. Anything later would repeat or mix work, so that turn stops instead.
                        let turnStart = state.turns[state.turns.count - 1].start
                        let untouched = !streamed
                            && entries[turnStart...].allSatisfy { if case .prompt = $0 { true } else { false } }
                            && (!resuming || LocalChatContext.isUnanswered(history))
                        guard untouched else {
                            state.entries = closingInterruptedCalls(Self.trimmingUnfinished(entries, base: history.count, ledger: ledger))
                            return finish(.failed(Self.offlineAfterOutputMessage, notice: false))
                        }
                        switch local.backend.availability() {
                        case .ready:
                            state.entries = before.entries
                            state.pendingInputs = before.pendingInputs + state.pendingInputs
                            state.undoNotices = before.undoNotices
                            state.attachments = before.attachments
                            route = .local(local)
                            continue
                        case .missing:
                            state.entries = entries
                            return finish(.failed(String(localized: "当前离线，本地模型未安装。请联网后重试，或在设置中导入本地模型。"), notice: false))
                        case .invalid(let reason):
                            state.entries = entries
                            return finish(.failed(String(localized: "当前离线，本地模型不完整（\(reason)）。请联网后重试，或在设置中重新导入本地模型。"), notice: false))
                        }
                    }
                    state.entries = closingInterruptedCalls(Self.trimmingUnfinished(entries, base: history.count, ledger: ledger))
                    return finish(.failed(Self.message(for: error), notice: false))
                }
            }
        }
    }

    /// The files sent with `input` join the chat's attached files as it enters the transcript. The
    /// cloud model is told their names in front of the person's words; the local model, which has
    /// no tools to read them with, is not.
    private func attached(_ input: NativeAgentState.Input, local: Bool) -> String {
        let names = state.attach(input)
        return local || names.isEmpty ? "" : AgentToolResult.attachedNotice(names)
    }

    /// A local turn whose model wrote no usable reply: what it wrote goes, the user's input stays.
    private func finishLocalWithoutReply(_ entries: [Transcript.Entry], base: Int) {
        state.entries = Array(entries[..<base]) + entries[base...].filter { if case .prompt = $0 { true } else { false } }
        finish(.failed(LocalChatError.noReply.localizedDescription, notice: false))
    }

    /// After a Stop only the cut-off reply goes: finished tool calls and their results stay, and
    /// calls left without a result are marked as not run. A final reply that completed before the
    /// Stop took effect keeps the turn completed. A cancelled stream can end without an error, so
    /// the ledger, not the stream, says what finished
    /// (`AgentHarnessTests.stopKeepsFinishedToolResultsAndRacesCompletion`).
    private func finishStopped(_ entries: [Transcript.Entry], base: Int, ledger: GenerationLedger) {
        var kept = Self.trimmingUnfinished(entries, base: base, ledger: ledger)
        if let reply = ledger.finalReply {
            // The model finished its reply before the Stop took effect. Foundation Models may still
            // have dropped the chunk it held back, or the whole entry; the ledger has all of it.
            let whole = Transcript.Entry.response(Transcript.Response(id: reply.id, assetIDs: [], segments: [.text(.init(content: reply.text))]))
            if let index = kept.indices.last(where: { if case .response(let r) = kept[$0] { r.id == reply.id } else { false } }) {
                kept[index] = whole
            } else {
                kept.append(whole)
            }
        }
        state.entries = closingInterruptedCalls(kept)
        if let response = Self.finalResponse(state.entries, after: base), state.pendingInputs.isEmpty {
            return finish(.stopped(reply: deliver(response)), outcome: .completed)
        }
        finish(.stopped(reply: nil), outcome: .interrupted)
    }

    /// The reply `entries` end with after `base`, when they end with one that says anything.
    private static func finalResponse(_ entries: [Transcript.Entry], after base: Int) -> Transcript.Response? {
        guard let index = entries.indices.last, index >= base, case .response(let response) = entries[index],
              !text(response.segments).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return response
    }

    /// Shows `response` as the turn's final reply, and returns its message's ID.
    private func deliver(_ response: Transcript.Response) -> UUID {
        let reply = replyID(response.id)
        project()
        host?.harnessStream(operation: operationID(response.id), text: Self.text(response.segments), toolCall: false, final: true)
        return reply
    }

    /// Calls left without a result: a finished write keeps its result. Any other produced none: the
    /// turn waits for a write that started, so one without a result never started.
    private func closingInterruptedCalls(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        Self.closingDanglingCalls(entries) { [finishedOutputs] index, call in
            finishedOutputs["\(index):\(call.id)"] ?? AgentToolResult.cancelledBefore
        }
    }

    private func finish(_ ending: AgentTurnEnding, outcome: AgentTurnOutcome? = nil) {
        if let last = state.turns.indices.last, state.turns[last].outcome == nil {
            state.turns[last].outcome = outcome ?? {
                switch ending {
                case .completed: .completed
                case .stopped: .interrupted
                case .failed: .failed
                }
            }()
        }
        steering.set(false)
        resumeFinderWaiters(.failure(CancellationError()))
        resumeTurnWaiters(.failure(CancellationError()))
        batchCalls = [:]; doneCalls = []
        runningPrompt = nil; live = []; checkpointed = []; dispatched = []
        callKeys = [:]; callDirectories = [:]; finishedOutputs = [:]; undoableCalls = []
        let responses = Set(state.entries.compactMap { if case .response(let response) = $0 { response.id } else { nil } })
        state.replies = state.replies.filter { responses.contains($0.key) }
        project()
        // Idle before the conversation hears the ending, so a listener may start the next turn at once.
        turn = nil
        host?.harnessFinish(ending)
    }

    // MARK: Streaming and hooks (main actor)

    private func receive(_ entries: [Transcript.Entry]) {
        guard isRunning, !stopRequested else { return }
        // A snapshot can trail what the tool hooks already showed; it never takes entries away.
        let structureChanged = entries.count > live.count || zip(entries, live).contains { Self.kind($0) != Self.kind($1) }
        if entries.count >= live.count { live = entries }
        for (position, entry) in entries.enumerated() {
            guard case .response(let response) = entry else { continue }
            let beside = entries[(position + 1)...].contains { if case .toolCalls = $0 { true } else { false } }
            host?.harnessStream(operation: operationID(response.id), text: Self.text(response.segments), toolCall: beside, final: false)
        }
        if structureChanged { project() }
    }

    /// "entry index:call ID" of the latest batch holding `call`, in the session's history.
    private static func key(of call: Transcript.ToolCall, in history: [Transcript.Entry]) -> String? {
        history.indices.last { index in
            if case .toolCalls(let calls) = history[index] { calls.contains { $0.id == call.id } } else { false }
        }.map { "\($0):\(call.id)" }
    }

    fileprivate func toolDispatched(_ call: Transcript.ToolCall, history: [Transcript.Entry]) {
        guard isRunning, let key = Self.key(of: call, in: history) else { return }
        if let identity = call.arguments.id { callKeys[identity] = key }
        if let batch = Int(key.prefix { $0 != ":" }), batchCalls[batch] == nil, case .toolCalls(let calls) = history[batch] {
            batchCalls[batch] = calls.map { ("\(batch):\($0.id)", $0.toolName) }
        }
        // Stream snapshots trail the transcript by one event; the session's own history shows the
        // call now. Its generation finished, so everything up to it can be saved.
        let base = state.entries.count + 1
        if history.count - base > live.count { live = Array(history[base...]) }
        checkpointed = history.count > base ? Array(history[base...]) : []
        dispatched.insert(key)
        if !stopRequested { host?.harnessStatus(AgentToolRecord.summary(call)) }
        project()
    }

    /// A tool result joins the saved conversation before the next model request can see it.
    fileprivate func toolFinished(_ call: Transcript.ToolCall, history: [Transcript.Entry]) throws {
        guard isRunning else { throw CancellationError() }
        if let key = Self.key(of: call, in: history) { dispatched.remove(key) }
        let base = state.entries.count + 1   // the running prompt follows the saved history
        checkpointed = history.count > base ? Array(history[base...]) : []
        if live.count <= checkpointed.count { live = checkpointed }
        project()
        try save()
    }

    /// The conversation's project as it is now. A tool never asks for one: only the person gives
    /// a conversation its project, in the UI.
    fileprivate func projectRoot() throws -> AgentProjectRoot {
        guard isRunning, !stopRequested else { throw CancellationError() }
        if steering.isPending { return .superseded }
        return host?.harnessProjectDirectory() ?? .noProject
    }

    /// One finder_location call: it points this chat's Finder folder at the folder Finder shows
    /// now; a call that finds none leaves the chat's folder as it was. The folder's path goes to the
    /// call's record, never to the model.
    fileprivate func locateFinder(call identity: GenerationID?) async throws -> FinderLocation? {
        let key = callKey(identity)
        defer { if let key { finishCall(key) } }
        guard isRunning, !stopRequested else { throw CancellationError() }
        if let key { try await waitForEarlierCalls(key) }
        if steering.isPending { return nil }
        let location = try await lookUpFinder()
        if case .folder(let path)? = location {
            state.finderFolder = path
            if let key = callKey(identity) { callDirectories[key] = path; project() }
        }
        return location
    }

    /// Asks Finder where its frontmost window is. Callers asking at the same time share one lookup.
    /// Stop and newer input answer a caller at once (nil for newer input); the Apple Event already
    /// sent runs to its end and its result is dropped.
    private func lookUpFinder() async throws -> FinderLocation? {
        let lookup = finderLookup ?? Task { [finder] in await finder.locate() }
        finderLookup = lookup
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FinderLocation?, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                finderWaiters[id] = continuation
                Task { [weak self] in
                    let location = await lookup.value
                    guard let self else { return }
                    if self.finderLookup == lookup { self.finderLookup = nil }
                    self.finderWaiters.removeValue(forKey: id)?.resume(returning: location)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finderWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    /// This chat's Finder folder for a call, which has waited for its turn in its batch. A chat
    /// without one takes the folder Finder shows now. A call in the folder shows it on its card.
    fileprivate func finderRoot(call identity: GenerationID?) async throws -> AgentFinderRoot {
        guard isRunning, !stopRequested else { throw CancellationError() }
        let key = callKey(identity)
        if steering.isPending { return .superseded }
        if state.finderFolder == nil {
            switch try await lookUpFinder() {
            case nil: return .superseded
            case .folder(let path)?: if state.finderFolder == nil { state.finderFolder = path }
            case let failure?: return .failed(failure.toolResult)
            }
        }
        guard let folder = state.finderFolder else { return .superseded }
        if let key { callDirectories[key] = folder; project() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(AgentToolResult.finderFolderMissing(name: (folder as NSString).lastPathComponent))
        }
        return .folder(folder)
    }

    /// One read_file call on a file attached to the chat, by its name. The file is read on a thread
    /// of its own: opening it can wait on the system's access prompt, and a Stop or newer input
    /// ends the call at once while the read runs on. Its card shows the file's path.
    fileprivate func readAttached(name raw: String, startLine: Int, call identity: GenerationID?) async throws -> String {
        guard isRunning, !stopRequested else { throw CancellationError() }
        if steering.isPending { return AgentToolResult.superseded }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let file = state.attachments.first(where: { $0.name == name }) else {
            return AgentToolResult.failed(AgentToolResult.notAttached(name: raw, attached: state.attachments.map(\.name)))
        }
        if let key = callKey(identity) { callDirectories[key] = file.path; project() }
        let hooks = attachmentHooks
        let read: String? = try await unlessInterrupted {
            hooks.beforeOpening()
            return ReadFileTool.read(attached: file, startLine: startLine)
        }
        return read ?? AgentToolResult.superseded
    }

    nonisolated static let writeTools: Set<String> = ["write_file", "edit_file"]
    /// The reminders and calendar tools that change something.
    nonisolated static let calendarChangeTools: Set<String> = ["create_reminder", "complete_reminder", "create_event"]
    nonisolated static let calendarTools: Set<String> = calendarChangeTools.union(["list_reminders", "list_events"])
    /// The tools that open an app or a web page: they change what is on the person's screen, and
    /// cannot be undone.
    nonisolated static let openTools: Set<String> = ["open_app", "open_url"]
    /// The tools that change the memory.
    nonisolated static let memoryTools: Set<String> = ["remember", "update_memory"]
    /// The tools that create a file of their own, outside the write tools' rules.
    nonisolated static let imageTools: Set<String> = [GenerateImageTool.toolName]
    /// Every tool that changes something: each waits for every call written before it in its batch.
    nonisolated static let changeTools = writeTools.union(calendarChangeTools).union(openTools).union(memoryTools).union(imageTools)
    /// The tools a batch orders; a call to any other tool never runs, so nothing waits for it.
    private static let orderedTools: Set<String> = changeTools.union(calendarTools).union(["list_files", "read_file", "finder_location"])

    /// A read's turn: after the finder_location and change calls written before it in its batch.
    fileprivate func waitForTurn(call identity: GenerationID?) async throws {
        guard isRunning, !stopRequested else { throw CancellationError() }
        guard let key = callKey(identity) else { return }
        try await waitForEarlierCalls(key)
    }

    fileprivate func finished(call identity: GenerationID?) {
        if let key = callKey(identity) { finishCall(key) }
    }

    /// Whether a call to `tool` waits for an `earlier` call in its batch: a change waits for every
    /// call written before it, and any other call for the changes and, unless it is one itself, the
    /// finder_location calls before it.
    private static func waits(_ tool: String, for earlier: String) -> Bool {
        orderedTools.contains(earlier)
            && (changeTools.contains(tool) || changeTools.contains(earlier) || (earlier == "finder_location" && tool != "finder_location"))
    }

    /// Returns once every call written before `key` in its batch that it waits for is done.
    private func waitForEarlierCalls(_ key: String) async throws {
        while true {
            guard let batch = Int(key.prefix { $0 != ":" }), let calls = batchCalls[batch],
                  let position = calls.firstIndex(where: { $0.key == key }) else { return }
            let tool = calls[position].tool
            if calls[..<position].allSatisfy({ !Self.waits(tool, for: $0.tool) || doneCalls.contains($0.key) }) { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    turnWaiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.turnWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
            }
        }
    }

    /// A call is done however it ended; the calls waiting look again.
    private func finishCall(_ key: String) {
        doneCalls.insert(key)
        resumeTurnWaiters(.success(()))
    }

    private func resumeTurnWaiters(_ result: Result<Void, any Error>) {
        let waiters = turnWaiters; turnWaiters = [:]
        waiters.values.forEach { $0.resume(with: result) }
    }

    /// The key of the call whose arguments carry `identity`, once the harness saw it dispatched.
    private func callKey(_ identity: GenerationID?) -> String? { identity.flatMap { callKeys[$0] } }

    /// A call that may change something starts: its key, nil for one the harness did not see
    /// dispatched, and the turn it belongs to. A call whose turn ended does nothing.
    private func startCall(_ identity: GenerationID?) throws -> (key: String?, serial: Int) {
        guard isRunning else { throw CancellationError() }
        return (callKey(identity), turnSerial)
    }

    /// The call is done, however it ended, and the calls after it in its batch may go, unless a
    /// later turn has begun meanwhile.
    private func endCall(_ key: String?, of serial: Int) {
        if let key, serial == turnSerial { finishCall(key) }
    }

    /// Returns once the calls written before `key` in its batch that it waits for are done. Once a
    /// save failed, nothing more is written this turn, not even the rest of a batch.
    private func waitInBatch(_ key: String?) async throws {
        if let key { try await waitForEarlierCalls(key) }
        if storageFailure != nil || stopRequested { throw CancellationError() }
    }

    /// Throws unless the call's turn runs on and may still change things: a later turn may have
    /// begun while the call waited off the main actor, and the call then belongs to one that ended.
    private func checkTurn(_ serial: Int) throws {
        guard serial == turnSerial, isRunning, !stopRequested, storageFailure == nil else { throw CancellationError() }
    }

    /// Saves the conversation. Once a save failed, the turn changes nothing more and ends with its failure.
    private func save() throws {
        do { try host?.harnessSave() }
        catch { storageFailure = error.localizedDescription; throw error }
    }

    /// A change begins: the call is saved before anything changes, so a crash from here on reopens
    /// it as unknown, and the change then runs to its end, which the turn waits for.
    private func beginChange() throws {
        try save()
        writesInFlight += 1
    }

    /// A change that began has run to its end. Its result is kept for its card and the save even if
    /// Foundation Models never records it, and the turn may settle.
    private func changeEnded(_ key: String?, result: String, undoable: Bool) -> String {
        if let key {
            finishedOutputs[key] = result
            if undoable { undoableCalls.insert(key) }
            project()
        }
        writesInFlight -= 1
        if writesInFlight == 0 { let waiters = writeWaiters; writeWaiters = []; waiters.forEach { $0.resume() } }
        return result
    }

    /// The card ID of a call this turn: turns count from 1, the batch's entry and the call ID come from its key.
    private func cardID(_ key: String) -> String { "\(state.turns.count):\(key)" }

    /// The chat's folder a change writes in, canonical, once the write policy allows writing there;
    /// otherwise the result that ends the call. `nothing` says what it did not do: "written" or "generated".
    private func writableFolder(call identity: GenerationID?, nothing: String) async throws -> AgentRootResolution {
        let folder: String, scope: AgentReadScope
        switch try await AgentReadContext.resolve(call: identity, access: HarnessAccess(harness: self), steering: steering, nothing: nothing) {
        case .result(let result): return .result(result)
        case .folder(let path, let kind): (folder, scope) = (path, kind)
        }
        if storageFailure != nil || stopRequested { throw CancellationError() }
        if steering.isPending { return .result(AgentToolResult.superseded) }
        guard let root = ProjectPath.canonical(folder) else {
            return .result(scope == .project ? AgentToolResult.failed(AgentToolResult.projectMissing(nothing: nothing))
                : AgentToolResult.finderFolderMissing(name: (folder as NSString).lastPathComponent))
        }
        if let refusal = writePolicy.refusal(folder: root, scope: scope) {
            return .result(AgentToolResult.naming(root: root, scope: scope, in: AgentToolResult.failed(refusal)))
        }
        return .folder(root, scope)
    }

    /// One write call, in its turn: after every call written before it in its batch, in the folder
    /// the read tools would use. The file work runs off the main actor in two steps around a save:
    /// reading the original, which can wait for a file to download, then the change itself. Until
    /// the save, a Stop or newer input ends the call with nothing changed. The call is saved before
    /// anything on disk changes, and once it is the change runs to its end: the turn does not settle
    /// before it does, and its result is kept for the card and the save even if Foundation Models
    /// never records it. The calls after it in its batch wait for it.
    fileprivate func write(call identity: GenerationID?, _ arguments: Result<AgentWriteRequest, AgentInvalidArguments>) async throws -> String {
        let (key, serial) = try startCall(identity)
        defer { endCall(key, of: serial) }
        try await waitInBatch(key)
        let request: AgentWriteRequest
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): request = valid
        }
        let root: String, scope: AgentReadScope
        switch try await writableFolder(call: identity, nothing: "written") {
        case .result(let result): return result
        case .folder(let path, let kind): (root, scope) = (path, kind)
        }

        let hooks = writeHooks
        let prepared = try await unlessInterrupted {
            AgentFileWriter.prepare(root: root, path: request.path, change: request.change, scope: scope, hooks: hooks)
        }
        guard let prepared else { return AgentToolResult.superseded }
        // A later turn may have begun while the original was read; this call belongs to one that ended.
        try checkTurn(serial)
        if steering.isPending { return AgentToolResult.superseded }
        let plan: AgentFileWriter.Plan
        switch prepared {
        case .failure(let failure): return AgentToolResult.naming(root: root, scope: scope, in: failure.result)
        case .success(let ready): plan = ready
        }

        try beginChange()
        let directory = host?.harnessBackupDirectory(), chat = host?.harnessChatID
        let tool = if case .edit = request.change { "edit_file" } else { "write_file" }
        let card = key.map(cardID) ?? ""
        let output = await Task.detached {
            AgentFileWriter.commit(plan, hooks: hooks) { original in
                guard let directory, let chat else {
                    // Without a folder of records a new file is still created; it has no undo.
                    if original == nil { return }
                    throw CocoaError(.fileWriteNoPermission)
                }
                try AgentBackupStore(directory: directory).save(original, record: .init(
                    path: root + "/" + plan.path, root: root, rootKind: scope.rawValue, relativePath: plan.path,
                    chat: chat, toolRecord: card, tool: tool, savedAt: Date(), original: original, action: plan.action, written: plan.content))
            }
        }.value
        let result = AgentToolResult.naming(root: root, scope: scope, in: output)
        return changeEnded(key, result: result, undoable: directory != nil && chat != nil && AgentToolResult.changed(result))
    }

    private struct WriteSuperseded: Error {}

    /// One reminders or calendar call, in its turn: a read after the finder_location and change
    /// calls written before it in its batch, a change after every call before it. Access is asked
    /// for first, and the wait for the person's answer ends at once on a Stop or newer input. A
    /// change is saved before it is made and then runs to its end, as a write does; what it
    /// changed is kept for its card's Undo.
    fileprivate func calendar(call identity: GenerationID?, _ arguments: Result<AgentCalendarRequest, AgentInvalidArguments>) async throws -> String {
        let (key, serial) = try startCall(identity)
        defer { endCall(key, of: serial) }
        try await waitInBatch(key)
        if steering.isPending { return AgentToolResult.superseded }
        let request: AgentCalendarRequest
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): request = valid
        }
        let store = calendarStore, clock = clock
        guard let permission = try await unlessInterrupted({ await store.permission(for: request.kind) }) else {
            return AgentToolResult.superseded
        }
        guard permission == .granted else { return AgentCalendarResult.denied(request.kind, permission) }
        guard let plan = try await unlessInterrupted({ await AgentCalendarRunner.prepare(request, store: store, clock: clock) }) else {
            return AgentToolResult.superseded
        }
        try checkTurn(serial)
        if case .done(let result) = plan { return result }
        if steering.isPending { return AgentToolResult.superseded }

        try beginChange()
        let (result, change) = await Task.detached { await AgentCalendarRunner.commit(plan, store: store, clock: clock) }.value
        if let key, let change { state.calendarChanges[cardID(key)] = change }
        return changeEnded(key, result: result, undoable: change != nil)
    }

    /// One open_app or open_url call, in its turn: after every call written before it in its batch.
    /// Nothing is asked first. Finding the app is ended at once by a Stop or newer input; the call
    /// is saved before anything opens, and the opening then runs to its end, as a write does.
    fileprivate func open(call identity: GenerationID?, _ arguments: Result<AgentOpenRequest, AgentInvalidArguments>) async throws -> String {
        let (key, serial) = try startCall(identity)
        defer { endCall(key, of: serial) }
        try await waitInBatch(key)
        if steering.isPending { return AgentToolResult.superseded }
        let request: AgentOpenRequest
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): request = valid
        }
        let opener = opener
        guard let plan = try await unlessInterrupted({ await AgentOpenRunner.prepare(request, opener: opener) }) else {
            return AgentToolResult.superseded
        }
        try checkTurn(serial)
        if case .done(let result) = plan { return result }
        if steering.isPending { return AgentToolResult.superseded }

        try beginChange()
        let result = await Task.detached { await AgentOpenRunner.commit(plan, opener: opener) }.value
        return changeEnded(key, result: result, undoable: false)
    }

    /// One remember or update_memory call, in its turn: after every call written before it in its
    /// batch. It runs as a write does, on the memory file alone: the file is read off the main
    /// actor, the call saved before anything changes, and the change then runs to its end. The
    /// file's earlier content is kept with this chat's records for the card's Undo; a chat without
    /// a records folder still changes the memory, with no undo.
    fileprivate func changeMemory(call identity: GenerationID?, _ arguments: Result<AgentMemoryChange, AgentInvalidArguments>) async throws -> String {
        let (key, serial) = try startCall(identity)
        defer { endCall(key, of: serial) }
        try await waitInBatch(key)
        if steering.isPending { return AgentToolResult.superseded }
        let change: AgentMemoryChange
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): change = valid
        }
        guard let memory = turnMemory else { return AgentToolResult.failed("the memory is not available in this chat") }

        let hooks = writeHooks
        let prepared: Result<(root: String, plan: AgentFileWriter.Plan), AgentInvalidArguments>? = try await unlessInterrupted {
            do { try FileManager.default.createDirectory(at: memory.folder, withIntermediateDirectories: true) }
            catch { return .failure(.failed("the memory file's folder cannot be made: \(error.localizedDescription)")) }
            guard let root = ProjectPath.canonical(memory.folder.path) else { return .failure(.failed("the memory file's folder cannot be found")) }
            return AgentFileWriter.prepare(root: root, path: AgentMemoryFile.fileName, change: .derive { AgentMemoryEdit.apply(change, to: $0) },
                                           hooks: hooks).map { (root: root, plan: $0) }
        }
        guard let prepared else { return AgentToolResult.superseded }
        try checkTurn(serial)
        if steering.isPending { return AgentToolResult.superseded }
        let root: String, plan: AgentFileWriter.Plan
        switch prepared {
        case .failure(let failure): return failure.result
        case .success(let ready): (root, plan) = ready
        }

        try beginChange()
        let directory = host?.harnessBackupDirectory(), chat = host?.harnessChatID
        let tool = if case .remember = change { "remember" } else { "update_memory" }
        let card = key.map(cardID) ?? ""
        let output = await Task.detached {
            AgentFileWriter.commit(plan, hooks: hooks) { original in
                guard let directory, let chat else { return }
                try AgentBackupStore(directory: directory).save(original, record: .init(
                    path: root + "/" + plan.path, root: root, rootKind: AgentBackupStore.memoryRoot, relativePath: plan.path,
                    chat: chat, toolRecord: card, tool: tool, savedAt: Date(), original: original, action: plan.action, written: plan.content))
            }
        }.value
        // The memory's own words for what was done; a failure says it as the write tools do.
        let changed = AgentToolResult.changed(output)
        return changeEnded(key, result: changed ? AgentMemoryEdit.result(change) : output, undoable: changed && directory != nil && chat != nil)
    }

    /// One web_search call. Nothing on the Mac changes, so it waits for no other call and is not
    /// saved first; a Stop or newer input ends the wait at once and drops the result.
    fileprivate func search(_ arguments: Result<AgentWebSearchRequest, AgentInvalidArguments>) async throws -> String {
        guard isRunning, !stopRequested, storageFailure == nil else { throw CancellationError() }
        if steering.isPending { return AgentToolResult.superseded }
        let request: AgentWebSearchRequest
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): request = valid
        }
        guard let searcher else { return AgentToolResult.failed("web_search is not available with this model provider") }
        return try await unlessInterrupted { await AgentWebSearchResult.run(request, with: searcher) } ?? AgentToolResult.superseded
    }

    /// One web_fetch call. Nothing on the Mac changes, so it waits for no other call and is not
    /// saved first; a Stop or newer input stops the page loading and drops the result.
    fileprivate func fetch(_ arguments: Result<String, AgentInvalidArguments>) async throws -> String {
        guard isRunning, !stopRequested, storageFailure == nil else { throw CancellationError() }
        if steering.isPending { return AgentToolResult.superseded }
        let address: String
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): address = valid
        }
        let fetcher = fetcher
        return try await cancellingUnlessInterrupted { await AgentWebFetchResult.run(address, with: fetcher) } ?? AgentToolResult.superseded
    }

    /// One generate_image call, in its turn: after every call written before it in its batch. When
    /// the image goes in the chat's folder, the folder is found first, so a chat without one
    /// generates nothing. A Stop or newer input cancels the request at once. Once the image is in,
    /// the call is saved before the file is written, and the write then runs to its end, as a write
    /// call's does; the card undoes it like a file write_file created.
    fileprivate func generateImage(call identity: GenerationID?, _ arguments: Result<AgentImageRequest, AgentInvalidArguments>) async throws -> String {
        let (key, serial) = try startCall(identity)
        defer { endCall(key, of: serial) }
        try await waitInBatch(key)
        if steering.isPending { return AgentToolResult.superseded }
        let request: AgentImageRequest
        switch arguments {
        case .failure(let invalid): return invalid.result
        case .success(let valid): request = valid
        }
        guard let generator = imageGenerator else { return AgentToolResult.failed("generate_image is not available: no Volcengine Ark key is saved") }

        // The chat's folder, when the person asked for it; otherwise Pictures/Echo, made when the image is saved.
        var chatRoot: (path: String, scope: AgentReadScope)?
        if request.saveToChatFolder {
            switch try await writableFolder(call: identity, nothing: "generated") {
            case .result(let result): return result
            case .folder(let root, let scope):
                chatRoot = (root, scope)
                if let key { callDirectories[key] = root; project() }
            }
        }
        let named = { (result: String) in chatRoot.map { AgentToolResult.naming(root: $0.path, scope: $0.scope, in: result) } ?? result }

        let generated = try await cancellingUnlessInterrupted { () async -> Result<AgentGeneratedImage, AgentImageFailure> in
            do throws(AgentImageFailure) { return .success(try await generator.generate(request)) } catch { return .failure(error) }
        }
        guard let generated else { return AgentToolResult.superseded }
        // A later turn may have begun while the image was made; this call belongs to one that ended.
        try checkTurn(serial)
        if steering.isPending { return AgentToolResult.superseded }
        let image: AgentGeneratedImage
        switch generated {
        case .failure(let failure): return named(AgentImageResult.failed(failure))
        case .success(let made): image = made
        }

        try beginChange()
        let directory = host?.harnessBackupDirectory(), chat = host?.harnessChatID
        let card = key.map(cardID) ?? ""
        let base = AgentImageFiles.baseName(prompt: request.prompt, at: clock.now(), in: clock.timeZone)
        let pictures = picturesFolder
        let (output, folder) = await Task.detached { () -> (String, String?) in
            let root: String
            if let chatRoot { root = chatRoot.path } else {
                do { try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }
                catch { return (AgentImageResult.notSaved(error.localizedDescription), nil) }
                guard let canonical = ProjectPath.canonical(pictures.path) else { return (AgentImageResult.notSaved(String(cString: strerror(ENOENT))), nil) }
                root = canonical
            }
            let rootKind = chatRoot?.scope.rawValue ?? AgentImageFiles.picturesRoot
            let saved = AgentImageFiles.save(image, in: root, base: base) { name in
                // Without a folder of records the image is still saved; it has no undo.
                guard let directory, let chat else { return }
                try AgentBackupStore(directory: directory).save(nil, record: .init(
                    path: root + "/" + name, root: root, rootKind: rootKind, relativePath: name, chat: chat, toolRecord: card,
                    tool: GenerateImageTool.toolName, savedAt: Date(), original: nil, action: "created", written: image.data))
            }
            switch saved {
            case .failure(let failure): return (AgentImageResult.notSaved(failure.message), root)
            case .success(let name):
                let path = chatRoot == nil ? (pictures.path as NSString).abbreviatingWithTildeInPath + "/" + name : name
                return (AgentImageResult.saved(image, path: path), root)
            }
        }.value
        let result = named(output)
        if let key, let folder { callDirectories[key] = folder }
        return changeEnded(key, result: result, undoable: directory != nil && chat != nil && AgentToolResult.changed(result))
    }

    /// Awaits `work` off the main actor. A Stop ends the wait at once by throwing CancellationError,
    /// and newer input by returning nil; the work runs on and its result is dropped.
    private func unlessInterrupted<T: Sendable>(_ work: @escaping @Sendable () async -> T) async throws -> T? {
        if steering.isPending { return nil }
        let once = ResumeOnce<T>()
        let id = UUID()
        pendingPrepares[id] = { once.resume(throwing: $0) }
        defer { pendingPrepares[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                    once.set(continuation)
                    if Task.isCancelled { once.resume(throwing: CancellationError()); return }
                    Task.detached { once.resume(returning: await work()) }
                }
            } onCancel: {
                once.resume(throwing: CancellationError())
            }
        } catch is WriteSuperseded {
            return nil
        }
    }

    /// As `unlessInterrupted`, but a Stop or newer input also cancels `work`, so a request under way
    /// is abandoned rather than left to run on.
    private func cancellingUnlessInterrupted<T: Sendable>(_ work: @escaping @Sendable () async -> T) async throws -> T? {
        if steering.isPending { return nil }
        let once = ResumeOnce<T>()
        let worker = Task.detached { once.resume(returning: await work()) }
        let id = UUID()
        pendingPrepares[id] = { once.resume(throwing: $0); worker.cancel() }
        defer { pendingPrepares[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                    once.set(continuation)
                    if Task.isCancelled { once.resume(throwing: CancellationError()); worker.cancel() }
                }
            } onCancel: {
                once.resume(throwing: CancellationError()); worker.cancel()
            }
        } catch is WriteSuperseded {
            return nil
        }
    }

    private func interruptPrepares(_ error: any Error) {
        let waiting = pendingPrepares; pendingPrepares = [:]
        waiting.values.forEach { $0(error) }
    }

    /// Returns once no write that started is still changing the disk.
    private func writesSettled() async {
        guard writesInFlight > 0 else { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func resumeFinderWaiters(_ result: Result<FinderLocation?, any Error>) {
        let waiters = finderWaiters; finderWaiters = [:]
        waiters.values.forEach { $0.resume(with: result) }
    }

    private func tools() -> [any Tool] {
        let access = HarnessAccess(harness: self)
        let context = AgentReadContext(access: access, steering: steering)
        // A chat has one folder: its project, or else its Finder folder, which finder_location
        // switches. A chat gets its project before its first message, so its tools stay the same
        // from request to request and a service's prompt cache keeps matching.
        let finder: [any Tool] = host?.harnessProjectDirectory() == .noProject ? [FinderLocationTool(access: access)] : []
        return [ListFilesTool(context: context), ReadFileTool(context: context)] + finder + [
                WriteFileTool(access: access), EditFileTool(access: access),
                ListRemindersTool(access: access), CreateReminderTool(access: access), CompleteReminderTool(access: access),
                ListEventsTool(access: access), CreateEventTool(access: access),
                OpenAppTool(access: access), OpenURLTool(access: access), WebFetchTool(access: access)]
            + (searcher.map { [WebSearchTool(access: access, service: $0.service)] } ?? [])
            + (imageGenerator == nil ? [] : [GenerateImageTool(access: access)])
            + (turnMemory == nil ? [] : [RememberTool(access: access), UpdateMemoryTool(access: access)])
    }

    @concurrent private static func consume(
        _ session: LanguageModelSession, prompt: Prompt, metadata: [String: any ConvertibleToGeneratedContent],
        onEntries: @Sendable ([Transcript.Entry]) async -> Void
    ) async -> Result<Void, any Error> {
        do {
            var count = -1, lastText: String?
            for try await snapshot in session.streamResponse(to: prompt, metadata: metadata) {
                let entries = Array(snapshot.transcriptEntries)
                let text = entries.last.flatMap { if case .response(let r) = $0 { Self.text(r.segments) } else { nil } }
                // Snapshots repeat; hand the main actor only what changed.
                guard entries.count != count || text != lastText else { continue }
                count = entries.count; lastText = text
                await onEntries(entries)
            }
            return .success(())
        } catch { return .failure(error) }
    }

    // MARK: Projection

    /// Rebuilds the conversation's messages and tool records from the transcript. Messages keep
    /// their identity: user messages through prompt metadata, replies through `state.replies`.
    private func project() {
        guard let host else { return }
        var entries = state.entries
        if isRunning, let runningPrompt {
            // A reply still being written is the stream's to show; it becomes a message once a
            // tool call follows it or its generation ends.
            var written = live
            if case .response = written.last { written.removeLast() }
            entries += [runningPrompt] + written
        }
        let existing = Dictionary(host.harnessMessages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownTools = Dictionary(host.harnessTools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var messages: [ConversationMessage] = []
        var tools: [AgentToolRecord] = []
        var anchor: UUID?
        var turnIndex = 0
        for (index, entry) in entries.enumerated() {
            while turnIndex < state.turns.count, state.turns[turnIndex].start <= index { turnIndex += 1 }
            switch entry {
            case .prompt(let prompt):
                guard let id = Self.messageID(of: entry).flatMap(UUID.init(uuidString:)) else { continue }
                var message = existing[id] ?? ConversationMessage(role: .user, content: AgentToolResult.withoutSentNotice(Self.text(prompt.segments)))
                message.id = id
                // Input in the transcript has been taken, so it is neither queued nor interrupted.
                message.steering = nil
                messages.append(message); anchor = id
            case .response(let response):
                let text = Self.text(response.segments)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let id = replyID(response.id)
                var message = existing[id] ?? ConversationMessage(role: .assistant, content: text)
                message.id = id; message.content = text; message.status = .completed
                messages.append(message); anchor = id
            case .toolCalls(let calls):
                for call in calls {
                    let key = "\(turnIndex):\(index):\(call.id)"
                    var record = knownTools[key] ?? AgentToolRecord(
                        callID: call.id, entryID: UInt64(index), turnID: UInt64(turnIndex), afterMessageID: anchor,
                        command: AgentToolRecord.display(call))
                    // bash calls in chats saved by earlier builds keep their records without a tool name.
                    record.tool = call.toolName == "bash" ? nil : call.toolName
                    record.afterMessageID = anchor; record.result = nil
                    if record.edit == nil { record.edit = AgentToolRecord.edit(call) }
                    if record.timeRange == nil { record.timeRange = AgentToolRecord.timeRange(call) }
                    let callKey = "\(index):\(call.id)"
                    record.state = isRunning && dispatched.contains(callKey) ? .running : .waiting
                    if let directory = callDirectories[callKey] { record.directory = directory }
                    if let output = finishedOutputs[callKey] {
                        record.result = output; record.state = AgentToolRecord.state(forResult: output, tool: record.tool)
                    }
                    if undoableCalls.contains(callKey), record.undo == nil { record.undo = .available }
                    tools.append(record)
                }
            case .toolOutput(let output):
                guard let position = tools.lastIndex(where: { $0.callID == output.id && $0.result == nil }) else { continue }
                let result = Self.text(output.segments)
                tools[position].result = result
                tools[position].state = AgentToolRecord.state(forResult: result, tool: tools[position].tool)
                if AgentToolResult.isUndone(result) { tools[position].undo = .undone }
            default:
                continue
            }
        }
        for input in state.pendingInputs {
            var message = existing[input.messageID] ?? ConversationMessage(role: .user, content: input.text)
            message.id = input.messageID
            messages.append(message)
        }
        host.harnessProject(messages: messages, tools: tools)
    }

    private func replyID(_ entryID: String) -> UUID {
        if let id = state.replies[entryID] { return id }
        let id = UUID()
        state.replies[entryID] = id
        return id
    }

    private func operationID(_ entryID: String) -> UInt64 {
        if let id = operations[entryID] { return id }
        nextOperation += 1
        operations[entryID] = nextOperation
        return nextOperation
    }

    // MARK: Transcript helpers

    private nonisolated static func userPrompt(_ input: NativeAgentState.Input, prefix: String = "") -> Transcript.Prompt {
        Transcript.Prompt(metadata: [AgentPromptKey.message: input.messageID.uuidString], segments: [.text(.init(content: prefix + input.text))])
    }

    nonisolated static func text(_ segments: [Transcript.Segment]) -> String {
        // Most entries hold one text segment: its string as it is, without a copy.
        if segments.count == 1, case .text(let text) = segments[0] { return text.content }
        return segments.map { if case .text(let text) = $0 { text.content } else { "" } }.joined()
    }

    private nonisolated static func string(_ content: GeneratedContent) -> String? { try? content.value(String.self) }

    private nonisolated static func messageID(of entry: Transcript.Entry) -> String? {
        guard case .prompt(let prompt) = entry else { return nil }
        return prompt.metadata[AgentPromptKey.message].flatMap(string)
    }

    private nonisolated static func kind(_ entry: Transcript.Entry) -> Int {
        switch entry {
        case .instructions: 0
        case .prompt: 1
        case .response: 2
        case .reasoning: 3
        case .toolCalls: 4
        case .toolOutput: 5
        @unknown default: 6
        }
    }

    /// Calls without a result, in order.
    nonisolated static func danglingCalls(_ entries: [Transcript.Entry]) -> [Transcript.ToolCall] {
        var open: [Transcript.ToolCall] = []
        for entry in entries {
            switch entry {
            case .toolCalls(let calls): open.append(contentsOf: calls)
            case .toolOutput(let output):
                if let index = open.lastIndex(where: { $0.id == output.id }) { open.remove(at: index) }
            default: continue
            }
        }
        return open
    }

    /// Gives every call without a result one, right after the last entry of its batch's results.
    nonisolated static func closingDanglingCalls(_ entries: [Transcript.Entry], with result: String) -> [Transcript.Entry] {
        closingDanglingCalls(entries) { _, _ in result }
    }
    /// `result` gets the index of the call's batch in `entries`, and the call; nil leaves it open.
    nonisolated static func closingDanglingCalls(_ entries: [Transcript.Entry], result: (Int, Transcript.ToolCall) -> String?) -> [Transcript.Entry] {
        var output: [Transcript.Entry] = []
        var open: [Transcript.ToolCall] = []
        var batch = 0
        func close() {
            for call in open {
                guard let text = result(batch, call) else { continue }
                output.append(.toolOutput(.init(id: call.id, toolName: call.toolName, segments: [.text(.init(content: text))])))
            }
            open = []
        }
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .toolCalls(let calls):
                close(); output.append(entry); open = Array(calls); batch = index
            case .toolOutput(let result):
                if let index = open.firstIndex(where: { $0.id == result.id }) { open.remove(at: index) }
                output.append(entry)
            default:
                close(); output.append(entry)
            }
        }
        close()
        return output
    }

    /// Drops what a cancelled generation left after `base`: model output whose generation never
    /// finished. Tool calls run only after their generation finished, so a call that ran stays.
    nonisolated static func trimmingUnfinished(_ entries: [Transcript.Entry], base: Int, ledger: GenerationLedger) -> [Transcript.Entry] {
        entries.enumerated().filter { index, entry in
            guard index >= base else { return true }
            switch entry {
            case .response(let response): return ledger.isComplete(response.id)
            case .reasoning(let reasoning): return ledger.isComplete(reasoning.id)
            case .toolCalls(let calls): return ledger.isComplete(calls.id)
            default: return true
            }
        }.map(\.element)
    }

    private nonisolated static func unwrap(_ error: any Error) -> any Error {
        if let tool = error as? LanguageModelSession.ToolCallError { return unwrap(tool.underlyingError) }
        return error
    }

    private nonisolated static func message(for error: any Error) -> String {
        let error = unwrap(error)
        if let model = error as? AgentModelError { return model.message }
        if error is CancellationError { return String(localized: "Agent 请求已取消。") }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// How the tools reach the harness. They hold it weakly: a call that outlives its harness is cancelled.
private struct HarnessAccess: AgentProjectAccess, AgentFinderAccess, AgentWriteAccess, AgentCalendarAccess, AgentOpenAccess,
                              AgentWebSearchAccess, AgentWebFetchAccess, AgentImageAccess, AgentMemoryAccess {
    weak var harness: AgentHarness?

    private var live: AgentHarness {
        get throws {
            guard let harness else { throw CancellationError() }
            return harness
        }
    }

    func projectRoot() async throws -> AgentProjectRoot { try await live.projectRoot() }
    func finderRoot(call: GenerationID?) async throws -> AgentFinderRoot { try await live.finderRoot(call: call) }
    func waitForTurn(call: GenerationID?) async throws { try await live.waitForTurn(call: call) }
    func finished(call: GenerationID?) async { await harness?.finished(call: call) }
    func readAttached(name: String, startLine: Int, call: GenerationID?) async throws -> String {
        try await live.readAttached(name: name, startLine: startLine, call: call)
    }
    func locate(call: GenerationID?) async throws -> FinderLocation? { try await live.locateFinder(call: call) }
    func write(call: GenerationID?, _ request: Result<AgentWriteRequest, AgentInvalidArguments>) async throws -> String {
        try await live.write(call: call, request)
    }
    func run(call: GenerationID?, _ request: Result<AgentCalendarRequest, AgentInvalidArguments>) async throws -> String {
        try await live.calendar(call: call, request)
    }
    func run(call: GenerationID?, _ request: Result<AgentOpenRequest, AgentInvalidArguments>) async throws -> String {
        try await live.open(call: call, request)
    }
    func search(_ request: Result<AgentWebSearchRequest, AgentInvalidArguments>) async throws -> String { try await live.search(request) }
    func fetch(_ address: Result<String, AgentInvalidArguments>) async throws -> String { try await live.fetch(address) }
    func generate(call: GenerationID?, _ request: Result<AgentImageRequest, AgentInvalidArguments>) async throws -> String {
        try await live.generateImage(call: call, request)
    }
    func change(call: GenerationID?, _ request: Result<AgentMemoryChange, AgentInvalidArguments>) async throws -> String {
        try await live.changeMemory(call: call, request)
    }
}

/// One `respond`'s profile: Echo's instructions and tools, the turn's model, and the hooks that
/// report dispatched calls and gate each tool result on a save.
private struct AgentProfile: LanguageModelSession.DynamicProfile {
    let model: any LanguageModel
    let tools: [any Tool]
    /// The names of the files attached to the chat.
    let attachments: [String]
    /// What the memory file holds, read for this `respond`.
    let memory: String?
    weak var harness: AgentHarness?
    @SessionProperty(\.history) var history

    var body: some DynamicProfile {
        Profile {
            Instructions(AgentInstructions.text(tools: tools.map(\.name), attachments: attachments, memory: memory))
            tools
        }
        .model(model)
        .transcriptErrorHandlingPolicy(.preserveTranscript)
        .onToolCall { [weak harness, history = _history] call in
            let entries = Array(history.wrappedValue).filter { if case .instructions = $0 { false } else { true } }
            await harness?.toolDispatched(call, history: entries)
        }
        .onToolOutput { [weak harness, history = _history] call, output in
            var entries = Array(history.wrappedValue).filter { if case .instructions = $0 { false } else { true } }
            if !entries.contains(where: { if case .toolOutput(let saved) = $0 { saved.id == output.id && saved.segments == output.segments } else { false } }) {
                entries.append(.toolOutput(output))
            }
            guard let harness else { throw CancellationError() }
            try await harness.toolFinished(call, history: entries)
        }
    }
}

/// One local `respond`: short instructions and the model, with no tools and so no tool hooks.
private struct LocalChatProfile: LanguageModelSession.DynamicProfile {
    let model: any LanguageModel

    var body: some DynamicProfile {
        Profile {
            Instructions(LocalChatContext.instructions)
        }
        .model(model)
        .transcriptErrorHandlingPolicy(.preserveTranscript)
    }
}
