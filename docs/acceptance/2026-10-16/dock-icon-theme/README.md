# Dock 图标主题同步修复 · 2026-10-16

用户确认的问题为：深色主题下 Dock 仍显示蓝底的第二版 W。根因是此前只打包了 Icon Composer 的 Default/Dark 外观，AppPreferences 只驱动内容主题；运行中的 Dock 没有应用主题的同步入口。macOS 的图标样式与内容外观分开管理，见 [Apple 外观设置](https://support.apple.com/en-gb/guide/mac-help/mchlp1225/27/mac/27)。

## 实现

AppPresentation 缓存两份由现有 Icon Composer 母版导出的原生 ICNS，使用 [NSApplication.applicationIconImage](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage) 更新运行中的 Dock。AppPreferences 在显式主题改变时立即同步，已有的 effectiveAppearance 观察器负责初次恢复和 System 变化；没有增加轮询或重建窗口/仓库会话。关于、确认及退出保护使用相同主题图标。

浅色选择蓝底 WeGitLight.icns，深色选择石墨底 WeGitDark.icns，System 解析当前系统外观。两份文件在 WeGit/Resources/AppearanceIcons，内容与 branding/wegit-v2 的原生导出一致；Release 来源校验新增存在性与逐字节核对，防止资源遗漏。原 AppIcon.icon 仍用于 Finder 等静态系统入口。应用退出后，Dock 静态图标同样交回系统图标样式管理。

## 回归证据

| 检查 | 结果 |
| --- | --- |
| 修复前的实际 AppKit 图标检查 | [before.json](before.json) 在“Restored Dark selects the graphite Dock icon”失败，采样仍为蓝色 |
| 修复后的原生切换检查 | [16 项通过](appearance-checks.json)，读取真实 applicationIconImage 像素，覆盖恢复、Light/Dark/System、无窗口、重置及原生面板 |
| 同进程的实际界面切换 | [进程记录](same-process.json)，Dark → Light → System，未重启 |
| 实际图标 | [深色](about-dark.png)、[浅色](about-light.png)、[跟随当前浅色系统](about-system.png) |
| 核心完整回归 | Apple Git 2.54.0、私有最低 Git 2.46.0 各 183 项 / 32 套件通过，见 [verify.log](verify.log)、[core-git246.log](core-git246.log) |
| 其他验证 | 27 项原生菜单、偏好迁移、本地化、严格格式、Debug/Release、原生 UI 编译及 6 种最终源码恢复启动通过 |

实际 AppKit 图像背景采样：深色约 (0.135,0.157,0.208)，浅色约 (0.256,0.443,0.796)，均为 sRGB 0～1。16 项检查运行在独立私有偏好域，系统 Light/Dark 转换只影响检查进程自身的 NSApplication.appearance，没有改变用户系统设置。回归脚本 scripts/verify-appearance-icons.sh 已接入 verify.sh --ui；临时检查 App 在退出时删除。

电脑控制工具读取 Dock 系统进程时超时，未采集整条 Dock 的视觉截图；不以关于窗口截图冒充 Dock 截图。Dock 同步由实际 AppKit 属性的像素断言、公开 API 和同进程生命周期检查验证。完整 XCTest 执行仍受既有初始化问题阻塞，本轮确认编译成功，没有重复无变化的失败尝试；完整辅助访问、矩阵和性能门槛保持待验。调试状态为 DONE_WITH_CONCERNS，限制为上述完整视觉/自动化范围。

## 隔离与保留

本轮界面检查使用空的私有测试会话，未创建或打开测试项目仓库。恢复启动脚本自行清理临时仓库。普通/测试两个偏好域在测试实例退出后恢复为原 40/0 个键，随后才打开新包，见 [恢复摘要](preference-restoration.json)。最终恢复原中文、浅色、WeGit 仓库、Changes、Package.swift、Split、Inspector 关闭和空草稿，见 [AX](ordinary-release.ax.txt)、[截图](ordinary-release.png)。第一版 67 个文件原样保留，见 [核对](v1-preservation.json)。没有改动全局 Git 配置、系统图标样式或系统外观。

## 交付

最终应用输入摘要 `bcedd0fcf7adfa767783a4e8b91539ab02356fa2448ed7eeaa3091d2bf59164e`。普通 Release 为 `.build/releases/package-0QjAlo/WeGit-0.1.0-development.zip`，SHA-256 `3bdac66d22fa259b210031b6dfab4de15d01c8ebebd0d8f68a0b5b102ff9b1ca`。来源、两份主题图标、签名、空权限、AskPass/MIT、测试入口排除、CRC 和校验和通过。版本仍为 0.1.0 开发预览、com.willxue.wegit.development、ad-hoc 签名，未公证；不关闭 V1.0 正式发布门槛。结构化结果见 [validation.json](validation.json)。
