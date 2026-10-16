# 原生 UI 环境与受控验收

更新：2026-10-17。对应 Issue #2 / #3 / #6。常规 CI 的 UI 编译通过不等于 XCTest 已执行。

## 只读诊断

```bash
python3 scripts/ci/ui_probe.py --mode environment
```

报告保存在 `.build/ci/ui/environment.json`，记录真实 Aqua 会话、控制台 UID 是否一致、开发工具调试授权、SIP、Gatekeeper、Xcode 首次启动状态、选中工具链的 Git、提交及工作区是否干净。不读取凭据或 TCC 数据库，不修改系统授权、主题、安全选项或全局 Git 配置，也不启动 XCTest。

2026-10-17 本机报告：Aqua、控制台 UID 一致、Xcode 首次启动完成，SIP 和 Gatekeeper 开启；`DevToolsSecurity -status` 为 disabled。这是新的环境证据，不足以独立断定历史初始化失败的唯一原因；本轮不在该环境重复失败的 XCTest 启动。

## 托管独立 VM 的验证路径

官方 Runner 镜像配置包含开发工具/自动化环境准备，实际使用前仍检查，而不是只相信标签：
[configure-machine.sh](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-machine.sh)、[Xcode 27 镜像](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。

`Native UI validation` 只允许受信任 main 手动运行，签出当前明确的提交，使用新的 `xcode-27` VM。默认 token 只读，不连接个人凭据或自托管设备。先验证实际 OS/SDK/Aqua/控制台/调试授权，再串行编译；没有权限修改或自动重复失败步骤。

```bash
gh workflow run native-ui.yml --repo WeOpen/WeGit --ref main -f scope=smoke
# 仅在最小用例成功后推进：
gh workflow run native-ui.yml --repo WeOpen/WeGit --ref main -f scope=functional
gh workflow run native-ui.yml --repo WeOpen/WeGit --ref main -f scope=accessibility
```

每种模式都先执行 Welcome/Clone 最小用例；失败后立即停止，不运行大套件。最小用例总上限 240 秒，并保留 XCTest 失败；功能/辅助访问整体执行上限各 90 分钟，workflow 仍为 120 分钟，给失败归档留出时间。功能模式运行全部功能和阅读矩阵，辅助访问审查独立执行；不把排除该审查的功能结果冒充辅助访问通过。

脚本的进程组截止行为经过实际成功/超时/子进程停止断言；还解析 xcresult 实际数量，拒绝 0 项、跳过、失败及不完整的计数，最小范围必须恰好执行并通过 1 项。超时只负责结束当前测试命令，不重试、不提高产品性能预算。日志、环境与 xcresult 限定归档到对应 Actions artifact。

Swift 夹具执行器与 C 延迟/回执辅助均通过 `xcrun --find git` 使用当前选中 Xcode 的 Git，避免 `/Applications/Xcode.app` 固定路径与预览工具链不一致；所有仓库命令仍先执行原有隔离探针，配置写入约束不变。

## 发布边界

该路径首先用于验证托管 VM 是否能执行实际 UI。尚无成功记录时，不把它标为可用验收 Runner。即使 smoke 成功，也不等于完整功能、VoiceOver、辅助访问、性能或干净机器安装通过。

`Full acceptance` 的同一 SHA 稳定版发布门禁继续保留；本 workflow 不能替代它。专用自托管 Runner 当前仍为 0。若托管环境通过实际最小用例，再根据完整结果、原始系统保护状态和性能隔离条件决定可承载的范围，不能仅为改标签而宣称完成。

另有 4 项真实辅助程序验证：配置隔离、实际 Git 版本、大块 Unicode/CRLF/NUL 输入字节与输出、错误退出码/stderr，不能只凭辅助程序可编译就声明透明转发。

## 2026-10-17 首次托管执行

[Run 38933704080](https://github.com/WeOpen/WeGit/actions/runs/38933704080)，源码 `76bc7df`，实际执行 1 项、失败 1 项、跳过 0 项。Aqua、控制台 UID、开发工具授权、Gatekeeper 与 Xcode 首次启动检查通过。提供者的 VM 默认 SIP 为 disabled；没有执行关闭 SIP 的命令，因此这轮只能提供功能诊断，不能替代受保护目标机器的安装验收。

XCTest 已进入 `testWelcomeAndCloneForm`，自动化初始化不再是本轮阻塞。首个失败为 `native-menu-app` 不存在，随后旧辅助尝试打开 `native-menu-window` 也不存在；快照只有 Apple 与 WeGit 菜单，没有主窗口。主线程仍能响应 XCTest 查询，应用 stdout 的 linkd 警告尚未证实为根因。没有在此基础上运行更大套件或假定应用启动修复完成。

当前诊断进一步保留桌面截图、目标进程启动状态和线程采样；最小用例在首个断言后停止，保持原断言和时限。候选 PR 的 smoke 可由受信任 main workflow 手动选择：

```bash
gh workflow run native-ui.yml --repo WeOpen/WeGit --ref main -f scope=smoke -f candidate_pr=123
```

该入口只接受仍开放、同仓库、目标为 main 的 PR，并固定其 head SHA；禁止 fork/其他分支、可变 ref 和大套件候选运行。构建前将 main 的测试计数/截止驱动复制到 RUNNER_TEMP，之后签出候选源码，归档名与 build-source 记录实际源码。该诊断的 workflow head 仍是 main，判读必须查看报告里的实际 sourceCommit；它不能作为稳定版的同 SHA Full acceptance 证明。
