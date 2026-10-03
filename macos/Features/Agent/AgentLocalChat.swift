import Foundation
import FoundationModels
import Synchronization

// Local chat: a small on-device model that answers without tools. The runtime sits behind
// `LocalChatBackend`, so this file builds in every target; only the app links Core AI
// (`CoreAILocalChat.swift`). One generation runs at a time across all conversations: the Core AI
// engine cancels a generation when another one starts.

/// Where the local model lives, judged from its files alone.
enum LocalModelLocation {
    static let name = "qwen3_0_6b_4bit_dynamic"
    /// Where an imported model goes.
    static var installURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiyan.desktop-pet/Models/\(name)", isDirectory: true)
    }

    /// `ECHO_LOCAL_MODEL_PATH` (development and tests), then the installed copy, then a copy
    /// inside the app. The first directory that exists decides.
    static func find(environment: [String: String] = ProcessInfo.processInfo.environment,
                     bundle: Bundle = .main) -> LocalModelAvailability {
        var candidates: [URL] = []
        if let path = environment["ECHO_LOCAL_MODEL_PATH"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        }
        candidates.append(installURL)
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("Models/\(name)", isDirectory: true))
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return .missing }
        if let problem = problem(in: url) { return .invalid(problem) }
        return .ready(url.resolvingSymlinksInPath())
    }

    /// Copies the model at `source` to `destination` after checking it is complete and is the model
    /// Echo expects. Whatever was at `destination` goes to the Trash (a link is removed, not what it
    /// points to). Returns the failure to show, or nil.
    static func install(from source: URL, to destination: URL = installURL) -> String? {
        if let problem = problem(in: source) { return String(localized: "无法导入：\(problem)。") }
        let files = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(name).importing-\(UUID().uuidString)")
        do {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: source.resolvingSymlinksInPath(), to: partial)
            if (try? files.attributesOfItem(atPath: destination.path)) != nil {
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            try files.moveItem(at: partial, to: destination)
            return nil
        } catch {
            try? files.removeItem(at: partial)
            return String(localized: "导入失败：\(error.localizedDescription)")
        }
    }

    /// What keeps the directory from being the complete model Echo supports, with its own
    /// tokenizer, or nil.
    static func problem(in url: URL) -> String? {
        let files = FileManager.default
        guard let metadata = metadata(in: url) else { return String(localized: "缺少 metadata.json") }
        guard metadata["name"] as? String == name else { return String(localized: "不是 \(name) 模型") }
        guard metadata["kind"] as? String == "llm",
              let main = (metadata["assets"] as? [String: Any])?["main"] as? String,
              let language = metadata["language"] as? [String: Any] else { return String(localized: "metadata.json 不是语言模型的描述") }
        guard files.fileExists(atPath: url.appendingPathComponent(main).path) else { return String(localized: "缺少模型文件 \(main)") }
        // Without its own tokenizer, Core AI would fetch one from Hugging Face.
        guard language["embedded_tokenizer"] as? Bool == true,
              files.fileExists(atPath: url.appendingPathComponent("tokenizer/tokenizer.json").path) else { return String(localized: "缺少内嵌 tokenizer") }
        return nil
    }
}

extension LocalModelLocation {
    /// The model's name as its metadata gives it — the source model and its compression —
    /// never the folder it was imported from. Nil unless the directory passes `problem(in:)`.
    static func displayName(in url: URL) -> String? {
        guard problem(in: url) == nil, let metadata = metadata(in: url) else { return nil }
        let source = ((metadata["source"] as? [String: Any])?["hf_model_id"] as? String)
            .flatMap { $0.split(separator: "/").last.map(String.init) } ?? name
        guard let compression = metadata["compression"] as? String, !compression.isEmpty else { return source }
        return "\(source) \(compression)"
    }

