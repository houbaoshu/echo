import CoreAILanguageModels
import Foundation
import FoundationModels
import Synchronization

// Built into the app target only: the other targets that share `macos/` exclude this file, so
// they need no Core AI.

/// Runs the local model with Core AI. One model stays loaded between replies and goes after five
/// idle minutes or under memory pressure, never while a reply is being generated. Core AI keeps an
/// engine only while someone holds its model, so this object holds it.
final class CoreAILocalChatBackend: LocalChatBackend {
    static let idleUnload: Duration = .seconds(300)

    private struct State {
        var model: LoadedModel?
        var loading: Task<LoadedModel, any Error>?
        /// Replies being generated, or waiting for the model to load.
        var active = 0
        var idleTimer: Task<Void, Never>?
        /// Memory ran low during a reply: unload as soon as it ends.
        var unloadWhenIdle = false
    }
    private let state = Mutex(State())
    private let locate: @Sendable () -> LocalModelAvailability
    private let idle: Duration
    private let pressure: any DispatchSourceMemoryPressure

    init(idle: Duration = CoreAILocalChatBackend.idleUnload,
         locate: @escaping @Sendable () -> LocalModelAvailability = { LocalModelLocation.find() }) {
        self.locate = locate
        self.idle = idle
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak self] in self?.memoryPressure() }
        pressure.activate()
    }
    deinit { pressure.cancel() }

    func availability() -> LocalModelAvailability { locate() }

    var isLoaded: Bool { state.withLock { $0.model != nil } }

    /// A loaded model and the name its files gave when it was loaded; replacing the files later
    /// does not change what this instance is.
    struct LoadedModel: Sendable {
        let model: CoreAILanguageModel
        let name: String
    }

    func respond(to request: LanguageModelExecutorGenerationRequest,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws -> String {
        begin()
        defer { end() }
        let loaded = try await loadedModel()
        let executor = try CoreAILanguageModel.CoreAIExecutor(configuration: loaded.model.executorConfiguration)
        do {
            try await executor.respond(to: request, model: loaded.model, streamingInto: channel)
        } catch InferenceRuntimeError.contextLengthExceeded {
            throw LocalChatError.messageTooLong
        }
        return loaded.name
    }

    /// Unloads the model now unless a reply is using it.
    func unloadIfIdle() {
        let model = state.withLock { state -> CoreAILanguageModel? in
            guard state.active == 0, state.loading == nil else { return nil }
            state.idleTimer?.cancel(); state.idleTimer = nil
            state.unloadWhenIdle = false
            defer { state.model = nil }
            return state.model?.model
        }
        model?.unload()
    }

    // MARK: Loading

    private func loadedModel() async throws -> LoadedModel {
        let (model, loading) = state.withLock { state -> (LoadedModel?, Task<LoadedModel, any Error>?) in
            if let model = state.model { return (model, nil) }
            if let loading = state.loading { return (nil, loading) }
            let availability = locate()
            let loading = Task { [weak self] in
                do {
                    let model = try await Self.load(availability)
                    self?.finishLoad(model)
                    return model
                } catch {
                    self?.finishLoad(nil)
                    throw error
                }
            }
            state.loading = loading
            return (nil, loading)
        }
        if let model { return model }
        // A Stop does not wait for the load; it carries on and the model is kept for next time.
        return try await Self.value(of: loading!)
    }

    private func finishLoad(_ model: LoadedModel?) {
        let unloadNow = state.withLock { state -> Bool in
            state.loading = nil
            if let model { state.model = model }
            return settle(&state)
        }
        if unloadNow { unloadIfIdle() }
    }

    private static func load(_ availability: LocalModelAvailability) async throws -> LoadedModel {
        let url: URL
        switch availability {
        case .ready(let ready): url = ready
        case .missing: throw LocalChatError.modelMissing
        case .invalid(let reason): throw LocalChatError.modelInvalid(reason)
        }
        let bundle: LanguageBundle
        do { bundle = try LanguageBundle(at: url) } catch { throw LocalChatError.modelInvalid(error.localizedDescription) }
        // Without its own tokenizer, Core AI would fetch one from Hugging Face.
        guard bundle.hasEmbeddedTokenizer else { throw LocalChatError.modelInvalid("缺少内嵌 tokenizer") }
        guard let name = LocalModelLocation.displayName(in: url) else { throw LocalChatError.modelInvalid("模型信息不完整") }
        do {
            let model = try await CoreAILanguageModel(resourcesAt: url, mode: .lazy)
            try await model.load()
            return LoadedModel(model: model, name: name)
        } catch {
            throw LocalChatError.loadFailed(error.localizedDescription)
        }
    }

    /// The task's value, or CancellationError as soon as the caller is cancelled.
    private static func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let waiter = OnceContinuation<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.set(continuation)
                if Task.isCancelled { waiter.take()?.resume(throwing: CancellationError()) }
                Task { let result = await task.result; waiter.take()?.resume(with: result) }
            }
        } onCancel: {
            waiter.take()?.resume(throwing: CancellationError())
        }
    }

    // MARK: Idle and memory

    private func begin() {
        state.withLock { state in
            state.active += 1
            state.idleTimer?.cancel(); state.idleTimer = nil
        }
    }

    private func end() {
        let unloadNow = state.withLock { state -> Bool in
            state.active -= 1
            return settle(&state)
        }
        if unloadNow { unloadIfIdle() }
    }

    /// Once no reply uses the model: true when it must go now because memory ran low; otherwise
    /// the idle timer starts.
    private func settle(_ state: inout State) -> Bool {
        guard state.active == 0 else { return false }
        if state.unloadWhenIdle { return true }
        state.idleTimer?.cancel()
        guard state.model != nil else { state.idleTimer = nil; return false }
        let idle = idle
        state.idleTimer = Task { [weak self] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            self?.unloadIfIdle()
        }
        return false
    }

    private func memoryPressure() {
        let busy = state.withLock { state -> Bool in
            guard state.model != nil || state.loading != nil else { return false }
            if state.active > 0 || state.loading != nil { state.unloadWhenIdle = true; return true }
            return false
        }
        if !busy { unloadIfIdle() }
    }
}

/// A continuation resumed at most once, by whichever side gets to it first.
private final class OnceContinuation<T: Sendable>: Sendable {
    private let slot = Mutex<CheckedContinuation<T, any Error>?>(nil)
    func set(_ continuation: CheckedContinuation<T, any Error>) { slot.withLock { $0 = continuation } }
    func take() -> CheckedContinuation<T, any Error>? {
        slot.withLock { continuation in defer { continuation = nil }; return continuation }
    }
}
