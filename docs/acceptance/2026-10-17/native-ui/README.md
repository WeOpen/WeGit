# 原生环境恢复准备

2026-10-17，Issue #6 / #2。本机只读诊断确认 Aqua/控制台匹配，但开发工具调试授权关闭；SIP 和 Gatekeeper 开启。没有修改授权或重复初始化失败。

新增 main-only 托管 VM 验证路径，先实际环境检查，再最小 UI；只有成功后才执行所选大套件。单个 VM 内串行编译/测试，截止与失败结果均保留。UI Git 夹具改为选中 Xcode 的实际可执行文件，原隔离探针保持。

本地工具测试和回归编译按各自日志记录；托管 smoke 已执行但未通过，不能宣称完整 UI 通过。操作与边界见 [原生验收说明](../../../NATIVE_VALIDATION.md)。

合并网站基线后的 24 项工具行为、原生 UI 编译和 4 项 Git 辅助程序实测通过。Swift/C 两处固定 Xcode 路径均已修正；见 git-wrapper.json。仍未运行本机 XCTest。

首轮托管 run 38933704080 已执行 1 项并失败：首次窗口/菜单未出现；没有继续大套件。原始摘要、日志和环境保留为 hosted-*，根因仍在调查。提供者 SIP 默认关闭，安装/安全结论不据此签收；本机系统保护没有改变。新诊断入口让应用修复可以先在同仓库候选 PR 的固定 SHA 上验证，再进入受保护 main。

## 启动证据补充

[Run 38990703801](https://github.com/WeOpen/WeGit/actions/runs/38990703801)，源码 `73905434917c03c24647e9589060e21384e74523`，同一应用摘要 `6fbcded9970a9bb44ea7383051f84a3f0cb515e0934f11e2494fa2990c2acbda`，实际执行 1、失败 1、跳过 0。诊断显示进程 active=true、hidden=false、finishedLaunching=true、普通激活策略；桌面截图没有主窗口，也没有权限弹窗。非提权 `sample` 被系统拒绝，未改权限或使用 sudo。详见 `diagnostic-*` 文件，失败不作为任何功能验收通过。

本机独立 `Window`/`WindowGroup` 对照均在后台启动时呈现窗口，已关闭两份专用控制应用，见 [local-scene-controls.json](local-scene-controls.json)。它只反驳“单窗口在后台必定不显示”的泛化假设，不能代替托管环境复现。随后临时 Debug 阶段日志确认状态初始化及场景声明完成，但没有工作区或窗口。场景恢复、命令抑制和窗口类型三项受控候选均未改善；详见 [全部候选](startup-experiments.json) 及逐轮 `candidate-*` 摘要。所有实验性应用改动及临时日志已撤回，120 个输入文件与原开发包一致，摘要仍为 `6fbcded...`，见 [源码核对](reverted-source.json)。

额外的本机应用封装对照改变了可执行入口，不能当作 XCTest 的等价复现或产品根因证据，明确记录为 [未定](local-wrapper-inconclusive.json)。四份专用控制应用均已停止并删除，原始日志/控制源保留在本机 `.build/`，用户的 WeGit 应用和仓库不受影响。

后续建立不依赖 WeGit 的 [独立 SwiftUI/XCTest 控制工程](../../../../Tools/SceneLaunchControl/README.md)，包含裸 WindowGroup 与两种匹配场景配置。每组实际执行 1 项，串行、有限时、保留失败和环境；这不是完整产品 UI 或发布验收。原产品仍使用单个 `Window`。

## 本机旁白尝试与恢复

系统设置确认原开关 off，临时 on 后仍未观察到 VoiceOver 读屏进程；已存在的 Quickstart 引导无法通过控制通道读取，未取得字幕或朗读证据。开关恢复 off，系统设置恢复原 General 页面，未改其他辅助选项，见 [voiceover-attempt.json](voiceover-attempt.json)。旁白验收保持未完成。
