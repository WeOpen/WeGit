# 原生 UI 环境与受控验收

更新：2026-10-18。对应 Issue #2 / #3 / #6。常规 CI 的 UI 编译通过不等于 XCTest 已执行。

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

每种模式都先执行 Welcome/Clone 最小用例；失败后立即停止，不运行大套件。最小用例总上限 240 秒，并保留 XCTest 失败。功能/辅助访问模式启用 XCTest 单用例超时，普通用例默认300秒；最小窗口控件矩阵单独600秒，固定144组阅读矩阵单独2700秒，最大值2700秒。两项长用例通过各自的 `executionTimeAllowance` 设置，不改变其组合、断言或截图。整套进程组上限各90分钟，workflow仍为120分钟，给失败归档留出时间。功能模式运行全部功能和阅读矩阵，辅助访问审查独立执行。与 `Full acceptance` 一致，功能模式排除必须显式启用的 `ManualAccessibilitySession`；该人工工作区不进入自动套件的计数，所选自动用例仍必须全部执行、通过且无跳过。自动审查与人工旁白验收各自保留，功能通过不代替辅助访问通过。

脚本的进程组截止行为经过实际成功/超时/子进程停止断言；还解析 xcresult 实际数量，拒绝 0 项、跳过、失败及不完整的计数，最小范围必须恰好执行并通过 1 项。超时只负责结束当前测试命令，不重试、不提高产品性能预算。日志、环境与 xcresult 限定归档到对应 Actions artifact。

同源码的单项诊断通过只覆盖该用例；完整套件失败或没有生成完整 xcresult 时，仍保留原失败和缺失计数，等待完整范围重新实际执行。超过父窗口宽度的原生 Sheet 使用完整屏幕截图保留面板边缘，同时断言路径与关闭按钮可操作；父窗口截图不能证明这些边缘控件已完整显示。

长用例界限依据[完整历史实测](acceptance/2026-10-18/native-ui/final-functional/README.md)：阅读矩阵1778.596秒，最小窗口控件矩阵268.186秒。统一180秒会误判正常组合验证。固定专项仍使用默认120/最大180秒和300秒进程组界限；单用例截止用于限制挂起，[XCTest文档](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance)也明确要求性能回归用专门测量验证，不能将这些截止值当作产品延迟预算。

构建阶段通过 `xcrun --find git` 记录当前选中 Xcode 的 Git，Swift 夹具执行器与 C 延迟/回执辅助在运行时读取同一随包回执，避免 `/Applications/Xcode.app` 固定路径与预览工具链不一致；所有仓库命令仍先执行原有隔离探针，配置写入约束不变。

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

