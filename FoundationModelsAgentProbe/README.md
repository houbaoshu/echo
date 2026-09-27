# Foundation Models Agent Harness Probe

验证 `LanguageModelSession` 能否承担 Echo Agent 的 session、transcript、连续 tool calling、错误处理与取消职责。

独立 SwiftPM 包：不修改 `Echo.xcodeproj`、Rust workspace 或任何生产代码。删除整个目录即可移除。

## 环境

- Xcode 27.0（27A266a）、macOS 27.0 SDK、Swift 6.4
- `apple/foundation-models-utilities`，锁定在 `cc3820d`，提供官方 `ChatCompletionsLanguageModel`

## 运行

```sh
cd FoundationModelsAgentProbe
swift test                          # 14 个测试，把实测 SDK 行为固定为断言
swift run fm-agent-probe            # 本地假模型，全部场景，打印日志与 transcript 摘要

# OpenAI 兼容云模型（官方 ChatCompletionsLanguageModel，不打印 key）
ARK_BASE_URL='https://…/v3' ARK_MODEL='…' ARK_API_KEY='…' swift run fm-agent-probe cloud

# 火山 Responses（自写 ArkResponsesLanguageModel）：baseURL / model 读 Echo settings.json，
# key 读 Echo 的 Keychain 项。未签名的 debug 二进制直接读会弹钥匙串授权框，所以用 security 读出后经环境变量传入。
ARK_API_KEY="$(security find-generic-password -s local.chiyan.desktop-pet.model -a <secretAccount> -w)" \
ARK_WIRE_LOG=/path/wire.jsonl swift run fm-agent-probe responses 20 smoke
```

`ARK_BASE_URL` 需包含 `/v1`、`/v3` 这类版本段：适配器检测到版本段时只追加 `/chat/completions`，否则追加 `/v1/chat/completions`。

## 结构

| 文件 | 内容 |
|---|---|
| `ProbeTools.swift` | `get_number`、`add_numbers`、`finish`、慢 `sleep`、动态工具 `tool_a` / `tool_b` |
| `ScriptedModel.swift` | 假模型：通过公开的 `LanguageModel` / `LanguageModelExecutor` 协议接入，每一步只看框架传入的 transcript；`RecordingModel` 包装任意模型并记录每次生成请求 |
| `Probe.swift` | 各场景。每轮用户输入只调用一次 `session.respond`，应用层没有 tool loop |
| `CloudModel.swift` | 从环境变量或 Echo settings.json + Keychain 构造官方 `ChatCompletionsLanguageModel` / 自写 `ArkResponsesLanguageModel` |
| `EchoBashTool.swift` | Echo 生产 `bash` tool（定义同 mini-agent-rs `ToolSet::Bash`），经 `EchoExecutorFFI` 调生产 `LocalConversationExecutor`；Swift Task 取消 → Rust 取消并等进程树清理 |
| `EchoScenarios.swift` | Echo 生产 prompt（`mini-agent-rs/config/prompts/conversation.md`）+ 真实 bash 的三组场景：自主修 bug、多轮 + restore、子进程执行中取消 |
| `EchoExecutorFFI/` | 探针专用 Rust staticlib，只读依赖 mini-agent-rs，最小 C ABI（`Sources/CEchoExec` 为头文件模块）。`swift build` 前先 `cargo build --release --manifest-path EchoExecutorFFI/Cargo.toml` |
| `ArkResponsesLanguageModel.swift` | 最小 Responses API executor：transcript ↔ `input` items，SSE ↔ channel 事件。每次 `respond` 只发一次 HTTP，无循环 |
| `TranscriptReport.swift` | transcript 结构化摘要 |
| `Tests/` | 实测行为的特征测试 |

假模型不是“替身 session”：它和 `ChatCompletionsLanguageModel` 处于同一层（executor），只决定“这一步输出 tool call 还是文本”。Tool 调度、写回、再次生成都由 Foundation Models 完成。`add_numbers(7, 5)` 的参数是它从框架传回的 tool output 中读出来的。

## 已验证

以下结论来自 `swift test`，以及对假模型和本地 Ollama（`qwen3.5:4b`，经官方适配器）的实际运行。

