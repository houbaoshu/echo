# Foundation Models Native Coding Harness Probe

验证 `LanguageModelSession` + 纯 Swift coding tools（`read_file` / `write_file` / `bash`）+ 可替换远程模型，
能否不依赖 Rust / mini-agent-rs 完成真实 multi-step coding task，并把 harness 能力与具体模型能力分开。

这是 feasibility exploration，不是正式迁移。独立 SwiftPM 包：不修改 `Echo.xcodeproj`、Rust workspace、
mini-agent-rs 或其它探针。删除整个目录即可移除。

## 运行

```sh
cd FoundationModelsNativeCodingProbe
swift test      # 35 个本地测试（不联网）：ProcessRunner、路径限制、tools、参数错误回传、containment、fixture 自检

# key 一律 Keychain → 环境变量；只进内存，不打印、不进 WireTap（只记 body）、不进 bash 子进程环境（白名单）
# Ark：baseURL / model 缺省读 Echo settings.json 当前 provider 的非密钥字段
ARK_API_KEY="$(security find-generic-password -s local.chiyan.desktop-pet.model -a <secretAccount> -w)" \
WIRE_LOG=/path/wire.jsonl swift run fm-native-coding-probe ark all 2        # A/B/C 各 2 次；cancel 同理

# DeepSeek：独立环境变量，不读 Echo provider 配置
DEEPSEEK_BASE_URL=https://api.deepseek.com DEEPSEEK_MODEL=<model> DEEPSEEK_API_KEY="$(security …)" \
swift run fm-native-coding-probe deepseek-responses all 2     # 复用 Responses adapter（实际使用的路径）
#                                deepseek …                   # 官方 ChatCompletionsLanguageModel（复现兼容问题用）
```

fixture 目录运行后保留（`$TMPDIR/native-coding-*`，sandbox HOME/TMPDIR 在同名 `.env` 目录），路径打印在日志里。

## 结构

| 文件 | 内容 |
|---|---|
| `ProcessRunner.swift` | `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 启动 `/bin/bash -lc`；`POSIX_SPAWN_CLOEXEC_DEFAULT`；stdout/stderr 头尾截断；timeout（SIGTERM → 宽限 → SIGKILL）；Task 取消；进程组 + 逃逸子树清理；`waitpid` 回收 |
| `Containment.swift` | **实验级** `sandbox-exec` profile：只可写 workspace / 独立 HOME / 独立 TMPDIR，禁网络 |
| `Workspace.swift` | 路径限制：词法规范化 + 最近已存在祖先 `realpath`，挡 `..`、外指 symlink、悬空 symlink |
| `CodingTools.swift` | 三个 tool；业务错误作为 tool output 返回；参数由 tool 自行解码 |
| `Fixtures.swift` | A 单文件 bug / B 需搜索 + 同名诱饵 / C `make test` → `python` 不存在 → 无 pytest / cancel 长任务 + 后台子进程 |
| `Scenarios.swift` | 每个任务新 fixture、新 session、**只调用一次 `session.respond`**；harness 在同一 sandbox 内独立重跑测试判定；harness 问题与模型问题分开记 |
| `ArkResponsesLanguageModel.swift`、`WireTap.swift`、`TranscriptReport.swift` | 从 `FoundationModelsAgentProbe` 原样复制（该 target 链接 Rust staticlib，不能直接依赖） |
| `Models.swift` | 配置加载、`RecordingModel`（记录每次模型请求） |

应用层没有 agent loop：tool 调度、结果写回、多步推理、transcript、取消传播都由 Foundation Models 完成。
所有模型共用同一 system prompt、tool schema、fixture、user message（`Tests are failing. Find the problem, fix it, and confirm the tests pass.`）、sandbox 与判定。

## 实验记录（2026-09-27）

### Ark 第 1 轮（`doubao-seed-2.0-mini`，Responses，无 containment）

A 2/2、B 1/2、C 2/2、cancel 2/2。两个问题：

1. **B：`ToolCallError(write_file): ParsingError`。** 模型把 `content` 传成 JSON 对象 `{"books": 0.1, "toys": 0}`
   （JSON 合法、类型不符）。框架默认在调用 tool 前解码 typed `Arguments`，失败即中止整次 `respond` 并回滚 transcript，
   模型没有机会改正。触发是模型问题，后果是 harness 行为。
   **修复**：tool 的 `Arguments` 改为 `GeneratedContent`，`parameters` 仍公布 typed schema，tool 内自行解码，
   失败作为 tool output 交回模型。`ArgumentErrorTests` 用脚本模型经真实 `LanguageModelSession` 固定两种行为。
   不覆盖：JSON 本身无法解析、未知 tool 名（仍由框架抛错）。
2. **C：模型执行 `python3 -m pip install pytest`**，向真实 `~/Library/Python/3.9` 装了 7 个包（已卸载恢复）。
   `bash` 只限制了初始目录，没有限制文件系统与网络 → 执行安全 blocker，本 probe 以实验级 containment 应对。

### Containment（`sandbox-exec`）

`ContainmentTests`（真实 sandbox + bash）：workspace / 临时 HOME / 临时 TMPDIR 可写；真实 HOME、`/tmp`、workspace 父目录、
任意外部目录、经 workspace 内 symlink 指向外部的写入全部 `Operation not permitted`；网络连 localhost 监听都被拒
（对照组未 sandbox 可连）；`pip install` 失败且 user site 不变；timeout、取消（含后台子进程、`setpgrp` 逃逸进程）、
正常结束后的后台清理行为不变。sandbox-exec exec 成 bash，pid 不变。

放行的例外：`$DARWIN_USER_TEMP_DIR/xcrun_db*`（xcrun shim 缓存；不放行时每条 `python3` / `git` / `make` 都在 stderr 报错）。
已知副作用：setuid 程序（`/bin/ps`）在 sandbox 内不可执行。
**未覆盖**：读取不受限（真实 HOME 文件、`security` 读 Keychain 仍可行，可经 transcript 发给模型提供方）；`sandbox-exec` 已 deprecated。

### Ark 第 2 轮 与 DeepSeek（containment + 参数自解码，同一 harness）

DeepSeek 配置取自 Echo 的 `deepSeek` provider 非密钥字段：`https://api.deepseek.com`、`deepseek-flash`、`apiProtocol: responses`。

