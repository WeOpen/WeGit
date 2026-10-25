# 2026-10-25 会话接续原生检查

接续 01a1703b-1a0e-7231-9705-4838cee85cfe。原会话最后一轮因 invalid_encrypted_content 失败，实施文件仍保留在 codex/v1-1-1-polish。

## 本轮核对

- 当前 Debug 原生预览包的 145 项应用输入与工作树源码逐项一致；使用原有隔离 launcher 和私有样例仓库，diagnosticOnly。不是普通 Release 或托管 XCTest。
- 六类设置深色页面截图与 AX 原文保存在 preview-resumed/。外观从浅色即时切换深色，设置页面未发现裁切；不据此覆盖所有主题和窗口尺寸。
- Git 配置来源展开后显示 local 文件来源与当前仓库值，并显示继承分支默认值。AX click 未切换展开状态；使用截图中可见箭头坐标点击后 Value 为 on，完整来源可见。
- 私有样例原先 core.hooksPath=/dev/null，第一次预期拒绝的提交实际成功，HEAD 从 8e015e9a507e4a6389bd6d96e35af24ddb2cd36e 到 71ac19c3e5ee1c8e70c73b5e83fdf307718a7394，提交消息为“验证失败反馈时保留草稿”。保留成功证据，不重写该历史。
- 将私有仓库 Hook 路径显式设为其 .git/hooks 后，通过 UI 暂存 Workbench.swift，填写“失败后仍保留的私有草稿”，提交被 Hook 拒绝。反馈从暂存成功变为 failure，未重现旧成功；草稿与暂存内容保留，HEAD 未变化。弹出详情完整显示 Private preview rejects this commit。截图与 AX 原文同目录。
- 已移除本轮私有 Hook，恢复夹具 core.hooksPath=/dev/null。个人仓库、真实远端和全局 Git 配置未修改。
- 本轮重新运行 Python 独立检查 53/53 通过；本地化检查 1165 字符串、7 复数键通过，扫描 1552 处；git diff --check 通过。本机未执行 XCTest。

## 未完成范围

自定义主题、更多工作区状态、取消与 needsReview 原生路径、完整阅读矩阵、最终源码托管回归及有效性能测量仍需完成。旧构建与旧 Beta 数据不作为本版通过证据。本轮没有发布或宣称版本完成。
