# 双语 README 与发布路线核对

日期：2026-10-16。本轮仅修改文档，未更改应用源码、构建配置、签名逻辑或运行偏好，未提交、推送、修改仓库可见性、发布 Release 或部署网站。

- 默认 README.md 为英文，新增 README.zh-CN.md，居中第二版 Logo、六个静态徽章、语言互链与 emoji 分节。
- 不展示未经验证的 CI passing / V1.0 / 已公证徽章。当前 0.1.0、私有仓库、无 Release、无网站状态有明确说明。
- 用户确认仅 GitHub＋网站、无商店/无开发者账号；同步 PLAN、PRD、架构、发布操作、索引和开发记录。保留历史验收时点，Developer ID／公证改为将来可选，实际下载与干净机器门槛保留。
- 当前剩余工作集中到 [V1.0 发布清单](../../../V1_RELEASE_CHECKLIST.md)，已有 GitHub 传输和旧性能通过不冒充缺失或最终源码通过。
- 169 处本地文件引用通过；六个徽章返回 HTTP 200 和有效 SVG。中英 README 均经 CommonMark＋表格解析生成本地预览，未添加项目依赖。
- 浏览器视觉预览未通过：本机预览连接超时，Chrome 不可用，自包含 data URL 被 URL 安全策略拒绝。未绕过策略或继续尝试浏览器替代路径，未宣称已完成浏览器视觉验收。本地渲染文件保留在 .build/readme-preview/。
- 应用本轮未改动，无需重复核心/UI 测试；此前通过结果保留其原始来源。

结构、引用、徽章与源码摘要见 [validation.json](validation.json)。只读远端快照见同目录 github-*.json；观察时仓库私有、无 Release、Runner 0、最近 CI cancelled。网站尚未上线为用户直接确认。
