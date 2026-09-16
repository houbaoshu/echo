# Mini Agent Bridge v2：接入契约

本文件最初是 [迁移计划](mini-agent-mainline-bridge-v2-plan.md) 第 1 阶段的类型规范；第 2 阶段实现主线运行器，第 3 阶段接入生产 Rust/C ABI v2，第 4 阶段接入 Swift v2。核心类型来自 `mini_agent::conversation::runner`，wire 类型位于 `agent-bridge/src/wire.rs`，Swift 类型位于 `macos/AgentWire.swift`。第 5 阶段的跨层回归与应用包验收记录见计划末尾。

## 1. 类型归属与 API 边界

| 类型 | 归属及语义 |
| --- | --- |
| `SessionCommand` | `conversation::runner`；`SendMessage` 原子决定 submit/steer。保留显式 Submit、Steer、Continue、ProvideDirectory、ExportHistory。 |
| `SessionControl` | 独立控制入口；保存成功、保存失败、工具放行，不能进入普通命令队列。 |
| `SessionBatch<ConversationHistory>` | 核心批次，包含类型化核心事件、可选 checkpoint、输入回执及显示投影；无 wire version。 |
| `CheckpointId` | `(generation, revision)`；generation 每次创建句柄更新，revision 从 1 开始、严格递增、不回绕。会话 ID 相同也不能跨句柄确认。 |
| `InputMessage` / `InputReceipt` | 稳定客户端 ID 和文本；回执将客户端 ID 映射至核心 message/turn ID。request ID 只关联一次传输，不替代客户端 ID。 |
| `RestoreInput` | 原始 v1 历史、旧文本历史、或空历史三选一；完整已知映射、待确认输入和显式目录覆盖。 |
| `DisplayEntry` | 有序消息/工具投影；以核心 ID 定位。工具 result 保留原始结果字符串及其中的退出码、超时、截断和 unknown/not_executed 信息。 |
| `WireCreate` / `WireRequest` / `WireReply` / `WirePoll` | Bridge 所有；JSON 版本、模型凭据、Bundle prompt 文件路径及传输封装。 |

生产 Bridge 直接使用主线 `conversation` 导出的 `ConversationHistory` / `ConversationEvent` 和运行器类型。泛型 `H` 只表达核心历史与 wire 原样 JSON 字符串之间的编码边界，不要求公共运行器 API 本身泛型化。v2 顶层批次不再复用 v1 的任意 JSON 字典。

### SessionHandle 接口约束（第 2 阶段已实现）

以下是运行器的核心接口；具体类型和初始化参数见第 6 节：

```rust,ignore
// conversation::runner，所有 Result 使用类型化 SessionError。
fn spawn<M, E, I>(runtime: &tokio::runtime::Handle, initialize: I,
                  options: SessionOptions) -> Result<SessionHandle, SessionError>
where
    M: ConversationModel + Send + 'static,
    E: ConversationExecutor + Send + 'static,
    I: Future<Output = Result<SessionParts<M, E>, SessionError>> + Send + 'static;

impl SessionHandle {
    fn try_command(&self, request_id: String, command: SessionCommand)
        -> Result<(), SessionError>;
    fn try_control(&self, request_id: String, control: SessionControl)
        -> Result<(), SessionError>;
    fn stop(&self);    // 独立、幂等、非阻塞
    fn close(&self);   // 独立、非阻塞；放弃未消费事件
    fn try_next_batch(&mut self) -> Result<Option<SessionBatch>, SessionError>;
    async fn next_batch(&mut self) -> Option<SessionBatch>;
    fn completion(&self) -> SessionCompletion;
}
impl SessionCompletion {
    async fn wait(self); // 独立于事件消费和 handle 生存期的每会话清理确认
}
```

