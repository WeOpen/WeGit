# WeGit Website — 双页面高保真前端

基于两张 WeGit 视觉效果图重建的**可运行静态网站**。包含：

- `index.html` — 完整长版首页 / landing page。
- `themes.html` — 独立主题中心，包括实时主题预览、六色强调色、对比度、字体、字号调节。
- `styles.css` — 浅色/深色、桌面/平板/手机响应式样式。
- `app.js` — 无框架依赖的页面逻辑、中英文词典、本地主题生成/下载/导入。
- `assets/*.svg` — SVG 品牌标志、高清水墨山峦、亭台素材、favicon。
- `references/` — 两张原始参考图，仅用于设计比对，不作为网页背景。

## 本地运行

直接用浏览器打开 `index.html` 和 `themes.html` 即可查看页面。建议本地 HTTP 服务器（以避免浏览器对 `file://` 文件下载的限制）：

```sh
cd WeGit-Website
python3 -m http.server 8080
# http://localhost:8080/index.html
# http://localhost:8080/themes.html
```

无需 npm install、无需外部字体/图片 CDN。水墨背景、logo、模拟 macOS 客户端界面均由 SVG/HTML/CSS 绘制，高清缩放不失真。

## 功能

1. 顶部语言切换支持简体中文/英文，记住上次选择。
2. 顶部昼夜切换支持浅色/深色，默认参考系统模式，手工选择后保存。
3. 主题中心展示 Light、Dark、Ink、Crimson 四个主题。单击缩略图或预览按钮后主预览即时更新。
4. 选择强调色、界面对比度、字体及字号时，主预览无需刷新即可变化。
5. 「下载主题」生成对应 `.wegit-theme.json` 文件；「导入 WeGit」也下载文件并提示从桌面应用内打开。
6. 「导入主题文件」读取本地 JSON，校验 7 个六位 hex 颜色值及 schema 后追加至主题库并实时预览。
7. 浏览器不会未经支持直接改变 macOS 原生应用。本页面的 `.wegit-theme.json` 结构是**示例接口设计**，需要 macOS 客户端实现相应解析后才能正式导入。
8. App「下载 WeGit」按钮现在会明确显示尚未接入正式安装包。实际发布前在 `app.js` 配置 `APP_DOWNLOAD_URL`。

## 主题示例格式

```json
{
  "format":"wegit-theme",
  "version":1,
  "id":"ink",
  "name":"Ink",
  "appearance":"light",
  "colors":{
    "background":"#faf8f1",
    "panel":"#f6f4ed",
    "sidebar":"#e9e8df",
    "text":"#39413d",
    "muted":"#828b82",
    "border":"#d8d9d1",
    "accent":"#b3322d"
  }
}
```

## 设计还原边界

构图、内容和品牌色均依照两张参考图重新实现；不同于静态截图，此版可在不同视口重排，文字和 Git 界面保持高清。参考图由图像生成，部分微小 UI 字段本身无法作为可靠产品规格，所以模拟 Git 历史采用可读的示例数据，非真实 Git 操作。图标右下「庫」字目前为矢量文本示意，不代表经篆书考据完成的最终小篆字形。原型页面未绑定正式安装包下载地址。


## V1.1 视觉升级

- 新增高清水墨背景素材：`assets/ink-bg-light.png`、`assets/ink-bg-dark.png`
- 新增太极阴阳 Loading 动画（纯 HTML/CSS）
- 新增滚动进入动画与动效增强
- 引入动画库：AOS（滚动入场）与 GSAP + ScrollTrigger（细节动画，可选增强）
- 继续支持：响应式布局、浅色/深色模式、中英文切换、主题实时预览、下载与导入 JSON

### 动画库说明

页面默认通过 CDN 加载以下库：

- `https://unpkg.com/aos@2.3.1/dist/aos.css`
- `https://unpkg.com/aos@2.3.1/dist/aos.js`
- `https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/gsap.min.js`
- `https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/ScrollTrigger.min.js`

若需要完全离线部署，可将这些依赖下载到本地后替换为本地路径。

## V1.1 测试与注意事项

详细结果参见 `TEST-REPORT.md`。本环境下浏览器直接访问本地 HTTP 地址被策略阻止，已用浏览器内容注入验证页面交互，并通过独立 HTTP 请求确认资源可读取。由于实际服务器端到端访问尚未验证，请在 macOS Safari/Chrome 再做一次部署验收。

Loading 新增 2 秒自动退出保护；辅助动效尊重 `prefers-reduced-motion`。


## V1.2 背景视觉精修

根据用户提供的两张长页面参考图，重制水墨背景并拆成三个网页区块资产：`landscape-hero.webp`（页首）、`landscape-section.webp`（内容过渡）、`landscape-footer.webp`（底部山水）；原图 `landscape-master.webp` 保留方便后续裁切。新版取消此前大面积不透明米白遮罩，保留山体、树木、雾气的清晰细节。深色模式沿用 `ink-bg-dark.png`，保证暗色可读性。

提示：背景是基于高清生成素材的区域化重构，并非参考图原图像素级提取。第三方动画脚本加载需要互联网。
