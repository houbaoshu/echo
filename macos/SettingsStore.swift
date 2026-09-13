import Foundation
import Security

enum ModelAPIProtocol: String, Codable, CaseIterable, Sendable {
    case chatCompletions
    case responses

    var title: String { self == .chatCompletions ? "Chat Completions" : "Responses" }
    var path: String { self == .chatCompletions ? "chat/completions" : "responses" }
}

struct ModelConfiguration: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var apiProtocol: ModelAPIProtocol = .chatCompletions

    private enum CodingKeys: String, CodingKey { case baseURL, model, apiProtocol }

    func rootURL() throws -> URL {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())),
              let url = parts.url else { throw SettingsError("请输入 HTTPS API 根地址；本机服务可使用 HTTP。地址不能包含凭据、查询参数或片段。") }
        return url
    }
    func endpoint() throws -> URL { try rootURL().appendingPathComponent(apiProtocol.path) }
    func validated(requiresModel: Bool = true) throws -> Self {
        _ = try endpoint()
        var result = self
        result.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.baseURL.hasSuffix("/") { result.baseURL.removeLast() }
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requiresModel || !result.model.isEmpty else { throw SettingsError("请输入默认模型。") }
        return result
    }
}

extension ModelConfiguration {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        // Settings saved before protocol selection used Chat Completions.
        apiProtocol = try values.decodeIfPresent(ModelAPIProtocol.self, forKey: .apiProtocol) ?? .chatCompletions
    }
}

struct SettingsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor protocol SecretStore {
    func read(_ account: String) throws -> String
    func write(_ value: String, account: String) throws
    func remove(_ account: String) throws
}

@MainActor final class KeychainSecretStore: SecretStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.chiyan.desktop-pet.model", kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SettingsError("无法读取钥匙串中的 API Key（OSStatus \(status)），请检查钥匙串访问权限。")
        }
        return value
    }
    func write(_ value: String, account: String) throws {
        var query = query(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw SettingsError("无法保存 API Key 到钥匙串。")
        }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsError("无法清除旧的钥匙串凭据。") }
    }
}

struct SettingsSnapshot: Codable {
    var version = 1
    var model = ModelConfiguration()
    var secretAccount: String?
    var selectedPetID = "builtin:chiyan"
    var voice: VoiceConfiguration?
    var voiceSecretAccount: String?
}

protocol ConnectionTesting: Sendable {
    func test(configuration: ModelConfiguration, key: String) async throws
}

