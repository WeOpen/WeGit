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

目前没有上线或创建 Cloudflare 远端资源。当前 `.github/workflows/workers.yml` 只运行测试、构建、预算、dry-run 与本地 Worker 检查，不会发布；`.github/workflows/pages.yml` 发布的是旧静态 GitHub Pages。

推荐使用 Cloudflare Workers Builds 连接 GitHub 自动发布：

1. 将经过 PR 检查的官网分支合入 main；本地未推送的提交不会被 Cloudflare 读取。
2. Cloudflare 控制台 → Workers & Pages → Create application → GitHub，连接 WeOpen/WeGit。选择 Worker 项目，名称 `wegit-site`（与 wrangler.jsonc 一致）。
3. 设置生产分支 `main`、Root directory `site`；使用 Node 24（构建变量 `NODE_VERSION=24`）。依赖由平台安装，锁文件在 site/package-lock.json；本地或自建 CI 使用 `npm ci`。
4. Build command：`npm test && npm run build && npm run check:budget`。Deploy command：`npx wrangler deploy`。部署包含 Worker 与 ASSETS，不是只上传 dist/client 的静态站点。
5. 公开构建变量 `VITE_SITE_ORIGIN=https://实际域名` 用来生成 canonical、语言 alternate 与分享图片地址。必须在构建时设置；未配置时使用相对地址。
6. 首次发布核对 workers.dev 地址；在 Worker 的 Settings → Domains & Routes 接入正式域名后，用正式域名重建验证。GitHub main 后续新提交会触发 CF Builds。构建监听路径若启用，至少覆盖 `site/**` 与 `design/brand/**`，后者是素材生成输入。

Workers Builds 与 GitHub Actions 部署择一作为生产发布入口，避免同一提交重复发布。若需要严格等 GitHub CI 成功才部署，可改用现有 build job 成功后的 deploy job，仅 main push/受控手动触发时运行；在 GitHub Secrets 配置 `CLOUDFLARE_API_TOKEN` 与 `CLOUDFLARE_ACCOUNT_ID`，从 site 执行 `npx wrangler deploy`，或使用 cloudflare/wrangler-action。仅配置 Secrets 不会让当前 workflow 自动发布。

参考：[Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)、[构建设置](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/)、[GitHub Actions](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/)。

手动发布：在包含最新官网提交的 site 目录运行 `npm ci`、`npx wrangler login`，再以实际域名设置 `VITE_SITE_ORIGIN` 后执行 `npm run deploy`。该脚本已包含 build，不能只 deploy 旧产物。首次可先 build → check:budget → wrangler deploy --dry-run 复核。

本机手动部署使用 Wrangler 登录既有 Cloudflare 账户后执行 npm run deploy。ASSETS 由部署构建管理。后续需要数据库、文件存储、任务队列时，在 wrangler.jsonc 增加 D1、R2、Queues 等 binding，重新运行 npm run cf-typegen，再通过服务端代码使用 binding；当前没有业务需求的资源不预先创建。私密值通过 Wrangler secrets 配置，禁止放入 VITE_ 变量或提交到代码。

## 运行开销与验证

公开营销页面使用按构建版本隔离的 5 分钟 Workers Cache API 缓存；Cookie、Authorization、Set-Cookie 与非公开路径不进入该缓存。HTML 在浏览器中重新验证，哈希 JS/CSS 长期缓存，未哈希品牌素材与主题文件重新验证。SSR 按请求创建 Router 与 CSP nonce，没有共享可变请求状态；缓存写入使用 waitUntil。

项目预算：分发资源 3 MB、CSS 总量 64 KiB、全部客户端 JS 合计 gzip 150 KiB、Worker 模块合计 gzip 512 KiB。构建后 check:budget 会执行这些预算。页面和页脚动效尊重减少动态效果；像素时钟离屏/隐藏暂停，React 卸载时解除观察器和事件监听。字号调整不会重建主题列表的工作台 DOM。

页面使用 Motion 的 mini 入口，通过原生合成动画实现 Hero 文字和滚动标题、卡片、图标的入场；主截图保持完整可见。入场在每个页面元素重新进入视口时播放（完全离开后重置），键盘聚焦会立即完成，切页时取消并还原样式。装饰印章只在可见且页面未隐藏时浮动。

底部像素字标保持同一份缓存，W/e/G/i/t 按 140ms 间隔依次浮现，每字 520ms，完成后仅保留原有轻微像素流动。减少动态效果时立即显示全部字母；离屏/隐藏暂停，切换外观或缩放布局不重新播放已完成的字母入场。

workers.yml 在 GitHub-hosted CI 上执行锁定依赖安装、测试、类型生成、构建、部署 dry-run、预算和本地 Worker HTTP 检查；没有远端部署任务。

当前锁定的 Vite 8 在 SSR CSS 构建中仍会输出一条 css-post 源码映射警告；类型、构建和运行检查通过。该诊断不作为零警告或线上性能通过的声明。兼容日期使用已安装 workerd 实际支持的 2026-10-26，本机时间更新不自动改变运行时支持范围。

## 静态兼容入口

旧 Python 模板和 GitHub Pages 工作流保留为静态兼容路径，不能用其通过证明 Workers 应用已验证：

```sh
npm run build:legacy
npm run test:legacy
```

现有 Sites 与 Pages 发布说明属于该静态路径。后续切换生产托管需单独完成真实 Cloudflare 域名、权限、缓存和线上性能验收。
