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
