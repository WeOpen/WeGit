# 首窗修正收尾与功能回归准备

2026-10-18，对应 Issue #2 / #6。PR #19 最终 head `84df3ed49635fa0e8bc35c8d723e821816954b81` 的原始回执已下载核对：

- [产品 smoke 39011174351](https://github.com/WeOpen/WeGit/actions/runs/39011174351)：实际执行 1、通过 1、失败 0、跳过 0，测试区间 17.589 秒。报告、摘要和 Debug 应用回执见 `final-head-smoke*` 与 `final-head-build-source.json`。
- [独立重排回归 39010912745](https://github.com/WeOpen/WeGit/actions/runs/39010912745)：实际执行 1、通过 1、失败 0、跳过 0；应用未启用 sandbox，UI runner sandbox 保持启用，见 `final-head-scene.json`。
- [最终 CI 39010946472](https://github.com/WeOpen/WeGit/actions/runs/39010946472)：全部通过，PR 合并快照 `4b7d789653052fb0b52fff3cf8e53bcaf0546953`。主题 34、图标 18、菜单 27，以及两组各 7 项 OpenPGP 与夹具/私有服务清理的原始报告均已核对；Debug/Release 回执全部 120 项应用输入与本机一致。
- [PR #19](https://github.com/WeOpen/WeGit/pull/19) 已按分支保护 Squash 合入 main `4a9f47523277b2dc78a216b538ca3249099222df`，见 `startup-merge.json`。

完整功能执行前，发现托管 `functional` 入口选中了 opt-in 的 `ManualAccessibilitySession`；该工作区在未显式开启时执行 XCTSkip，而驱动要求所有所选测试零跳过。现与 Full acceptance 一致，仅从自动功能范围排除人工工作区，保留单独自动辅助访问审查与人工验收。新的选择范围回归在修正前实际失败、修正后通过；27 项工具测试、actionlint、仓库契约与 diff 检查通过。这些是工具测试，不计为产品功能 XCTest。

原始 xcresult、启动状态、日志与截图仍在各 Actions artifact 及本机 `.build/continuation-pr19-*`。托管 VM 原 SIP 关闭、Gatekeeper 开启，没有修改系统保护。本轮不签收 VoiceOver、完整性能、干净机器安装或发布；完整功能与 144 阅读组合等待主分支执行。
