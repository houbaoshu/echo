## Xcode MCP

构建、测试、诊断一律用 Xcode MCP，不要用 Computer Use 操作 Xcode。
工具调不通时报告具体错误，不要绕路。
MCP 只能跑 scheme 的默认测试计划，切换计划无效。改动涉及 EchoAppTests 或 EchoLiveTests 里的测试时，切到 Echo-App 或 Echo-Live scheme，跑相关的那几条。

## Git 工作流

- 每个任务从干净的主分支新建分支，分支名体现任务。我说明接着某个未合并分支做时，留在那个分支上。
- 每个能独立描述的改动提交一次，写清改了什么、为什么。
- 报告完成前，构建改动涉及的 scheme，看构建结果的警告列表，确认没有新增警告。
- 做完停在分支上等我确认。确认后 `git merge --squash <分支名>`，再 `git branch -D <分支名>`。

## 测试

- 开发中只跑和改动相关的测试；报告完成前完整跑一次 EchoTests。
- 测试结果不能依赖键盘布局、键盘导航设置、输入法或哪个应用在前台。
- 产品代码给测试提供注入时，只用带默认值的 init 参数或 SwiftUI 的 `@Entry`，不用 `#if DEBUG`。

## 本地化

界面文案的源语言是简体中文，英文在 `assets/Localizable.xcstrings`。新增或改动给用户看的文案时同时补英文。
英文用词参考已有译文（会话一律叫 chat）；大小写按 Apple 规范：菜单、按钮、标题每词首字母大写，状态、提示、说明、错误信息句首大写。
