import AppIntents

// Shortcuts, Spotlight and Siri reach the pet through these. Each one does what the pet's own
// control does, through the same call, and nothing more: none opens the main window or waits for
// a reply. Every one runs with Echo in the background, so one that launches Echo leaves it the way
// a plain launch does, with only the pet on screen. A failure shows where the pet's own control
// shows it. The system resolves `companion` before `perform()`; tests set it themselves.

struct ShowPetIntent: AppIntent {
    static let title: LocalizedStringResource = "显示桌宠"
    static let description = IntentDescription("把收起的桌宠放回桌面。")
    static let supportedModes: IntentModes = .background
    @Dependency var companion: CompanionController

    @MainActor func perform() async throws -> some IntentResult {
        companion.setPetHidden(false)
        return .result()
    }
}

struct HidePetIntent: AppIntent {
    static let title: LocalizedStringResource = "隐藏桌宠"
    static let description = IntentDescription("收起桌宠，Echo 仍在运行。")
    static let supportedModes: IntentModes = .background
    @Dependency var companion: CompanionController

    @MainActor func perform() async throws -> some IntentResult {
        companion.setPetHidden(true)
        return .result()
    }
}

/// The pet's Live Voice button. A call already on is left alone: the workspace starts none while
/// one runs.
struct StartLiveVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "开始 Live Voice"
    static let description = IntentDescription("在新聊天里开始 Live Voice，和点桌宠上的语音按钮一样。已在通话中时不做任何事。")
    static let supportedModes: IntentModes = .background
    @Dependency var companion: CompanionController

    @MainActor func perform() async throws -> some IntentResult {
        companion.setPetHidden(false)
        companion.workspace.startVoiceInNewConversation(projectID: companion.controlsPresentation.projectID)
        return .result()
    }
}

/// The pet's quick composer: a new chat whose reply shows on the pet's card. The composer's own
/// draft stays as it is.
struct AskEchoIntent: AppIntent {
    static let title: LocalizedStringResource = "向 Echo 提问"
    static let description = IntentDescription("在新聊天里发出问题，回答显示在桌宠卡片上。")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "问题", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "要问什么？")
    var question: String
    @Dependency var companion: CompanionController

    static var parameterSummary: some ParameterSummary { Summary("向 Echo 提问 \(\.$question)") }

    @MainActor func perform() async throws -> some IntentResult {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw $question.needsValueError() }
        companion.setPetHidden(false)
        companion.workspace.sendQuickMessage(question, projectID: companion.controlsPresentation.projectID)
        return .result()
    }
}

struct EchoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskEchoIntent(), phrases: ["向 \(.applicationName) 提问", "问 \(.applicationName) 一个问题"],
                    shortTitle: "向 Echo 提问", systemImageName: "text.bubble")
        AppShortcut(intent: StartLiveVoiceIntent(), phrases: ["用 \(.applicationName) 开始 Live Voice", "和 \(.applicationName) 语音聊天"],
                    shortTitle: "开始 Live Voice", systemImageName: "waveform")
        AppShortcut(intent: ShowPetIntent(), phrases: ["显示 \(.applicationName) 桌宠", "叫出 \(.applicationName) 桌宠"],
                    shortTitle: "显示桌宠", systemImageName: "eye")
        AppShortcut(intent: HidePetIntent(), phrases: ["隐藏 \(.applicationName) 桌宠", "收起 \(.applicationName) 桌宠"],
                    shortTitle: "隐藏桌宠", systemImageName: "eye.slash")
    }
}