- **Tool loop 由框架驱动。** 一次 `respond` 触发 5 次模型生成：4 次依赖前一步结果的 tool call，加 1 次最终回复。每次生成请求都已包含之前所有的 `toolCalls` / `toolOutput`。
- **Transcript** 记录 `instructions`（含 tool 定义）、`prompt`、`toolCalls`（id、名称、JSON 参数）、`toolOutput`（与 call 同 id）、`response`、`reasoning`。它是 `Codable`，可以用 `LanguageModelSession(model:tools:transcript:)` 恢复后继续对话。JSON 往返内容无损，但往返后 `==` 为 false：tool call 参数的 `GenerationID` 不会被序列化。
- **Tool 抛错：** `respond` 直接抛出 `LanguageModelSession.ToolCallError`（带 tool 与 underlying error），不会把错误作为 tool output 交回模型。
  - 未知 tool 名、已被动态移除的 tool：抛 `GeneratedContent.ParsingError`。
  - 参数类型错误：抛 `ToolCallError(underlying: ParsingError)`。
  - `transcriptErrorHandlingPolicy`：默认 `nil` 表现同 `.revertTranscript`，回滚到本次请求之前。`.preserveTranscript` 保留已生成的部分，可能留下没有 output 的 `toolCalls`，下一轮会原样发给模型。
- **取消：** 取消外层 Task 后 1 ms 内结束，session 可立即继续使用。
  - tool 执行中取消：Tool 收到 `CancellationError`，`respond` 抛 `ToolCallError(underlying: CancellationError)`。
  - 生成中取消：抛裸 `CancellationError`。官方 HTTP executor 约 0.6 ms 内返回，服务端连接确实被关闭（Ollama 日志：1.6 s 时出现 500）。
- **动态工具：** `DynamicProfile` 读取 `Observable` 状态，同一 session 内可以切换工具集。切换在下一次生成立即生效，包括在同一次 `respond` 内由 Tool 自身触发的切换。transcript 的 instructions entry 会被就地改写为当前工具集，不保留历史工具集。
- **并发 `respond`：** 第二次调用抛 `LanguageModelSession.Error`（“programmer error”）。
  - 竞态窗口内，被拒绝的调用仍可能污染进行中的那一轮：prompt 泄入、答案被改写，或首个调用抛 `ParsingError` 且 transcript 被清空。300 次压测中约一半次数出现。
  - 在 `.preserveTranscript` 下可稳定复现 prompt 泄入。
- **Steering：** `@SessionProperty(\.history)` 可以在同一次 `respond` 内注入用户消息，模型在下一次生成可见。但 `onToolOutput` 触发时 output 尚未写入，注入的 prompt 会落在 `toolCalls` 与 `toolOutput` 之间。

## 火山 Responses 路径（`ArkResponsesLanguageModel`）

背景：官方 `ChatCompletionsLanguageModel` 把火山流里的 `reasoning_content + content:""` 转成空 response entry，
回放时同一个 assistant turn 被拆成 `assistant(reasoning_content)` + `assistant(tool_calls)`，多步 tool loop 不稳定。

实测（`doubao-seed-2.0-mini`，`/api/plan/v3/responses`，2026-09-27）：

- **映射**：reasoning、function_call、function_call_output 在 Responses 里本来就是独立 item，transcript 每个 entry 对应一个 item，
  不存在“合并到同一条 assistant 消息”的问题。空文本 delta 丢弃，usage 记在最后一个已有 entry 上，不产生空 response entry。
- **火山的流**：`output_item.added{reasoning, rs_…}` → `reasoning_summary_text.delta` → `output_item.added{function_call, fc_…, call_id, name}`
  → `function_call_arguments.delta`（第一个 delta 为空串）→ `response.completed` → `[DONE]`。
  `include: ["reasoning.encrypted_content"]` 也不返回 `encrypted_content`；回放 reasoning 只能用 summary 明文。
  reasoning 带真 id、伪 id、无 id、或整段省略，服务端都接受。
- **多步 tool loop**：20/20 通过（`get_number(alpha)` → `get_number(beta)` → `add_numbers(7,5)` → `finish` → `"12"`）。
  每次应用层 1 次 `respond`，框架发 5 次请求；transcript 恒为 `[instructions,prompt,(reasoning,toolCalls,toolOutput)×4,reasoning,response]`，
  空 response entry 0 个，没有空字符串静默结束。WireTap：113 次请求全部发往 `/api/plan/v3/responses`，全部 200，日志无 `Bearer`。
