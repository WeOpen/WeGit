# XCTest 首窗启动参数顺序修正

[实际 WeGit smoke 39010563892](https://github.com/WeOpen/WeGit/actions/runs/39010563892) 验证 PR #19 的 `4609baf2a64d89fcabc984d02359d4a2e8102d9c`：实际执行 1、通过 1、失败 0、跳过 0，30.263 秒。欢迎页、原生菜单、Clone 表单输入自动建议文件夹与取消全部通过。

根因范围是测试启动参数顺序：公共启动器原来将 `-language zh-Hans` 追加到 `--uitesting` 后面。同源独立场景在原顺序失败、把设置放到标记前通过，见相邻 scene-controls 的 combined-arguments-report.json。AppKit/NSHostingView 均通过，裸 SwiftUI 默认参数或单个参数也通过。Foundation 的独立解析探针两序都正确读取 language，所以没有宣称已证实底层参数吞掉机制。

修正仅在 WeGitUITests/UITestGit.swift：保留全部设置和值，将三个已知无值测试标记稳定移到末尾。正式应用、核心、资源和偏好没有修改，最终 Debug 回执内全部 120 项应用输入均与当前源码及原开发包一致。默认独立控制改为只执行已通过的 reordered 回归，失败历史仍可显式选择。

本机只编译 build-for-testing，没有在开发工具授权关闭的机器运行 XCTest或调整授权。实际执行来自独立 arm64 VM，其原 SIP 为关闭、Gatekeeper 开启；此结果用于功能回归，不覆盖目标机器的安装保护。完整功能、144 组合、辅助访问、性能、干净机器与发布仍待验。