`SessionParts` 包含已初始化的会话、模型和执行器；初始化输入包含会话 ID、generation、显式 prompt 内容/会话预算及 `RestoreInput<ConversationHistory>`。prompt 文件读取与模型凭据转换由 Bridge 的后台初始化适配完成。运行器负责驱动初始化 future；停止/关闭必须中止或等待初始化资源清理，停止后不得启动模型。对于不可取消的 blocking 初始化，等待其返回并清理，不把 abort JoinHandle 当作已结束。Drop 触发 close，已取得的 `SessionCompletion` 仍可等待。

普通命令容量 32、事件容量 64；按批次数限制，完整历史大小不因此有界。控制入口使用独立、有界、可唤醒的邮箱；重复 Stop/close 合并，重复确认可合并。不同控制不能静默覆盖；容量不足须返回 `queue_full`，宿主保留并重试。Stop/close 始终无需容量。保存失败必须有独立终止信号保障，不得因确认邮箱已满而继续调度。等待确认、目录或事件容量时使用通知/通道等待，不忙轮询。

### 执行器契约

```rust,ignore
trait ConversationExecutor: Send {
    fn execute(&mut self, action: Action, directory: PathBuf,
               cancellation: CancellationSignal)
        -> impl Future<Output = Result<ExecutionOutcome, SessionError>> + Send;
}
enum ExecutionOutcome { Completed(CommandOutput), Cancelled }
```

`CancellationSignal` 为持久化停止状态加异步通知；执行前检查已取消，执行中持续监听。返回任何结果（包括错误/取消）前完成子进程清理；不为任意 `Environment` 提供“丢弃 future 即已取消”的默认实现。内置实现复用主线底层进程执行代码，保留旧 `Environment::execute`，桌宠参数为 `/bin/bash`、30 秒、stdout/stderr 各 64 KiB。停止杀进程组并等待 shell 回收；macOS 上还按内核进程血缘终止并有界等待脱离进程组/会话的后代（由 mini-agent-rs 执行器负责，Swift 侧不做进程管理）；模型任务取消后同样 await 结束。完成的真实工具结果优先保留，执行中取消由状态机记录 unknown。

## 2. 保存及工具放行顺序

1. 初始化恢复完成或历史/输入映射发生实质变化后，产生完整 checkpoint。仅确认、导出、拒绝命令不得增加 revision；可重新发送同一 checkpoint。
2. Swift 将原样 `history` 字符串、全部 `input_receipts`、投影/UI 快照及尚未确认的输入原子写入同一个 sidecar，然后确认该 checkpoint。UI 可先显示，但不能据此放行工作。
3. 每个批次注明 generation；事件和输入回执属于该 generation。已发出 checkpoint 才能确认。确认是同一 generation 内的累计保存水位：保存 revision N 的完整快照可覆盖 ≤N 的变化；重复已确认水位为无操作，未来或其他 generation 返回 `stale_checkpoint`。
4. 模型派发前必须先保存用户输入和模型预算变化。当前 `next_operation()` 会增加 `model_calls` 并改变状态：运行器先取得/保留 operation、发 checkpoint，确认后才启动请求；等待期间仍处理 Stop、输入和目录变化。不能在每次收到确认时再次调用 `next_operation()` 重复计费。
5. 工具提案批次包含 checkpoint、operation ID 和规范化目录。只有该提案仍有效、对应 revision 已保存且宿主持有该目录整轮租约时，才处理 `AuthorizeTool { checkpoint, operation_id, directory }`。授权可以先到，必须继续等待保存确认。
6. 派发前先处理已经接收的控制，再检查 generation、operation、保存水位及真实目录，最后 `begin_tool`。steer、Stop、目录变更使旧授权失效；确认旧 revision 不能授权新提案。
7. 工具结果产生新 checkpoint；该结果未保存前禁止下一次模型请求。保存失败返回 `persistence_failed`，停止并清理，不自动恢复调度；宿主修复存储后重新创建/显式继续。

