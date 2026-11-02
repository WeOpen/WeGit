# v1.2 完整原生回归的失败与恢复

main `9ee1ab243ed7d886de78cde91882121fd5fb1e2f` 已包含 PR #87 的最终实现。当前收口仍需要完整 functional 实际通过；本页保留该主线的失败和同源单项诊断，最新候选、主线重跑及清理结果跟踪 [#98](https://github.com/WeOpen/WeGit/issues/98)。

| 执行 | 实际结果 |
| --- | --- |
| [完整 functional 41368232586](https://github.com/WeOpen/WeGit/actions/runs/41368232586) | smoke 1/1/0/0。Blame 在关闭来源提交后打开文件历史，`file-history-path` AX 查询超时；随后 ChangesList 用例停止进展。5400 秒外层截止触发，functional xcresult 未完成，job 在120分钟取消。不能提供完整套件通过计数。 |
| [同源 smoke + Blame 41383018010](https://github.com/WeOpen/WeGit/actions/runs/41383018010) | smoke 与专项各1/1/0/0，专项 summary 67.605秒，194输入逐SHA一致；完整ZIP 62,923,408bytes、2045个CRC、临时显示恢复均核验。该结果只覆盖一个用例。 |

原始失败 [回执](functional-41368232586-failed.json) 和同源专项 [回执](blame-main-41383018010-verified.json) 分别保留。ZIP、完整日志、xcresult 与导出的截图位于主检出 `.build/v1-2-closeout-2026-11-02/`，也由对应 Actions artifact 保存。

完整 scope 之前只设置了90分钟进程组上限，现沿用专项的 XCTest 默认120秒、最大180秒单用例边界。新增 Python 契约先复现缺失设置，再确认设置修正、失败后的报告保留及完整范围选择；本机全量74项 Python检查通过，原生只编译，XCTest仍在托管环境执行。

Blame 的历史 Sheet 宽1080，超过980宽父窗口。父窗口截图会裁掉该 Sheet 边缘；这不是产品内容被裁剪的证明。该步骤改为完整屏幕截图，并断言路径和关闭按钮可操作。原固定历史路径/提交、原始字节、分页、Escape、草稿、HEAD、index及工作文件断言全部保留。

应用和 Core 源码保持同源；候选变更只涉及可信测试驱动、Blame用例的额外检查/截图和文档。仍须当前必需CI、可信候选专项、正常集成后完整functional及实际制品核验。正式发布和 [维护者明确延期的验收](../../2026-11-01/v1-2-closeout/README.md) 保留各自边界。
