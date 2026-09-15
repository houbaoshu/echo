# Mini Agent Bridge v2：第 1 阶段契约

本文件是 [迁移计划](mini-agent-mainline-bridge-v2-plan.md) 第 1 阶段的交付。`agent-bridge/tests/support/v2_contract.rs` 是随测试编译的类型规范，**没有接入生产库、没有实现运行器、没有启用 C ABI v2**。当前 C ABI、Swift 和依赖路径继续遵循 [现有 v1 契约](agent-integration-stage2.md)。

## 1. 类型归属与 API 边界

| 类型 | 后续归属及语义 |
| --- | --- |
| `SessionCommand` | `conversation::runner`；`SendMessage` 原子决定 submit/steer。保留显式 Submit、Steer、Continue、ProvideDirectory、ExportHistory。 |
| `SessionControl` | 独立控制入口；保存成功、保存失败、工具放行，不能进入普通命令队列。 |
| `SessionBatch<ConversationHistory>` | 核心批次，包含类型化核心事件、可选 checkpoint、输入回执及显示投影；无 wire version。 |
| `CheckpointId` | `(generation, revision)`；generation 每次创建句柄更新，revision 从 1 开始、严格递增、不回绕。会话 ID 相同也不能跨句柄确认。 |
| `InputMessage` / `InputReceipt` | 稳定客户端 ID 和文本；回执将客户端 ID 映射至核心 message/turn ID。request ID 只关联一次传输，不替代客户端 ID。 |
| `RestoreInput` | 原始 v1 历史、旧文本历史、或空历史三选一；完整已知映射、待确认输入和显式目录覆盖。 |
| `DisplayEntry` | 有序消息/工具投影；以核心 ID 定位。工具 result 保留原始结果字符串及其中的退出码、超时、截断和 unknown/not_executed 信息。 |
| `WireCreate` / `WireRequest` / `WireReply` / `WirePoll` | Bridge 所有；JSON 版本、模型凭据、Bundle prompt 文件路径及传输封装。 |

编译规范暂时复用当前依赖的 `ConversationHistory` / `ConversationEvent`；切换依赖后应使用主线 `conversation` 导出的类型。泛型 `H` 只表达核心历史与 wire 原样 JSON 字符串之间的编码边界，不要求公共运行器 API 本身泛型化。v2 顶层批次不再复用 v1 的任意 JSON 字典。

### 第 2 阶段的 SessionHandle 接口约束

以下是待实现接口的签名约束，不提供空实现或模拟运行循环：

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

`CancellationSignal` 为持久化停止状态加异步通知；执行前检查已取消，执行中持续监听。返回任何结果（包括错误/取消）前完成子进程清理；不为任意 `Environment` 提供“丢弃 future 即已取消”的默认实现。内置实现复用主线底层进程执行代码，保留旧 `Environment::execute`，桌宠参数为 `/bin/bash`、30 秒、stdout/stderr 各 64 KiB。停止杀进程组并等待 shell 回收；模型任务取消后同样 await 结束。完成的真实工具结果优先保留，执行中取消由状态机记录 unknown。

## 2. 保存及工具放行顺序

1. 初始化恢复完成或历史/输入映射发生实质变化后，产生完整 checkpoint。仅确认、导出、拒绝命令不得增加 revision；可重新发送同一 checkpoint。
2. Swift 将原样 `history` 字符串、全部 `input_receipts`、投影/UI 快照及尚未确认的输入原子写入同一个 sidecar，然后确认该 checkpoint。UI 可先显示，但不能据此放行工作。
3. 每个批次注明 generation；事件和输入回执属于该 generation。已发出 checkpoint 才能确认。确认是同一 generation 内的累计保存水位：保存 revision N 的完整快照可覆盖 ≤N 的变化；重复已确认水位为无操作，未来或其他 generation 返回 `stale_checkpoint`。
4. 模型派发前必须先保存用户输入和模型预算变化。当前 `next_operation()` 会增加 `model_calls` 并改变状态：第 2 阶段应先取得/保留 operation、发 checkpoint，确认后才启动请求；等待期间仍处理 Stop、输入和目录变化。不能在每次收到确认时再次调用 `next_operation()` 重复计费。
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

