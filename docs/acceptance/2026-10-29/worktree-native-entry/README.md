# Worktree 管理原生诊断入口

Refs #75。只注册 `WorktreeManagementWorkflowTests/testCreateCancelRemoveAndProtectChangedWorktrees`，实际应用和 UI 用例由功能分支提供。

入口先经必需 CI 和正常 PR 合入可信 main；候选 PR 只允许运行一次真实 smoke，全部通过且没有跳过才执行这个有界方法。失败/跳过 smoke 不会启动专项，候选不能扩大原生范围。本机仅执行入口的 Python 边界检查，不执行 XCTest。

此准备不表示 Worktree 管理产品实现或版本验收完成。实现、取消/失败/陈旧变化与安全保留、源码回执、真实原生交互和性能继续由 #75 跟踪。

入口边界检查15/15通过；首轮一个方法的2个子场景误将ValueError断言为SystemExit，已保留失败并修正测试。产品门禁未放宽，失败/跳过仍不启动专项。
