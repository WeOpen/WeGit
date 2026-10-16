# ✅ WeGit V1.0 当前发布清单

更新：2026-10-16。此表按当前证据汇总发布前剩余事项，不把 PLAN 中的未勾选数量当作缺失功能数量。历史回合保留其源码与失败记录，不能用旧通过替代最终源码验收。

## 📦 当前分发决定

- **渠道：GitHub Releases＋项目网站**；不发布到 Mac App Store，不使用 TestFlight。
- **网站：尚未上线**，暂不填写域名或占位链接。
- **账号：没有 Apple Developer Program 账号**。当前路线为无 Developer ID、未公证的直接分发，保留 ad-hoc 签名和来源回执；Developer ID／公证属于将来的可选升级，不作为本路线的账号前置依赖。
- **许可证与标识：MIT**；正式标识 `com.willxue.wegit`，当前开发包标识 `com.willxue.wegit.development`。
- 无账号分发不等于通过系统默认信任。ad-hoc 不证明开发者身份，实际浏览器下载后的 Gatekeeper 首启行为与用户安装说明必须在干净目标机器验收。参考 [Apple Developer ID](https://developer.apple.com/developer-id/) 与 [Apple 安全打开说明](https://support.apple.com/zh-cn/102445)。

## 🔎 当前基线

| 已有结果 | 证据与边界 |
| --- | --- |
| 两套 Git 各 183 项核心测试 / 32 套件通过 | Apple Git 2.54.0、私有 Git 2.46.0；[主题轮完整验证](acceptance/2026-10-16/custom-themes/README.md)。最新图标轮核对核心输入未变，没有冒充重跑。 |
| 34 项主题、18 项图标、27 项原生菜单行为通过 | 不同专项分别记录；[主题](acceptance/2026-10-16/custom-themes/README.md)与[图标](acceptance/2026-10-16/dock-scale-material/README.md)。 |
| Debug / 普通 Release、格式、可追溯开发包通过 | 最近图标轮源码摘要 `6fbcded9970a9bb44ea7383051f84a3f0cb515e0934f11e2494fa2990c2acbda`；[开发包记录](acceptance/2026-10-16/dock-scale-material/README.md)。 |
| 6 种恢复启动与部分实际 UI 检查通过 | 属于存活、恢复及局部交互检查，不代表完整 XCTest 或辅助访问通过。 |
| GitHub HTTPS / SSH 真实传输已有完整验收 | Push、核对、Clone、Fetch、仅快进 Pull、过期 Lease 拒绝；[兼容性第 6 节](COMPATIBILITY.md#6-获准-github-仓库的完整传输验收2026-10-11)。其他服务/认证环境仍待验。 |
| 历史普通仓库 30 次 Release 五项预算通过 | Status P95 295.19 ms、Diff 141.40 ms；[性能第 12 节](PERFORMANCE.md#12-索引修复后普通仓库的完整验收)。该旧源码结果不覆盖后续 UI/主题改动。 |
| 远端项目状态已重新读取 | 2026-10-16 用户授权后仓库已公开，默认 main，尚无 Release；托管 CI 已启用，专用交互 Runner 仍为 0。配置见 [PR #10](https://github.com/WeOpen/WeGit/pull/10)，稳定化见 [PR #14](https://github.com/WeOpen/WeGit/pull/14)。 |

## 🚧 发布前剩余事项

| 优先级 | 未完成事项 | 完成标准 / 依赖 |
| --- | --- | --- |
| P0 | **恢复完整原生 UI 执行并统一回归** | 在可用交互登录环境先跑最小用例，再跑完整功能、144 阅读组合和专项。旧完整回合为 36/37；Clone 长路径输入失败仍需关闭。最终中英、内置/自定义主题、复制/缓存、分页、恢复与任务生命周期使用同一稳定源码验收。[开发记录](DEVELOPMENT.md)、[旧最终状态](acceptance/2026-10-11/final-validation.json)。 |
| P0 | **辅助访问与显示选项** | 逐条处理原 44 条待判定自动报告；完成 VoiceOver、完整键盘、实际对比度、减少透明度/动态效果与增强对比度；记录例外及系统设置恢复。[辅助访问记录](ACCESSIBILITY.md)。 |
| P0 | **最终源码完整性能** | 固定夹具和冷热条件，串行至少 30 次 Release 采样；普通外壳 <500 ms、Status <300 ms、Diff <150 ms、History <300 ms、外部稳定更新 <1 s。补复杂图、十万级内存/滚动、磁盘 Diff、取消响应；用 signpost/Instruments 定位实际热点。[性能记录](PERFORMANCE.md)。 |
| P0 | **兼容性与真实工作流边界** | 补 Homebrew Git/GPG、Helper/签名组合、GitLab/通用服务与未覆盖系统/显示器条件；统一复核权限失效、排队/取消/关闭/切换后的权威状态、草稿、冲突恢复。已有 GitHub 验收不重复标为缺失。[兼容性矩阵](COMPATIBILITY.md)、[PLAN](PLAN.md)。 |
| P0 | **完整验收 Runner 与最新应用 CI** | 常规托管 CI 已在 [main 实际通过](https://github.com/WeOpen/WeGit/actions/runs/38881671955)，调度/工具链修正已合并。专用交互 Runner 仍为 0，需配置并通过完整验收；最新应用已在 [PR #15](https://github.com/WeOpen/WeGit/pull/15) 经 [#12](https://github.com/WeOpen/WeGit/issues/12) 接入新 CI，结果按其提交记录，不能把基线通过移作新代码证据。 |
| P0 | **无账号的正式制品与干净机器安装** | 正式 ID 的 `--adhoc` 打包路径已完成并实测；仍需最终版本、开发偏好与数据迁移、更新/回退说明；版本化 ZIP、SHA-256、manifest、AskPass/许可/权限核对。通过实际 HTTPS 下载→解压/安装→首次系统提示→打开仓库/提交/同步完整流程，不能用同机本地产物启动代替。此项不依赖购买开发者账号。 |
| P0 | **可公开访问的 GitHub 和网站渠道** | 仓库已公开，Issue/PR 与草稿发布流程已配置。仍需实际创建和核对正式制品、公开 Release、下载/帮助入口及网站上线，链接同一版本资产及校验和；没有自动发布应用或站点。 |
| P0 | **真实 Beta 与 V1.0 发布收尾** | 按计划约 10～30 名用户，取得名单与发送授权后邀请；记录并关闭发布阻塞反馈。完成版本说明、已知限制、安装/升级/回退与数据说明，再对最终制品统一签收和发布。当前没有 Beta 反馈记录。 |

## 📝 已更新与不属于本次阻塞的事项

- [x] 默认英文 [README](../README.md) 和[中文 README](../README.zh-CN.md)，顶部居中 Logo、静态状态徽章与互链。
- [x] 明确 GitHub＋网站、无商店、无开发者账号的当前分发决定，并同步 PLAN、发布操作及架构。
- [ ] 最终发布时将 README 中的“开发预览／无已发布版本”替换为真实版本与已上线网址；补最终版本说明。当前文档结构完成不代表所有发布文案已签收。
- **未来可选：** Developer ID、Apple 公证与装订。保留工具支持，但不再因账号缺失阻塞本路线。
- **后续产品版本：** Stash / Tag 管理、内置冲突编辑器、Interactive Rebase、Blame、Worktree/Submodule 管理、Provider / AI；不临时加入 V1.0 P0。

完整分阶段计划仍见 [PLAN](PLAN.md)。仅在实现和对应验证证据都完整时关闭门槛；分发渠道改变不会自动关闭质量、兼容性或安装验收。

## 🧭 Issue 入口

首版收尾以 [V1.0 milestone](https://github.com/WeOpen/WeGit/milestone/1) 管理。#2 UI、#3 辅助访问、#4 性能、#5 兼容性、#6 交互 Runner、#7 安装、#8 网站、#9 Beta/发布；[最新应用源码接入 #12](https://github.com/WeOpen/WeGit/issues/12) 单独跟进；[CI 稳定化 #13](https://github.com/WeOpen/WeGit/issues/13) 已在复验通过后关闭。创建需求与 PR 的规则见 [贡献说明](../CONTRIBUTING.md)。
