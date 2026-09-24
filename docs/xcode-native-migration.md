# Echo 原生测试迁移记录

基线：Echo `61f1e113395c66653c29535889b309ce06012c9f`；相邻 mini-agent-rs `57d3d53f0191362abbe23409f766731415a8eb34`。上游路径依赖测试继续由其仓库管理。

## 验证证据

所有本次日志和 xcresult 位于 `/private/tmp/echo-native-migration/`。该目录不提交。沙箱内首次尝试因 Swift 宏插件和 Rust host dylib 加载失败，未执行测试；清除本次临时 checkout 的 Rust 缓存后重跑。真实服务、Keychain 授权及 Speech 设备测试尚未执行。历史基线报告不作为本轮通过证据。

基线实测：`BehaviorBaseline.xcresult` 发现 6 个 XCTest，5 通过、1 runner crash、0 skip。崩溃为 `VoiceTests.swift:171` 的 “the page starts from a successful test”，调用场景 `settingsPageRevisitKeepsSuccessTests`；旧实现使用固定短 sleep 等待异步成功，`VoiceRetry.xcresult` 单独重跑通过；固定 25 ms sleep 存在调度敏感性。Session CLI 和 Bridge Probe 完整通过。所有旧断言与场景源码保持原样。

构建基线修正：原 adapter 传入 SDKROOT/MACOSX_DEPLOYMENT_TARGET 时，干净构建的 zerofrom_derive dylib 出现 `mis-aligned LINKEDIT string pool`。原生 Cargo 和移除这两个 host 环境变量的最小隔离环境均完成 release 构建。行为基线仅在临时副本跳过 adapter，使用相同源码单独构建的静态库；不计为原工程干净构建通过。

## 迁移门槛

按 inventory → 构建/资源/宿主隔离 → 原生断言 → production bridge → UI → 手动计划 → 退役 → 干净 checkout 验收推进。旧入口仅在等价原生场景通过后退役。未实测的场景不能记为通过。

## 场景映射

下列是基线可辨认的场景入口；迁移期间更新原生标识与证据。状态为“待迁移”的行仍通过原 harness 执行，不能计作原生覆盖。

