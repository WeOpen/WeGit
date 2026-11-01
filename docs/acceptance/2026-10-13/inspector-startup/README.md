# 启动恢复检查器崩溃修复

会话日期：2026-10-13。环境：macOS 27.0.1（26A434）、Xcode 27.0（27A266a）、arm64。原始日志保留主机实际记录的时间。

## 问题与根因

用户运行 `scripts/build.sh Debug` 后，通过 `open .build-app/Build/Products/Debug/WeGit.app` 启动，应用意外退出。正常偏好恢复最近仓库、History 路由和已打开的 Inspector 后，可以稳定复现。

LLDB 在 `objc_exception_throw` 捕获到窗口约束更新循环，堆栈包含 `NSWindow._postWindowNeedsUpdateConstraints` 和 SwiftUI 的 AppKit 布局宿主。异常原文和堆栈见 [exception-backtrace.txt](exception-backtrace.txt)。隔离复制同一仓库视图状态后，History / Changes + Inspector 均崩溃；关闭 Inspector 时通过，见 [initial-isolation-failed.json](initial-isolation-failed.json)。单独 Text / Form Inspector 的最小应用通过，加入嵌套 HSplitView 后失败；替换为同级原生辅助分栏后通过。

此轮保留正常仓库、SwiftData 数据库、Git 配置及草稿。没有将删除用户偏好作为修复。

## 实现

`WorkspaceView` 将系统 `.inspector` 展示宿主替换为右侧原生 HSplitView 辅助栏，保留 Inspector 内容、开关和仓库视图持久化。工具栏读出“已打开 / 已关闭”，辅助栏有 `repository-inspector` 标识。

检查器关闭时保持 980 × 640 pt 内容最小尺寸；打开时内容最小宽度为 1292 pt，容纳最大 Sidebar、主工作区及检查器宽度。这个约束放在工作区外层，避免在已有安全边距补偿内重复增加最小宽度。初始宽度不足及内部额外最小宽度导致的裁切实验截图保留，最终最小窗口截图核对 History、Changes、Diff、提交区及 Inspector 没有该裁切。

生产修复仅涉及工作区视图。Git 服务、写队列、原文复制与窗口状态桥接保持原有实现；临时日志与探针已移除。

## 验证与边界

- 原来的普通 `open` 启动路径通过，实际恢复用户的 History 和打开的检查器；关闭、重开、切到 Changes 和正常退出后重启均经过原生界面检查。
- 独立启动回归使用私有 Git 仓库、UITests 偏好域、内存数据库和唯一窗口状态命名。浅色 / 深色 × History / Changes / Branches 共 6 种组合，每次持续运行 10 秒，核对保存状态、夹具文件、提交与索引，并恢复测试域和测试影响的原生窗口偏好。最终结果见 [startup-final.json](startup-final.json)。它验证进程存活与恢复状态，不能代替完整 UI 行为回归。
- 对照包在临时源码副本中恢复系统 Inspector 宿主；同一启动脚本在两种主题下的 History / Changes 均捕获 SIGTRAP / SIGABRT，Branches 通过。见 [startup-before-fix.json](startup-before-fix.json) 和 [布局差异](inspector-layout-fix.patch)。对照包是控制实验，不是已发布历史包；其源码与当前包的差异为工作区布局和临时项目生成配置。
- 两套 Git 的完整核心各 176 项 / 31 套件通过；严格格式、Debug、普通 Release、新增原生回归编译通过。最终命令和来源见 [validation.json](validation.json)。
- 新增 `InspectorRestorationTests.testOpenInspectorRestoresAcrossBothSplitWorkspaces`：真实退出、重启恢复、开关状态、最小窗口边界和夹具数据断言。当前 XCTest 自动化模式初始化仍不可用，此轮只确认编译，不标记该原生用例或完整套件执行通过。既有失败结果 `.build-app/ui-polish-environment-probe.xcresult` 保留，没有重复无变化的初始化尝试。
- 手动窄窗口截图：检查器打开约 1292 × 692～693 pt，关闭约 981 × 692～693 pt。字号 / 密度完整矩阵、VoiceOver、完整键盘与新源码 30 次 Release 性能仍需独立验收；启动生存时间不属于性能指标。

复现独立启动回归时，先关闭 WeGit，并确保没有其他 UI 测试运行：

```bash
scripts/build.sh Debug
swift scripts/verify-inspector-startup.swift \
  .build-app/Build/Products/Debug/WeGit.app \
  .build/inspector-startup/report.json
```

V1.0 发布继续未完成。开发包、签名与源码回执信息见 [validation.json](validation.json)；Developer ID、公证、Runner、干净目标机器及真实 Beta 的依赖保持原记录。