第二次诊断 [run 38990703801](https://github.com/WeOpen/WeGit/actions/runs/38990703801) 在 `7390543` 实际执行 1 项并失败，没有跳过。进程已 active/finishedLaunching，桌面没有主窗口或权限弹窗；普通权限的线程采样被系统拒绝，没有提权。独立的本机单窗口/窗口组后台启动对照均正常，尚不能断言窗口类型是根因。仅在隔离 Debug UI 测试中增加阶段日志，继续用候选 PR smoke 定位；完整证据见 [本轮记录](acceptance/2026-10-17/native-ui/README.md)。

阶段日志及三项候选随后均已撤回，产品源码保持原单窗口和原配置；各失败回合保留，尚无根因结论。新的 [独立控制工程](../Tools/SceneLaunchControl/README.md) 用三个无 WeGit 依赖的应用区分最基础 SwiftUI 启动与匹配场景配置。`SwiftUI scene controls` 仅运行同仓库 PR 的固定 head 或 main 手动入口；每个控制串行构建、执行恰好 1 项并检查实际结果，不能关闭任何产品发布门槛。

首轮三项控制均实际失败，包括裸 WindowGroup；本机普通启动的裸场景可见。继续以两份新 bundle ID 比较异步 XCTest 与公开 NSWorkspace 启动，保留现有 runner sandbox，并独立要求隔离参数收到、窗口数量和内容通过。原三项没有变化的失败不自动重跑；小摘要与完整结果分开归档。该通道试验不修改现有 WeGit 测试启动器或系统保护。

## 启动参数顺序修正后的实际 smoke

[39010563892](https://github.com/WeOpen/WeGit/actions/runs/39010563892) 在候选 `4609baf` 实际执行并通过 1 项，0 失败/跳过，首次窗口、原生菜单和 Clone 表单正常。公共测试启动器把带值参数放在无值测试标记之前；应用和核心不改。独立场景的原序失败、重排通过，Foundation 探针不能证明更底层解析机制。完整结果见 [修正证据](acceptance/2026-10-17/native-ui/launch-order-fix/README.md)。可继续主分支完整功能回归，但此单项不关闭辅助访问或发布门槛。

2026-10-18 最终 head smoke 与独立回归均通过 1/1、零跳过，CI 全绿后 PR #19 已合入 main `4a9f475`。原始回执与修正前后测试范围证据见 [收尾记录](acceptance/2026-10-18/native-ui/README.md)。功能入口现与 Full acceptance 一致排除人工旁白工作区，零跳过门禁保持；完整功能等待新的主分支运行。

## 2026-10-18 Git 夹具的 sandbox 前置条件

主分支辅助访问尝试的 UI-only smoke 通过后，用例仍在仓库夹具初始化时失败，未执行界面审查。强化 smoke 捕获原始错误 `xcrun: error: cannot be used within an App Sandbox.`（exit 1）。修正把选中 Git 的查找移到构建阶段，让 Swift 夹具与 C 辅助程序直接读取同一绝对路径回执；缺失或无效回执不回退到系统 shim。测试 runner 的 sandbox 和签名配置未变。

候选 `e7f3216` 的 [强化 smoke 39088573828](https://github.com/WeOpen/WeGit/actions/runs/39088573828) 实际执行并通过 1 项，零失败/跳过，17.677 秒；包括欢迎页/Clone、Git 配置隔离与直接/嵌入 Git 版本相同。成功截图和 xcodebuild 生成的 sandbox entitlement 已归档。全部 120 项当前构建输入匹配；相对首窗修正只改变测试目标配置的两项工程输入，其余 118 项应用/核心/资源未变。详见 [夹具工具链记录](acceptance/2026-10-18/native-ui/fixture-toolchain/README.md)。完整功能与自动辅助访问审查继续分别执行，VoiceOver 和发布门槛不因此签收。

## 完整功能基线与有界单项诊断（2026-10-18）

同一 main `6087cf7` 的完整功能实际执行 45、通过 28、失败 17、跳过 0；历史 Clone 长路径/已有目录重试用例通过，阅读矩阵提前失败。独立辅助访问执行 1、失败 1、零跳过，旧 Sidebar Outline 查询在系统审查前失败。完整摘要与两张已完成阅读检查的截图见 [基线记录](acceptance/2026-10-18/native-ui/full-baseline/README.md)，旧 44 条审查没有被新的报告替代。

受信任 main 驱动提供固定 allowlist 的单项候选诊断；始终先通过恰好 1 项强化 smoke，再执行恰好 1 项指定检查，每项必须无失败/跳过。单项测试的 XCTest 上限 180 秒、进程组总上限 300 秒。任意路径与 `functional/accessibility` 搭配 focus 均拒绝，候选仍只接受开放同仓库 main PR 的固定 SHA。此入口不改变完整验收或发布门禁。

```bash
gh workflow run native-ui.yml --repo WeOpen/WeGit --ref main \
  -f scope=smoke -f candidate_pr=123 -f focus=minimum-layout
```

可选项由 `scripts/ci/ui_probe.py` 的 FOCUSED_TESTS 明确映射到单个测试，不包含完整阅读循环或人工辅助访问工作区。独立 SceneLaunchControl 同时保留只读的当前/可用显示模式及屏幕可见区域回执，不修改显示设置；用于区分 1024×768 VM 条件与宽窗口断言。

## 托管测试显示会话

只读 VM 回执确认原 1024×768 的可见区域仅 1024×674，支持临时 1920×1080。原生 UI 与独立控制使用受信任的 DisplaySession 父进程，在 GitHub-hosted VM 内持有该模式并在子命令结束后恢复原模式；不能在本机调用修改。display=original 保留历史显示条件复现入口，模式缺失或恢复失败明确失败。开始/生效/恢复与子命令状态写入 display-session.json；实际 hosted 验证状态见 [显示会话记录](acceptance/2026-10-18/native-ui/display-session/README.md)。不调整 SIP、Gatekeeper、辅助访问或开发工具授权。

## 当前同源审查与颜色修正

PR #26 已合入 main `bcca7f3`，七项实际单项通过且原断言保留。[独立审查 39119367892](https://github.com/WeOpen/WeGit/actions/runs/39119367892) 真正进入系统 API，执行 1、失败 1、零跳过，产生 59 条待判定报告；[逐条原始记录](acceptance/2026-10-18/native-ui/current-audit/README.md) 区分报告数和缺陷数。同 SHA 的完整功能 39119370087 已完成 45 项：43 通过、2 失败、零跳过；ReadingMatrix 的 144 个组合全部通过，详见 [完整基线](acceptance/2026-10-18/native-ui/after-controls-baseline/README.md)。

新的 [设置名称/语义色候选](acceptance/2026-10-18/native-ui/native-contrast/README.md) 按用户确认的 4.5:1 目标修正内置角色，不改变色相和布局；源色对、原生控件、实际截图、完整功能与系统审查分别验证，不能以本机主题检查替代其余范围。

PR #27 已合入 main `734b8e1`。最终候选主题与字号两个运行均 smoke 1/1 加 focused 1/1、零失败/跳过，实际菜单/次要文字与选中行反差断言通过，详见 [配色 UI 证据](acceptance/2026-10-18/native-ui/contrast-ui-results/README.md)。原有功能基线中的恢复检查器 Outline 边界和 Diff RightArrow 两处失败先用有界诊断记录，不重复无变化完整失败。

## 最新完整自动功能 · 2026-10-18

固定 main `2c2533c` 的 [39137123756](https://github.com/WeOpen/WeGit/actions/runs/39137123756) 完成 smoke 1/1 与功能 45/45，零失败/跳过；144 个精确阅读组合全部有图，无缺失/重复。源码、全部用例、运行期提示及显示恢复见 [本轮完整记录](acceptance/2026-10-18/native-ui/final-functional/README.md)。后续工具/文档分支未改 120 项应用输入和 21 项产品 UI 测试输入；该等价校核不替代正式发布的精确提交 Full acceptance。55 条辅助访问报告及专用环境、性能和安装门槛继续开放。
