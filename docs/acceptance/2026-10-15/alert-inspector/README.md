# 原生确认框与检查器底色验收 · 2026-10-15

修复重置界面偏好的确认框在浅色界面中呈深色、使用空白通用图标的问题，并将深色 Inspector 外层背景与中间阅读区统一。当前环境为 macOS 27.0.1、Xcode 27.0（27A266a）、arm64；应用输入摘要为 `6844a5f7c0cda2aeb7b7693bfed0c8c45529d9803a0f612274bb822403ff646f`。工作区仍包含既有未提交改动，未提交或推送。

## 实现

NSAlert 不在 SwiftUI 的 preferredColorScheme 环境内。新增内部 AppPresentation，为确认框显式解析当前 Light/Dark/System 偏好，并从应用 Bundle 加载真实 AppIcon；直接启动 Debug、尚未由 Launch Services 注册图标时也能显示。已有通用确认、退出保护和关于窗口共用该配置。增强对比度使用系统对应 appearance，未新增 Git 接口或队列。

canvas 使用原生 controlBackgroundColor，Inspector 的 grouped Form 隐藏额外滚动背景并绘制同一 canvas。原生分组卡片、分隔线、Sidebar 与标题栏仍保留自身系统角色。

## 实际检查

| 操作 | 结果与证据 |
| --- | --- |
| 浅色设置 → 高级 → 重置界面偏好 | 白色原生确认框、深色文字、蓝色 WeGit 图标；[截图](reset-light.png)、[AX](reset-light.ax.txt) |
| 深色设置 → 高级 → 重置界面偏好 | 深色原生确认框、浅色文字、真实图标；[截图](reset-dark.png)、[AX](reset-dark.ax.txt) |
| 两种主题取消确认框 | 返回设置，未执行重置 |
| 浅色中间区与 Inspector 外层底色 | 两者 RGB 均为 (255,255,255)，最大通道差 0；[Diff](panels-light-diff.png)、[空状态](panels-light-empty.png) |
| 深色中间区与 Inspector 外层底色 | 两者 RGB 均为 (30,30,30)，最大通道差 0；[Diff](panels-dark-diff.png) |
| 私有夹具中确认重置 | 显示已重置反馈，保留当前仓库及逐字草稿 `Preserve reset draft 中文🙂`；[反馈](reset-applied-settings.ax.txt)、[草稿](reset-draft-preserved.ax.txt) |
| 普通 Release 恢复原工作区 | 英文、System、WeGit 仓库、Changes、Package.swift、Unified、Inspector 打开、空草稿；[AX](ordinary-release.ax.txt)、[截图](ordinary-release.png) |

像素测量取中心空白处 (0.55w,0.70h) 与 Inspector 卡片外侧 (0.99w,0.70h)。两个确认框各检测到 2533 个蓝色品牌像素，结合实际查看排除通用占位图；[数据](visual-measurements.json)。该取样只验证底色与图标，不代表完整文字/材质对比度合格。

## 构建与隔离

Debug、普通 Release、严格格式检查、27 项原生菜单行为检查均通过。原生 UI 套件 build-for-testing 成功，未重试既有无变化的 XCTest 初始化阻塞，也未把编译记作执行通过。最终源码的 Light/Dark × Changes/History/Branches 共 6 种恢复启动通过，属于存活与持久化检查。[验证清单](validation.json) 关联日志与结果。

81 个 Core、AskPass、核心测试及 Package.swift 输入与上轮逐文件一致，本轮未重跑核心测试；上轮两套 Git 各 183 项 / 32 套件的通过证据仍见 [无重启菜单验收](../live-menu-language/README.md)。本轮没有新增 Release 延迟、FPS 或 30 次采样结论。

UI 操作在 `.build/ui-review/alert-inspector-fcada191/fixture` 与私有测试偏好域中完成；夹具 HEAD、status 和文件字节未变化。普通/测试两个偏好域在所有测试实例退出后恢复并逐值核对，随后才打开最终普通包；未改动全局 Git 配置或系统外观。[夹具核对](fixture-check.json)、[偏好恢复](preference-restoration.json)。

## 交付

最终普通 Release 包位于 `.build/releases/package-36Yu9M/WeGit-0.1.0-development.zip`，SHA-256 为 `4d1574d123db04fd21db403343d530c76c23319ca2095836aec4ecaf74eff989`。当前源码回执、签名完整性、空签名权限、AskPass/MIT、测试入口排除、ZIP CRC 及校验和通过，普通包已实际打开。

版本为 0.1.0、开发标识 com.willxue.wegit.development、ad-hoc 签名、未公证。完整 XCTest、VoiceOver/完整键盘/增强对比度等系统选项、144 阅读组合、最终性能、缺失兼容性与正式分发/Beta 继续待验，V1.0 保持未发布。
