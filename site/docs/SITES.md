# WeGit Sites

这是2026-10-27首次发布的历史来源与恢复记录，2026-11-03从旧WIP提取保留。项目标识、源码/版本及部署标识沿用原记录；本次没有重新查询Sites线上状态或执行发布。官网主入口已迁为TanStack Start/Cloudflare Workers，以下方法用于保留的静态/Sites路径。

- 项目：`appgprj_6ae060717260819187b9e0c9d4629e20`
- 域名：`https://wegit.civilreed24.chatgpt.site`
- 首次发布源码：`f41cfb7b717337a0a5908ab387c4f0197f857323`
- 已保存版本：`appgprj_6ae060717260819187b9e0c9d4629e20~appgver_766e257ae8688191ade25a932c632507`
- 部署：`appgdep_6ae0614ebed881919408613d7d249d96`（结果见项目 HANDOFF.MD）
- 访问范围：创建时默认仅本人可见，未修改分享权限。

独立发布目录为 `.build/sites/wegit-web/`，其中 `.openai/hosting.json` 保存项目与 `static.directory=dist`。此目录是独立的 Sites Git 仓库；主工作区已有原生应用与网站改动，不将整仓放入 Sites。

更新前用 Sites `get_site` 读取现有项目，并为同一项目申请源码写入凭据，再通过插件 `site-workflow.mjs` 打开源码。如本地发布目录已清理，使用新的空目录从同一 Sites 源码仓库恢复。不要再次创建站点。凭据只放内存，通过 stdin 交给 helper，不写文件。

从公开 GitHub Releases 元数据构建：

```sh
python3 site/scripts/build.py --base-path '' \
  --site-origin https://wegit.civilreed24.chatgpt.site \
  --releases-json .build/sites/public-releases.json \
  --output .build/sites/wegit-web/dist
```

构建器过滤所有草稿；本次仅包含公开 v1.0.0。构建后由 helper 同步精确源码并打包，再保存和部署该提交。首次静态分发 69 个文件、2,467,614 bytes，低于 3,000,000 bytes；压缩包约 2.1 MB。JS 9/9（另含发布行为 11 个场景）、Python 11/11、策略校验通过。新增域名检查覆盖 canonical、alternate、分享图以及拒绝带路径、凭据或不安全字符的 origin。

本地 Codex 浏览器 382px 首页无横向溢出、无损坏图片；Chrome 已检查主题弹窗打开、Escape 关闭与焦点恢复、公开下载地址。中英首页、主题、隐私和 404 文档 HTTP 200，缺失文档返回真实 404；这是本地校验，不代表托管端的 404 路由或网络性能已通过。
