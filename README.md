# WeGit

面向 macOS 27 的原生 Git 工作台，使用 SwiftUI、SwiftData 和系统 Git CLI。

当前为 **0.1.0 开发预览**，按 [执行计划](docs/PLAN.md) 推进。已经建立可运行工程与「打开仓库 → 查看差异 → 暂存 → 提交」闭环；不等同于完成 V1.0。阶段证据、范围和待办见 [开发进度](docs/DEVELOPMENT.md)。

## 环境

- macOS 27 或更新版本。
- Xcode 27，Swift 6.4（本地已验证）。
- Git 2.46 或更新版本，启动时检查配置隔离与远端地址重置能力；已验证 Apple Git 2.54.0 和独立编译的 Git 2.46.0，见 [兼容性记录](docs/COMPATIBILITY.md)。
- XcodeGen 2.43 或更新版本，仅修改 `project.yml` 后重新生成工程时需要。

Git 核心没有第三方运行时依赖。当前使用系统自带 `swift format`，无需额外安装格式化工具。

## 构建与运行

```bash
scripts/build.sh Debug
open .build-app/Build/Products/Debug/WeGit.app
```

也可以直接用 Xcode 打开 `WeGit.xcodeproj`，选择 WeGit scheme 后运行。`project.yml` 是工程配置源，生成的 Xcode 工程保留在仓库中。

当前开发包采用本机 ad-hoc 签名，Bundle ID 为 `org.weopen.WeGit.development`，不启用 App Sandbox。项目使用 [MIT 许可证](LICENSE)，正式发行采用 Developer ID 签名、公证后直接分发；签名身份与公证环境仍待配置，当前开发包尚未公证。

## 验证

```bash
# Swift 核心单元测试及真实临时仓库集成测试
swift test

# 格式、核心测试、应用构建
scripts/verify.sh

# 增加原生 UI 测试；需要可交互的 macOS 登录会话
scripts/verify.sh --ui

# 格式化源码
swift format format --in-place --recursive WeGitCore WeGit WeGitAskPass WeGitTests WeGitUITests WeGitPerformanceTests Benchmarks Package.swift
```

测试仓库、签名测试密钥和测试身份均在临时目录中创建并清理。核心与 UI 夹具先验证配置隔离；全局配置编辑测试强制写入私有临时文件。旧 Git 隔离失效事件、恢复和回归见 [兼容性记录](docs/COMPATIBILITY.md)。UI 测试使用独立偏好与内存数据库。

最新核心测试为 175 项、31 个套件，在上述两个 Git 版本下全部通过。已有 33 项原生 UI 功能用例曾在一次完整运行中全部通过，包含配置保存时退出保护、多轮冲突、真实回收、窗口恢复、原文选区复制和八种上下文操作组合；新增字号、密度与窗口尺寸矩阵仍在收尾，最终稳定源码需再次完整验证。独立的辅助访问审查仍未通过，详见 [辅助访问验收](docs/ACCESSIBILITY.md) 和 [开发记录](docs/DEVELOPMENT.md)。普通与十万级仓库均有 30 次 Release 后台样本；另有 30 次原生新进程启动样本，P95 为 468.98 ms。这些性能数据保留各自源码和测量边界，见 [性能记录](docs/PERFORMANCE.md)。

`scripts/verify.sh --ui` 包含尚未通过的辅助访问审查，目前会因该用例返回失败。复现已通过的功能套件时，使用同一 Debug 工程并显式排除该审查：

```bash
xcodebuild -project WeGit.xcodeproj -scheme WeGit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
  -skip-testing:WeGitUITests/LayoutTests/testAccessibilityAuditInBothThemes test
```

CI 工作流使用 `wegit-macos27` 标签的自托管 macOS 27 Runner；需要配置该 Runner 后才能运行，当前不声称远端 CI 已通过。此工作流不运行来自 fork 的 PR 代码。

## 当前操作

