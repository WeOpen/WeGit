# UI 夹具工具链前置失败

[主分支辅助访问尝试 39087745504](https://github.com/WeOpen/WeGit/actions/runs/39087745504) 在 main `4a9f47523277b2dc78a216b538ca3249099222df` 实际执行并通过 smoke 1/1、零跳过；随后辅助访问用例执行 1、失败 1、跳过 0，在 UITestGit 解析 Xcode Git 时提前抛错，未进入界面审查。该结果没有产生新的系统辅助访问报告，旧 44 条与人工旁白验收仍未关闭。

原错误仅为 `Could not resolve Git from the selected Xcode.`。后续候选给该解析保留退出码与原始输出，并把原有 Git 配置隔离探针与版本检查加入最小 smoke，另保留成功欢迎页截图。只运行小范围候选，待确认夹具可用后才推进大套件。本机只完成 strict format 与 build-for-testing，未改变开发工具授权或系统保护。

[诊断 smoke 39088080576](https://github.com/WeOpen/WeGit/actions/runs/39088080576) 在 `29fff95` 实际执行 1、失败 1、跳过 0。窗口与 Clone 表单步骤完成后，Git 夹具返回 `xcrun exit=1` 与原始错误 `xcrun: error: cannot be used within an App Sandbox.`，明确定位为 runner 内不能调用 xcrun。前一版 UI-only smoke 通过不足以证明仓库夹具可用。

修正将 xcrun 查找移到构建阶段，记录选中 Git 的绝对路径，并把同一回执随 C 辅助程序复制到测试 bundle。Swift 夹具和 C 辅助程序都直接使用该路径，不再在 runner 内调用 xcrun。缺失或无效回执明确失败，不回退到系统 shim。standalone 与 embedded helper 各 4 项原有行为检查、缺失/无效回执拒绝、本地测试包编译及 27 项工具测试通过。runner sandbox 与 Git 配置隔离不变。原 120 项应用构建输入中只有 project.yml 和生成的 Xcode 工程因测试目标调整而变化，其余 118 项应用、核心及资源输入逐文件不变；实际修正后 smoke 尚待执行。

修正候选 `e7f3216417b0c6f5523b71868ac8b04862a05168` 的 [实际 smoke 39088573828](https://github.com/WeOpen/WeGit/actions/runs/39088573828) 执行 1、通过 1、失败 0、跳过 0，17.677 秒；完成欢迎页/Clone 取消、原有 Git 配置隔离探针、真实 Git 版本与嵌入辅助程序版本一致性。原始 xcresult、截图与全部 120 项当前构建输入已下载核对。构建日志明确仍含 `com.apple.security.app-sandbox = 1`，见 fixed-runner-entitlements.txt；fixture 失败没有通过关闭 sandbox 解决。CI 与主分支功能回归继续单独记录。

[最终 CI 39088573265](https://github.com/WeOpen/WeGit/actions/runs/39088573265) 全部通过：三套 Git 各 183 项 / 32 套件、34 主题、18 图标、27 原生菜单、两组 OpenPGP 与清理、UI 编译/辅助行为和 Release 打包。PR #22 已按分支保护合入 main `6087cf79536a651715a0ce98106ea7fafed54daf`，见 final-ci.json 与 merge.json。同一 main SHA 的完整功能与独立辅助访问已分别排队，保持串行执行；这些后续结果单独记录。