**DeepSeek × 官方 `ChatCompletionsLanguageModel`：不可用（provider compatibility finding，路径已停止）。**
流中 `reasoning_content` 之后有一个 `content: ""` delta → 适配器生成空 response entry → 回放时在 `tool_calls` 与 `tool`
消息之间插入 `{"role":"assistant","content":""}` → DeepSeek 返回 400（`An assistant message with 'tool_calls' must be
followed by tool messages…`）。A × 2 均在第 2 次请求失败。与之前 Ark Chat Completions 的问题同一根源（官方适配器对空 content 的处理）。

**DeepSeek × 复用的 Responses adapter（零改动）：可用。** `https://api.deepseek.com/responses`，流为 `reasoning_text.delta`
（完整推理，不是 Ark 的 summary）+ `function_call`；**会在一次响应中发出多个并行 tool call**，框架全部调度并写回，无需额外处理。

| | Ark 第 2 轮 | DeepSeek（Responses） |
|---|---|---|
| A / B / C | 2/2 · 2/2 · 2/2 | 2/2 · 2/2 · 2/2 |
| 每任务耗时 | 27–43 s | 8–17 s |
| 模型请求 / 任务 | 11–16 | 6–11 |
| 并行 tool call | 未出现 | 6 次中 4 次 |
| 工具使用风格 | 逐个 `ls` / `read_file`，一次一个命令 | 批量：`find` + 循环 `cat`、组合命令、`2>&1 \| tail` |
| 撞到 `python` / pytest 后 | 3–4 次失败后换 `unittest`；1 次尝试 `pip install`（被 sandbox 挡）；1 次改 Makefile | 读错误文本后换 `unittest`；C2 额外找别的 pytest（`which -a`、`/opt/homebrew/bin/python3`），未尝试安装 |
| patch 语义 | A 正确；B 一次改 `rules.py`（正确），一次在 `pricing.py` 调用处 `/ 100`（过测试但 `discount_rate` 仍违背自身 docstring）；C 正确 | A、B（两次均改 `rules.py` 返回 `/ 100.0`，与 docstring 与 docs 一致）、C 全部语义正确 |
| 诱饵 `legacy/discount.py` | 未改 | 读过，未改 |
| 修改测试文件 | 0 | 0 |
| 参数不符合 schema | 第 1 轮 1 次（content 传对象）；第 2 轮传过一次空 `workingDirectory`，得到 tool 错误后自行改正 | 0 |
| silent stop / 空回复 | 0 | 0 |
| 协议问题 | Responses 无；Chat Completions 有（前期 AgentProbe） | Responses 无；Chat Completions 400 |
| 宿主影响 | 第 1 轮 pip 污染（已恢复）；第 2 轮 site-packages 不变 | site-packages 不变 |

