# 第二版品牌接入验收

2026-10-15 开始，2026-10-16 完成。用户确认将第二版 Logo 和图标替换到应用，并保留旧版资源。环境为 macOS 27.0.1、Xcode 27.0（27A266a）、arm64。

## 实现与保留

- `WeGit/Resources/AppIcon.icon` 切换为第二版原生母版，编译后包含 AppIcon.icns 与 Assets.car。
- 新增内部 BrandGeometry，侧栏、欢迎页、快捷面板使用相同的连续 W 与右上单节点分叉；系统状态项采用同轮廓的光学加粗模板，保留 22 × 18 pt、isTemplate 与原辅助名称。
- 应用内字标使用系统字体的 medium 字重，独立品牌文件仍保留已转曲的 Inter 字标。没有为应用新增字体依赖。
- 欢迎页使用短淡入与小幅缩放，继续遵循界面动效和减少动态效果设置。
- 第一版完整目录 `branding/wegit-v1` 及原 ZIP/校验和原样保留。替换前核对原应用图标与第一版备份一致，最终逐文件核对 67 个旧版文件均未改变，见 [保留检查](v1-preservation.json) 与 [原摘要](v1-preservation-before.json)。此前第二版设计 ZIP 也保留，接入后的素材另行打包。

## 实际界面

| 检查 | 证据与结果 |
| --- | --- |
| 浅色／深色欢迎页 | [浅色](welcome-light.png)、[深色](welcome-dark.png)，新标记及较轻字标正常 |
| 浅色／深色侧栏 | [浅色](workspace-light.png)、[深色](workspace-dark.png)，蓝色 W、品牌卡片和 Add 保留 |
| 浅色／深色快捷面板 | [浅色](menu-panel-light.png)、[深色](menu-panel-dark.png)，新标记与原路由/操作入口正常 |
| 原生关于窗口 | [深色确认框](about-dark.png) 显示第二版真实应用图标 |
| 编译后的图标外观 | [Assets.car 记录](compiled-icon-assets.json) 含 21 个 AppIcon 条目，包含 Aqua、DarkAqua 与 Tintable 外观 |
| 普通 Release 启动 | [截图](ordinary-release.png)、[AX](ordinary-release.ax.txt) 恢复原中文、浅色、WeGit 仓库、Changes、Package.swift、Unified、Inspector 打开及空提交草稿 |

应用图标的 Default/Dark 外观由系统管理，与应用内容主题分别处理；深色内容中的关于图标仍可采用系统当前选择的蓝色 Default 图标。系统状态项使用黑白模板，未据局部图像扩展整条系统菜单栏的对比度或 VoiceOver 通过结论。

## 验证与隔离

Debug、普通 Release、严格格式与原生 UI 套件编译通过；最终应用源码下的 Light/Dark × Changes/History/Branches 共 6 种恢复启动通过。这些启动检查属于存活与持久化验证，不是性能数据。完整 XCTest 执行仍有既有初始化阻塞，本轮没有重复尝试，也没有把编译记作执行。

81 个 Core、AskPass、核心测试及 Package.swift 输入与上一轮逐文件相同，本轮未重跑核心；此前两套 Git 各 183 项通过的证据见 [无重启菜单验收](../live-menu-language/README.md)。47 个素材 PNG、转曲字标、实心节点及两份 ICNS 的导出校验通过。

本轮复用已有 `.build/ui-review/alert-inspector-fcada191/fixture`，未新增保留的测试项目，未暂存、提交或重置夹具。HEAD、status 与文件字节均一致，见 [夹具核对](fixture-check.json)。恢复启动脚本自行清理其临时夹具。普通与测试偏好域在测试实例退出后分别恢复为原 40／0 个键，再打开最终普通包，见 [恢复结果](preference-restoration.json)。未切换系统外观或改动全局 Git 配置。中间工具绑定、截图索引及空偏好域恢复问题均已处理并记录于 [检查过程](investigation-notes.md)。

## 交付与边界

应用输入摘要为 `abf032bdab6e609a41ae5710a14a25cc641abe8903bd12c950103e3036e54d32`。最终普通 Release 位于 `.build/releases/package-Fg4E0i/WeGit-0.1.0-development.zip`，SHA-256 为 `fdefc5133bd4cadc058302096e1319242e8f73a112b09fd19f6b329a7e7adc79`。源码回执、签名完整性、空签名权限、AskPass/MIT、测试入口排除、ZIP CRC 及校验和通过。

当前仍为 0.1.0 开发预览、com.willxue.wegit.development、ad-hoc 签名且未公证。本项完成品牌接入，不关闭完整 XCTest、辅助访问、144 阅读组合、最终源码 Release 性能、缺失兼容性、Beta 或正式分发门槛。完整机器清单见 [validation.json](validation.json)。
