# v1.2 · 单提交 Cherry-pick / Revert

2026-10-26，需求 [#62](https://github.com/WeOpen/WeGit/issues/62)，分支 `codex/v1.2-single-commit-operations`。已有 Worktree 支持已由 PR #60 合入 main；本批以该能力为基础。这里记录开发验证，不代表 v1.2 全部完成或版本发布。

## 行为与范围

- 历史页的操作菜单可预览一个普通或根提交，显示当前分支、HEAD、目标完整 SHA 和实际受影响的文件。工作区/索引不干净、有其他序列、Merge 提交、特殊索引标记、子模块或超出读取上限时拒绝操作。
- 使用指定 merge base 的 `merge-tree` 预演，将新增 Git 对象放入私有临时目录，现有对象通过正确转义的 alternate 读取。中文、换行及冒号路径保留；预览不改用户 HEAD、索引或工作文件。实际合并落点包含目录重命名后的路径，先保护忽略文件、目录内容和符号链接父路径。
- 执行按 common → private 的固定顺序获取写许可，再重新核对身份、分支、HEAD、索引、目标对象和合并结果。只执行确认的单个对象，不自动 Stash 或重复写入。
- Revert 先使用原生 `--no-commit` 保留 REVERT_HEAD，核对得到的索引树，再调用 `--continue` 提交。Hooks 或签名失败后仍有 Git 自己的恢复入口，不用应用自造的恢复日志。
- 冲突和未完成提交分别呈现待处理状态。单提交标记与实体身份一致时可继续/中止，重开仍从 Git 读取；外部多提交队列留给 Terminal。丢失回执、HEAD 异常变化或结果不符均需核对，不显示为成功。
- 保留提交草稿；中止明确说明会撤回操作内的手工编辑。没有增加 Merge mainline、多提交队列、Reset、Reflog、自动签名降级或远端历史改写。

预览上限为每次元数据输出 32 MiB、每棵树 100,000 条、2,000 个源/结果变更文件、参与变化的去重 blob 合计 64 MiB；预览 Git 命令限时 30 秒，写入为 120 秒。大文件或复杂结构冲突超出当前范围时明确拒绝，而不是猜测写入位置。

## 本机验证

| 验证 | 实际结果 |
| --- | --- |
| 独立 Git 行为 | [65 项通过](independent-checks.json)：普通/根提交、精确 CRLF/末尾字节、重命名、文件与符号链接互换、忽略文件与目录、陈旧确认、取消、重复写入保护、冲突重开/继续/中止、Hook 和签名失败恢复 |
| 预演开销 | 普通与 5,000 文件夹具各 30 次，p95 为 **87.59 / 281.70 ms**，低于 2,000 ms 后台预算；全部样本保留在同一 JSON |
| 核心测试目标 | `swift build --build-tests` 编译通过；新增真实 Git 与队列、丢失回执、外部标记变化回归，本机未执行 |
| 原生测试目标 | `xcodebuild ... build-for-testing` 编译通过；新增一个固定流程，包含最小 980×692 窗口、中英文/浅深色、键盘、取消、写入、重开、中止和继续，本机未执行 |
| 工具与资源 | Python CI 工具 55/55、1,190 字符串/8 复数、本次 Swift 格式与仓库策略通过 |

性能样本使用本机 Debug 核心，每次重新构建预演，不复用应用缓存。普通夹具与大型夹具分别有少量提交，大型规模为 5,000 个小文件。它们不是普通 Release UI 首屏、启动、滚动、峰值内存或完整版本性能验收。

## 原生预览诊断

专用 Debug 预览仅打开本批私有仓库，实际完成：取消预览、Cherry-pick、新提交 Revert、产生冲突、退出/重开、中止恢复、再次冲突、外部保存、标记解决并继续，以及 Return 执行和 Escape 取消。Git 回执逐一核对提交父链、原始对象、索引与文件字节，提交草稿保留。

- [中文流程预览](screenshots/preview-zh.png)记录语义分组后的初次窗口；之后英文复核继续调整了标签宽度。
- [最终英文深色预览](screenshots/preview-en-dark.png)确认标签完整可读，分支、HEAD 和目标 SHA 各有一个独立的可访问名称。
- [最终干净状态与草稿](screenshots/final-clean-draft.png)及 [Git / 清理回执](ui-receipt.json)保留结果。专用预览已退出，私有夹具已移除，专用 UITests 偏好与原备份逐值一致。
- 最终预览 [161 项应用输入](preview-build-source.json)与本批源码逐一匹配。以上属于 CUA 诊断；真实托管 XCTest 的计数与截图仍需单独验收。

## 失败记录与后续门禁

- 首轮 [CI 40274156920](https://github.com/WeOpen/WeGit/actions/runs/40274156920) 在 `67ad681` 执行 218 个测试声明/39 suites，两个方法有三条失败记录。失败均发生在新夹具写文件时缺少 `old` / `.git/fixture-hooks` 父目录，尚未进入对应产品操作。核心 `Fixture.write` 与独立检查的 helper 行为不同；已在新用例显式建目录，原断言保留，等待托管重跑。
- 首轮 [原生 40274310004](https://github.com/WeOpen/WeGit/actions/runs/40274310004) 的 [smoke 1/1 通过](native-first-smoke.json)；[专项 0/1、1 失败、0 跳过](native-first-failure.json)。普通操作、冲突与重开已执行，失败在中止确认定位。AX 证实按钮处于顶层 Dialog，Touch Bar 还有同名按钮；用例误查主窗口 Sheet，现限定实际 Dialog。原始 xcresult、录像、日志和 UI 树保留于本机 `.build/v12-development/resumed/native-single-commit-first/`、同轮附件目录及托管制品。
- [独立 Git 复现](revert-signing-failure.json)证明单次 Revert 签名失败后没有可恢复标记，`--stdin` 也未修复；[两阶段原生恢复复现](revert-recovery-probe.json)的继续和中止均成功。最初独立行为检查停在这项，修复后完整 65 项通过。
- SwiftUI 初次把相邻预览字段合并为一个 AX 元素；直接修饰 GridRow 又给两个子项重复赋予同一语义。改用实际 HStack 容器后各字段只暴露一次。英文 Selected commit 的截断随后通过标签列宽与换行修正。
- 独立检查最初的 Swift 编译问题和格式问题均修正；本机 iOS CoreSimulator 版本警告不属于 macOS 测试通过证据，最终 macOS 测试目标实际编译成功。
- `defaults import` 会保留新增加的测试偏好键。只对已经完整备份、预览进程已退出的专用 UITests 域先清除再导入，并比较 plist 语义，确认恢复。
- 托管入口 PR #63 已通过四项检查并合入可信 main `df1c4d0`。待本功能 PR 固定 SHA 后执行 smoke + `single-commit`，再核对实际源码、计数与截图。三套 Git 的新核心执行结果及完整最终回归、Release 性能、Beta 与发布门禁此时仍待验。
