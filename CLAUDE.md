## Xcode MCP

本项目配置了 Xcode MCP。构建、测试、诊断一律用它，
不要用 Computer Use 操作 Xcode 界面。
工具调不通时报告具体错误，不要绕路。
MCP 只能运行 scheme 默认测试计划里的 target，切换测试计划无效；
跑非默认计划里的 target 要先切到以该计划为默认的 scheme。

## 测试计划

测试计划按测试在哪里跑来分，每条测试只属于一个计划：
- EchoTests：Echo 的默认计划，例行测试就是跑它。包含所有在 xctest 进程里跑的 target
  （Chat、Rust、Voice、Workspace、View、Integration），不按标签筛选。
  其中有的测试会显示窗口、把测试进程调到前台，可以直接跑。
- EchoAppTests：Echo-App 的默认计划。以 Echo.app 为宿主或从外部驱动 Echo 的 target
  （AppIntegration，含 NativeAppKitEventTests；EchoUITests；Performance）。
- EchoLiveTests：Echo-Live 的默认计划。Live、Soak 和 Device 测试，用真实的密钥、服务和语音识别。
  需要更长超时的测试在代码里设 executionTimeAllowance，计划的最大允许时间不能比它小。
- EchoSanitizers：开 Address Sanitizer 跑 EchoCABITests。

Echo scheme 挂着全部四个计划，方便在 Xcode 里切换；MCP 在 Echo 下只跑 EchoTests。

## Git 工作流

- 每个任务开始前，先确认工作区干净，然后从主分支新建一个分支，分支名体现任务内容。如果我说明是接着某个还没合并的分支做，就留在那个分支上。
- 开发过程中，每完成一个可以独立描述的改动就提交一次，提交信息说明改了什么、为什么改。
- 报告完成前，用 Xcode MCP 构建改动涉及的 scheme，确认没有新增警告；对系统框架接口的隔离违规编译器只给警告、不会让构建失败，要看构建结果里的警告列表。
- 任务完成后先停在分支上，等我确认。确认后切回主分支，使用 `git merge --squash <分支名>` 将该分支压成一个提交，提交信息完整描述整个任务。
- 合并后删除原分支。压缩合并的分支要用 `git branch -D <分支名>`。

## UI 测试

EchoUITests 和 NativeAppKitEventTests 同等对待：两者都会把 Echo 拉到前台并发送按键，都在 EchoAppTests 里。
EchoUITests 经系统的 testmanagerd 发出真实的键盘鼠标事件，会接管键盘；
NativeAppKitEventTests 在 Echo 进程内派发按键事件。
不要顺带跑整个 EchoUITests；只跑和本次改动相关的测试。
跑 EchoAppTests 里的 NativeAppKitEventTests 或 EchoUITests 之前先告诉我；
EchoLiveTests 会用真实的密钥和服务，跑之前也先告诉我。
完整的 UI 测试由我决定什么时候跑。

测试代码不切换输入法，也不改系统设置。XCUITest 打字时，testmanagerd 按当前键盘布局把字符换算成按键；
当前是输入法、换算不了时，它可能临时切换键盘布局，结束后恢复。

测试结果不能取决于键盘布局、键盘导航设置、当前输入法或开测时哪个应用在前台：
- 进程内合成按键事件时，字母、数字和标点的键码按当前键盘布局查（NativeAppKitEventTests 的 TestKey），不写死 QWERTY 键码。
- 依赖 Echo 在前台的测试自己把 Echo 带到前台。
- 和键盘导航有关的断言按 AppKit 当前的设置分支。

测试尽量不让系统真的响警告声：验证某个按键“不起作用”时，检查菜单项是否可用或处理函数的返回值，
不要把按键送到没有对象处理的地方。

## 本地化

界面文案的源语言是简体中文，英文翻译在 assets/Localizable.xcstrings。
新增或修改给用户看的文案时，同时补上英文。
英文用词参考已有译文（会话一律叫 chat）；大小写按 Apple 规范：
菜单、按钮、标题每词首字母大写，状态、提示、说明、错误信息句首大写。
诊断日志的内容不翻译。
