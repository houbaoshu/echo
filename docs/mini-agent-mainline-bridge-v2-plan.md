# 桌宠接入 Mini Agent 主线及 Bridge 收敛计划

## 1. 结论与当前实现

以 `/Users/houbaoshu/workspace/mini-agent-rs` 的当前 `main` 为基线，检查时为 `b03cf72`。按已确认的选择：

- 将完整异步会话运行器上移到 Mini Agent。
- 沿用 `conversation` feature，保留可独立使用的纯会话状态机。
- 一并收敛 Swift 的历史修补和发送竞态处理。
- 内部桥接协议升级为 v2，继续兼容 v1 会话存档。

当前主要发现：

| 位置 | 当前职责与问题 |
|---|---|
| [Rust Bridge](/Users/houbaoshu/workspace/desktop-pet-agent-exp/agent-bridge/src/session.rs) | 除桥接外，还承担 Tokio 会话驱动、模型任务、工具调度、背压、取消、清理及事件封装。 |
| Rust 执行适配 | 重复实现 bash 执行、输出截断、超时和进程组清理；其可等待清理保证目前不能直接用主线 `LocalEnvironment` 的 Drop 替代。 |
| [Swift 会话适配](/Users/houbaoshu/workspace/desktop-pet-agent-exp/macos/AgentTaskSource.swift) | 直接构造和修改历史内部 ID，匹配错误文案重试 `submit` / `steer`，并过滤部分终态事件。 |
| Swift 工作区 | 已负责目录选择、同目录调度、历史落盘及显示投影；这些属于桌宠职责。 |

普通聊天已经使用 `AgentTaskSource`，因此本次迁移同时影响聊天和工具任务。应继续使用 `Conversation`，其直接回复语义与 `Agent::run()` 的必需工具调用、完成标记语义不同。

## 2. 目标架构与 features

目标调用链：

**Swift 工作区 → Swift 类型化适配 → `echo-agent` C ABI → Mini Agent 会话运行器 → 会话状态机、模型与执行环境**

| 层 | 重构后职责 |
|---|---|
| Mini Agent 状态机 | 历史、ID 分配、模型预算、工具校验、steering、恢复、事件及终态语义。 |
| Mini Agent 运行器 | 异步初始化与 operation 驱动、有界队列、背压、取消与清理确认、保存确认及工具放行门控。 |
| `echo-agent` | C 指针和字符串所有权、JSON 编解码与版本校验、参数转换、panic 隔离、共享 Tokio runtime 和关闭计数适配。 |
| Swift | 凭据与 Bundle 资源、项目关联和目录租约、原子落盘、UI 状态投影、语音与任务生命周期展示。 |

[桌宠依赖配置](/Users/houbaoshu/workspace/desktop-pet-agent-exp/agent-bridge/Cargo.toml) 改为：

```toml
mini-agent-rs = {
    path = "../../mini-agent-rs",
    default-features = false,
    features = ["conversation"]
}
```

- 新运行器位于 `conversation::runner`；不新增 feature。
- 不启用 `tdd`：当前桌宠需要普通会话和 bash 工具；启用 TDD 也不会为会话自动增加 TDD 行为。
- 主线继续保持 `default = []`，Core、CLI 和 TDD 的已有入口保持兼容。
- prompt 从同一主线依赖目录打包，运行时仍从应用 Bundle 显式加载。

## 3. Mini Agent API 与运行契约

### 会话运行器

增加类型化的 `SessionCommand`、`SessionBatch`、`SessionHandle` 和错误码；运行器接收宿主提供的 Tokio handle，以及模型、执行器和初始化输入。

- 模型约束使用 `ConversationModel`，消息使用 `conversation::ConversationMessage`。
- `Model` 继续只承担 Core 查询；自定义会话模型和测试替身显式实现 `ConversationModel`。
- 保留现有每会话串行执行、命令队列 32、事件队列 64 的默认值。
- 运行器等待外部确认时不忙轮询；Stop、销毁和确认通道不会被普通命令队列阻塞。
- Mini Agent 使用 Rust 类型，不引入 C ABI、Swift 类型、工作区文件路径或应用全局状态。

