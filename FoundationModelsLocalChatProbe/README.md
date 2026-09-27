# Foundation Models Local Chat Probe

验证 Core AI 本地模型能否经 coreai-models 自带的 `CoreAILanguageModel: LanguageModel` 直接接入 `LanguageModelSession`，做 chat-only、完全离线的对话。不写自定义 `LanguageModel`，不注册 tools。

独立 SwiftPM 包：不修改 `Echo.xcodeproj`、Rust workspace、`FoundationModelsAgentProbe` 或任何生产代码。删除整个目录即可移除。

## 环境

- Xcode 27.0、macOS 27.0 SDK
- 本地 `apple/coreai-models` 克隆，路径 `../../coreai-models`（与 echo 仓库同级），product `CoreAILM`
- 模型固定为 `coreai-models/exports/qwen3_0_6b_4bit_dynamic`（内嵌 tokenizer）

## 运行

```sh
cd FoundationModelsLocalChatProbe
swift build -c release -j 2            # 8 GB 内存机器上默认并行度可能把进程挤掉

# 单轮 respond、流式、4 轮对话、空白 session 对照、transcript JSON round-trip + 同进程 restore
.build/release/fm-local-chat-probe all /tmp/transcript.json
# 新进程只读 JSON 重建 session 继续对话
.build/release/fm-local-chat-probe restore /tmp/transcript.json

# 离线：任何网络 socket 操作都会让进程被 SIGKILL（exit 137），正常退出即证明没有网络访问
NOKILL='(version 1)(allow default)(deny network* (with send-signal SIGKILL))'
sandbox-exec -p "$NOKILL" .build/release/fm-local-chat-probe all /tmp/transcript.json
sandbox-exec -p "$NOKILL" .build/release/fm-local-chat-probe restore /tmp/transcript.json
```

`PROBE_VERBOSE=1` 打开 coreai-models 的 `CLILogger`（stderr），可看到 engine 选择与每轮 tokenize 的 token 数。

检查分两类：`plumbing`（session / transcript / restore 机制，失败则 exit 1）与 `recall`（模型是否答对，子串匹配，只报告不影响退出码）。
