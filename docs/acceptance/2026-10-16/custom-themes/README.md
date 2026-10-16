# 原生底色统一与独立自定义主题验收

日期：2026-10-16。环境：macOS 27.0.1 / Xcode 27.0（27A266a），arm64。基于 `c99aa80` 的 `codex/v1-validation` 脏工作区；本轮未提交或推送，保留全部预存改动与 `.spec-workflow`。

## 实现与使用

内置 Light/Dark/System 保持原生配色；主窗口工具栏、中心内容、Inspector 外层、底部提交区及设置标题栏/正文共用对应的原生 canvas。透明标题栏只对所属窗口处理，不修改整个应用或系统的 appearance；主题变化不替换仓库会话和窗口。

设置 → 外观 → 编辑自定义主题，提供独立于内置主题的一套完整方案。17 个颜色角色覆盖强调色、内容/工具栏/侧栏/卡片/边界、主次文字、Git 状态、Diff 背景及四类语法文本。控件外观选择 Light/Dark，决定系统控件与运行中 Dock 图标基底；AppKit 文件面板、原生材质和控件仍遵循系统渲染，不宣称每个系统像素都被主题覆盖。

支持十六进制输入、原生颜色井、实时预览、应用/取消、恢复初始色及 JSON 导入导出。实时预览不写偏好，取消恢复先前主题；导入只改变编辑草稿，应用后才保存并选择 Custom。切回内置主题不丢失自定义方案；重置界面偏好也保留方案。非法颜色禁用应用；未知版本、缺失/多余角色、非法值、超过 64 KiB 或无效 JSON 拒绝导入。对声明的实色文字/背景组合给出 4.5:1 对比度提示，不替用户修改颜色。

颜色通过 SwiftUI 环境传递；内存/磁盘 Diff 绘制与原生选区共享角色。颜色不参与 Git 补丁、Stage/Discard 或原始代码复制。沿用现有 GitEngine、ProcessRunning 与仓库队列。

## 自动验证

| 检查 | 结果与证据 |
| --- | --- |
| Apple Git 2.54.0 核心 | 183 项 / 32 套件通过，[完整 verify](verify.log) |
| 私有 Git 2.46.0 核心 | 183 项 / 32 套件通过，[日志](core-git246.log) |
| 主题行为 | 34 项通过，[断言列表](theme-checks.json)；包含真实 NSHostingView 挂载、偏好隔离/保存/预览回滚、窗口底色、非法导入和内置主题隔离 |
| 图标与原生菜单 | [16 项图标](appearance-checks.json)、[27 项菜单](native-menu.json)通过 |
| 迁移、文案、格式 | 15 项迁移；998 对字符串 / 7 对复数；严格 Swift 格式、源码覆盖/参数检查通过 |
| Debug / Release | 构建通过；[原生 UI 套件编译](native-compile.log)通过，未宣称执行通过 |
| 恢复启动 | [6 种浅深色/Changes/History/Branches](startup.json)通过，夹具 HEAD/status/索引未变，偏好恢复 |
| 分发预览 | 来源回执、签名完整性、空权限、AskPass/MIT、测试入口排除、两份主题 ICNS 字节匹配、ZIP CRC 与 SHA-256 通过 |

应用源码摘要：`9b8f7f77bc312b804d1d42c9429c695009fad10be91523ab972c8f6622e6ba1f`，算法为排序的应用 sourceFiles JSON 的 SHA-256。启动报告的应用输入与最终普通 Release [回执](release-build-source.json)逐文件相同。完整核对见 [validation.json](validation.json)。

## 实际界面与行为

复用原有 `.build/ui-review/alert-inspector-fcada191/fixture`，未新增项目仓库。交互检查采用 Debug 隔离偏好与私有 Git 配置，不读取/改写用户全局 Git 配置。

