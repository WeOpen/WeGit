# 无重启的原生菜单语言切换 · 2026-10-15

本轮按用户确认的方向，由 WeGit 完整管理普通 AppKit 菜单项，应用界面和顶部菜单在同一进程内切换中英文。上一轮的待重启提示和重启实现已移除。macOS 提供的文件选择器、字符面板和外部服务等界面仍可能沿用系统语言。

## 实现

NativeApplicationMenu 持有八个顶层菜单及稳定命令标识；ApplicationMenuActions 适配已有 AppState 动作和状态，GitEngine/ProcessRunning/仓库队列保持现有边界。SwiftUI 场景取消命令生成，提供窗口/设置打开回调。框架仍可能在场景激活时原地重写菜单树，因此通过公开通知和 mainMenu 观察恢复自有树；不修改框架缓存菜单项，不使用私有 API 或方法替换。

编辑动作每次从原生响应链解析目标，用独立菜单项验证可用性，防止系统校验改写已翻译的标题。保留 Undo/Redo、Cut/Copy/Paste、选择、窗口操作、侧栏与页面快捷键。系统窗口排列项目在展开时本地化；仓库、窗口、设备和服务名称作为数据保留原文。设置窗口标题和状态图标说明随语言更新。MenuTitles 独立词表区分菜单 File 和文件列表 Files。

## 验证与证据

| 项目 | 结果 |
| --- | --- |
| Apple Git 2.54.0 / 最低 Git 2.46.0 | 各 183 项 / 32 套通过，[Apple](core-apple.log)、[2.46](core-git246.log) |
| 原生菜单行为 | 27 项通过，覆盖双向观察更新、原生文字与 AXTitle、目标校验、拒绝执行、快捷键、最新响应者、框架重写后的恢复和名称保留，[报告](native-menu-checks.json) |
| 文案 / 格式 | 覆盖检查与严格格式通过；952 文本键、7 复数键，标准菜单另有独立词表 |
| Debug / 普通 Release | 构建通过；原生 UI 回归编译通过，完整 XCTest 未执行，现有初始化超时环境未变 |
| 恢复启动 | 浅/深色 × 更改/历史/分支共 6 种带 Inspector 恢复通过，[报告](startup.json)，不是性能测量 |
| 实际菜单 | [英文 File](final-english-file.ax.txt)、[中文 File](final-chinese-file.ax.txt)、[英文窗口排列及列表](final-window-english.ax.txt)、[Help](help-english.ax.txt) |
| 标准动作 | Undo/Redo、⌃⌘S、原生关闭设置、关闭/菜单重开主窗口通过；私有文件 Stage all/Unstage all 后状态及可用条件正确刷新 |
| 持续 Git 读取 | 使用仅位于私有夹具的可释放读取代理；切换前后同一应用 PID 与 Git 读取 PID 存活，界面从 Reading commit history 切为读取提交历史，释放后出现预期提交，[证明](held-read-proof.json)、[切换后仍在读取](held-read-after-language.ax.txt)、[完成结果](held-read-completed.ax.txt) |
| 草稿与夹具 | `Live draft 中文🙂 %1$@` 保留；文件内容、HEAD 与 Git 状态恢复原夹具语义，[夹具核对](fixture-check.json) |
| 最终普通包 | 真实用户工作区中即时 English → Follow system，PID 不变；File/Close 已翻译，最后恢复跟随系统、原设置页及 WeGit/Changes/CHANGELOG.md/Inspector/空草稿，[英文菜单](ordinary-english-file.ax.txt)、[恢复状态](ordinary-release.ax.txt) |

详细交互在移除 Debug 诊断打印前完成；清理只删除日志，随后以最终源码重跑 27 项菜单检查、构建、原生编译和 6 种启动，最终普通 Release 另行实测同进程语言切换。完整 XCTest、VoiceOver、144 阅读组合和 30 次 Release 性能仍待验。

初轮候选发现 commandsRemoved 后框架仍会原地替换菜单内容，修复后独立检查和实际窗口均验证恢复；初始构建/候选记录保留。Computer Use 无法在应用无窗口时取窗口快照，因此首次恢复通过临时 Finder 窗口正常打开现有应用，临时窗口已关闭；后续专门保留设置窗口，验证 Native Window → Show WeGit main window 恢复主窗口。两次均保留进程与仓库状态。所有设置验证使用私有测试域，两个偏好域在打开普通包前精确恢复，[记录](preference-restoration.json)。未修改系统语言、权限保护或全局 Git 配置。

## 来源与交付

最终应用输入 SHA-256：`3704b58de5d6f2e2a52c9b0709e8d2505476ddccc3116584054395a1bca65fbe`。

开发包：`.build/releases/package-GQPxL0/WeGit-0.1.0-development.zip`。

SHA-256：`33998882235be9e3e035784c078335e4d6eb0c349a18804b9ec68142a3ebdf3f`。

来源回执、签名完整性、空权限、AskPass/MIT、测试入口排除、双语资源及 ZIP CRC 通过。当前为未公证 ad-hoc 开发预览，基于 c99aa80 的未提交工作区，本轮未提交/推送源码；V1.0 正式发布仍未完成。来源、工具链、证据摘要及限制见 [validation.json](validation.json)。