保存失败关联一个已发出且未被成功保存水位覆盖的 checkpoint；即使有更新 revision 等待保存，该失败也必须终止调度。对已经成功保存的旧 revision 的迟到失败回执按 stale 处理。清理确认独立于保存成功和事件消费；正常 Stop 的 `Cancelled` 批次在清理完成后输出，销毁的 completion 也在同一边界完成。目录租约只能在此后释放。

## 3. 输入、恢复和终态

- Swift 在首次发送前持久化稳定客户端 ID。一次接收成功仅代表入队；`CommandResult::Applied` 才确认输入已分配的核心 IDs，并与包含该输入的 checkpoint 一起发出。停止前已排队而未处理的输入返回 `cancelled_before_processing`。
- `SendMessage` 在串行运行器内按实际状态开始新轮或追加指令；停止期间返回 `stopping`。完成边界的两条输入无需 Swift 文案匹配或 submit/steer 往返重试。
- 同一客户端 ID、同一文本重复交付返回同一映射，不追加第二条；同一 ID 不同文本返回 `client_message_conflict`。相同文本、不同 ID 是独立消息。映射必须与历史的用户消息 ID、turn ID 和内容校验，不能仅相信宿主映射。
- 恢复先验证 v1 schema、ID、tool/result 配对及 Responses 一致性；损坏历史禁止运行。缺失结果补 unknown、未结束轮标记 interrupted。导入后保持 idle，显式 Continue 请求新模型判断，不重新追加原请求、不重放旧命令。
- `RestoreInput.pending_inputs` 按输入顺序恢复：已有映射的输入不重复追加，无映射的输入由核心分配 ID。恢复本身不执行。旧文本由核心导入；Swift 仅传 role、稳定 ID 和文本。`directory: null` 明确清除历史目录。
- 确认前崩溃：恢复上次原子快照及未确认输入；保存后、确认前崩溃：映射和历史已一起保存，重新创建可重新确认新 generation 的恢复 checkpoint。不能通过文本猜测消息是否已接收。
- UI/语音用 generation、turn ID、message ID 和待确认输入选择当前终态；旧 final/finished 不结束新任务。最终回复以核心 message ID 去重展示和播报。

## 4. Wire v2

保留现有 C 符号、16 MiB 请求限制、字符串独立所有权和 panic 隔离。第 3 阶段 C ABI 已仅接受 v2 请求，v1 wire 返回 `unsupported_version`，**持久化历史仍为 v1**；Swift 调用方已在第 4 阶段升级。版本在读取顶层 JSON 后先检查，再解码 payload；不要把一个合法 v1 请求误报为普通字段错误。generation、request ID、客户端 ID 必须非空；revision 和核心 IDs 必须为正整数。JSON 数字完整保留 u64，不经 Double。

普通输入示例：

```json
{"version":2,"request_id":"r-1","command":{"type":"send_message","input":{"client_message_id":"ui-1","text":"你好 🌱"}}}
```

独立控制示例（仍走 `echo_agent_request` 符号，Bridge 解码后直接路由控制邮箱）：

```json
{"version":2,"request_id":"ack-1","command":{"type":"acknowledge_checkpoint","checkpoint":{"generation":"handle-2","revision":7}}}
```

同步回执使用 `WireReply.admission`（queued/rejected），不是核心已应用回执；异步回执在 `BatchKind::CommandResult`。`echo_agent_submit` / `steer` 校验嵌套 command 类型；`echo_agent_cancel` 不需要 JSON。poll 返回 `WirePoll`；只有队列已空且工作者完成才为 closed。

`WireCreate.restore.source = {"type":"v1","history":"…完整 v1 JSON…"}`，wire checkpoint 中 `history` 也为字符串。Swift Codable 只解码外围和 projection，按 UTF-8 原样保存内部字符串；不解析 `next_id`/turn/entry，不剥离 reasoning。核心仍使用 Rust 历史类型，只有 Bridge 做 JSON 字符串转换。这里的“原样”指保留核心输出 JSON 的完整内容；核心合法恢复可新增中断记录，不承诺恢复前后的空格/字段顺序相同。

