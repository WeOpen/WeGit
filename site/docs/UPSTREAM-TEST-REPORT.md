> Imported author report. Historical evidence only; current acceptance is documented in the project README.

# WeGit Website — V1.1 验证记录

验证日期：2026-10-26

## 已检查
- `app.js` JavaScript 语法检查通过。
- 本地静态资源和两张长页 HTML 均成功通过 HTTP 读取；HTML 资源相对路径完整。
- 使用 Chromium 的内存页面注入方式运行页面（本环境禁止浏览器直接访问本地服务器地址）。
- 首页 1440px 桌面：正常渲染；无 JS 异常；无横向溢出。
- 主题中心 1440px 桌面：正常渲染；无 JS 异常；无横向溢出。
- 首页及主题页 390px 移动端：无 JS 异常、无横向溢出；移动菜单打开和关闭正常。
- 两页面：浅色/深色模式切换、中英文切换通过。
- 主题中心：切换 Ink、调整强调色、下载 `.wegit-theme.json` 通过。
- 太极加载层可退出，并增加 2 秒后备退出机制；尊重 `prefers-reduced-motion`。

## 局限
- 本地服务器运行后的端到端浏览器直接访问由于运行环境访问策略限制而未能验证，采用浏览器内容注入与独立静态资源 HTTP 检查代替。
- 线上 CDN（AOS、GSAP/ScrollTrigger）可达性、不同操作系统的字体、Safari/macOS 实机表现尚未验证；离线时网站仍具备原生 CSS/IntersectionObserver 动效回退。
- macOS 客户端的正式下载地址与主题文件导入协议仍须接入真实应用。