// Do not forward a credential-bearing request to a redirect target.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@MainActor final class SettingsStore: ObservableObject {
    @Published var voiceDraft = VoiceConfiguration()
    @Published var voiceAPIKey = ""
    @Published var voiceNotice: String?
    private var savedVoiceKey = ""
    private var voiceKeyLoaded = true
    var isVoiceDirty: Bool { voiceDraft != (snapshot.voice ?? VoiceConfiguration()) || voiceAPIKey != savedVoiceKey }
    @Published var selectedSection = "模型"
    @Published var presentationRevision = 0
    @Published var draft = ModelConfiguration() { didSet { invalidateTest() } }
    @Published var apiKey = "" { didSet { invalidateTest() } }
    @Published private(set) var snapshot = SettingsSnapshot()
    @Published var notice: String?
    @Published private(set) var testResult: String?
    @Published private(set) var testing = false
    @Published private(set) var testSucceeded = false
    private let url: URL?
    private let secrets: any SecretStore
    private let tester: any ConnectionTesting
    private var savedKey = ""
    private var keyLoaded = true
    private var task: Task<Void, Never>?
    private var revision = 0
    private var loadBlocked = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.chiyan.desktop-pet")
    }
    var isDirty: Bool { draft != snapshot.model || apiKey != savedKey }
    init(url: URL? = nil, secrets: any SecretStore = KeychainSecretStore(), tester: any ConnectionTesting = ModelConnectionTester()) {
        self.url = url; self.secrets = secrets; self.tester = tester
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(contentsOf: url))
                guard decoded.version == 1 else { throw SettingsError("设置文件版本不受支持。") }
                snapshot = decoded
            } catch {
                loadBlocked = true
                notice = "设置文件无法读取，原文件保留。请修复或移走 settings.json 后重启应用。"
            }
        }
        draft = snapshot.model
        if let account = snapshot.secretAccount {
            do { savedKey = try secrets.read(account); apiKey = savedKey }
            catch { keyLoaded = false; notice = error.localizedDescription }
        }
        voiceDraft = snapshot.voice ?? VoiceConfiguration()
        if let account = snapshot.voiceSecretAccount {
            do { savedVoiceKey = try secrets.read(account); voiceAPIKey = savedVoiceKey }
            catch { voiceKeyLoaded = false; voiceNotice = "无法读取已保存的语音密钥，请检查钥匙串访问权限。" }
        }
    }
    func savedVoiceCredentials() throws -> (configuration: VoiceConfiguration, key: String) {
        guard voiceKeyLoaded else { throw SettingsError("无法读取已保存的语音密钥，请检查钥匙串访问权限。") }
        let key = try resolvedVoiceKey(savedVoiceKey)
        VoiceDiagnostics.shared.record("1 API Key", "PASS", "来源=\(savedVoiceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已保存的模型密钥" : "语音专用密钥")；非空且格式有效，服务端鉴权待连接验证")
        return (try (snapshot.voice ?? VoiceConfiguration()).validated(), key)
    }
    func savedDictationKey() throws -> String {
        guard voiceKeyLoaded else { throw SettingsError("无法读取已保存的语音密钥，请检查钥匙串访问权限。") }
        return try resolvedVoiceKey(savedVoiceKey)
    }
    // An empty override shares the saved model credential without duplicating it in Keychain.
    // Model form drafts must never silently change the credentials used by voice tests or calls.
    private func resolvedVoiceKey(_ override: String) throws -> String {
        let key: String
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { key = override }
        else {
            guard keyLoaded else { throw SettingsError("无法读取共用的模型 API Key，请在模型设置中重新保存。") }
            key = savedKey
        }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else {
            throw SettingsError("请在模型设置中保存可用于语音服务的 API Key。")
        }
        return value
    }
    func voiceTestKey() throws -> String { try resolvedVoiceKey(voiceAPIKey) }
    var canTestVoice: Bool { (try? voiceTestKey()) != nil }
    func restoreVoice() {
        voiceDraft = snapshot.voice ?? VoiceConfiguration(); voiceAPIKey = savedVoiceKey; voiceNotice = nil
    }
    func saveVoice() {
        do {
            let value = try voiceDraft.validated()
            let key = voiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.contains("\r"), !key.contains("\n") else { throw SettingsError("语音 API Key 不能包含换行。") }
            guard voiceKeyLoaded || !key.isEmpty else { throw SettingsError("原语音密钥尚未读取，请重新填写后保存。") }
            let changed = key != savedVoiceKey || !voiceKeyLoaded
            let oldAccount = snapshot.voiceSecretAccount
            var next = snapshot; next.voice = value
            if changed {
                next.voiceSecretAccount = key.isEmpty ? nil : "voice-\(UUID().uuidString)"
                if let account = next.voiceSecretAccount { try secrets.write(key, account: account) }
            }
            do { try persist(next) }
            catch {
                if changed, let account = next.voiceSecretAccount { try? secrets.remove(account) }
                throw error
            }
            snapshot = next; voiceDraft = value; savedVoiceKey = key; voiceAPIKey = key; voiceKeyLoaded = true
            voiceNotice = nil
            if changed, let oldAccount {
                do { try secrets.remove(oldAccount) }
                catch { voiceNotice = "语音配置已保存，但旧密钥清理失败，请检查钥匙串。" }
            }
        } catch { voiceNotice = error is SettingsError ? error.localizedDescription : "语音配置保存失败，请检查目录写入权限。" }
    }
    func savedModelCredentials() throws -> (configuration: ModelConfiguration, key: String) {
        guard !snapshot.model.model.isEmpty else { throw SettingsError("请先在设置中配置并保存默认模型。") }
        guard keyLoaded else { throw SettingsError("无法读取已保存的 API Key，请在设置中重新填写并保存。") }
        guard !savedKey.contains("\n"), !savedKey.contains("\r") else { throw SettingsError("已保存的 API Key 无效，请重新设置。") }
        return (try snapshot.model.validated(), savedKey)
    }
    private func persist(_ value: SettingsSnapshot) throws {
        guard !loadBlocked else { throw SettingsError("设置文件无法读取，暂不能覆盖原文件。") }
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    func save() {
        do {
            let value = try draft.validated(requiresModel: false)
            guard !apiKey.contains("\n"), !apiKey.contains("\r") else { throw SettingsError("API Key 不能包含换行。") }
            guard keyLoaded || !apiKey.isEmpty else { throw SettingsError("原 API Key 尚未读取，请重新填写密钥后保存。") }
            var next = snapshot; next.model = value
            let changedKey = apiKey != savedKey || !keyLoaded
            let oldAccount = snapshot.secretAccount
            if changedKey {
                next.secretAccount = apiKey.isEmpty ? nil : UUID().uuidString
                if let account = next.secretAccount { try secrets.write(apiKey, account: account) }
            }
            do { try persist(next) }
            catch {
                if changedKey, let account = next.secretAccount { try? secrets.remove(account) }
                throw error
            }
            snapshot = next; draft = value; savedKey = apiKey; keyLoaded = true
            notice = nil
            if changedKey, let oldAccount {
                do { try secrets.remove(oldAccount) }
                catch { notice = "配置已保存，但旧密钥清理失败，请检查钥匙串访问权限。" }
            }
        } catch { notice = error is SettingsError ? error.localizedDescription : "保存失败，请检查设置目录的写入权限后重试。" }
    }
    func selectPet(_ id: String) throws {
        var next = snapshot; next.selectedPetID = id
        try persist(next); snapshot = next
    }
    func restore() { draft = snapshot.model; apiKey = savedKey; notice = nil }
    private func invalidateTest() {
        revision += 1; task?.cancel(); task = nil; testing = false; testResult = nil; testSucceeded = false
    }
    func cancelTest() { invalidateTest(); testResult = "测试已取消。" }
    func testConnection() {
        invalidateTest()
        do {
            let configuration = try draft.validated()
            guard !apiKey.contains("\r"), !apiKey.contains("\n") else { throw SettingsError("API Key 不能包含换行。") }
            let key = apiKey; let current = revision; let tester = tester
            testing = true
            task = Task { [weak self] in
                var result: String; var success = false
                do { try await tester.test(configuration: configuration, key: key); result = "连接成功，指定协议已返回有效的 bash 工具调用。"; success = true }
                catch is CancellationError { return }
                catch let error as SettingsError { result = error.message }
                catch let error as URLError where error.code == .timedOut { result = "连接超时，请检查服务地址与网络后重试。" }
                catch { result = "网络连接失败，请检查服务地址、证书和网络。" }
                guard let self, self.revision == current, !Task.isCancelled else { return }
                self.testing = false; self.testResult = result; self.testSucceeded = success; self.task = nil
            }
        } catch { testResult = error.localizedDescription }
    }
}