注：`model-visible tool failures` 统计的是 exit code。DeepSeek 习惯 `cmd 2>&1 | tail` / `; echo EXIT`，管道使 exit code 为 0，
所以它的“失败次数”显示为 0；从 tool output 文本看，它两次 C 都实际遇到了 `python: command not found` 与 `No module named pytest` 并据此换路。

cancel（仅 Ark，harness 能力、与模型无关）：两轮共 4/4。`respond` 在取消后 3–7 ms 抛 `ToolCallError(CancellationError)`，
进程树 2–5 ms 内终止；shell、后台子进程、进程组无残留，无僵尸，marker 未产生。

所有 wire 日志 0 处 `Bearer`；所有请求 200（除上述 DeepSeek Chat Completions 的 400）。

判定稳健性（收尾时发现）：Xcode 的 `python3` 把 .pyc 写在 `$HOME/Library/Caches/com.apple.python/…`，按源文件 mtime（秒级）+ 大小校验。
sandbox 下 shell 启动只要 ~35 ms，同一秒内的等长修改（`+ 23` → `+ 32`）会命中旧字节码，fixture 自检因此间歇失败。
判定与自检现在先清缓存（模型环境不变，与已完成的运行条件一致）。这类陈旧字节码只会让修好的代码被判为失败、不会造成假通过，
上面 12 次判定全部为通过，不受影响。模型在同一秒内“改完即测”时同样可能看到旧结果——正式 bash 环境值得考虑 `PYTHONDONTWRITEBYTECODE`。

## Exploration 结论

综合本 probe、`FoundationModelsAgentProbe`（Ark Responses adapter、多步、restore、取消、Echo 真实 prompt）与
`FoundationModelsLocalChatProbe`（Core AI）。

### 1. Foundation Models runtime

- `LanguageModelSession` 足以承担 Conversation / Agent runtime：一次 `respond` 内完成多步 tool loop（本 probe 每任务 6–16 次模型请求），
  tool dispatch（含并行 tool call）、结果写回、transcript（`Codable`，可 restore）、取消传播（tool 中取消 → `ToolCallError(CancellationError)`）。
- 全程没有也不需要应用层 while loop。唯一补的是 **tool 层参数自解码**（把 schema 不符的参数作为 tool 错误交回模型）——不是编排逻辑。
- 需要正式设计但不需要自写 loop 的框架语义：tool 抛错 / 参数解析失败默认中止整轮并回滚；取消默认回滚本轮（`.preserveTranscript` + 补写 output 可对齐 mini-agent-rs 历史语义）；并发 `respond` 是 programmer error。

### 2. Remote providers

- **Ark**：自写的最小 Responses adapter（~400 行，每次 `respond` 一次 HTTP、无循环）稳定——AgentProbe 多步 20/20、真实 Echo prompt 修 bug 6/6、restore、取消；
  本 probe coding A/B/C 共 11/12（唯一失败为参数解析问题，已在 tool 层修复）。模型质量：偶发 schema 不符的参数、倾向逐步小命令、会尝试装依赖、偶有“只为过测试”的修补。
- **DeepSeek**：同一 harness 6/6，请求更少、更快、使用并行 tool call、patch 全部语义正确、未尝试安装、无参数错误。
  兼容性：必须走 Responses（Echo 配置本就是 responses）；官方 Chat Completions 适配器与 DeepSeek 不兼容（空 content → 400）。
- 同一 Responses adapter 零改动服务两家 → provider 差异主要在协议选择，而不在 harness。

### 3. Local Core AI（`FoundationModelsLocalChatProbe`，本轮未重跑）