### 统一工具执行与取消

增加会话执行器 trait，输入为 action、目录和取消信号，返回执行结果或取消结果；返回前必须完成执行清理。

- 内置实现复用 `LocalEnvironment` 的底层进程执行代码，删除 Bridge 中的独立执行算法。
- 保留 `Environment::execute` 的现有接口；可等待取消能力作为新增接口，不给任意执行环境添加仅靠丢弃 future 的默认实现。
- 桌宠继续使用 `/bin/bash`、30 秒命令超时、stdout/stderr 各 64 KiB；主线现有调用者保留默认 shell 选择。
- 停止工具时发送进程组终止信号并等待 shell 回收，再确认停止；停止模型时取消并等待请求任务结束。
- 已完成的工具结果即使尚未发送，也保留真实结果；执行中取消仍记录效果未知。清理完成前禁止启动新操作。

### 保存确认与项目门控

新增 checkpoint revision 和显式确认：

1. 历史发生实质变化后，运行器输出事件、完整历史及对应 revision。
2. Swift 更新显示投影，并原子保存历史、消息和映射，再确认该 revision。
3. 工具提案还必须取得 Swift 的目录租约，并收到对应 operation 的放行。
4. 运行器处理已接收的控制消息，重新检查 operation、保存状态和目录，再调用 `begin_tool` 执行。
5. 工具结果保存成功后，才允许发起下一次模型请求。

确认本身不产生新 checkpoint。过期确认不能放行新提案；保存失败停止后续调度并执行清理。Stop 和销毁在保存等待、目录等待及事件背压期间仍可响应。

目录租约继续按真实路径、整轮持有；取消或删除会话后，Swift 等待该会话清理确认再释放。

### 输入与历史恢复

- 增加原子的 `SendMessage`：运行器根据实际状态选择开始新轮或追加指令，停止期间明确拒绝；Swift 不再往返重试 `submit` / `steer`。
- 输入携带稳定的客户端消息 ID，回执返回对应核心 message/turn ID；用这些标识处理确认与显示，替代文案匹配和按文本猜测。
- Mini Agent 提供旧文本会话导入、未确认用户消息恢复及目录覆盖入口；内部负责 ID 分配、工具结果配对和中断标记。
- 导入不触发执行；继续处理不重复追加原请求，也不重放旧命令。
- v1 历史及 Responses 元数据完整保留。Swift 保存原样历史 JSON，通过独立类型化投影显示消息和工具，不再修改 `next_id`、turn 或 entry。
- 历史、客户端消息映射和 UI 快照一起原子保存；覆盖确认前后崩溃及重复文本输入的恢复，避免丢失或重复用户消息。

## 4. Bridge 与桌宠调用点迁移

### C ABI v2

保留现有 C 函数符号和内存规则，统一升级 JSON 请求与批次版本；旧 wire v1 请求明确返回版本错误，不维护两套运行流程。持久化历史版本仍为 1。

v2 增加类型化错误码、输入确认、checkpoint revision/确认、原样历史及显示投影。保存确认通过独立控制路径进入运行器。原有 submit/steer C 入口仍映射对应命令，桌宠正常发送改用 `SendMessage`。

`echo-agent` 删除自有会话循环和 bash 执行器，保留 FFI 所需的初始化、runtime 和生命周期适配。

### Swift 调整范围

- **AgentBridge**：改用 `Codable` 请求、批次和错误类型；保留 MainActor 句柄所有权、50 ms 轮询、字符串复制释放和异步关闭。
- **AgentTaskSource**：传递历史及待恢复输入，删除内部历史修改和错误字符串重试；保留每轮读取已保存模型配置、重建会话的行为。
- **TaskStore**：接收类型化投影、保存后确认、目录放行；使用 generation、turn ID 和待确认输入控制终态展示，防止旧回复触发新任务完成或语音播报。
- **WorkspaceStore**：继续拥有 sidecar 存储和目录调度；适配保存确认及每会话清理回执。
- **连接探针与测试替身**：同步迁移 v2。连接测试继续只检查工具提案，不放行命令。

