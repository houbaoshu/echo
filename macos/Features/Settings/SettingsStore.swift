import Foundation
import Observation

@MainActor @Observable final class SettingsStore {
    var voiceDraft = VoiceConfiguration()
    var voiceNotice: String?
    var isVoiceDirty: Bool { voiceDraft != (snapshot.voice ?? VoiceConfiguration()) }
    /// The Volcengine Ark group's key, as edited. Emptying it turns "use for chat" off.
    var arkAPIKey = "" { didSet { arkGroupEdited() } }
    /// The rest of the Volcengine Ark group, as edited. "Use for chat" stays off without a key.
    var arkDraft = ArkSettings() { didSet { arkGroupEdited() } }
    var arkNotice: String?
    private var arkCredential = Credential()
    var isArkDirty: Bool { arkAPIKey != arkCredential.key || arkDraft != snapshot.ark }
    /// What the Volcengine Ark group reports below its box: why it could not be saved, or its test.
    var arkStatus: SettingsTestLine? { arkNotice.map { SettingsTestLine(text: $0, succeeded: false) } ?? arkTestResult }
    /// Whether "use for chat" can be on: only with a Volcengine Ark key typed in.
    var canUseArkForChat: Bool { !arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The Volcengine Ark group's test: one search with the key as typed, and the language model's
    /// tool calling when one is filled in, as one line.
    private(set) var arkTestResult: SettingsTestLine?
    private(set) var arkTesting = false
    @ObservationIgnored private var arkTask: Task<Void, Never>?
    @ObservationIgnored private var arkRevision = 0
    var selectedSection = SettingsSection.model
    var presentationRevision = 0
    private(set) var selectedProvider: ModelProvider = .deepSeek
    var draft = ModelConfiguration() { didSet { invalidateTest() } }
    var apiKey = "" { didSet { invalidateTest() } }
    private(set) var snapshot = SettingsSnapshot()
    var notice: String?
    /// The model service's test: chat and tool calling with the group as typed.
    private(set) var testResult: SettingsTestLine?
    /// What the model service group reports below its box: why it could not be saved, or its test.
    var modelServiceStatus: SettingsTestLine? { notice.map { SettingsTestLine(text: $0, succeeded: false) } ?? testResult }
    private(set) var testing = false
    /// The offline model, as its files show it; refreshed when the model settings appear.
    private(set) var localModel: LocalModelAvailability = .missing
    /// The ready model's name from its metadata, read with `localModel`; nil when there is no usable one.
    private(set) var localModelName: String?
    private(set) var importingLocalModel = false
    var localModelNotice: String?
    private let url: URL?
    /// What the person asked the Agent to remember, beside settings.json; nil when the store is off disk.
    var memoryFile: AgentMemoryFile? { url.map { AgentMemoryFile(folder: $0.deletingLastPathComponent()) } }
    /// Why the memory file could not be opened or cleared, or the switch saved, beneath the buttons.
    var memoryNotice: String?
    /// The memory as the memory page last read it; nil when it holds nothing.
    private(set) var memoryContents: MemoryContents?
    struct MemoryContents: Equatable {
        let modified: Date?
        let lines: [AgentMemoryLine]
    }
    /// Where clearing the memory moves its file.
    private let trash: AgentTrash
    /// Where the offline model is imported and looked for. Like `url`, nil keeps the store off
    /// disk: there is no model.
    let localModels: LocalModelLocation?
    private let secrets: any SecretStore
    private let tester: any ConnectionTesting
    private let arkTester: any ArkConnectionTesting
    private struct Credential {
        var key = ""
        var loaded = true
    }
    private struct ProviderDraft {
        var model: ModelConfiguration
        var key: String
    }
    private var credentials: [ModelProvider: Credential] = [:]
    private var providerDrafts: [ModelProvider: ProviderDraft] = [:]
    private var savedCredential: Credential { credentials[snapshot.activeProvider] ?? Credential() }
    private var selectedCredential: Credential { credentials[selectedProvider] ?? Credential() }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    private var loadBlocked = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.houbaoshu.echo")
    }
    var isDirty: Bool {
        selectedProvider != snapshot.activeProvider || draft != snapshot.settings(for: selectedProvider).model
            || apiKey != selectedCredential.key
    }
    var canRestoreModel: Bool {
        isDirty || providerDrafts.contains { provider, value in
            value.model != snapshot.settings(for: provider).model || value.key != (credentials[provider]?.key ?? "")
        }
    }
    init(url: URL? = nil, localModels: LocalModelLocation? = nil, secrets: any SecretStore = KeychainSecretStore(),
         tester: any ConnectionTesting = NativeConnectionTester(),
         arkTester: any ArkConnectionTesting = DoubaoSearchTester(), trash: AgentTrash = .system) {
        self.url = url; self.localModels = localModels; self.secrets = secrets; self.tester = tester
        self.arkTester = arkTester; self.trash = trash
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(contentsOf: url))
                snapshot = decoded
            } catch let error as SettingsError where error == SettingsSnapshot.unsupportedVersion {
                loadBlocked = true
                notice = error.message
            } catch {
                loadBlocked = true
                notice = String(localized: "设置文件无法读取，原文件保留。请修复或移走 settings.json 后重启应用。")
            }
        }
        removeReplacedKeys()
        // Without a key the switch cannot be on, a setting carried over from a provider included.
        if snapshot.arkSecretAccount == nil { snapshot.ark.useForChat = false }
        selectedProvider = snapshot.activeProvider
        loadProvider(selectedProvider)
        voiceDraft = snapshot.voice ?? VoiceConfiguration()
        if let account = snapshot.arkSecretAccount {
            do { arkCredential.key = try secrets.read(account); arkAPIKey = arkCredential.key }
            catch { arkCredential.loaded = false; arkNotice = String(localized: "无法读取已保存的火山方舟 API Key，请检查钥匙串访问权限。") }
        }
        arkDraft = snapshot.ark
    }
    /// Voice's own key and Volcengine Ark's own model key, from before the Volcengine Ark group,
    /// are never read: launch removes them from the keychain and their names from settings.json.
    /// A name whose key could not be removed stays, to be tried again at the next launch.
    private func removeReplacedKeys() {
        guard !loadBlocked else { return }
        var next = snapshot
        if let account = next.legacyVoiceSecretAccount, (try? secrets.remove(account)) != nil {
            next.legacyVoiceSecretAccount = nil
        }
        if let account = next.legacyArkSecretAccount, (try? secrets.remove(account)) != nil {
            next.legacyArkSecretAccount = nil
        }
        guard next.legacyVoiceSecretAccount != snapshot.legacyVoiceSecretAccount
                || next.legacyArkSecretAccount != snapshot.legacyArkSecretAccount else { return }
        do { try persist(next); snapshot = next } catch {}
    }
    private func loadProvider(_ provider: ModelProvider) {
        if credentials[provider] == nil {
            var credential = Credential()
            if provider.requiresKey, let account = snapshot.settings(for: provider).secretAccount {
                do { credential.key = try secrets.read(account) }
                catch { credential.loaded = false }
            }
            credentials[provider] = credential
        }
        if credentials[provider]?.loaded == false {
            notice = String(localized: "无法读取此 provider 的 API Key，请检查钥匙串权限或重新填写后保存。")
        }
        draft = providerDrafts[provider]?.model ?? snapshot.settings(for: provider).model
        apiKey = provider.requiresKey ? (providerDrafts[provider]?.key ?? selectedCredential.key) : ""
    }
    func selectProvider(_ provider: ModelProvider) {
        guard provider != selectedProvider else { return }
        providerDrafts[selectedProvider] = ProviderDraft(model: draft, key: apiKey)
        selectedProvider = provider
        notice = nil
        loadProvider(provider)
    }
    func savedVoiceCredentials() throws -> (configuration: VoiceConfiguration, key: String) {
        let key = try savedArkCredential()
        VoiceDiagnostics.shared.record("1 API Key", "PASS", "非空且格式有效，服务端鉴权待连接验证")
        return (try (snapshot.voice ?? VoiceConfiguration()).validated(), key)
    }
    /// Voice tests what voice will use: the saved Volcengine Ark key, not one still being typed.
    func voiceTestKey() throws -> String { try savedArkCredential() }
    var canTestVoice: Bool { savedArkKey != nil }
    /// Saves the voice ID when it was edited: the voice page has no save button, so Return and
    /// leaving the field both come here.
    func commitVoice() { if isVoiceDirty { saveVoice() } }
    func saveVoice() {
        do {
            let value = try voiceDraft.validated()
            var next = snapshot; next.voice = value
            try persist(next)
            snapshot = next; voiceDraft = value
            voiceNotice = nil
        } catch { voiceNotice = Self.notice(for: error, otherwise: String(localized: "语音配置保存失败，请检查目录写入权限。")) }
    }
    /// The saved Volcengine Ark key, trimmed; nil when there is none or it cannot be read. Voice
    /// uses this key whichever service chats; chat with Volcengine Ark and Doubao search use it
    /// while Volcengine Ark chats. No other key ever stands in for it.
    var savedArkKey: String? { Self.usableKey(arkCredential) }
    private func savedArkCredential() throws -> String {
        guard arkCredential.loaded else { throw SettingsError(localized: "无法读取已保存的火山方舟 API Key，请检查钥匙串访问权限。") }
        guard let key = savedArkKey else { throw SettingsError.arkKeyMissing }
        return key
    }
    func restoreArk() { arkAPIKey = arkCredential.key; arkDraft = snapshot.ark; arkNotice = nil }
    func saveArk() {
        do {
            var value = try arkDraft.validated()
            let key = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.hasLineBreak else { throw SettingsError(localized: "API Key 不能包含换行。") }
            guard arkCredential.loaded || !key.isEmpty else { throw SettingsError(localized: "原 API Key 尚未读取，请重新填写密钥后保存。") }
            let changed = key != arkCredential.key || !arkCredential.loaded
            let oldAccount = snapshot.arkSecretAccount
            // The first key saved while the model service has no key of its own, neither saved nor
            // typed, turns Volcengine Ark chat on, once, when there is a language model to chat with;
            // from then on the switch is the person's.
            if snapshot.arkSecretAccount == nil, !key.isEmpty, !value.languageModel.isEmpty,
               snapshot.activeProvider.requiresKey, savedModelServiceKey == nil, selectedProvider.requiresKey,
               apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.useForChat = true }
            var next = snapshot; next.ark = value
            if changed { next.arkSecretAccount = try writeNewKey(key, prefix: "ark") }
            try persist(next, removingOnFailure: changed ? next.arkSecretAccount : nil)
            snapshot = next; arkCredential = Credential(key: key); arkAPIKey = key; arkDraft = value
            arkNotice = changed ? removeReplacedKey(oldAccount) : nil
        } catch { arkNotice = Self.notice(for: error, otherwise: String(localized: "保存失败，请检查设置目录的写入权限后重试。")) }
    }
    func refreshLocalModel() {
        localModel = localModels?.find() ?? .missing
        if case .ready(let url) = localModel {
            localModelName = LocalModelLocation.displayName(in: url) ?? url.lastPathComponent
        } else { localModelName = nil }
    }
    /// Copies a model folder the user picked into Echo's Models folder, checking it first.
    func importLocalModel(from source: URL) {
        guard !importingLocalModel, let localModels else { return }
        importingLocalModel = true; localModelNotice = nil
        Task {
            let failure = await Task.detached {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                return localModels.install(from: source)
            }.value
            importingLocalModel = false
            localModelNotice = failure ?? String(localized: "已导入本地模型。")
            refreshLocalModel()
        }
    }
    /// The memory file to open in the person's editor, created empty when there is none. Nil when
    /// it cannot be, with `memoryNotice` saying why.
    func memoryFileForEditing() -> URL? {
        guard let memoryFile else { return nil }
        do {
            let url = try memoryFile.prepareForEditing()
            memoryNotice = nil
            return url
        } catch {
            memoryNotice = String(localized: "无法创建记忆文件：\(error.localizedDescription)")
            return nil
        }
    }
    /// Reads the memory again, as the Agent's next turn would get it.
    func reloadMemory() {
        guard let memoryFile, let text = memoryFile.read() else { memoryContents = nil; return }
        let lines = AgentMemoryLine.lines(of: text)
        memoryContents = lines.isEmpty ? nil : MemoryContents(modified: memoryFile.modified(), lines: lines)
    }
    /// Moves the memory file to the Trash, so Put Back restores it.
    func clearMemory() {
        guard let memoryFile else { return }
        do {
            try trash.move(memoryFile.url)
            memoryNotice = nil
        } catch {
            memoryNotice = String(localized: "无法清空记忆：\(error.localizedDescription)")
        }
        reloadMemory()
    }
    /// The model service's saved key, trimmed; nil when there is none or it cannot be read. Unlike
    /// `savedModelCredentials`, it is the model service's whether or not Volcengine Ark chats.
    var savedModelServiceKey: String? { Self.usableKey(savedCredential) }
    func savedModelCredentials() throws -> (configuration: ModelConfiguration, key: String) {
        if snapshot.ark.useForChat {
            guard !snapshot.ark.languageModel.isEmpty else { throw SettingsError.modelNotConfigured }
            return (try snapshot.ark.chatConfiguration.validated(), try savedArkCredential())
        }
        guard !snapshot.model.model.isEmpty else { throw SettingsError.modelNotConfigured }
        guard savedCredential.loaded else { throw SettingsError(localized: "无法读取已保存的 API Key，请在设置中重新填写并保存。") }
        guard !savedCredential.key.hasLineBreak else { throw SettingsError(localized: "已保存的 API Key 无效，请重新设置。") }
        return (try snapshot.model.validated(), savedCredential.key)
    }
    /// A saved key as it can be sent: read, trimmed, not empty and on one line; nil otherwise.
    private static func usableKey(_ credential: Credential) -> String? {
        let key = credential.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.loaded, !key.isEmpty, !key.hasLineBreak else { return nil }
        return key
    }
    private func persist(_ value: SettingsSnapshot) throws {
        guard !loadBlocked else { throw SettingsError(localized: "设置文件无法读取，暂不能覆盖原文件。") }
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    /// Saves `next`; a key just written for it is removed again when the file cannot be.
    private func persist(_ next: SettingsSnapshot, removingOnFailure newAccount: String?) throws {
        do { try persist(next) }
        catch {
            if let newAccount { try? secrets.remove(newAccount) }
            throw error
        }
    }
    /// Writes a key to a keychain account of its own, named after `prefix`; no key, no account.
    private func writeNewKey(_ key: String, prefix: String) throws -> String? {
        guard !key.isEmpty else { return nil }
        let account = "\(prefix)-\(UUID().uuidString)"
        try secrets.write(key, account: account)
        return account
    }
    /// Removes the key a save replaced; what the group reports when it could not be.
    private func removeReplacedKey(_ account: String?) -> String? {
        guard let account else { return nil }
        do { try secrets.remove(account); return nil }
        catch { return String(localized: "配置已保存，但旧密钥清理失败，请检查钥匙串访问权限。") }
    }
    /// What a failed save shows: a SettingsError says why itself; anything else gets `fallback`.
    private static func notice(for error: any Error, otherwise fallback: @autoclosure () -> String) -> String {
        error is SettingsError ? error.localizedDescription : fallback()
    }
    func save() {
        do {
            let value = try draft.validated(requiresModel: false)
            let key = selectedProvider.requiresKey ? apiKey : ""
            guard !key.hasLineBreak else { throw SettingsError(localized: "API Key 不能包含换行。") }
            guard selectedCredential.loaded || !key.isEmpty else { throw SettingsError(localized: "原 API Key 尚未读取，请重新填写密钥后保存。") }
            var next = snapshot
            next.activeProvider = selectedProvider
            let oldAccount = snapshot.settings(for: selectedProvider).secretAccount
            let changedKey = key != selectedCredential.key || !selectedCredential.loaded
                || (!selectedProvider.requiresKey && oldAccount != nil)
            var entry = ProviderSettings(model: value, secretAccount: oldAccount)
            if changedKey { entry.secretAccount = try writeNewKey(key, prefix: "model-\(selectedProvider.rawValue)") }
            next.providers[selectedProvider.rawValue] = entry
            try persist(next, removingOnFailure: changedKey ? entry.secretAccount : nil)
            snapshot = next; draft = value; apiKey = key
            credentials[selectedProvider] = Credential(key: key)
            providerDrafts[selectedProvider] = nil
            notice = changedKey ? removeReplacedKey(oldAccount) : nil
        } catch { notice = Self.notice(for: error, otherwise: String(localized: "保存失败，请检查设置目录的写入权限后重试。")) }
    }
    /// Takes effect from the next turn; a reply being written keeps its model.
    func setLocalModelOnly(_ enabled: Bool) {
        guard enabled != snapshot.localModelOnly else { return }
        do { try update { $0.localModelOnly = enabled } }
        catch { localModelNotice = Self.notice(for: error, otherwise: String(localized: "设置保存失败，请检查目录写入权限。")) }
    }
    /// Takes effect from the next turn; a reply being written keeps the memory it started with.
    func setMemoryEnabled(_ enabled: Bool) {
        guard enabled != snapshot.memoryEnabled else { return }
        do { try update { $0.memoryEnabled = enabled } }
        catch { memoryNotice = Self.notice(for: error, otherwise: String(localized: "设置保存失败，请检查目录写入权限。")) }
    }
    func selectPet(_ id: String) throws { try update { $0.selectedPetID = id } }
    func selectPlanet(_ id: String) throws { try update { $0.selectedPlanetID = id } }
    /// One saved preference: the published snapshot changes only once the file has it.
    private func update(_ change: (inout SettingsSnapshot) -> Void) throws {
        var next = snapshot; change(&next)
        try persist(next); snapshot = next
    }
    func restore() {
        providerDrafts.removeAll()
        selectedProvider = snapshot.activeProvider
        notice = nil
        loadProvider(selectedProvider)
    }
    private func invalidateTest() {
        revision += 1; task?.cancel(); task = nil; testing = false; testResult = nil
    }
    /// "Use for chat" goes off with the key; any edit outdates the group's test.
    private func arkGroupEdited() {
        if arkDraft.useForChat && !canUseArkForChat { arkDraft.useForChat = false }
        invalidateArkTest()
    }
    private func invalidateArkTest() {
        arkRevision += 1; arkTask?.cancel(); arkTask = nil; arkTesting = false; arkTestResult = nil
    }
    private static let cancelled = SettingsTestLine(text: String(localized: "测试已取消。"), succeeded: false)
    /// Stops whichever tests are running; a group whose test was not running keeps what it showed.
    func cancelTest() {
        if testing { cancelModelServiceTest() }
        if arkTesting { cancelArkTest() }
    }
    func cancelModelServiceTest() { invalidateTest(); testResult = Self.cancelled }
    func cancelArkTest() { invalidateArkTest(); arkTestResult = Self.cancelled }
    /// The model service's own test needs its key, unless the provider takes none.
    var canTestModelService: Bool {
        !selectedProvider.requiresKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canTestArk: Bool { canUseArkForChat }
    /// Tests the model service as typed, saved or not: one request that must call a tool. Its result
    /// takes the place of whatever the group last said.
    func testConnection() {
        invalidateTest(); notice = nil
        let configuration: ModelConfiguration, key: String
        do {
            configuration = try draft.validated()
            key = selectedProvider.requiresKey ? apiKey : ""
            guard !key.hasLineBreak else { throw SettingsError(localized: "API Key 不能包含换行。") }
        } catch { testResult = SettingsTestLine(text: error.localizedDescription, succeeded: false); return }
        let current = revision, tester = tester
        testing = true
        task = Task { [weak self] in
            let line = await Self.testChat(tester, (configuration, key))
            guard let self, self.revision == current, !Task.isCancelled else { return }
            self.testing = false; self.testResult = line; self.task = nil
        }
    }
    /// Tests the Volcengine Ark group as typed, saved or not: one web search with the key, and the
    /// language model's tool calling when one is filled in, whether or not the switch is on.
    func testArk() {
        invalidateArkTest(); arkNotice = nil
        let key = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard !key.hasLineBreak else {
            arkTestResult = SettingsTestLine(text: String(localized: "API Key 不能包含换行。"), succeeded: false); return
        }
        let model = arkDraft.languageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = arkDraft; chat.languageModel = model
        let request = model.isEmpty ? nil : (configuration: chat.chatConfiguration, key: key)
        let current = arkRevision, tester = tester, arkTester = arkTester
        arkTesting = true
        arkTask = Task { [weak self] in
            async let searchLine = Self.testSearch(arkTester, key: key)
            async let chatLine = Self.testChat(tester, request)
            let line = Self.arkLine(search: await searchLine, chat: await chatLine)
            guard let self, self.arkRevision == current, !Task.isCancelled else { return }
            self.arkTesting = false; self.arkTestResult = line; self.arkTask = nil
        }
    }
    /// The two checks as one line: one sentence when both pass, otherwise only what failed.
    private nonisolated static func arkLine(search: SettingsTestLine, chat: SettingsTestLine?) -> SettingsTestLine {
        guard let chat else { return search }
        let chatFailure = String(localized: "语言模型：\(chat.text)")
        switch (search.succeeded, chat.succeeded) {
        case (true, true): return SettingsTestLine(text: String(localized: "连接成功，联网搜索和工具调用均正常。"), succeeded: true)
        case (true, false): return SettingsTestLine(text: chatFailure, succeeded: false)
        case (false, true): return search
        case (false, false): return SettingsTestLine(text: "\(search.text) \(chatFailure)", succeeded: false)
        }
    }
    private nonisolated static func testChat(_ tester: any ConnectionTesting,
                                             _ request: (configuration: ModelConfiguration, key: String)?) async -> SettingsTestLine? {
        guard let request else { return nil }
        do {
            try await tester.test(configuration: request.configuration, key: request.key)
            return SettingsTestLine(text: String(localized: "连接成功，指定协议已返回有效的工具调用。"), succeeded: true)
        }
        catch let error as SettingsError { return SettingsTestLine(text: error.message, succeeded: false) }
        catch let error as URLError where error.code == .timedOut { return SettingsTestLine(text: String(localized: "连接超时，请检查服务地址与网络后重试。"), succeeded: false) }
        catch { return SettingsTestLine(text: String(localized: "网络连接失败，请检查服务地址、证书和网络。"), succeeded: false) }
    }
    private nonisolated static func testSearch(_ tester: any ArkConnectionTesting, key: String) async -> SettingsTestLine {
        do {
            try await tester.test(key: key)
            return SettingsTestLine(text: String(localized: "连接成功，联网搜索已返回结果。"), succeeded: true)
        }
        catch let error as SettingsError { return SettingsTestLine(text: error.message, succeeded: false) }
        catch { return SettingsTestLine(text: String(localized: "无法连接豆包搜索：\(error.localizedDescription)"), succeeded: false) }
    }
}

extension String {
    /// A key with a line break in it cannot go in a request header.
    var hasLineBreak: Bool { contains("\r") || contains("\n") }
}
