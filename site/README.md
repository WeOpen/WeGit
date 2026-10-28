# WeGit website

官网主入口已迁为 **TanStack Start + React + TypeScript + Cloudflare Workers**，保留中英文、山水素材、真实客户端截图、10 套原生主题、主题编辑弹窗及原 footer 下方的像素字母 Logo。

## 本地开发

需要 Node.js 22.12+；CI 使用 Node.js 24。依赖版本由 package-lock.json 固定。

```sh
cd site
npm ci
npm run cf-typegen
npm run dev
```

开发地址为 http://127.0.0.1:4178/zh/。Cloudflare Vite 插件在本地 Workers 运行时执行 SSR，支持 HMR 与 ASSETS binding。

```sh
npm run build
npm run preview -- --port 4179
npm run test:worker
npm test
npm run check:budget
```

preview 使用实际生产构建和本地 Workers；重建后必须重启 preview，再刷新浏览器。仅刷新旧进程会继续使用旧 SSR 模块。

## 页面与组件

- src/routes：TanStack 文件路由，英文主页、主题与隐私页及 /zh/ 对应版本。
- src/pages：React 页面；布局与原模板一致。
- src/components：共用页头、页脚、像素 Logo、主题弹窗、导入和导出。
- src/lib：本地双语文案、主题目录和路由元数据。
- src/server.ts：Workers 入口、资源 binding、公开页面缓存、CSP nonce 和兼容跳转。
- scripts/prepare-assets.mjs：从 public 和 design/brand 准备 .generated/ 资源，不修改 canonical 品牌来源。
- dist/client 与 dist/server：Vite 生成的资源与 Worker，由 Cloudflare 插件生成部署配置。

主题文件继续使用 version/name/controls/17 colors 的客户端 v1 格式，最大 64 KiB。文件只在浏览器本地导入；预览与导出使用同一组实际颜色。字体和字号仅影响网页预览。主要工作台图片仍为原生截图，主题预览复用已核对的工作台布局。

浏览器链接使用 TanStack Router；原 themes.html 地址以 308 跳转并保留主题参数。未知页面返回真实 HTTP 404，缺失资源不返回伪装的 HTML 页面。关闭弹窗、Escape 和搜索退出还原触发焦点。

## Cloudflare 部署准备

接入方案依据 [Cloudflare 官方 TanStack Start 文档](https://developers.cloudflare.com/workers/framework-guides/web-apps/tanstack-start/)。

```sh
npm run build
npx wrangler deploy --dry-run
npx wrangler check startup --config dist/server/wrangler.json
```

目前没有上线或创建 Cloudflare 远端资源。正式部署时，在 Cloudflare Workers Builds 中连接该仓库、设置根目录 site，安装命令 npm ci、构建命令 npm run build、部署命令 npx wrangler deploy。为目标域名设置公开构建变量 VITE_SITE_ORIGIN=https://实际域名，生成准确的 canonical、语言 alternate 和分享图片地址。未配置时使用相对地址，不写死另一个托管平台的域名。

本机手动部署使用 Wrangler 登录既有 Cloudflare 账户后执行 npm run deploy。ASSETS 由部署构建管理。后续需要数据库、文件存储、任务队列时，在 wrangler.jsonc 增加 D1、R2、Queues 等 binding，重新运行 npm run cf-typegen，再通过服务端代码使用 binding；当前没有业务需求的资源不预先创建。私密值通过 Wrangler secrets 配置，禁止放入 VITE_ 变量或提交到代码。

## 运行开销与验证

公开营销页面使用按构建版本隔离的 5 分钟 Workers Cache API 缓存；Cookie、Authorization、Set-Cookie 与非公开路径不进入该缓存。HTML 在浏览器中重新验证，哈希 JS/CSS 长期缓存，未哈希品牌素材与主题文件重新验证。SSR 按请求创建 Router 与 CSP nonce，没有共享可变请求状态；缓存写入使用 waitUntil。

项目预算：分发资源 3 MB、CSS 总量 64 KiB、全部客户端 JS 合计 gzip 150 KiB、Worker 模块合计 gzip 512 KiB。构建后 check:budget 会执行这些预算。页面和页脚动效尊重减少动态效果；像素时钟离屏/隐藏暂停，React 卸载时解除观察器和事件监听。字号调整不会重建主题列表的工作台 DOM。

workers.yml 在 GitHub-hosted CI 上执行锁定依赖安装、测试、类型生成、构建、部署 dry-run、预算和本地 Worker HTTP 检查；没有远端部署任务。

当前锁定的 Vite 8 在 SSR CSS 构建中仍会输出一条 css-post 源码映射警告；类型、构建和运行检查通过。该诊断不作为零警告或线上性能通过的声明。兼容日期使用已安装 workerd 实际支持的 2026-10-26，本机时间更新不自动改变运行时支持范围。

## 静态兼容入口

旧 Python 模板和 GitHub Pages 工作流保留为静态兼容路径，不能用其通过证明 Workers 应用已验证：

```sh
npm run build:legacy
npm run test:legacy
```

现有 Sites 与 Pages 发布说明属于该静态路径。后续切换生产托管需单独完成真实 Cloudflare 域名、权限、缓存和线上性能验收。