构建、打包、Agent/Voice 测试中的 prompt 路径统一从实际解析到的 Mini Agent 依赖目录获取，避免代码与资源指向不同版本；更新 README 和当前接入契约。

修改限定在 Agent 接入及直接受影响的测试、构建和文档。桌宠动画、窗口、文件浏览、音频识别与播放实现保持现状。

## 5. 实施顺序与验收

### 实施顺序

1. 固化现有行为测试和 v1 存档样例，定义 v2 类型与运行器契约。
2. 在 Mini Agent 实现运行器、可等待执行清理及历史恢复入口。
3. 桌宠切换主线路径和 feature，替换 Rust Bridge 内部实现。
4. 同步迁移 Swift 类型、保存确认和输入回执，删除旧恢复与重试逻辑。
5. 完成跨层回归、独立应用包验证和文档更新。

### 必须覆盖的场景

| 类别 | 验收重点 |
|---|---|
| 聊天与协议 | 无目录直接回复、多轮聊天、Chat Completions/Responses 切换、reasoning 元数据保留、下一轮采用新配置。 |
| 工具调用 | 真实读写验证、输出截断与超时、目录选择/取消/失效、连续工具调用、同目录及符号链接串行、不同目录并行。 |
| 输入竞态 | 模型执行、工具执行、等待目录及完成边界连续追加；Stop 后迟到回执不启动请求；重复文本保持独立消息。 |
| 取消与生命周期 | 初始化、网络、工具、保存等待、满队列期间取消；重复 Stop、删除、销毁、退出；清理确认后才释放租约。 |
| 持久化 | 保存意图或结果失败时禁止后续操作；未确认 checkpoint 不启动下一次请求；v1 导入、缺失结果恢复、损坏历史阻止执行、不自动重放。 |
| UI 与语音 | 消息和工具顺序稳定、最终回复只展示/播报一次、旧终态不覆盖新任务、隐藏窗口继续运行。 |
| FFI | v2 版本校验、Unicode、大输入限制、队列满回执、字符串跨句柄生命周期及 C AddressSanitizer 检查。 |

Mini Agent 对默认、无默认 feature、conversation、tdd、all-features 五种组合运行测试、文档测试和 Clippy，并验证 feature API 边界。桌宠运行 Rust 工作区检查、现有 Bridge/Session/TaskSource、聊天、工作区、UI 和语音回归。

最后构建 Apple Silicon ad-hoc 应用包，从无源码的临时工作目录运行，确认资源自包含、主线程响应和退出清理。自动验收使用本地模型服务与临时项目；真实服务和 Live Voice 用于发布前抽验。

**完成标准：有效依赖和资源不再引用旧实验目录；Bridge 不再拥有第二套会话循环或命令执行算法；既有行为通过回归，新增保存与取消契约得到跨层验证。**

## 6. 第 1 阶段实施记录（2026-09-15）

范围仅为实施顺序第 1 项：固化现有行为测试和 v1 存档样例，定义 v2 类型与运行器契约。生产运行器、依赖切换、C ABI/Swift 迁移均未开始。

### 交付

- [v2 契约](mini-agent-mainline-bridge-v2-contract.md)：类型归属、SessionHandle/执行器接口、保存及派发顺序、输入恢复、错误码、wire 边界和后续验收矩阵。
- `agent-bridge/tests/support/v2_contract.rs`：仅随测试编译的 v2 类型规范；`v2_contract.rs` 验证序列化及关联字段约束，不接入生产 FFI。
- `tests/fixtures/agent-v1/`：合成的固定 v1 聊天、Responses 工具结果、缺失结果中断及损坏 ID 样例；`history_v1.rs` 验证恢复、元数据、ID、幂等性和禁止自动重放。
- `lifecycle.rs`：增加固定存档的两种协议重建与损坏存档初始化失败验证；继续保留现有工具、背压和清理测试。

