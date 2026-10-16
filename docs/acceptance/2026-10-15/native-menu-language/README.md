# 原生菜单语言应用 · 2026-10-15

本轮处理切到英文后顶部仍有中文菜单的问题。最终行为是：普通界面文案即时切换；macOS / SwiftUI 系统生成的菜单和对话框通过设置中的“重新启动并应用语言”完整应用。尚未应用时显示明确提示，已应用后提示消失。

## 原因与实现

窗口内容的本地化已更新，但内置菜单按启动时的 Bundle 语言创建。诊断发现 `SwiftUIMenuItem.title` 即使变成英文，其 AXTitle 仍可能使用启动时缓存的中文。运行时修改菜单、AX 标题、Scene locale 和原生替换候选均未通过实际展开验证，已全部撤掉；失败证据保存在 `discarded-runtime-candidates/`，其中 19 项候选检查不能计作最终方案通过。

最终只变更 AppPreferences、AppState、SettingsView 与两份文案资源这 5 个应用输入。记录真实启动语言，与当前所选语言比较后显示 pending 状态；调用 NSWorkspace 的公共新实例启动接口传递选定语言，保存偏好和当前页面后正常退出旧实例，遵循已有启动恢复设置。统一活动状态阻止忙时重启，关闭草稿保存且存在草稿时禁用；新实例启动失败保留旧实例并反馈错误。

标准菜单保留系统实现和快捷键，仓库、分支、窗口和第三方服务名称保持原文。全局 Git 配置和系统语言均未修改。

## 验证

| 项目 | 最终结果 |
| --- | --- |
| Apple Git 2.54.0 / 最低 Git 2.46.0 | 各 182 项 / 32 套通过，[Apple](core-apple-final.log)、[2.46](core-git246-final.log) |
| 严格格式与文案覆盖 | 通过；947 文本键、7 复数键，扫描 1199 处，[覆盖](coverage.log) |
| Debug / 普通 Release | 构建通过 |
| 原生 UI 回归 | 增加待应用状态与英文启动后的内置菜单断言，编译通过；完整 XCTest 未执行，环境初始化超时条件未变 |
| 恢复启动 | 浅/深色 × Changes/History/Branches 共 6 种通过，[报告](startup.json)，仅存活与状态校验 |
| 实际语言应用 | 中文→英文、英文→中文均通过；同一私有仓库和 `Restart draft 中文🙂 %1$@` 草稿逐字保留 |
| 原生菜单 | [File / Close](applied-file.ax.txt)、[Edit / Copy](applied-edit.ax.txt) 与菜单栏 File/Edit/View/Window/Help 均随新进程语言统一；设置窗口标题也更新 |
| 草稿保护 | [保存关闭时禁用](unsaved-draft-restart-disabled.ax.txt)，[开启保存后可用](saved-draft-restart-enabled.ax.txt) |
| 最终普通包 | 已以英文打开，恢复原 WeGit / Changes / CHANGELOG.md / Inspector / 空草稿；[工作区](ordinary-release.ax.txt)、[原生 File](ordinary-release-file.ax.txt) |
| 偏好与夹具 | 两个偏好域精确恢复后才打开普通包，私有文件、HEAD 与状态不变；[偏好](preference-restoration.json)、[夹具](fixture-check.json) |

实际重启行为在隔离 Debug 会话中验证；普通 Release 另做真实启动与原工作区恢复。完整 XCTest、VoiceOver、144 阅读组合和最终 Release 性能保持待验，不能以本专项替代。

诊断中一次最低 Git 路径写错，结果保留于 `core-git246-invalid-path.log`，随后使用 `install/bin/git` 重跑最终 182 项通过。独立候选检查还曾遇到旧静态库、资源定位与编译问题，最终不再采用该候选。偏好恢复发现 defaults import 会保留额外测试键，随后用已备份的完整域替换并核对字典精确相等。

原生菜单变更通知参考 [Apple NSMenu 文档](https://developer.apple.com/documentation/appkit/nsmenu/didchangeitemnotification)；实际限制以本机日志和展开结果判定。

## 交付与来源

应用输入 SHA-256：`60e79ea8cfb5a921256c9a077550fae0c09dc7f33d223353f220f44aec1b13dd`。

开发包：`.build/releases/package-tufzkw/WeGit-0.1.0-development.zip`。

SHA-256：`c87fe973135aabf2da03fe8ab2b5fe4e72083310d0828f5cfed3b4eeb5fbb5a5`。

来源回执、签名完整性、空权限、AskPass/MIT、测试入口排除和 ZIP CRC 通过。当前为未公证 ad-hoc 开发预览，基于 c99aa80 的未提交工作区；本轮没有提交或推送源码，V1.0 正式发布保持未完成。详见 [validation.json](validation.json)。
