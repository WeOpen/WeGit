# ✅ WeGit V1.0 当前发布清单

**2026-10-19 发布决定：维护者要求暂缓辅助功能并直接发布 v1.0.0。** 本表保留质量跟进项；本次一次性例外、实际验证范围与未完成项见[版本说明](releases/v1.0.0.md)。下方 P0 是此前完整验收标准，不再作为本次获准发布的等待条件，也不因此标记通过。

历史基线更新：2026-10-18。此表按当前证据汇总发布前剩余事项，不把 PLAN 中的未勾选数量当作缺失功能数量。历史回合保留其源码与失败记录，不能用旧通过替代最终源码验收。

## 📦 当前分发决定

- **渠道：GitHub Releases＋项目网站**；不发布到 Mac App Store，不使用 TestFlight。
- **网站：GitHub Pages**，地址为 [weopen.github.io/WeGit](https://weopen.github.io/WeGit/)，没有自定义域名。公开访问证据由 Issue #8 和站点验收记录跟进。
- **账号：没有 Apple Developer Program 账号**。当前路线为无 Developer ID、未公证的直接分发，保留 ad-hoc 签名和来源回执；Developer ID／公证属于将来的可选升级，不作为本路线的账号前置依赖。
- **许可证与标识：MIT**；正式标识 `com.willxue.wegit`，当前开发包标识 `com.willxue.wegit.development`。
- 无账号分发不等于通过系统默认信任。ad-hoc 不证明开发者身份，实际浏览器下载后的 Gatekeeper 首启行为与用户安装说明必须在干净目标机器验收。参考 [Apple Developer ID](https://developer.apple.com/developer-id/) 与 [Apple 安全打开说明](https://support.apple.com/zh-cn/102445)。

## 🔎 当前基线

| 已有结果 | 证据与边界 |
| --- | --- |
| 三套 Git 各 183 项核心测试 / 32 套件通过 | Apple Git 2.54.0、私有 Git 2.46.0，以及新增 Homebrew Git 2.56.0；[OpenPGP / Homebrew 验收](acceptance/2026-10-17/git-signing/README.md)。Apple / Homebrew 各 7 项非交互 OpenPGP 及清理也已通过。 |
| 278 项主题、18 项图标、27 项原生菜单行为通过 | 原有 34 项主题行为保留，加 216 个真实角色/背景色对与 28 个源色相检查；[配色 UI 与 VM 记录](acceptance/2026-10-18/native-ui/contrast-ui-results/README.md)。系统显示选项的实际切换另验。 |
| Debug / 普通 Release、格式与源码回执通过 | 最新普通 Release CI 39138069932 的全部 120 项应用输入匹配功能所测 2c2533c；不等于正式制品下载/安装或 Release 性能签收。 |
| 完整自动原生 UI 45/45、阅读 144/144 通过 | 固定 main `2c2533c`，先 smoke 1/1，再功能 45/45，零失败/跳过；144 个精确组合无缺失/重复，内存/磁盘各 72。[完整原始结果与范围](acceptance/2026-10-18/native-ui/final-functional/README.md)。这不替代辅助访问、性能或受保护目标机安装。 |
| GitHub HTTPS / SSH 真实传输已有完整验收 | Push、核对、Clone、Fetch、仅快进 Pull、过期 Lease 拒绝；[兼容性第 6 节](COMPATIBILITY.md#6-获准-github-仓库的完整传输验收2026-10-11)。其他服务/认证环境仍待验。 |
| 历史普通仓库 30 次 Release 五项预算通过 | Status P95 295.19 ms、Diff 141.40 ms；[性能第 12 节](PERFORMANCE.md#12-索引修复后普通仓库的完整验收)。该旧源码结果不覆盖后续 UI/主题改动。 |
| 远端项目状态已重新读取 | 2026-10-16 用户授权后仓库已公开，默认 main，尚无 Release；托管 CI 已启用，专用交互 Runner 仍为 0。配置见 [PR #10](https://github.com/WeOpen/WeGit/pull/10)，稳定化见 [PR #14](https://github.com/WeOpen/WeGit/pull/14)。 |

## 🚧 发布前剩余事项

| 优先级 | 未完成事项 | 完成标准 / 依赖 |
| --- | --- | --- |
| P0 | **辅助访问与显示选项** | 配色后实际审查仍有 55 条待判定回调（说明 22、动作 14、对比度 19），旧 59/44 条保留原来源；独立 SDK 对照复现部分报告，不统一忽略。完成 VoiceOver、完整键盘、实际阅读、减少透明度/动态效果与增强对比度并恢复设置。[辅助访问记录](ACCESSIBILITY.md)。 |
| P0 | **最终源码完整性能** | 固定夹具和冷热条件，串行至少 30 次 Release 采样；普通外壳 <500 ms、Status <300 ms、Diff <150 ms、History <300 ms、外部稳定更新 <1 s。补复杂图、十万级内存/滚动、磁盘 Diff、取消响应；用 signpost/Instruments 定位实际热点。[性能记录](PERFORMANCE.md)。 |
| P0 | **兼容性与真实工作流边界** | Homebrew 核心与非交互 OpenPGP 已有实际证据；继续补真实 Pinentry/硬件密钥、Helper/签名组合、GitLab/通用服务与未覆盖系统/显示器条件，统一复核权限失效、排队/取消/关闭/切换后的权威状态、草稿、冲突恢复。已有 GitHub 验收不重复标为缺失。[兼容性矩阵](COMPATIBILITY.md)、[PLAN](PLAN.md)。 |
| P0 | **专用完整验收 Runner** | 常规托管 CI 和完整自动功能已实际执行通过；自托管 Runner 仍为 0。现有 hosted VM 原始 SIP disabled / Gatekeeper enabled，仅作功能诊断，不能替代受保护机器的完整验收、性能与安装。需要配置既有受信任 main 专用标签；不修改本机或 VM 的保护设置。[环境记录](NATIVE_VALIDATION.md)。 |
| P0 | **无账号的正式制品与干净机器安装** | 正式 ID 的 `--adhoc` 打包路径已完成并实测；仍需最终版本、开发偏好与数据迁移、更新/回退说明；版本化 ZIP、SHA-256、manifest、AskPass/许可/权限核对。通过实际 HTTPS 下载→解压/安装→首次系统提示→打开仓库/提交/同步完整流程，不能用同机本地产物启动代替。此项不依赖购买开发者账号。 |
| P0 | **可公开访问的 GitHub 和网站渠道** | 仓库已公开，Issue/PR 与草稿发布流程已配置。网站代码、双语页面与 Pages 部署流程已建立，下载仅引用同一版本 GitHub 资产；仍需实际公开 Release 与文件下载/校验和验证。站点上线不等于应用发布。 |
| P0 | **真实 Beta 与 V1.0 发布收尾** | 按计划约 10～30 名用户，取得名单与发送授权后邀请；记录并关闭发布阻塞反馈。完成版本说明、已知限制、安装/升级/回退与数据说明，再对最终制品统一签收和发布。当前没有 Beta 反馈记录。 |

## 📝 已更新与不属于本次阻塞的事项

- [x] 默认英文 [README](../README.md) 和[中文 README](../README.zh-CN.md)，顶部居中 Logo、静态状态徽章与互链。
- [x] 明确 GitHub＋网站、无商店、无开发者账号的当前分发决定，并同步 PLAN、发布操作及架构。
- [ ] 最终发布时将 README 中的“开发预览／无已发布版本”替换为真实版本与已上线网址；补最终版本说明。当前文档结构完成不代表所有发布文案已签收。
- **未来可选：** Developer ID、Apple 公证与装订。保留工具支持，但不再因账号缺失阻塞本路线。
- **后续产品版本：** Stash / Tag 管理、内置冲突编辑器、Interactive Rebase、Blame、Worktree/Submodule 管理、Provider / AI；不临时加入 V1.0 P0。

完整分阶段计划仍见 [PLAN](PLAN.md)。仅在实现和对应验证证据都完整时关闭门槛；分发渠道改变不会自动关闭质量、兼容性或安装验收。

## 🧭 Issue 入口

首版收尾以 [V1.0 milestone](https://github.com/WeOpen/WeGit/milestone/1) 管理。#2 UI、#3 辅助访问、#4 性能、#5 兼容性、#6 交互 Runner、#7 安装、#8 网站、#9 Beta/发布；[最新应用源码接入 #12](https://github.com/WeOpen/WeGit/issues/12) 已完成；[CI 稳定化 #13](https://github.com/WeOpen/WeGit/issues/13) 已在复验通过后关闭。创建需求与 PR 的规则见 [贡献说明](../CONTRIBUTING.md)。
