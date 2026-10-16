# GitHub Issue 工作流与 CI/CD 验收

日期：2026-10-16。仓库 WeOpen/WeGit。用户明确允许设为 public；发布仍仅 GitHub＋项目网站、无商店/无开发者账号。

## 实施范围

通过专用管理工作树从已提交 main 创建独立 PR，不把原开发工作区未提交的应用、主题、图标、双语 README、历史证据和 .spec-workflow 混入。主工作区保留并同步新 CI 工具，最新应用接入单独用 Issue #12 管理。

- 公开前审查 165 个已提交文件和一个提交历史。gitleaks 8.30.1 的两条疑似项逐一核对为源码 SHA-256，精确指纹例外后通过；没有按整个目录忽略。
- 仓库已 public；默认 token 降为只读，关闭 Actions 自动批准 PR；main 要求三个来自 GitHub Actions 的检查，管理员受约束，禁止强推/删除、要求会话解决与线性 Squash。
- 三类 Issue 表单、PR 模板、21 个受管标签、V1.0/V1.1 里程碑、幂等初始化和 P0 Issues 已建立。元数据 workflow 实际执行通过，重复迁移计划为 0；不会覆盖人工内容或重开闭合事项。
- CI 分为 PR policy、Repository policy、托管 xcode-27 Native macOS；完整交互验收独立手动，仍需要专用 Runner。
- 提供正式 Bundle ID 的 --adhoc 路径，无需 Apple 证书；只读构建/来源/ZIP/权限核对与单独 contents:write 的草稿创建隔离。稳定标签需同一 SHA 的规范 CI 与完整验收；没有自动创建版本 tag、公开 Release 或部署网站。

## 验证与失败保留

PR #10 通过三个托管检查后按保护规则 Squash 合并。main 首轮暴露测试过度并行造成的隔离探针超时；PR #14 初轮又暴露 xcodebuild -version | head 导致 Broken pipe。失败记录保留在 failed-*.json 和两个 excerpt 文件。

修正只改变 CI 外层用例调度及工具版本输出消费：内部 TaskGroup 并发、队列、取消、超时断言、OS/架构/SDK 门槛与性能预算不变。增加延迟双行输出和错误环境拒绝回归，19 项工具行为通过。PR #14 的托管 Native macOS 完整通过，用时 8 分 31 秒，两个 Git 各 175 项 / 31 套件通过；UI 只编译，未宣称执行。普通本地运行不设串行标志时保持原调度。

本地显式串行 175 项通过（52.509 s），16-task 探针用例 0.006 s，Debug/UI 编译与正式 ID ad-hoc 打包通过。干净签出下实际包经 prepare 校验，未生成真实 tag 或 Release。当前主工作区 183 项源代码仍未进入本次远端基线，不能互换证据。

main 合并提交 `5f647fa151fff211bcc639f2fc091f88a1e61478` 在 [run 38881671955](https://github.com/WeOpen/WeGit/actions/runs/38881671955) 最终全绿，详见 validation.json 与 final-main-ci.json；完整交互验收、干净机器、Beta 和最终 V1.0 发布不在本轮通过范围。

## 入口

- [方案与操作](../../../GITHUB_WORKFLOW.md)
- [贡献说明](../../../../CONTRIBUTING.md)
- [PR #10](https://github.com/WeOpen/WeGit/pull/10) / [稳定化 PR #14](https://github.com/WeOpen/WeGit/pull/14)
- [V1.0 里程碑](https://github.com/WeOpen/WeGit/milestone/1) / [最新应用接入 #12](https://github.com/WeOpen/WeGit/issues/12)

本目录保存配置快照、工具源码摘要、局部日志与远端运行链接；完整 CI 日志/测试结果留在对应 Actions artifact。Apple 账户、凭据、系统保护和主工作区应用偏好未因此修改。

专用工作树已通过 Codex 归档，并由 `list_artifacts` 确认为 `archived_worktree`。必要 manifest、失败摘要和验收证据已保存在本目录；临时旧基线构建产物不作交付。主开发包再次通过来源核对，原应用改动与 `.spec-workflow` 保留。核对时远端没有版本 tag 或 Release，详见 [清理回执](worktree-cleanup.json)。