错误码枚举见主线 `runner/types.rs` 及 Swift `AgentErrorCode`。Swift 根据 code 决策、message 仅显示；不得把密钥、完整配置或模型服务响应拼入基础设施错误。未知 wire 字段/命令和缺失必要字段拒绝；未来历史扩展由核心存档版本契约负责。

## 5. 验收入口与证据边界

| 场景 | 当前验收入口与范围 |
| --- | --- |
| 主线 API、执行器与恢复 | Mini Agent 默认、无默认 feature、conversation、tdd、all-features 的 `cargo test`（含文档测试）和全目标 Clippy；运行器门控、可等待取消、超时/截断、v1 恢复及 feature API 边界 |
| Rust/C v2 | `test-agent-bridge.sh` 中的 Rust `history_v1`、`lifecycle`、`v2_contract`、`wire_ffi`：两个协议、原样历史、保存屏障、输入去重、过期控制、满队列取消、进程清理、版本与大小限制；同时执行 C ASan 500 次句柄压力检查 |
| Swift v2 与输入竞态 | `test-agent-task-source.sh`：生产适配配合可控 Bridge 验证 Codable/UInt64、客户端 ID、确认前后恢复、迟到终态、保存与目录门控、控制背压和重复关闭 |
| 真实跨层会话 | `test-agent-session.sh`：Swift → Rust → 本地模型/真实 bash，验证配置重建、两种协议、目录与符号链接租约、并行/排队、追加、Stop/删除/退出、存档恢复和意图/结果保存失败 |
| 聊天、工作区与 UI | `test-chat.sh`、`test-workspace.sh`、`test-chat-ui.sh`：状态、持久化、项目归属、隐藏窗口、输入法、原生快捷键及显示交互 |
| Voice | `test-voice.sh` 全量模拟音频/ASR/TTS；`--agent-integration` 使用真实 Rust/bash 和本地模型，覆盖两种协议下模型/工具/目录/排队/Stop 中追加及最终回复只播报一次 |
| 独立应用包 | `build.sh` 与 `test-packaged-app.sh`：Apple Silicon ad-hoc 包移至 `/private/tmp` 的空工作目录，核对资源、系统动态库、真实读改验、协议切换、原子 sidecar 的历史/映射/投影/去重 ID、Responses 元数据、主线程心跳及 AppKit 退出进程清理 |

运行结果与限制以[第 5 阶段记录](mini-agent-mainline-bridge-v2-plan.md)为准。C ASan 不覆盖 Rust 内部全部访存；模拟音频回归不代替真实服务或真人 Live Voice 发布前抽验。最终包验证使用本地模型服务及临时项目，不读取用户凭据或真实工作区。

## 6. 第 2 阶段落地说明