    fileprivate static func metadata(in url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum LocalModelAvailability: Equatable, Sendable {
    case ready(URL)
    case missing
    case invalid(String)
}

enum LocalChatError: Error, LocalizedError, Equatable {
    case modelMissing
    case modelInvalid(String)
    case loadFailed(String)
    case messageTooLong
    case noReply
    case cannotContinue

    var errorDescription: String? {
        switch self {
        case .modelMissing: String(localized: "本地模型未安装。请在设置中导入模型文件夹后重试。")
        case .modelInvalid(let reason): String(localized: "本地模型不完整（\(reason)）。请在设置中重新导入模型文件夹。")
        case .loadFailed(let reason): String(localized: "本地模型加载失败：\(reason)")
        case .messageTooLong: String(localized: "这条消息太长，本地模型无法处理。请缩短后重试。")
        case .noReply: String(localized: "本地模型没有给出有效回复，请重试。")
        case .cannotContinue: String(localized: "这一轮已有回复或执行过工具，本地模型无法接着处理。")
        }
    }
}

/// Runs the local model. Implementations load it when first needed and may unload it when idle,
/// but never while a reply is being generated.
protocol LocalChatBackend: Sendable {
    func availability() -> LocalModelAvailability
    /// Streams one reply to `request`; waiting for a load ends at cancellation.
    func respond(to request: LanguageModelExecutorGenerationRequest,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}

/// The app's local model, shared by every conversation.
final class LocalChatService: Sendable {
    let backend: any LocalChatBackend
    private let gate = LocalChatGate()

    init(backend: any LocalChatBackend) { self.backend = backend }

    var factory: AgentHarness.ModelFactory {
        { [self] ledger, budget in LocalChatLanguageModel(service: self, ledger: ledger, budget: budget) }
    }

    fileprivate func generate(_ request: LanguageModelExecutorGenerationRequest,
                              into channel: LanguageModelExecutorGenerationChannel) async throws {
        try await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        try await backend.respond(to: request, streamingInto: channel)
    }
}

/// FIFO mutual exclusion across tasks; a cancelled waiter leaves the queue.
final class LocalChatGate: Sendable {
    private struct State {
        var busy = false
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    }
    private let state = Mutex(State())
    init() {}

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancellation is read under the lock, so the handler either sees this waiter or ran before it.
                let result = state.withLock { state -> Result<Void, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    guard state.busy else { state.busy = true; return .success(()) }
                    state.waiters.append((id, continuation))
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0).continuation }
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.waiters.isEmpty else { state.busy = false; return nil }
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}

// MARK: - Language model

/// Chat only: no tools, no reasoning, no guided generation.
struct LocalChatLanguageModel: LanguageModel {
    typealias Executor = LocalChatExecutor
    let service: LocalChatService
    let ledger: GenerationLedger
    let budget: GenerationBudget

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
    var executorConfiguration: LocalChatExecutor.Configuration {
        .init(service: ObjectIdentifierBox(service), ledger: ledger, budget: budget)
    }
}

struct LocalChatExecutor: LanguageModelExecutor {
    typealias Model = LocalChatLanguageModel
    struct Configuration: Hashable, Sendable {
        let service: ObjectIdentifierBox<LocalChatService>
        let ledger: GenerationLedger
        let budget: GenerationBudget
    }
    let configuration: Configuration
    init(configuration: Configuration) { self.configuration = configuration }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: LocalChatLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try configuration.budget.spend()
        var local = request
        local.enabledToolDefinitions = []
        // Qwen3 thinks before answering unless its chat template gets enable_thinking=false.
        local.contextOptions.reasoningLevel = .custom("none")
        local.generationOptions.maximumResponseTokens = LocalChatContext.maximumResponseTokens
        try await configuration.service.value.generate(local, into: channel)
        // A cancelled generation can end without an error; only one that ran to its end is complete.
        try Task.checkCancellation()
        configuration.ledger.markAllComplete()
    }
}

// MARK: - Context

/// What the local model sees: short instructions and the recent chat, never tool traffic. It is a
/// view for the model's input; the conversation's saved history stays whole.
enum LocalChatContext {
    static let instructions = """
        You are Echo's offline assistant, running as a small model on this Mac. You cannot use the \
        internet, read files, or run commands. Answer briefly in the user's language. If a request \
        needs tools, files, or current information, say that it needs a network connection.
        """
    static let maximumResponseTokens = 512
    /// Characters of chat, the message being answered included. The model holds 4096 tokens.
    static let characterBudget = 3000
    /// Messages, the one being answered included.
    static let messageLimit = 12

    /// The newest user messages and replies of `entries` that fit beside `prompt`. The message
    /// being answered — `prompt`, or for a continue the last user message — is never cut short:
    /// when it does not fit, this throws instead.
    static func history(_ entries: [Transcript.Entry], prompt: String) throws -> [Transcript.Entry] {
        var used = prompt.count
        guard used <= characterBudget else { throw LocalChatError.messageTooLong }
        var room = prompt.isEmpty ? messageLimit : messageLimit - 1
        var kept: [Transcript.Entry] = []
        for entry in entries.reversed() {
            guard let text = chatText(entry) else { continue }
            guard room > 0, used + text.count <= characterBudget else {
                if prompt.isEmpty && kept.isEmpty { throw LocalChatError.messageTooLong }
                break
            }
            kept.insert(entry, at: 0)
            used += text.count; room -= 1
        }
        // A reply without its question reads as the model's own opening.
        while let first = kept.first, case .response = first { kept.removeFirst() }
        return kept
    }

    /// Whether the last user message never got anything back: no reply was kept and no tool was
    /// called for it. Only such a message may be answered by the local model on a continue, so an
    /// interrupted turn is never handled twice. A restart closes calls left open with results, and
    /// a Stop drops only a reply that was cut off, so both are judged from the saved history alone.
    static func isUnanswered(_ entries: [Transcript.Entry]) -> Bool {
        guard let last = entries.lastIndex(where: { entry in
            if case .prompt(let prompt) = entry { prompt.metadata[AgentPromptKey.message] != nil } else { false }
        }) else { return false }
        return entries[(last + 1)...].allSatisfy { if case .prompt = $0 { true } else { false } }
    }

    /// The text of a user message or reply the local model keeps; nil for everything else.
    static func chatText(_ entry: Transcript.Entry) -> String? {
        switch entry {
        case .prompt(let prompt):
            guard prompt.metadata[AgentPromptKey.feedback] == nil, !AgentPromptMarker.isContinue(prompt) else { return nil }
            let text = AgentHarness.text(prompt.segments)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        case .response(let response):
            let text = AgentHarness.text(response.segments)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        default:
            return nil
        }
    }
}