- 同一进程在 Custom → Light → Dark 间切换；Changes、History、Branches、Inspector 与 Split 配色对应。[浅色工作区](workspace-light.png)、[深色工作区](workspace-dark.png)、[自定义分栏](split-inspector-custom.png)、[自定义分支](branches-custom.png)。
- [浅色设置](settings-light.png)、[深色设置](settings-dark.png)、[自定义设置](settings-custom.png)；切换内置后仍显示已保存的 Sea Glass 方案。
- [自定义快捷面板](quick-panel-custom.png)；[英文设置](settings-english.png)、[英文编辑器实时预览](live-preview-english.png)、[取消后回到 Dark](cancel-preview-english.png)、[英文工作区与菜单 AX](workspace-english.ax.txt)。
- 有效 JSON 导入→导出→应用逐值一致，[导出样例](exported-theme.json)与[比较记录](import-export-apply.json)。无效 JSON 提示后草稿仍在，[错误 AX](invalid-import.ax.txt)、[保留草稿](invalid-import-preserved.ax.txt)。
- `#12` 无效输入禁用 Apply，[记录](invalid-color.ax.txt)。17 个文本框与颜色井均独立暴露，[AX 记录](editor-accessibility.ax.txt)。
- 实际重启后已保存方案和 `Theme check 中文🙂` 草稿恢复；切换主题、页面和语言没有修改仓库或草稿。

[截图实色取样](surface-pixels.json)使用 NSBitmapImageRep 解码并转换为 sRGB：浅色 toolbar/canvas/Inspector/commitStrip 均为 (255,255,255)，深色四处均为 (40,40,40)；设置 titlebar/canvas 同样对应。取样包含原始坐标/图片尺寸，避开卡片、文字、按钮与材料；数值属于截图色彩转换结果，不代替实际材料对比度验收。Custom 各表面采用独立角色，允许用户主动选择差别。

`editor-initial.png`、`live-preview.png`、最早 debug 日志属于修复过程的历史证据；最终效果以本节链接截图及最后验证回合为准。

## 发现、修复与保留的失败

1. 早期 result builder 中的赋值表达式造成编译失败，改为计算属性；原始活动日志和[失败说明](diagnostic-build-failure.json)保留。该回合完整普通文本日志随后被构建覆盖，未补造。
2. 首次打开设置因 AppPreferences 环境注入顺序触发崩溃，[崩溃日志](diagnostic-settings-crash.log)及[提取诊断](diagnostic-settings-crash.json)保留。统一要求传入 preferences 的 workbenchAppearance 辅助器把环境包在正确层级，更新所有呈现根，并加入实际 NSHostingView 回归；最终手动设置/编辑器/快捷面板及 6 种启动通过。
3. 颜色行 LabeledContent 合并 AX 子控件，改为显式容器；17 个编辑字段和颜色井可单独访问。根层中性 tint 曾清掉自定义强调色，改为仅给普通玻璃按钮中性样式；自定义表单保持右对齐控件，侧栏选中文字使用可读选中前景。
4. 原生菜单点击后有选择但未提交的中间状态，独立 Return 并读取 Picker 值后再截图；最早误标的浅色截图已用实际 Light 回合覆盖。

## 恢复、清理与交付

[两偏好域精确恢复](preference-restoration.json)后，普通 Release 打开原中文/Dark/WeGit/Changes/Package.swift/Split/Inspector 关闭/空草稿，并重开原 Appearance 设置窗口。[普通工作区](ordinary-release.ax.txt)、[普通设置](ordinary-settings.ax.txt)。普通启动后一个 workspace JSON Data 的字节顺序变化，解码内容与原值完全相同，见[语义比较](ordinary-preferences.json)；没有将测试主题保存到用户域。

[复用夹具 HEAD/status/文件一致](fixture-preservation.json)；[旧版 67 资源一致](v1-preservation.json)。仅清理本轮 WeGitCustomThemes 临时偏好/JSON/日志目录，证据保存在此；原有 fixture 和所有历史品牌素材/开发包保留。

最终普通开发包：`.build/releases/package-MlXpuO/WeGit-0.1.0-development.zip`。

SHA-256：`94698b5f1e75aac03e976f6cccfe5967225222e9b59988603f35da9927f334ec`。版本 0.1.0，标识 com.willxue.wegit.development，ad-hoc 签名、无公证。[Manifest](manifest.json)与[校验文件](WeGit-0.1.0-development.zip.sha256)对应同一 ZIP。

## 未扩展的验收范围

完整原生 XCTest 仍受已记录的初始化问题阻塞，本轮只编译且不重复无变化的失败尝试。未完成最终 VoiceOver/完整键盘/系统显示选项实测、144 个阅读组合、最终源码 30 次 Release 延迟/内存/FPS。对比度提示只检查声明的实色组合；文件颜色井与系统材料的完整可访问性仍待验。Developer ID、团队/公证配置、合格 Runner、干净机器与真实 Beta 条件仍未齐备，V1.0 发布保持未完成。
