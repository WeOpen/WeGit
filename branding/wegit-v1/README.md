# WeGit 品牌素材 · 第一版

日期：2026-10-12。

蓝色 Git 分支路径组成 W，四个圆点表示提交节点，中心节点连接三个方向。应用图标和横版 Logo 均提供浅色、深色版本。主色 #2B67D8，浅色字标 #172033，深色字标 #EEF1F6 / 标记 #79AAFF。

## 使用文件

- app-icon.png / app-icon.svg：1024 × 1024 应用图标，透明外缘。
- app-icon-dark.png / app-icon-dark.svg：同一造型的深色图标，透明外缘。
- app-icon-native-light.png / app-icon-native-dark.png：Icon Composer 实际渲染的两个 macOS 外观；系统外框与材质由 Icon Composer 提供。
- AppIcon.icon：应用使用的原生图标文档副本，支持 Default / Dark，位于应用源码的母版是 ../../WeGit/Resources/AppIcon.icon。
- WeGit.icns / WeGit-dark.icns：静态 macOS 图标包，各包含 16/32/128/256/512 pt 的 1x / 2x 版本。
- AppIcon.appiconset：浅色静态资源，保留供旧工作流使用；当前应用采用 AppIcon.icon。
- logo-light.png / logo-light.svg：浅色背景使用的横版 Logo。
- logo-dark.png / logo-dark.svg：深色背景使用的横版 Logo。
- mark.png / mark.svg：无底座的独立品牌标记。
- preview.png：两种背景与 16/32/64 px 的展示图。
- generated/：imagegen 生成的视觉探索，保留原始 PNG，不覆盖或改写。

正式使用建议选择根目录的几何母版。图标边缘与 Logo 字形已由矢量路径构成；PNG 由相同路径直接渲染，SVG 字标已转曲，不依赖使用者安装字体。生成探索与几何母版不是逐像素相同文件。

应用已接入 WeGit/Resources/AppIcon.icon，project.yml 显式选择 AppIcon，并配置 XcodeGen 2.43 对 icon 包的整体文件处理。背景与标记的 Default / Dark 填充分别保存于原生文档，系统根据用户的图标外观设置选择。应用内浅色/深色主题设置与系统图标外观设置是不同选项。没有通过应用代码临时替换 Dock 图标，也没有改动用户系统外观偏好。

应用构建生成 AppIcon.icns 与 Assets.car，后者包含 NSAppearanceNameAqua、NSAppearanceNameDarkAqua 的 AppIcon 图标堆栈。验证记录见 ../../docs/acceptance/2026-10-12/app-icon.json。图标接入改变了应用源码摘要；以前的性能样本和安装包仍保留原来的构建来源。

## 来源与复现

视觉方向使用内置 image_gen 工具生成，提示集见 PROMPTS.md。随后以确定的几何路径重建可缩放母版，使用项目内 Inter Variable 字体生成 WeGit 字标路径。字体从官方 rsms/inter 仓库的固定提交取得，提交记录见 source/inter-source-commit.txt，SIL OFL 1.1 全文见 source/LICENSE-Inter.txt。字体只在渲染进程注册，没有安装到系统。

```sh
mkdir -p branding/wegit-v1/WeGit.iconset
swift branding/wegit-v1/source/render-brand.swift "$PWD/branding/wegit-v1"
iconutil -c icns branding/wegit-v1/WeGit.iconset -o branding/wegit-v1/WeGit.icns
iconutil -c icns branding/wegit-v1/WeGit-dark.iconset -o branding/wegit-v1/WeGit-dark.icns
bash branding/wegit-v1/source/export-native-icons.sh
```

icon-mark.svg 是不含底座、扩展至原生图标内容区域的图层；复制到应用母版的 Assets/mark.svg 后，由 Xcode 编译原生外观。原生渲染可使用 Xcode 所带 Icon Composer 的 ictool，传入 --platform macOS --rendition Default 或 Dark。浅色、深色、透明边缘、节点连接与小尺寸均已检查；原生渲染保留系统材质，静态几何预览不模拟材质。字体只用于独立 Logo 素材，不作为应用运行依赖。
