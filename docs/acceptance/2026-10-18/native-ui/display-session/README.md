# 托管测试显示条件与临时会话

[只读独立控制 39091012241](https://github.com/WeOpen/WeGit/actions/runs/39091012241) 在 `b6c6108` 实际通过 1/1、零失败/跳过。回执显示当前 VM 为 1024×768，可见区域 1024×674；支持 1920×1080 和 1600×1200，见 read-only-hosted-modes.json。此轮没有改变显示模式。

完整测试包含 1120 宽的窗口恢复、1460×900 阅读目标，以及打开检查器后至少 1292 宽的工作区。原 VM 的可见区域不满足这些条件，不能通过删掉尺寸断言关闭失败。

新增 DisplaySession 仅允许在 GITHUB_ACTIONS=true 且 RUNNER_ENVIRONMENT=github-hosted 时申请 1920×1080。它保留原 CGDisplayMode，持有子测试命令期间的临时模式，命令结束后显式恢复并核对原模式，归档 before/effective/restored 与子命令状态。缺少目标模式或恢复失败会失败，不回退小屏后宣称宽屏通过。API 的模式还会在调用进程退出时自动复原，见 [Apple CGDisplaySetDisplayMode](https://developer.apple.com/documentation/coregraphics/cgdisplaysetdisplaymode%28_%3A_%3A_%3A%29)。

原生 UI 与独立控制 workflow 默认选择 large；display=original 可显式复现历史默认显示条件。候选的 helper 源码和 Python 驱动均先由受信任 main 复制，再签出固定候选。readonly token、宿主机约束、测试 runner sandbox 与系统安全/辅助访问权限没有改变。

本机仅编译 helper、执行只读 inspection 和拒绝本机修改/拒绝 inspect 搭配 child 命令的检查，没有改变本机显示设置。实际 hosted 切换、1920 子测试与恢复原模式的回执仍待新场景控制运行，不能提前宣称成功。

[实际切换与恢复 39091547236](https://github.com/WeOpen/WeGit/actions/runs/39091547236) 在候选 `53e2ff8` 证实：原 1024×768 → 生效 1920×1080 → 恢复原 1024×768，setError=0、restoreError=0、restored=true、childExitCode=0，见 hosted-session.json。子独立控制实际执行 1、通过 1、失败 0、跳过 0。系统权限未改；此证据只证明显示会话与独立窗口，不证明产品阅读矩阵或完整功能通过。
