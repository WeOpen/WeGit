# R5 品牌与上下文检查器 · 2026-10-25

在 `codex/v1-1-1-polish` 保留既有未提交改动的基础上完成。以最新参考图制作两节点分支、薄底座和小投影；深色分支、印文和边框均为墨黑。已核实的「庫」印面哈希不变。完整生图原件和高清素材见项目 `design/brand/`。

## 检查结果

- Debug 构建成功，最终157个应用输入与制品回执逐一一致，见 `final-source.json`。
- 品牌素材检查见 `brand-validation.json`：共享路径、两个圆孔、保留印文、高清尺寸、透明完整边距、印章红基色和实际Composer Default/Dark分支/印章颜色。
- 独立主题342项通过，原生图标42项通过；本地化1171字符串、8复数、1570源码文字通过。见各JSON和 `localization.log`。
- Dock画布检查使用同画布下真实Finder图标作比例与中心对照；旧静态图标的主体边长本就相同，R5削薄的是视觉底边和投影。`Finder.png`、`Terminal.png`、`WeGit-R5.png`为实际AppKit资源渲染，不冒称桌面Dock截图。用户已有固定Dock缓存未改动。

## 原生界面与操作

| 检查 | 证据 |
| --- | --- |
| 文件路径、状态、统计、差异块 | [浅色](light-file-inspector.png) / [深色](dark-file-inspector.png) |
| 右栏选择文件驱动中央Diff | [浅色](light-commit-files.png) / [深色](dark-commit-files.png) |
| 提交作者、消息和SHA | [浅色](light-commit-info.png) / [深色](dark-commit-info.png) |
| 折叠后恢复文件列表和元数据 | [折叠状态](light-inspector-collapsed.png) |
| 标签底色和中式签牌空态 | [浅色](light-tag-empty.png) / [深色](dark-tag-empty.png) |
| 标签/储藏上下文 | [标签](dark-tag-inspector.png) / [储藏](dark-stash-inspector.png) |
| 文件历史sheet的独立文件列表 | [历史窗口](file-history-sheet.png) |
| 右栏差异块双向暂存 | `hunk-action.json`、`inspector-unstage-result.*`、`inspector-stage-result.*` |

原生夹具发现重新暂存后分区重映射有时留下空Diff。修复后重新执行两向操作，取消暂存时index为空、工作区+3/-3，重新暂存后index+3/-3、工作区diff为空；HEAD不变，中央Diff与右栏统计仍存在。

`ui-source.json`记录实际双向暂存和文件历史检查的构建；它与最终构建仅差 `ChangesView.swift` 中阅读菜单的对比度tint。全部浅深页面截图在 `visual-source.json` 对应构建重录。最终构建另外将差异块缩略预览限制为4个变化行、每行最多160字符，并改为惰性筛选，避免长行和大型块给侧栏增加无界文本布局；此改动后的文件检查器又单独复核。最终回执为 `final-source.json`。差异块双向暂存又在最终构建重跑，实际index仍为完整的+3/-3，见 `hunk-source.json`；预览限长不影响补丁。草稿在页面和主题切换后保持。

本机没有执行XCTest。此处是构建、独立行为检查与CUA原生诊断，不代表完整托管回归、性能或公开发布验收。所有Git写入都在隔离临时仓库与本地bare remote范围内，未修改用户仓库、全局Git配置或安装的应用。


## 2026-10-26 交付一致性复核

所有10种ICNS表示（含不同点尺寸/Retina倍率）均实际解码，16至1024像素的浅色白印与深色黑印全部通过，连同主题切换与Dock对照共42项。6张2400/4800像素Logo四边透明，应用内浅深Icon印文颜色正确。见 `icon-checks.json`、`hd-delivery.json`。

ZIP通过CRC与179条逐文件SHA-256校验，129项素材目录与压缩包、工作区完全一致；应用Icon Composer工程与品牌母版一致，运行预览仍对应最终157项应用输入。见 `delivery-integrity.json`。没有重新裁切或插值修改生图原件。
