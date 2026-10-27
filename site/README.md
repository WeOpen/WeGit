# WeGit Website

WeGit 的产品网站与主题中心。站点整体迁自用户提供的 `WeGit-Website`，保留山水视觉和笔记本构图；导航采用悬浮胶囊，页面功能图标统一使用太极、卷轴、梅枝、祥云、折扇与园窗等矢量图形。中英文、浅深色、公开版本下载和原生主题协议均已接入。

无需安装前端依赖。构建使用 Python 3.10+ 标准库，JavaScript 测试使用 Node.js 18+。

## 本地运行

从仓库根目录执行：

```sh
python3 site/scripts/serve.py --port 4173
```

或者进入 `site`：

```sh
npm run dev -- --port 4173
npm test
npm run test:build
```

预览地址：`http://127.0.0.1:4173/zh/`。英文首页在 `/`，主题页在 `/themes/` 和 `/zh/themes/`。原有 `themes.html` 链接仍兼容。隐私页和 404 同样提供两个语言版本。

默认构建不包含发布记录，下载入口会指向 GitHub Releases。要预览真实发布元数据，给构建或开发服务器传入 `--releases-json <file>`；文件应为公开 GitHub Releases API 的数组响应，不需要在浏览器中配置令牌。

## 目录

```text
site/
├── src/
│   ├── pages/          首页、主题页与 404 模板
│   ├── partials/       所有页面共用的导航与页脚
│   ├── styles/         页面、响应式与动效样式
│   └── scripts/        页面交互、主题模型、预览与动画模块
├── public/
│   ├── assets/         网站山水插画等静态资源
│   └── themes/         客户端可直接导入的 JSON
├── data/               双语文案、主题目录、品牌素材清单
├── scripts/            构建和本地服务器
├── tests/              主题协议、发布链接与静态构建检查
├── design/             山水素材母版，构建时不发布
├── docs/               迁移说明与原作者参考材料
├── package.json        统一开发、构建与测试命令，无运行依赖
└── README.md
```

构建产物统一在仓库的 `.build/website`，不提交到源码目录。根目录 `scripts/build_website.py` 是兼容入口；实际实现由 `site/scripts/build.py` 管理。构建先在临时目录完成校验，再替换既有生成目录。替换非空目录前必须验证非符号链接的 `.wegit-site-build` 标记及其精确内容；通用 `.nojekyll` 不代表目录归属，普通用户文件夹会被拒绝。

HTML 中的 CSS 和入口脚本地址带有文件内容摘要。静态与按需加载的 JavaScript 模块也带有内容版本，子模块更新会同步改变入口地址，避免新页面复用旧样式或旧交互。相同内容的重复构建保持相同地址，不增加运行时刷新脚本。

## 品牌资源

`design/brand` 是品牌素材的唯一来源。`data/brand-assets.json` 声明网站实际需要的横版 Logo、符号、浅深色 App Icon、favicon、小篆印章与分享图。构建按清单直接复制已导出的 WebP/PNG/SVG，不重新描字，也不依赖浏览器字体画「庫」。

页头与页尾使用含字标和外印的横版 Logo；浅深色切换同时切换相应字标与 App Icon。应用图标展示使用真实的 16～512 像素资源，尺寸标签对应实际文件。漂浮小印与品牌说明中的印章使用已核实的共享 SVG。

Hero 使用实际 WeGit 原生工作台截图，来源为 `docs/acceptance/2026-10-25/brand-integration/final/{light,dark}-changes.png`。网站使用 1920 像素宽的 WebP 衍生图，分别约 65 KB；没有重新绘制或伪造其中的客户端界面。

文化图标在 `public/assets/icons/culture.svg`，原有 16 个已重审并扩充至 48 个，统一使用 24 单位坐标系与 1.65 单位描边。`src/scripts/icons.js` 与构建器只引用该符号集，避免 Unicode 字形因系统字体不同而变化。名称和功能含义见 `data/icons.json`，绘制与审查记录见 [design/ICONS.md](design/ICONS.md)。

运行 `python3 site/scripts/build_icon_catalog.py` 可生成 `.build/website-icons/index.html`，离线查看全部图标的 16、24、40px 实际显示及浅深色。这个设计目录不随产品网站发布。

品牌更换不需要手动复制一套资源到 `public`；更新 canonical 品牌资源并构建即可。验证检查会逐个核对发布目录与 canonical 文件的字节。

## 主题中心

提供新版的 Light、Dark、Ink、Crimson，以及此前的 Rice Paper、Celadon、Sakura、Inkstone、Northern Light、Dusk，共 10 套。原型的 7 色示例文件已迁为客户端的 version 1 格式：

```json
{
  "version": 1,
  "name": "Theme name",
  "controls": "light",
  "colors": { "accent": "#B3322D", "canvas": "#F7F3ED" }
}
```

