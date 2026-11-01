# WeGit 品牌素材 · 第二版

日期：2026-10-15。设计方向：连续的 W 与右上角单节点分叉，保留蓝色识别，减少装饰与节点重量。

## 最终素材

| 文件 | 用途 |
| --- | --- |
| preview.png | 浅深色 Logo、原生图标与实际 16/32/64/128 px 尺寸对照 |
| mark.svg / mark.png | 平面蓝色标记，PNG 2048 × 2048，真实透明背景 |
| mark-dark、mark-black、mark-white 的 SVG/PNG | 深色背景、单色印刷及反白使用 |
| logo-light.svg / logo-light.png | 浅色背景字标；PNG 3006 × 1080，透明背景 |
| logo-dark.svg / logo-dark.png | 深色背景字标；PNG 3006 × 1080，透明背景 |
| app-icon-light.png / app-icon-dark.png | Icon Composer 渲染后加入 macOS 静态画布留白的图标，1024 × 1024 |
| AppIcon.icon | 单一原生母版，内含 Default、Dark 与 tinted 填充设置 |
| WeGit.icns / WeGit-dark.icns | macOS 静态图标包，16/32/128/256/512 pt 的 1x/2x 版本 |
| menu-bar/ | 加粗细节的单色小尺寸标记：16、18、20、24、32、36、40、48、64 px，以及 SVG 模板 |
| generated/ | 内置 image_gen 生成的原始探索与材质概念；未作像素修改 |

本版已接入应用的 AppIcon.icon、侧栏、欢迎页、菜单栏快捷面板和系统状态项。应用内标记使用同一几何母版，菜单栏采用光学加粗路径；字标使用系统字体以保持原生文字渲染。第一版素材及其 ZIP、ICNS 和矢量源文件原样保留在 ../wegit-v1。

## 视觉规则

- 平面标记：#2463DB；深色标记：#8CB5FF。
- 应用图标 Default 使用钴蓝原生渐变，Dark 使用石墨蓝原生渐变；珠白主体带浅层浮雕。精确颜色与原生材质参数以 AppIcon.icon/icon.json 为准。
- 标记宽度约占图标画布 67%，通过留白和一个小分叉建立辨识度。平面 Logo 保持单色，不加入图标材质。
- 字标采用项目已有的 Inter Variable，字重 510，重新调整图文比例与间距；SVG 已将文字转为路径，使用者无需安装字体。
- 应用图标由 Icon Composer 添加原生渐变、边缘高光和浅层浮雕。静态 ICNS 额外归一为 824/1024 的底板占比，原生 .icon 文档保持系统布局；两条路径避免重复留白。生成图中的照明更强，原生版本不等于生成图逐像素复刻。
- Default/Dark 使用相同几何轮廓。运行中的 Dock、关于与确认框图标跟随应用 Light/Dark/System；Dock 通过 AppKit applicationIconImage 选择两份原生 ICNS。Finder 和应用退出后的静态图标仍由 macOS 图标样式管理。

## 来源与复现

视觉探索使用内置 image_gen，四轮实际提示见 [PROMPTS.md](PROMPTS.md)。随后独立重建确定的矢量路径，用同一个母版导出平面标记、转曲字标及原生图标。最终矢量整理版与生成概念保持设计方向一致，但不是生成 PNG 的逐像素描摹；原始输出在 generated/ 单独保留。

字体与许可复用第一版已有的固定提交，来源记录及 SIL OFL 1.1 全文在 source/。字体仅在渲染进程注册，没有安装到系统或加入应用运行依赖。

```sh
swift branding/wegit-v2/source/render-brand.swift "$PWD/branding/wegit-v2"
bash branding/wegit-v2/source/export-native-icons.sh
swift branding/wegit-v2/source/render-preview.swift "$PWD/branding/wegit-v2"
swift branding/wegit-v2/source/verify-assets.swift "$PWD/branding/wegit-v2"
```

复现环境：macOS 27.0.1、Xcode 27.0（27A266a）、Icon Composer design generation 27。实际核对图标的 Default/Dark、透明外缘、SVG 实心节点、字标和常用小尺寸；详细数据见 validation.json。素材导出检查不替代应用验收。应用接入的实际截图、构建与来源证据见 [接入记录](../../docs/acceptance/2026-10-15/brand-v2/README.md)；其他系统和完整辅助访问状态保持原记录。

2026-10-16 补齐运行中 Dock 的主题同步；两份导出 ICNS 接入 WeGit/Resources/AppearanceIcons。后续更新图标时需同步该目录与 AppIcon.icon，Release 来源校验会拒绝缺失或不匹配的主题 ICNS。见 [主题同步修复](../../docs/acceptance/2026-10-16/dock-icon-theme/README.md)。

2026-10-16 修复 Dock 画布比例并增加原生材质层次，修正前第二版保留于 revisions/before-dock-material-2026-10-16；[根因、尺寸对比和交付](../../docs/acceptance/2026-10-16/dock-scale-material/README.md)。