| 原场景 | 原生标识 | fixture | 验证 |
|---|---|---|---|
| `AgentBridgeTests.main` | 待迁移 | 见 `tests/AgentBridgeTests.swift` | 未验证 |
| `AgentLiveTests.main` | 待迁移 | 见 `tests/AgentLiveTests.swift` | 未验证 |
| `AgentLiveTests.run` | 待迁移 | 见 `tests/AgentLiveTests.swift` | 未验证 |
| `AgentSessionTests.main` | 待迁移 | 见 `tests/AgentSessionTests.swift` | 未验证 |
| `AgentTaskSourceTests.streamTests` | `EchoAgentTaskSourceTests/AgentTaskSourceTests/streamTests()` | 见 `tests/AgentTaskSourceTests.swift` | 未验证 |
| `AgentTaskSourceTests.main` | `EchoAgentTaskSourceTests/AgentTaskSourceTests/durableInputsSurviveCancellation(cleanupFirst:)` | 见 `tests/AgentTaskSourceTests.swift` | 未验证 |
| `AgentTaskSourceTests.wireTests` | `EchoAgentTaskSourceTests/AgentTaskSourceTests/wireTests()` | 见 `tests/AgentTaskSourceTests.swift` | 未验证 |
| `AgentVoiceTests.agentVoiceIntegrationTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentVoiceTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentRefusedFinalTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentVoiceRecoveryTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentReplyStreamTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentSpokenReplyTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentVoiceUnseenTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentFinalAudioTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AgentVoiceTests.agentVoiceStartupAndFailureTests` | 待迁移 | 见 `tests/AgentVoiceTests.swift` | 未验证 |
| `AppleSpeechDeviceTests.main` | 待迁移 | 见 `tests/AppleSpeechDeviceTests.swift` | 未验证 |
| `AppleSpeechTests.run` | 待迁移 | 见 `tests/AppleSpeechTests.swift` | 未验证 |
| `AppleSpeechTests.recordedDevicePauseRegression` | 待迁移 | 见 `tests/AppleSpeechTests.swift` | 未验证 |
| `AppleSpeechTests.phraseBoundaryPunctuationTests` | 待迁移 | 见 `tests/AppleSpeechTests.swift` | 未验证 |
| `AppleSpeechTests.backgroundAuthorizationTests` | 待迁移 | 见 `tests/AppleSpeechTests.swift` | 未验证 |
| `AppleSpeechTests.localeTests` | 待迁移 | 见 `tests/AppleSpeechTests.swift` | 未验证 |
| `ChatTests.main` | `EchoChatTests/ChatTests/sendStopRetryAndRestore()` | 见 `tests/ChatTests.swift` | 未验证 |
| `ChatTests.contextTests` | `EchoChatTests/ChatTests/stoppedPartialContext()` | 见 `tests/ChatTests.swift` | 未验证 |
| `ConversationUITests.main` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.main` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.run` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testComposerAdaptiveHeight` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testWindowChromeAndSidebarAccessories` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testConsecutiveDictationAppends` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testStoppingAndDictationEscape` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testComposerActionMatrix` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testCodeCopyAndSyntaxPreview` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testAutomaticColumnThresholds` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPointerMonitorLifecycle` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testTranscriptTailAnchors` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testNativeMenuShortcuts` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetComposerPointerFocus` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testWorkspaceSidebarPointerAndKeyboard` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testProjectPickerKeyboardScroll` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testSearchResultAccessibilityActivation` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testProjectDetachPointer` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testEscapeAndKeyboardCommands` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testLiveVoiceComposerStatesAndAttribution` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testSettingsAndCompanionVoiceIntegration` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetSurfacePresentationAndLayout` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetQuickComposerAndTray` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testCompanionQuickComposerLifecycle` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testCompanionBubblePresentationAndLayout` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testChatStatusTextIsExceptionOnly` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testStreamingReplyRendersInTranscript` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testLiveVoiceHidesRunningStatusText` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testLiveVoiceTranscribesInTranscript` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testLiveVoiceTurnKeepsTaskCardHidden` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testCompanionBubbleViews` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetVoiceConnectingAndBell` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetProjectMenuAndCardReveal` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testCompanionBubblePanelAndHotKey` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetHidesOnlyForTheVoiceConversationOnScreen` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testPetVoiceEntryStartsItsOwnConversation` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testComposerPreservesEditorStateAcrossVoiceUpdates` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testProjectTreeScrollRestoration` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testRightSidebarLayoutAndToggling` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `ConversationUITests.testSettingsKeyboardAndFocus` | 待迁移 | 见 `tests/ConversationUITests.swift` | 未验证 |
| `DictationTests.run` | 待迁移 | 见 `tests/DictationTests.swift` | 未验证 |
| `DictationTests.deviceRecoveryTests` | 待迁移 | 见 `tests/DictationTests.swift` | 未验证 |
| `DictationTests.recordedPauseRegression` | 待迁移 | 见 `tests/DictationTests.swift` | 未验证 |
| `DictationTests.diagnosticLoggingTests` | 待迁移 | 见 `tests/DictationTests.swift` | 未验证 |
| `DictationTests.localTests` | 待迁移 | 见 `tests/DictationTests.swift` | 未验证 |
| `ModelTests.run` | `EchoChatTests/ModelTests/*` | 见 `tests/ModelTests.swift` | 未验证 |
| `ModelTests.sourceRevisionTest` | 待迁移 | 见 `tests/ModelTests.swift` | 未验证 |
| `ProjectFileBrowserTests.run` | 待迁移 | 见 `tests/ProjectFileBrowserTests.swift` | 未验证 |
| `ProjectFileBrowserTests.testRefreshCoalescesWhileScanning` | 待迁移 | 见 `tests/ProjectFileBrowserTests.swift` | 未验证 |
| `ProjectFileBrowserTests.testRefreshCommitsDirectoriesSeparately` | 待迁移 | 见 `tests/ProjectFileBrowserTests.swift` | 未验证 |
| `SettingsTests.run` | `EchoChatTests/SettingsTests/*` | 见 `tests/SettingsTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInGateTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInConverterTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInSuccessTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInRejectionTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInCancellationTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceBargeInTests.bargeInCompletionAndWatchdogTests` | 待迁移 | 见 `tests/VoiceBargeInTests.swift` | 未验证 |
| `VoiceLiveTests.main` | 待迁移 | 见 `tests/VoiceLiveTests.swift` | 未验证 |
| `VoiceLiveTests.run` | 待迁移 | 见 `tests/VoiceLiveTests.swift` | 未验证 |
| `VoiceSoakTests.main` | 待迁移 | 见 `tests/VoiceSoakTests.swift` | 未验证 |
| `VoiceSoakTests.run` | 待迁移 | 见 `tests/VoiceSoakTests.swift` | 未验证 |
| `VoiceTests.main` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.planetTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.configurationChangeTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.snapshotTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.snapshotLifecycleTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.backgroundAudioStartTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.voiceAudioHandoverTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.voiceAudioRestartTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.voiceAudioSwitchTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.captureWatchdogPauseTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.captureWatchdogRestartTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.mutedPlaybackTailProtectionTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.captureDiagnosticsTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.manualModelTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.probeTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.speakerPreviewTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.settingsPageRevisitKeepsSuccessTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.audioConversionTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.protocolTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.settingsTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.lifecycleTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.phase3InvariantsTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `VoiceTests.phase4FaultAndCleanupTests` | 待迁移 | 见 `tests/VoiceTests.swift` | 未验证 |
| `WorkspaceTests.main` | 待迁移 | 见 `tests/WorkspaceTests.swift` | 未验证 |
| `WorkspaceTests.quickComposerTests` | 待迁移 | 见 `tests/WorkspaceTests.swift` | 未验证 |
| `WorkspaceTests.projectAssociationTests` | 待迁移 | 见 `tests/WorkspaceTests.swift` | 未验证 |
| `WorkspaceTests.sessionCleanupTests` | 待迁移 | 见 `tests/WorkspaceTests.swift` | 未验证 |
| `WorkspaceTests.streamingPersistenceTests` | 待迁移 | 见 `tests/WorkspaceTests.swift` | 未验证 |
| `WorkspaceVoiceCommandTests.run` | 待迁移 | 见 `tests/WorkspaceVoiceCommandTests.swift` | 未验证 |