- channel 的 `entryID` 即 transcript entry id，所以 reasoning entry 保留 `rs_…` id。
- **冒烟**（各 1 次）：JSON 往返后的 transcript 恢复并继续回答 `"12"`；生成中取消 5 ms 抛 `CancellationError`，executor 6 ms 内以 `NSURLError`（连接取消）结束；
  tool 中取消与 Chat 路径一致；同一次 `respond` 内动态切换工具集立即生效。
- **未支持**：guided generation（`schema` 直接抛 unsupported）、图片附件、`parallel_tool_calls` 未设置（服务端默认）。

## Echo 真实 prompt + 生产 bash 执行器（2026-09-27）

`swift run fm-agent-probe echo fix|multi|cancel [N]`。session 只有 Echo 的 system prompt 与一个 `bash` tool；
用户消息是任务描述，不指定步骤。bash 由 mini-agent-rs 生产 `LocalConversationExecutor` 在进程内执行（配置同 `agent-bridge` 的 `initialize`：
`/bin/bash`、30 s、64 KiB），tool 返回值与生产写入历史的 `CommandOutput` JSON 逐字相同。

- **A 自主修 bug**（“测试跑不过，帮我修好并确认”）：6/6 通过（含首轮单跑）。每次 7–8 次 bash、8–9 次模型请求，
  模型自行 `ls`/`cat` 定位、`sed` 修复、跑测试；曾自行从 `python: command not found` 恢复为 `python3`。
- **B 多轮 + restore**：3/3 通过。两轮后 `Transcript` JSON 往返、新 session 恢复，恢复后第 3 轮不跑命令答对前文内容，第 4 轮继续执行。
  恢复后首个请求带回全部 reasoning / tool output，`rs_…` id 保留。
- 全部运行中：无空字符串静默结束；无一次出现一个 decision 多个 bash 调用（不需要 `parallel_tool_calls`）；81 次请求全部 200，全部发往 `/responses`。
- **C 子进程执行中取消**（`slow_build.sh` 派生后台子进程）：取消后约 7 ms Rust 执行器杀掉整棵进程树（含后台子进程）并返回 `cancelled`；
  `respond` 在执行器返回之后才抛 `ToolCallError(CancellationError)`（7–11 ms），之后无副作用（`build.done` 未生成）。
  **历史语义与生产不同**：
  - 默认（revert）：本轮 user prompt、reasoning、tool call 全部回滚，历史里看不出用户曾要求构建、也看不出命令被中断。
  - `.preserveTranscript`：留下没有 output 的 `function_call`，火山接受（200），但模型不知道它被中断。
  - `.preserveTranscript` + 应用层补写生产同款 `{"status":"unknown","detail":"Cancelled during execution; inspect workspace for effects."}`：
    请求 item 结构与 mini-agent-rs 生产历史一致。只用公开 API（`session.transcript.append`）。
  - 三种情况下后续“刚才的构建结果怎么样？”模型都能继续；后两种里模型直接重跑了构建并把新结果当作“刚才”的结果——这是模型在该历史下的行为。

## Phase 0 SDK spikes（2026-09-28）

`swift test` 现为 35 个测试（`Tests/AgentProbeTests/Phase0SpikeTests.swift` 与 `Tests/EchoSettingsCheckTests`），
连续 5 次全绿。脚本模型见 `Sources/AgentProbe/Phase0Support.swift`（分块流式、同一生成混合文本与 tool call、复用 call id、
metadata / 签名、中途失败）。结论均来自本机 macOS 27.0 SDK 的实际运行；每条后面是对 Echo harness 设计的影响。