保留现有 C 符号、16 MiB 请求限制、字符串独立所有权和 panic 隔离。升级发生于第 3/4 阶段；届时仅接受 v2 请求，v1 wire 返回 `unsupported_version`，**持久化历史仍为 v1**。版本在读取顶层 JSON 后先检查，再解码 payload；不要把一个合法 v1 请求误报为普通字段错误。generation、request ID、客户端 ID 必须非空；revision 和核心 IDs 必须为正整数。JSON 数字完整保留 u64，不经 Double。

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

错误码枚举见编译规范。Swift 根据 code 决策、message 仅显示；不得把密钥、完整配置或模型服务响应拼入基础设施错误。未知 wire 字段/命令和缺失必要字段拒绝；未来历史扩展由核心存档版本契约负责。

## 5. 测试边界与后续验收清单

| 场景 | 第 1 阶段证据 | 后续新增验收 |
| --- | --- | --- |
| v1 存档 | `history_v1.rs`：完整聊天、重复文本、Responses 元数据、缺失工具结果恢复幂等、损坏历史 fail closed | 主线恢复入口使用相同样例，增加客户端映射恢复 |
| 协议切换 | `lifecycle.rs`：固定 Responses 存档重建为两种协议，真实 loopback 请求保留结果、仅 Responses 发送 reasoning | 下一轮新配置和新 v2 适配保持语义 |
| 工具/取消 | 已有 executor 单测和 lifecycle：超时/截断、执行前取消、过期提案、满队列取消/销毁、真实进程清理、已完成结果保留 | 保存等待/授权等待时 Stop；每会话 completion；模型与工具清理未完成不得重启 |
| 发送竞态 | `AgentTaskSourceTests.swift`：完成边界连续追加，Stop 前后迟到回执；固定存档保留同文本不同 IDs | 原子 SendMessage，ID 去重及冲突，停止期间拒绝；删除文案重试后重写测试驱动 |
| 保存/目录 | `AgentSessionTests.swift`：当前真实 sidecar、目录调度、存储失败；`session.rs`：已接收 steer 撤销工具授权 | checkpoint 未确认禁止模型/工具；结果保存失败禁止下一模型；符号链接租约；旧 generation/revision/operation 不放行 |
| v2 编解码 | `v2_contract.rs`：类型 round-trip、必需关联 ID、控制/命令分离、wire v2 与 archive v1 分离、历史字节保留 | 实际 C v2 版本/大小/Unicode/队列回执、Swift Codable、C ASan |
| UI/语音 | 现有 Chat/UI/Voice 回归入口保留 | generation/turn/message 去重及晚到终态跨层验证 |

本阶段不以序列化测试代替运行器行为验收，不添加“通过”的假运行器或忽略测试。第 2 阶段按上述后续列编写真实运行器测试；第 3/4 阶段分别迁移 C 和 Swift；完整 feature 矩阵、应用包和跨层验收归第 5 阶段。

## 6. 第 2 阶段落地说明

核心契约已在 Mini Agent 主线工作区的 [`conversation::runner`](/Users/houbaoshu/workspace/mini-agent-rs/src/conversation/runner.rs) 实现，见 [运行器使用说明](/Users/houbaoshu/workspace/mini-agent-rs/docs/conversation-runner.md) 和 [计划第 2 阶段记录](mini-agent-mainline-bridge-v2-plan.md#7-第-2-阶段实施记录2026-09-15)。本文前述 wire 类型仍是后续 Bridge/Swift 迁移的规范，尚未接入生产 C ABI。

具体 API 使用 `SessionParts { restored, model, executor }`；`restored` 由 `Conversation::restore(session_id, config, restore_input)` 返回。`SessionOptions::new(session_id, generation)` 设置默认队列容量，宿主为每次创建提供新 generation。初始化在 Stop/close 后继续 await，宿主初始化 future 必须等待其 blocking 工作结束，运行器不会把 abort blocking 任务视为清理完成。

`SessionCompletion::wait()` 确认整个句柄 close/Drop 后完成清理；可复用句柄的普通 Stop 通过 `BatchKind::Cancelled` 确认本次操作清理完成。两者都要求宿主保持 runtime 存活。旧 `Environment` 仍可独立使用，只有显式实现 `ConversationExecutor` 的执行器提供可等待取消保证。