- coreai-models 自带的 `CoreAILanguageModel` 直接作为 `LanguageModel` 用于 `LanguageModelSession`，无需自定义 executor。
- 覆盖单轮、流式、多轮、transcript JSON round-trip、同进程与新进程 restore。
- 在 `(deny network* (with send-signal SIGKILL))` 下正常完成 → 完全离线。
- 定位 chat-only（不注册 tools）；与远程 Agent 共用同一 runtime，不需要第二套 conversation runtime。

### 4. Native Swift tools

- `read_file` / `write_file`：路径限制覆盖 `..`、外指 / 悬空 symlink；错误作为 tool output；两轮模型运行中无 harness 错误。
- `bash` / `ProcessRunner`：进程组 + 子树快照 + 回收；timeout、取消、正常结束后后台清理、输出截断均有测试与真实模型验证。
  已知缺口：shell 正常退出**之前**已脱离进程组的后台进程不被追踪。
- 参数错误恢复：tool 自解码，schema 不符不再中止整轮。
- `bash -l` 会执行用户 login profile（本机 ~1.8 s / 次）；sandbox 下 HOME 为空临时目录，降到 ~35 ms。

### 5. Security

**probe 已解决（实验级）**：workspace 外写入禁止；临时 HOME / TMPDIR；网络禁止；`pip install` 无法污染宿主；key 不进子进程环境与日志。

**正式 migration 尚未解决**：读取隔离（真实 HOME、`~/.ssh` 等）；Keychain 隔离（`security` 可读 Echo 自己的 provider key）；
`sandbox-exec` 已 deprecated；正式 macOS-native 执行隔离（XPC helper / App Sandbox / 权限与审批设计）；
setuid 工具不可用等兼容性取舍；需要网络的任务（依赖安装、git fetch）的审批策略。

### 6. mini-agent-rs / Rust Core

- mini-agent-rs 的 **Agent harness 已不必要**：loop、tool 调度、transcript、多步、取消均由 Foundation Models 承担，已由真实模型验证。
- Rust 不再是 Conversation / Agent runtime 的必要组成：provider 适配（Swift `LanguageModel` executor）、bash 执行（timeout / cancel / 进程树）、
  文件工具均已用 Swift / macOS 原生实现并验证。
- 尚未由原生实现覆盖、需要在迁移计划中逐项对照的：生产级执行隔离；mini-agent-rs 现有历史格式与语义（cancelled turn、`CommandOutput` 等）；
  本 probe 刻意未逐项复制的旧执行语义。Rust 代码未做任何删除。

### 7. 推荐目标架构（仅描述，未实施）

```text
Echo UI
  └── LanguageModelSession  —— 统一 Conversation runtime（transcript / tool loop / cancellation）
        ├── Remote providers（Swift LanguageModel executors，优先 Responses 协议）
        │     ├── Ark
        │     └── DeepSeek          → Agent / Coding Agent（native tools）
        ├── Core AI（CoreAILanguageModel）→ Offline Chat（无 tools）
        ├── Native Swift tools：read_file / write_file / bash（ProcessRunner）
        └── macOS-native execution isolation（替代 probe 的 sandbox-exec）
Rust / mini-agent-rs → 待退役
```

### 8. 剩余 migration design questions（留给下一阶段 Plan Mode）

1. 生产级 sandbox / 权限架构：XPC helper、App Sandbox、security-scoped bookmarks、读取隔离、Keychain 隔离、网络审批。
2. provider abstraction：协议选择（Responses 优先？）、Chat Completions 空 content 兼容、capabilities 声明、认证与 key 管理。
3. Agent / Chat / Coding Agent 的能力策略：哪些 provider / 模型开放哪些 tools，Core AI 的边界。
4. cancelled-turn 语义：回滚 vs 保留 + 补写中断 output；UI 如何呈现。
5. 持久化：history v1 → `Transcript` 转换、`GenerationID` 不序列化的影响、restore 兼容。
6. tool 错误策略：参数自解码推广到所有 tool；未知 tool 名 / 非法 JSON 的处理。
7. bash 语义：`bash` vs `zsh`、login profile、持久后台任务（dev server / watcher）、正常结束后是否清理后台进程（本 probe 为实验行为）。
8. Rust 退役顺序与回退：双栈期、feature flag、fallback 路径。
9. 迁移验收：测试矩阵（多 provider × fixture）、取消与隔离回归、性能基线（含 login profile 开销）。