## Phase 2 验证

- `Phase2Resources.xcresult`：8 个 XCTest 全部通过，0 skip，保留旧行为断言验证 bundle 资源迁移。
- Rust release 库位于 `DerivedData/Build/Intermediates.noindex/EchoCargo`；无 repo `build/target`。原有目录完整移动到 `/private/tmp/echo-native-migration/preexisting/`，未删除。
- hosted bundle 仅 `@testable import Echo`；测试实际默认 prompt 开 session、确认清理，以及宿主未建立用户工作区窗口。
- 首次 UI smoke 被 macOS “Enable UI Automation”认证阻挡；用户认证后，修正 runner 容器临时目录校验，`Phase2UIContainer.xcresult` 1 个真正 XCUITest 通过。
- `DevelopmentDebug` 构建成功；LLDB 在隔离 hosted 模式命中 `main.swift:12`，日志 `lldb.log`。

## Phase 3 / Chat + TaskSource

`NativeFastRetry.xcresult` / `FastRestored.xcresult`：21 个 Swift Testing 方法（含参数化场景），全部通过。`FailureProbe.xcresult` 临时反转 `AgentTaskSourceTests.wireTests` 的 history 断言，确认失败精确定位原用例与源码；随后自动恢复并通过完整 Fast。未改生产业务语义。

Model 请求协议、失败种类和配置迁移端点分别参数化；取消、SSE framing、回复、未知存档版本独立运行。旧 Chat/TaskSource XCTest 总入口已删除。后续仍需继续细分 Chat/Settings 的长状态序列。