- 打开本地仓库、拖入目录、最近仓库与收藏；克隆阶段进度、取消与失败恢复。
- 查看已暂存、未暂存、未跟踪和冲突文件；按路径和状态筛选，菜单提供外部打开、路径复制和整文件操作。
- Unified/Split 文本差异、后台词法高亮、词级差异、3/20/80/200 行上下文、忽略空白只读模式。
- 前后差异块导航、原文选区/跨行/完整行复制，保留空格、Tab、Unicode、CRLF 与无末尾换行；按区域展开/折叠上下文。
- 大差异先显示摘要，再显式读取、按页显示，可取消。
- 超过内存上限后使用私有磁盘快照，支持统一/分栏分页、完整导出和经过完整快照校验的块级操作。
- 磁盘与普通差异均可按区间展开上下文；分栏长行按列宽换行。未跟踪文件可经确认移到废纸篓。
- 文件与差异块暂存/取消暂存、未暂存差异块丢弃；过期或不属于当前差异的块会被拒绝。
- 普通提交、Amend、提交草稿、Hook/签名错误反馈。
- 固定引用快照的原生历史表格、可调整列宽、跨页提交图、分支/Tag 徽标、浅克隆边界、完整提交信息及可选父提交的文件差异。
- 从历史提交创建分支或检出 Detached HEAD；分支创建/切换/重命名/删除、跟踪和上游设置，保护其他工作树占用的分支。
- 明确远端与目标引用的 Fetch/Pull/Push、首次推送上游设置、三种 Pull 策略和固定预期提交的 Force Push With Lease。
- Merge/Pull Rebase 冲突的继续与中止；“提交并推送”在推送失败后保留本地提交，只重试同步。
- 推送回执丢失、超时或取消时保留原目标，只读核对后再决定下一步；重启后校验仓库实体和地址指纹，目标不同需要重新确认推送。
- 系统 Helper/SSH Agent 优先，缺少凭证时通过内置 AskPass 通道显示原生认证窗口；可取消、有限时，不绕过 SSH 主机检查。
- 按事件范围合并刷新，停用仓库释放监听和历史缓存；过期读取不会覆盖新会话，失败状态明确标记。
- 消息/作者/SHA 搜索、文件与分支筛选、可搜索的键盘分支切换器、命令面板及共享菜单动作。
- 六类原生设置：启动、窗口/分栏恢复、外观与密度、差异阅读、草稿、作用域明确的 Git 身份/策略、活动保留与主动诊断导出。
- 草稿和待推送结果按仓库实体保存，移动目录保持身份；同路径替换不会复用原仓库草稿。
- 会话绑定仓库目录及 `.git` 标记身份；目录替换或 Git 指向变化后拒绝旧会话写入，并允许重新打开。

使用 `⌘O` 打开仓库，`⌘1/2/3` 切换页面，`⌘R` 刷新，`⌘↩` 普通提交，`⌘⇧L/U` 打开 Pull/Push 目标表单。危险操作有独立确认。Git 配置与凭证继续复用现有环境。

## 已知边界

后续尚需完成真实远端写入与认证矩阵、字号/密度/辅助技术验收、大型完整应用性能，以及 CI、Beta 和签名公证。显式加载超过 8 MiB 补丁、2 MiB 预览或 100,000 行的内容时会转入磁盘分页；超过 256 MiB、2,000,000 行或 100,000 个差异区间时保留摘要并提示外部查看。完整 UI 规范是目标，不应视为当前全部已验收。

尚不开放 linked worktree、Bare 仓库、Stash/Tag 管理、内置冲突编辑器和 Interactive Rebase。克隆失败后保留本次新建目录，用户确认后可移到废纸篓；目录被替换、内容改变或无法完整核对时停止清理。超过 20,000 个目录项的失败目录通过 Finder 手动处理。

推送待核对记录不保存 URL 或凭据。地址含嵌入式凭据、查询参数或片段时，当前窗口可用原计划核对；重启后需要手动核对原目标并明确标记已处理。普通地址发生配置变化或相对路径移动时，恢复会在网络查询前拒绝，避免核对到新的目标。

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `WeGit/` | SwiftUI 应用、窗口状态、SwiftData 最近记录、页面与组件 |
| `WeGitCore/` | 可独立构建测试的模型、Git 命令、进程、队列与文件事件监听 |
| `WeGitAskPass/` | 随应用构建和签名的认证辅助可执行文件，通过私有 Unix Socket 传递输入 |
| `WeGitTests/` | Swift Testing 与真实临时仓库测试 |
| `WeGitUITests/` | XCUITest 的提交、差异、历史、分支、同步、设置与恢复验证 |
| `docs/` | 产品、设计、架构、执行计划与开发证据 |

产品和技术设计从 [文档索引](docs/README.md) 开始阅读。

后台性能复现使用 `scripts/benchmark.sh`，原生启动使用 `scripts/benchmark-ui-launch.sh`，工作区首屏使用 `scripts/benchmark-ui-workbench.sh`，需 Python 3 标准库；安装包准备见 [分发与发布操作](docs/RELEASE.md)。`scripts/package-release.sh --preview` 只生成本机开发包，且要求构建回执匹配当前源码并排除测试签名权限；正式分发必须完成 Developer ID 与公证路径。

## 反馈与帮助

遇到问题可到 [项目 Issues](https://github.com/WeOpen/WeGit/issues) 提供复现步骤、系统/Git 版本和实际结果；当前仓库为私有，需要有仓库访问权限。设置中的高级页面可主动导出诊断摘要，其范围不包含代码、Diff、提交消息、路径或凭证。不要把敏感内容直接贴进反馈。

### GitHub 协作与 CI/CD

需求先开 [Issue](https://github.com/WeOpen/WeGit/issues/new/choose)，再通过关联 PR 交付；见 [贡献说明](CONTRIBUTING.md)和 [CI/CD 方案](docs/GITHUB_WORKFLOW.md)。常规 CI 使用托管 macOS 27；专用完整验收及无账号 ad-hoc Draft Release 分别设置门槛，公开发布由维护者最终确认。
