# WeGit v1.2 开发与证据收口

本轮继续完成 V12-01～V12-09 的开发源码、可执行验证与正常 PR 集成。正式发布验收与下列延期条件保持独立；Issue 关闭原因区分 `completed` 和 `not_planned`。

## 用户确认延期的验收条件

2026-11-01，维护者确认 #3/#6/#7/#9，以及后续核对的 #4/#5 按延期归档处理。所有历史失败和未完成样本保留，不将缺少设备、账号、真实使用者或完整最终测量改写为通过。

| Issue | 延期条件与恢复时的标准 |
| --- | --- |
| [#3](https://github.com/WeOpen/WeGit/issues/3) | 完整 VoiceOver 朗读、焦点与辅助访问验收；必须在真实可控交互环境保留实际朗读/操作证据。已有 AX 名称、键盘和截图验证只覆盖各自记录范围。 |
| [#4](https://github.com/WeOpen/WeGit/issues/4) | 最终同源码普通 Release 至少30次原始样本；P95 外壳≤500ms、Status≤300ms、Diff≤150ms、History≤300ms、外部刷新≤1000ms、启动≤1000ms；十万级内存/滚动、复杂图、磁盘 Diff、取消与 Instruments 热点证据仍待完成。既有超预算或29个有效样本的结果保持失败/不完整。 |
| [#5](https://github.com/WeOpen/WeGit/issues/5) | 真实 Pinentry/硬件密钥、其他凭据 Helper、GitLab 与未覆盖服务组合；逐项记录实际 Git/工具版本、权限失效、取消/关闭/切换、权威状态及草稿。隔离临时 OpenPGP 密钥、GitHub 传输与本地 bare remote 不能代替这些组合。真实远端 LFS 服务与本地指针夹具分别记录。 |
| [#6](https://github.com/WeOpen/WeGit/issues/6) | 专用受控验收机和可复现的整版验证环境；托管 VM 和当前开发机上的专项结果不能自动成为实体发布验收。 |
| [#7](https://github.com/WeOpen/WeGit/issues/7) | 干净、受保护 Mac 上的签名/公证、安装、更新、数据迁移和回退；固定源码、包摘要、保护状态及实际步骤。开发包构建不覆盖此门禁。 |
| [#9](https://github.com/WeOpen/WeGit/issues/9) | 真实外部 Beta 使用者、实际反馈与关键问题处理；自动化测试或生成制品不能作为用户反馈。 |

上述项目以 `not_planned` 归档，并在重新安排验收时恢复跟踪。v1.1/v1.1.1 历史总任务中的发布与整版验收依赖同样保留在此表；开发实现、已执行验证及延期验收分别记载。

## 当前可执行工作

- Interactive Rebase：完成六种动作、组合消息、edit 暂停与应用内 amend、冲突/重开恢复、取消和不确定回执。独立检查已执行75项；最终原生与性能结果按固定输入补充。
- Submodule/LFS：核对已集成实现、受信任原生方法、成功截图和 AX 附件。#92 在新实际截图/AX 审阅完成前保持开放。
- 所有 PR 通过当前 head 的 `PR policy`、`Repository policy`、`Native macOS`，处理未解决 review，再正常 squash。最终重新核对开发源码、制品来源及可执行回归。
- 已完成分支在源码/未推送提交/工作区状态核对后清理；网站等既有未提交工作保留。

本文件将补充最终 Issue/PR、原生测试计数、性能源输入及清理回执。当前待执行项不会因准备此记录被标为通过。