上例省略了其余颜色；真实文件必须包含 `theme-model.js` 列出的全部 17 个角色。构建要求目录内每个主题通过客户端相同的 37 对文字对比度规则，且小于 64 KiB。

强调色和对比度调整会生成实际颜色值，预览和下载使用同一个结果。字体和字号是网页预览工具，页面会明确提示它们不随颜色主题导入。导入文件只在本地浏览器读取；名称用普通文本显示，不作为 HTML 插入。

主题页直接展示精选主题库。点击卡片上的「预览」打开原生 HTML dialog，弹窗内包含 WeGit 工作台和配色设置；关闭、Escape 或点击遮罩可退出，并将焦点还给触发按钮。手机端在弹窗内部滚动，关闭按钮保持可见。「导入主题文件」是可通过 Tab 聚焦、Enter 或空格触发的按钮；导入本地文件后也通过该弹窗预览，退出时焦点回到导入按钮。带 `?theme=ink` 的分享链接会直接打开相应主题。

小屏导航隐藏右上角下载入口。主题卡片在小屏或卡片内容宽度不足 288px 时只显示三个操作图标，保留完整的辅助功能名称和悬浮提示；宽卡片继续显示按钮文字。

所有可调色预览共用 `src/scripts/workbench.js`，按真实 WeGit 的工具栏、工作区侧栏、暂存文件、差异和提交栏构建，缩略图使用同一布局的精简版本。配色来自实际 JSON；这类预览是网页渲染，原生材质仍以客户端为准。卡片悬浮只抬起预览图或图标，标题、描述和尺寸标签保持原位。

客户端操作：**设置 → 外观 → 自定义配色 → 编辑 → 导入 → 应用主题**。网页里的「导入 WeGit」会下载对应文件并显示该路径；导入不代表自动保存，同一时间使用一套自定义主题。

## 404 页面

`src/pages/404.html` 的正文按用户提供的 1122×1402 原型实现，顶部导航与底部页脚使用和首页相同的 `src/partials/` 模板与样式；文字、按钮、四张推荐卡片、品牌字标与印章仍为真实 HTML 或 canonical 品牌资源。水墨 4–太极–4 主景和湖景页尾使用内置 imagegen 分别生成浅、深版本，未经插值放大，原生 PNG 与实际尺寸记录保存在 `design/source/error404/`，发布使用 WebP。站内搜索入口位于正文的重新加载按钮旁。

本地缺失文档会返回此页面及真实 HTTP 404 状态；HEAD 不发送正文，缺失 CSS/JS 等资源仍返回普通资源错误。GitHub Pages 使用根目录 `404.html`。独立中文预览为 `/zh/404.html`，英文为 `/404.html`。返回首页、主题中心、重新加载和站内恢复入口搜索均可操作；搜索框一次 Escape 关闭并恢复触发按钮焦点。

页面比对和交互记录见 [design-qa.md](design-qa.md)，当前集成复核与历史证据边界见 [网站验收记录](../docs/acceptance/2026-10-27/website/README.md)。

## 验证

```sh
node --test site/tests/*.test.mjs
python3 -m unittest discover -s site/tests -p 'test_*.py' -v
scripts/verify-themes.sh
python3 scripts/ci/check_policy.py
```

前两条验证主题导出/导入、预览一致性、版本链接、三种 base path、双语页面、品牌来源、48 个图标、404 HTTP 语义和输出目录保护。Swift 独立检查使用客户端真实模型与私有偏好验证目录中的全部主题，不执行 XCTest。

## 发布与性能

现有 GitHub Pages 工作流继续使用仓库根目录构建入口。PR 只构建；main 和受限发布事件才进入现有 Pages 部署任务。路径过滤同时覆盖 `site/**` 和 `design/brand/**`，品牌素材单独变化也会触发构建。修改网站源码不会自行创建客户端 Release。

网站不请求第三方动画或字体 CDN。原版 AOS/GSAP 效果使用本地 CSS 和一次性 IntersectionObserver 实现，减少动态效果偏好会关闭入场与 Loading。浅深色在 CSS 请求前确定，避免预先下载两套大背景。深色原始 PNG 保留在 design/source 中，发布使用约 58 KB 的 WebP。

当前包含 404 四张素材的静态分发约 2.47 MB，总预算为 3 MB。主 CSS 仍限 64 KiB、主脚本 25 KB、主题模型 10 KB；404 单独加载样式和恢复交互，主景每张限 450 KB、页尾每张限 300 KB。浅深色选择只请求对应的图片，PNG 母版不发布，页面没有持续 Canvas/WebGL 绘制。缩略预览使用较小的 DOM，不在字号滑动时重建整个主题列表。真实性能仍以目标环境的浏览器测量为准。

原作者说明和旧测试报告位于 `docs/UPSTREAM*`，属于历史参考，不作为此次迁移的验收结果。源文件、旧站点和原始预览图另有私有迁移存档，见 [迁移说明](docs/MIGRATION.md)。