核心契约已在 Mini Agent 主线工作区的 [`conversation::runner`](/Users/houbaoshu/workspace/mini-agent-rs/src/conversation/runner.rs) 实现，见 [运行器使用说明](/Users/houbaoshu/workspace/mini-agent-rs/docs/conversation-runner.md) 和 [计划第 2 阶段记录](mini-agent-mainline-bridge-v2-plan.md#7-第-2-阶段实施记录2026-09-15)。本文前述 wire 类型已在第 3 阶段接入 C ABI，第 4 阶段接入 Swift。

具体 API 使用 `SessionParts { restored, model, executor }`；`restored` 由 `Conversation::restore(session_id, config, restore_input)` 返回。`SessionOptions::new(session_id, generation)` 设置默认队列容量，宿主为每次创建提供新 generation。初始化在 Stop/close 后继续 await，宿主初始化 future 必须等待其 blocking 工作结束，运行器不会把 abort blocking 任务视为清理完成。

`SessionCompletion::wait()` 确认整个句柄 close/Drop 后完成清理；可复用句柄的普通 Stop 通过 `BatchKind::Cancelled` 确认本次操作清理完成。两者都要求宿主保持 runtime 存活。旧 `Environment` 仍可独立使用，只有显式实现 `ConversationExecutor` 的执行器提供可等待取消保证。


## 7. 第 3 阶段 Bridge 落地说明

- `agent-bridge/Cargo.toml` 指向 `../../mini-agent-rs`，仅启用 `conversation`。运行器已包含在主线提交 `3127fa2`；旧基线 `b03cf72` 不包含所需 API。
- `session.rs` 仅负责 prompt/模型后台初始化、主线 `Conversation::restore` 调用、`/bin/bash` 执行参数、共享 runtime 和 completion 计数。会话驱动、执行算法及门控均由主线负责。没有新增任何自动保存确认或 v1 兼容运行路径。
- `WireCreate` 需要非空 session/generation、绝对 prompt 路径和完整 `restore`。`restore.directory` 必须显式出现，null 表示清除。generation 由宿主生成，每次重建必须更新。旧文本及待确认输入直接交给核心恢复。
- `echo_agent_request` 解码嵌套 `WireCommand`，普通命令直接进入 `try_command`，三种控制直接进入 `try_control`。`echo_agent_cancel` 调用 `stop`，销毁通过 `SessionHandle::drop` 触发 close。
- wire 历史仅在后台初始化时解码为核心历史，在 poll 时编码为完整 JSON 字符串；投影、输入映射和事件直接透传。Bridge 不编辑历史内部 IDs，也不解释错误消息。
- poll 在观察到核心批次通道已断开且排空后返回 `closed:true`；若恰好取满请求上限，可能下一次 poll 才观察到关闭。初始化失败批次也会先交付，再报告关闭。Stop 的清理回执为 `kind.type=cancelled`；close/destroy 的全局退出水位由 `echo_agent_active_sessions` 提供。
- `scripts/agent-prompt-path.sh` 根据 Cargo metadata 中 `echo-agent` 的实际解析依赖定位 prompt，构建和 Agent/Voice 资源复制入口复用该路径。
- Rust/C 阶段验收使用 `scripts/test-agent-ffi.sh`。Swift Bridge/Session/聊天/Voice 集成入口已迁至 v2；Rust/C 独立通过不代表 Swift 跨层通过。

## 8. 第 4 阶段 Swift 落地说明

- `AgentWire.swift` 定义模型、恢复输入、命令、checkpoint、投影、事件和错误类型。`AgentBridge` 校验 v2 poll/reply、session/generation 及 request ID，所有核心 ID/revision 使用 `UInt64`；历史以 UTF-8 字符串原样保存在 sidecar 的 `agentHistory` 中。
- `TaskStore` 在发送前原子保存消息 UUID 作为客户端 ID。恢复时传入已有映射和待确认输入，旧文本交给核心导入；Swift 不解析历史的 `next_id`、turn 或 entry，不按文本匹配输入。
- checkpoint 的历史、完整映射、投影、待确认输入、UI 状态和最终回复去重 ID 一起保存后才确认。工具授权额外等待规范化目录租约，并携带提案 checkpoint、operation 和目录。失效目录按错误码回到目录选择。
- `AgentTaskSource` 不再重试 submit/steer 或删除终态事件。普通输入使用 `SendMessage`；控制队列满时保留并定时重试，Stop 丢弃未发送的授权，保存失败走独立控制并取消调度。
- 正常终态用 generation、turn ID、未确认输入和最终消息 ID 过滤与去重；停止终态等待 `Cancelled`。保存失败会话的清理确认只发一次，Swift 记录该确认用于关闭；重复 close 的回调等待同一个退休句柄完成清理。
- 连接探针是无存档、无目录的临时会话：在内存保留 checkpoint 并确认以允许模型请求，只验证工具提案，绝不发送工具授权。
- 直接验证入口为 `test-agent-task-source.sh`、`test-agent-bridge.sh`、`test-agent-session.sh` 和 `test-voice.sh --agent-only`。后者仅运行 Agent 语音适配测试替身，不等于全量 Voice、Live Voice 或应用包验收。
