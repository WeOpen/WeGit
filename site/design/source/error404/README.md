# 404 水墨插画母版

用户参考是本次提供的 1122×1402 页面原型 `codex-clipboard-05e31f7e-619c-4759-8d6d-27b9c52d1e53.png`，在本目录留存为 `reference.png`。主景和页尾分别交由内置 `image_gen` 生成，浅深色均有独立生成原件。

| 母版 | 原生像素 | 发布衍生图 |
| --- | --- | --- |
| hero-light-native.png | 1468×1071 | hero-light.webp |
| hero-dark-native.png | 1469×1071 | hero-dark.webp |
| footer-light-native.png | 2172×724 | footer-light.webp |
| footer-dark-native.png | 2172×724 | footer-dark.webp |

主景包含笔墨 4–太极–4、山水、仙鹤、亭台和朱砂落叶；页尾包含两岸山景与一叶舟。页面标题、说明、按钮、卡片及品牌不是图片中的伪 UI，均由 HTML 或现有品牌资源呈现；「庫」印章使用品牌 SVG。

工具实际返回主景约 1.5K 宽，不能将请求过的更大尺寸写成真实分辨率。四张原件和 WebP 均未插值放大。WebP 以原生尺寸、质量 90 导出，清单 `assets.json` 记录实际像素、发布字节与工具来源。母版不进入静态发布目录。

深色画面不是 CSS 反色。不同生图间的笔触、山峰及舟形会有变化；页面采用同一布局，并对较高页尾山峰作 CSS 透明度渐隐，使它不干扰上方卡片和中央品牌。