### 实际代码差异与最小调整

1. 主线重新核对仍为 `b03cf72`，工作区干净；桌宠仍依赖 `mini-agent-agent-core-exp`。第 1 阶段将可编译类型规范放在桌宠测试目录，避免为“定义契约”提前修改主线或启用 v2。第 2/3 阶段按类型归属迁入实际模块。
2. 当前核心 `next_operation()` 在返回模型 operation 时已增加 `model_calls`、修改状态并产生事件。计划中的保存屏障必须覆盖此变化：第 2 阶段需保留尚未派发的 operation，确认对应 checkpoint 后才发模型请求，不能直接包装现有 `advance()`。本阶段只明确该约束。
3. v1 wire 的 `start_tool` 走普通命令队列，而且工具结果之后可以立即进入下一模型请求；它不具备 v2 保存确认语义。契约将工具授权与保存控制一起放到独立入口，并明确结果保存屏障；不把现有测试通过误当作这些新保证已实现。
4. 现有 Swift 仍需要修改历史 IDs 和按错误文案重试。旧行为测试保留作迁移基线；v2 的相同客户端 ID 幂等、崩溃恢复及终态去重由后续真实运行器/Swift 测试验收。本阶段不实现替代算法。
5. 首次 `cargo test --locked -p echo-agent` 编译失败：实际实验依赖为 `e554495`，工作区干净，但已经采用 `default = []` 和 `conversation` feature，并将查询移入 `ConversationModel`。桌宠的旧配置及 `Model` 导入已不兼容。为使第 1 阶段基线可执行，提前做最小兼容修复：保留旧路径，仅显式声明 `default-features = false, features = ["conversation"]`，并从 `conversation` 导入 `ConversationModel` / `ConversationMessage`。不迁移运行器或执行器；原第 3 阶段的主线路径切换仍未实施。
6. 仓库 `.gitignore` 原本忽略整个 `docs/`，包括用户指定的计划。为让必要文档可随代码审查，仅解除本计划及新增 v2 契约文件的忽略；其他旧文档不变。

### 验证

以下均已通过：

- `cargo test --locked --workspace`：12 项 Rust 测试（原有 3 项单测、3 项 v1 存档测试、1 项多场景生命周期集成测试、5 项 v2 类型契约测试）；工作区 doc-test 入口通过，当前没有可执行文档测试。
- `cargo fmt -p echo-agent --check`、`cargo clippy --locked --workspace --all-targets -- -D warnings`、`git diff --check`。
- `/bin/zsh scripts/test-agent-task-source.sh`：完成边界连续追加、迟到拒绝及 Stop 后禁止重试。
- `/bin/zsh scripts/test-agent-session.sh`：真实 Bridge/Swift 会话、两种协议、连接探针、目录/排队/追加、清理、继续处理、原子存档恢复及保存失败。
- `/bin/zsh scripts/test-agent-bridge.sh`：Rust 回归、Swift 主线程心跳/Unicode/字符串所有权/异步关闭/独立 Bundle prompt，以及 C AddressSanitizer 500 次句柄生命周期压力检查。该 C 检查不等于对 Rust 内部访存的完整 sanitizer 覆盖。

首次集成运行受沙箱限制，无法监听 `127.0.0.1`；允许测试权限后重跑通过，未改测试来绕过端口失败。类型测试还捕获了 Serde 内部 tag 的 unit variant 会接受额外字段的问题；改为零字段 struct variant 后，未知字段拒绝测试通过。

Mini Agent 主线和实验依赖工作区均未修改。完整主线 feature 矩阵、UI/语音全量跨层回归与最终应用包验收仍按原实施顺序执行。本阶段到此完成，未进入第 2 阶段。