| # | 实测行为 | 对设计的影响 |
|---|---|---|
| S0 | harness 形态（自定义 executor、`@Generable` 工具自解码、DynamicProfile + hooks、`@MainActor` 协调者、每次 respond 新建 session、`@concurrent` 消费 `streamResponse`）在 Echo 的并发设置下（Swift 6、warnings-as-errors、**不开** `NonisolatedNonsendingByDefault`）零警告编译运行；profile 在 `@MainActor` 中构造，executor / hooks / tool 仍全部在主线程之外 | 不阻断 Phase 1；无需单独模块 |
| S1 | 顺序：`onPrompt`（每次 respond **仅一次**）→ `historyTransform`（**每次生成前**）→ executor → `onToolCall` → Tool.call → `onToolOutput` → 下一次 `historyTransform`。单个调用时 `onToolCall` 紧邻其 Tool.call；工具运行时 `session.transcript` 已含 `toolCalls` | 执行前落盘可挂在工具内部（此时 toolCalls 已在 transcript） |
| S1 | 注入排队输入：`onPrompt` 太早（循环中不再触发）；`historyTransform` 追加的 prompt 对下一次生成可见且位于 toolOutput 之后，但**不写回** `session.transcript`（只影响请求视图） | 原生注入不能直接当持久化机制；采用"分段 respond" |
| S1 | 分段 respond：工具执行后抛让步错误 → `.preserveTranscript` 留下 `[prompt, toolCalls]` → harness 追加真实 toolOutput 与排队输入、以新 session 继续 → 模型看到 `…toolCalls, toolOutput, prompt` | steering 按现状语义实现的机制已验证 |
| S2 | `streamResponse` **实时**：注册工具与否、`toolCallingMode .disallowed` 与否都一样；每块在下一块到达时出现（压住最新一块，约一个间隔），最后一块在生成结束时冲出；跨 tool loop 持续（文本、toolCalls、下一步文本都在同一个流里） | 实时显示可以直接用框架流；**不应**让适配器攒到 `response.completed` 才发事件，那会让界面在每步结束前看不到文字 |
| S2b | 同一次生成"文本 + tool call" → 两个条目：`response` 在前、`toolCalls` 在后 | "文本伴随工具调用"= toolCalls 之前的 response，投影为非 final 消息 |
| S2 | 非流式 `respond` 期间 `session.transcript` 不逐块更新，生成完成才出现完整 response | 不能靠轮询 transcript 做实时显示 |
| S2 | **取消正在消费 `streamResponse` 的任务：消费方不会收到错误，流正常结束**；executor 收到取消；半截文本作为普通 `response` 写入，`onResponse` 照常触发 | harness 必须自己记录 Stop，不能用"流正常结束 / onResponse"判定回复完整；Stop 后按 harness 状态截掉该条目 |
| S3 | `respond(to: "")` 可用，executor 收到文本为空的 prompt；`respond(to:metadata:)` 的 metadata 同时出现在 prompt 条目与请求上 | "继续处理"可用带 `echo.continue` 标记的空 prompt，由适配器在线格式中省略 |
| S4 | `.preserveTranscript` 残留：executor 抛错 → 无半截文本；取消 → 留半截 response；未知工具 → 留悬空 toolCalls；参数非 JSON → 什么都不留；文本 + 抛错工具 → 留 response + toolCalls。`.revertTranscript` → 连 prompt 一起回滚 | 规范化规则：补悬空调用的结果；Stop 时去掉被中断生成的半截 response；格式错误恢复两种形态都要处理 |
| S5 | 同一次生成的多个调用**并发执行**；`onToolCall` 与 Tool.call 在并发调用间交错不确定。不同生成复用同一 call id 时，写回与配对正确 | bash 串行化必须在工具内部做；运行中调用只能按参数匹配 `onToolCall`；投影按（条目, call）定位 |
| S6 | `Transcript` JSON 带 `"type":"FoundationModels.Transcript","version":"1.1"`；prompt / response metadata、reasoning id 与 `signature`、toolOutput 往返无损；已提交 golden JSON | 持久化可直接用 `Transcript` JSON；golden 测试作为 SDK 编码变化的护栏 |
| S7 | 从 `@MainActor` 或 `@concurrent` 调用 `respond`，executor / hooks / tool 都在主线程之外 | 主线程占用风险低；UI 投影仍需显式回主线程 |
| S8 | 计数包装器在第 N+1 次生成前抛错：`respond` 原样抛出该错误（不包装），之前的 toolCalls / toolOutput 全部保留 | 30 次上限按此实现，文案映射到现状 |
| S9 | 工具挂起在外部 continuation 上时取消 `respond`：约 1–4 ms 内 `ToolCallError(CancellationError)`，session 不再 responding | 目录请求 / 租约等待的取消语义可行 |
| S10 | executor 收到的 instructions 文本就是 profile 的文本，工具 schema 不混入；工具定义在 `toolDefinitions` / `enabledToolDefinitions` | 适配器无需过滤 instructions |

未覆盖：真实 provider 的流式时延（本节只用脚本模型）；Echo Live Voice 本身只在最终回复完成后播报（`VoiceSessionController.handleAgent` → `speakFinal`），与 FM 是否流式无关。
